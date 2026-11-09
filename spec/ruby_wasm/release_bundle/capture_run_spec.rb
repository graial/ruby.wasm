# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require "ruby_wasm/release_bundle/capture_run"
require "ruby_wasm/release_bundle/assembly"

# The one behavioural spec ADR-0068 asks for. It builds a miniature make tree
# and needs only GNU make. The tree reproduces F3's mechanism: build-ext's
# recipe names $(MAKE), so it runs even under -n and deletes a file. It also
# reproduces F1's shape: the top-level `ruby` target relinks without the
# sub-make's variables. llvm-nm and wasm-opt are stand-ins that print what the
# files hold.
RSpec.describe RubyWasm::ReleaseBundle::CaptureRun do
  around do |ex|
    Dir.mktmpdir("capture-run") do |dir|
      @dir = dir
      ex.run
    end
  end

  def write(path, text, mode: 0o644)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    File.chmod(mode, path)
  end

  def tree = File.join(@dir, "build/tree")
  def sdk = File.join(@dir, "toolchain/wasi-sdk")
  def wrapper = File.join(@dir, "checkout/tool/wasm-clangw")
  def wasm_opt = File.join(@dir, "toolchain/binaryen/bin/wasm-opt")

  # delete: what build-ext's $(MAKE) line removes. Relative lands in whichever
  # tree make runs in; absolute reaches the real tree from the copy.
  def build(delete: "ext/stamp.o")
    checkout = File.join(@dir, "checkout")
    write(wrapper, "#!/bin/sh\nexec \"$@\"\n", mode: 0o755)
    Open3.capture3("git", "init", "-q", checkout)
    Open3.capture3("git", "-C", checkout, "add", "-A")
    Open3.capture3("git", "-C", checkout, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x")

    write("#{sdk}/bin/clang", "#!/bin/sh\n", mode: 0o755)
    write("#{sdk}/bin/llvm-nm", "#!/bin/sh\n[ \"$1\" = --defined-only ] && cat \"$2\"\n", mode: 0o755)
    write("#{sdk}/share/wasi-sysroot/lib/wasm32-wasi/libc.a", "")
    write(wasm_opt, "#!/bin/sh\ncat \"$1\"\n", mode: 0o755)

    cc = "#{wrapper} #{sdk}/bin/clang"
    write("#{tree}/Makefile", <<~MK)
      ruby: main.o
      \t#{cc} -L. main.o -lruby-static -o ruby
      main.o: main.c
      \t#{cc} -c -O3 -o main.o main.c
      build-ext:
      \trm -f #{delete}; $(MAKE) -f exts.mk ruby EXTOBJS="dmyext.o enc/libenc.a"
    MK
    write("#{tree}/exts.mk", <<~MK)
      ruby: FORCE
      \t#{cc} -L. main.o $(EXTOBJS) -lruby-static -lc -Xlinker --stack-first -o ruby
      \t#{wasm_opt} --asyncify -g -o ruby ruby
      FORCE:
    MK
    write("#{tree}/main.c", "int main(void){return 0;}\n")
    write("#{tree}/main.o", "")
    write("#{tree}/dmyext.o", "00000001 T Init_ext\n")
    write("#{tree}/enc/libenc.a", "00000001 T Init_utf_16le\n")
    write("#{tree}/libruby-static.a", "00000001 T Init_Array\n00000002 W Init_extra_exts\n")
    write("#{tree}/ext/stamp.o", "")
    write("#{tree}/ruby", "0:_start\n1:Init_ext\n2:Init_utf_16le\n3:Init_Array\n4:Init_extra_exts\n")
    old = Time.now - 3600
    Dir.glob("**/*", base: tree).each { |f| File.utime(old, old, File.join(tree, f)) }
    File.utime(Time.now, Time.now, File.join(tree, "ruby"))
    checkout
  end

  def input
    {
      "path_keys" => {
        "wasi_sdk_path" => { "kind" => "root", "value" => sdk, "accounted" => "tools.wasi_sdk" },
        "cc_wrapper" => { "kind" => "token", "value" => wrapper, "accounted" => "tools.cc_wrapper_sha256" },
        "wasm_opt" => { "kind" => "token", "value" => wasm_opt, "accounted" => "tools.binaryen" }
      }
    }
  end

  def snapshot
    Dir.glob("**/*", base: tree).sort.select { |f| File.file?(File.join(tree, f)) }.to_h { |f| [f, File.binread(File.join(tree, f))] }
  end

  def capture(checkout)
    described_class.new(tree: tree, checkout: checkout, capture_dir: File.join(@dir, "cap"), input: input)
  end

  it "selects the sub-make's line, not the top-level relink, and leaves the real tree byte-identical" do
    skip "GNU make is not on PATH" unless system("make --version > /dev/null 2>&1")
    checkout = build
    before = snapshot
    run = capture(checkout)

    expect(run.run).to be(true), run.refusals.map(&:message).join("\n")
    expect(snapshot).to eq(before)
    expect(File).to exist(File.join(tree, "ext/stamp.o"))
    expect(File).not_to exist("#{tree}.capture-copy")

    link = File.read(File.join(@dir, "cap/link.raw.txt")).lines
    expect(link.first).to include("main.o dmyext.o enc/libenc.a -lruby-static")
    expect(link.last).to start_with("#{wasm_opt} ")
    meta = JSON.parse(File.read(File.join(@dir, "cap/capture.json")))
    expect(meta["build_members"]).to eq(%w[dmyext.o enc/libenc.a libruby-static.a])
    expect(meta["extensions"]).to eq([])
  end

  it "refuses, and keeps the copy, when build-ext reaches the real tree from the copy" do
    skip "GNU make is not on PATH" unless system("make --version > /dev/null 2>&1")
    checkout = build(delete: File.join(@dir, "build/tree/ext/stamp.o"))
    run = capture(checkout)

    expect(run.run).to be(false)
    expect(run.refusals.map(&:message).join).to include("the real Build tree changed", "ext/stamp.o")
    expect(File).to exist("#{tree}.capture-copy")
    expect(File).not_to exist(File.join(@dir, "cap/link.raw.txt"))
  end

  it "refuses before copying when the copy's path is taken" do
    checkout = build
    FileUtils.mkdir_p("#{tree}.capture-copy")
    run = capture(checkout)
    expect(run.run).to be(false)
    expect(run.refusals.map(&:clause)).to eq(["6.1"])
  end

  describe "assembling from the capture" do
    def assemble(input_extra = {})
      checkout = build
      write("#{tree}/install/usr/local/lib/libruby-static.a", File.read("#{tree}/libruby-static.a"))
      write("#{tree}/install/usr/local/lib/ruby/3.3.0/wasm32-wasi/rbconfig.rb", "# rbconfig\n")
      vfs = File.join(@dir, "wasi-vfs/libwasi_vfs.a")
      write(vfs, "")
      release = File.join(@dir, "release")
      Open3.capture3("git", "init", "-q", release)
      Open3.capture3("git", "-C", release, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "r")
      expect(capture(checkout).run).to be(true)
      keys = input["path_keys"].merge(
        "ruby_src" => { "kind" => "root", "value" => File.join(@dir, "checkout"), "accounted" => nil },
        "wasi_vfs" => { "kind" => "token", "value" => vfs, "accounted" => "wasi-vfs/libwasi_vfs.a" }
      )
      manifest_input = {
        "build_name" => "3.3-wasm32-unknown-icp-minimal", "capture" => "manual",
        "tools" => { "wasi_sdk" => "22.0" }, "path_keys" => keys
      }.merge(input_extra)
      RubyWasm::ReleaseBundle::Assembly.new(
        capture_dir: File.join(@dir, "cap"), input: manifest_input,
        dest: File.join(@dir, "bundle"), release_checkout: release
      )
    end

    it "names every member from the classification, links the archive, and passes the member check" do
      skip "GNU make is not on PATH" unless system("make --version > /dev/null 2>&1")
      asm = assemble
      expect(asm.run).to be(true), asm.refusals.map(&:message).join("\n")
      bundle = File.join(@dir, "bundle")
      expect(File.readlink(File.join(bundle, "build/libruby-static.a"))).to eq("../prefix/lib/libruby-static.a")
      listed = File.readlines(File.join(bundle, "hashes.txt"), chomp: true).map { |l| l.split("  ", 2)[1] }
      expect(listed.grep(%r{\Abuild/})).to eq(%w[build/dmyext.o build/enc/libenc.a build/libruby-static.a])
      expect(listed).to eq(listed.sort)
      expect(listed).not_to include("hashes.txt")
      m = YAML.safe_load_file(File.join(bundle, "manifest.yml"))
      expect(m["contract_version"]).to eq(3)
      expect(m["extensions"]).to eq([])
      expect(m["sysroot_libraries"]).to eq(JSON.parse(File.read(File.join(@dir, "cap/capture.json"))).fetch("sysroot"))
      expect(m["release_commit"]).to match(/\A\h{40}\z/)
      expect(m["transcript_cwd"]).to eq(tree)
    end

    it "has bin/check-manifest.rb accept the field, and stop on a bundle without it" do
      skip "GNU make is not on PATH" unless system("make --version > /dev/null 2>&1")
      asm = assemble
      expect(asm.run).to be(true), asm.refusals.map(&:message).join("\n")
      bundle = File.join(@dir, "bundle")
      script = File.expand_path("../../../bin/check-manifest.rb", __dir__)
      # This miniature satisfies 4.12 and not the path keys of 6.2-6.3, so the
      # script's other stops are expected; 4.12 is the one being watched.
      out, err, = Open3.capture3(RbConfig.ruby, script, bundle)
      expect(out + err).not_to include("4.12")
      manifest = File.join(bundle, "manifest.yml")
      File.write(manifest, File.read(manifest).sub(/^sysroot_libraries:.*?(?=^\s*$)/m, ""))
      out, err, st = Open3.capture3(RbConfig.ruby, script, bundle)
      expect(st).not_to be_success
      expect(out + err).to include("4.12 the manifest has no sysroot_libraries")
    end

    it "refuses an input that states a field the bundle derives" do
      skip "GNU make is not on PATH" unless system("make --version > /dev/null 2>&1")
      asm = assemble("extensions" => ["zlib"])
      expect { asm.run }.to raise_error(RubyWasm::ReleaseBundle::Assembly::Stop, /derived field/)
    end

    it "refuses a destination that exists (2.5)" do
      skip "GNU make is not on PATH" unless system("make --version > /dev/null 2>&1")
      asm = assemble
      FileUtils.mkdir_p(File.join(@dir, "bundle"))
      expect { asm.run }.to raise_error(RubyWasm::ReleaseBundle::Assembly::Stop, /already exists/)
    end
  end
end
