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

  def check(line, keys, listed, sysroot: V3Fixtures::SYSROOT)
    described_class.check(link_line: line, path_keys: keys, listed: listed, sysroot_archives: sysroot)
  end

  def messages(r) = r.refusals.map(&:message)

  %w[minimal full].each do |p|
    it "#{p}: a bundle assembled from the line's classification passes" do
      expect(messages(check(*bundle(p)))).to be_empty
    end

    it "#{p}: passes from the bundle alone, noting the -l it can only presume are the sysroot's" do
      r = check(*bundle(p), sysroot: nil)
      expect(messages(r)).to be_empty
      expect(r.notes.join("\n")).to include("-lm resolves to nothing in the bundle")
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

    it "cannot see that gap from the bundle alone, and says so as a presumption, not a pass" do
      line, keys, listed = bundle("full")
      r = check(line, keys, listed - ["lib/openssl_lib/libcrypto.a"], sysroot: nil)
      expect(messages(r)).to be_empty
      expect(r.notes.join).to include("-lcrypto resolves to nothing in the bundle")
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
