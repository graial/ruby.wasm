# frozen_string_literal: true

require "ruby_wasm/release_bundle/members"
require_relative "v3_fixtures"

RSpec.describe RubyWasm::ReleaseBundle::Members do
  # A bundle's hashes.txt paths and path keys, as an assembler following the
  # classification of the real line would write them.
  def bundle(profile)
    c = V3Fixtures.classify(profile)
    keys = {
      "wasi_sdk_path" => { "kind" => "root", "value" => V3Fixtures::WASI_SDK, "accounted" => "tools.wasi_sdk" },
      "wasi_vfs" => { "kind" => "token", "value" => V3Fixtures::WASI_VFS, "accounted" => "wasi-vfs/libwasi_vfs.a" }
    }
    c.root_keys.each { |name, k| keys[name] = { "kind" => "root", "value" => k["value"], "accounted" => "lib/#{name}" } }
    listed = %w[manifest.yml link.raw.txt compile.raw.txt prefix/lib/libruby-static.a wasi-vfs/libwasi_vfs.a]
    listed += c.build_members.map { |m| "build/#{m}" }
    c.root_keys.each { |name, k| listed += k["archives"].map { |a| "lib/#{name}/#{a}" } }
    [V3Fixtures.link_line(profile), keys, listed]
  end

  # What the producer writes: every -l the line's classification put in the
  # sysroot, here read off the line by what cannot be anywhere in a bundle.
  IN_BUNDLE = %w[ruby-static ssl crypto yaml z].freeze

  def stated(line)
    line.split(" ").grep(/\A-l./).map { |w| w.delete_prefix("-l") }.uniq - IN_BUNDLE
  end

  def check(line, keys, listed, sysroot: V3Fixtures::SYSROOT, libraries: stated(line))
    described_class.check(
      link_line: line, path_keys: keys, listed: listed,
      sysroot_libraries: libraries, sysroot_archives: sysroot
    )
  end

  def messages(r) = r.refusals.map(&:message)

  %w[minimal full].each do |p|
    it "#{p}: a bundle assembled from the line's classification passes" do
      expect(messages(check(*bundle(p)))).to be_empty
    end

    it "#{p}: passes from the bundle alone, on the manifest's sysroot_libraries" do
      expect(messages(check(*bundle(p), sysroot: nil))).to be_empty
    end

    it "#{p}: the producer's own classification gives those names, seven of them" do
      line, = bundle(p)
      expect(V3Fixtures.classify(p).sysroot).to eq(stated(line))
      expect(stated(line).length).to eq(7)
    end
  end

  it "minimal: build/ is exactly dmyext.o, the three enc/ objects and the archive" do
    _, _, listed = bundle("minimal")
    expect(listed.grep(%r{\Abuild/})).to contain_exactly(
      "build/dmyext.o", "build/enc/encinit.o", "build/enc/libenc.a", "build/enc/libtrans.a", "build/libruby-static.a"
    )
  end

  describe "a directory reference resolves exactly" do
    it "refuses a lib/<key>/ missing an archive the line resolves there: at least one is not enough" do
      line, keys, listed = bundle("full")
      out = messages(check(line, keys, listed - ["lib/openssl_lib/libcrypto.a"])).join
      expect(out).to include("-lcrypto resolves neither in the bundle nor in the sysroot")
    end

    it "sees that gap from the bundle alone: the name is not one the manifest says is the sysroot's" do
      line, keys, listed = bundle("full")
      r = check(line, keys, listed - ["lib/openssl_lib/libcrypto.a"], sysroot: nil)
      expect(r.refusals.map(&:clause)).to include("4.12")
    end

    it "refuses a lib/<key>/ holding an archive the line does not resolve there" do
      line, keys, listed = bundle("full")
      expect(messages(check(line, keys, listed + ["lib/openssl_lib/libunused.a"])).join).to include("libunused.a")
    end

    it "refuses a root key accounted anything but lib/<its name>" do
      line, keys, listed = bundle("full")
      keys["zlib_lib"]["accounted"] = "lib/z"
      expect(messages(check(line, keys, listed)).join).to include("accounted \"lib/z\"")
    end

    it "refuses a -L root on the line that is no root key" do
      line, keys, listed = bundle("full")
      keys.delete("yaml_lib")
      expect(messages(check(line, keys, listed)).join).to include("is no root path key")
    end

    it "refuses a file under lib/ that no root accounts for" do
      line, keys, listed = bundle("minimal")
      expect(messages(check(line, keys, listed + ["lib/stray/libx.a"])).join).to include("lib/stray/libx.a")
    end
  end

  describe "4.12 — sysroot_libraries is exactly what resolves nowhere in the bundle" do
    it "refuses a -l resolving nowhere that the list omits" do
      line, keys, listed = bundle("minimal")
      r = check(line, keys, listed, sysroot: nil, libraries: stated(line) - ["m"])
      expect(r.refusals.map(&:clause)).to eq(["4.12"])
    end

    it "refuses a listed name the line does not have" do
      line, keys, listed = bundle("minimal")
      r = check(line, keys, listed, sysroot: nil, libraries: stated(line) + ["pthread"])
      expect(r.refusals.map(&:clause)).to eq(["4.12"])
    end

    it "refuses a listed name that resolves in the bundle" do
      line, keys, listed = bundle("full")
      r = check(line, keys, listed, sysroot: nil, libraries: stated(line) + ["crypto"])
      expect(r.refusals.map(&:clause)).to eq(["4.12"])
    end

    it "refuses the right names in another order" do
      line, keys, listed = bundle("minimal")
      r = check(line, keys, listed, sysroot: nil, libraries: stated(line).reverse)
      expect(r.refusals.map(&:clause)).to eq(["4.12"])
    end

    it "refuses a field that is not a list" do
      line, keys, listed = bundle("minimal")
      r = check(line, keys, listed, sysroot: nil, libraries: nil)
      expect(r.refusals.map(&:clause)).to eq(["4.12"])
    end

    it "still has the producer's own listing refuse a listed name the sysroot lacks" do
      line, keys, listed = bundle("minimal")
      r = check(line, keys, listed, sysroot: V3Fixtures::SYSROOT - ["libm.a"])
      expect(r.refusals.map(&:clause)).to eq(["4.7"])
    end
  end

  describe "build/ holds exactly what the line names" do
    it "refuses a missing member" do
      line, keys, listed = bundle("full")
      expect(messages(check(line, keys, listed - ["build/ext/zlib/zlib.a"])).join).to include("build/ext/zlib/zlib.a")
    end

    it "refuses an extra member: v2's ext/extinit.o in a minimal bundle" do
      line, keys, listed = bundle("minimal")
      expect(messages(check(line, keys, listed + ["build/ext/extinit.o"])).join).to include("build/ext/extinit.o")
    end

    it "does not want main.o, which is the consumer's" do
      line, keys, listed = bundle("minimal")
      expect(messages(check(line, keys, listed + ["build/main.o"])).join).to include("build/main.o")
    end
  end
end
