# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require "ruby_wasm/release_bundle/capture"
require "ruby_wasm/release_bundle/preflight"
require "ruby_wasm/release_bundle/sibling"

# Each script, against a fake tree and a fake gh, with a case that should pass
# and a case that should fail.
RSpec.describe "the pipeline's scripts" do
  bin = File.expand_path("../../../bin", __dir__)
  lib = File.expand_path("../../../lib", __dir__)
  fixtures = File.expand_path("../../fixtures/v3", __dir__)

  around { |ex| Dir.mktmpdir("pipeline") { |d| @dir = File.realpath(d); ex.run } }

  def write(path, text = "", mode: nil)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    File.chmod(mode, path) if mode
    path
  end

  # Outside the bundle these specs run in: `bundle exec` would hand every script
  # a BUNDLE_GEMFILE, which is the very thing one of them refuses.
  define_method(:script) do |name, *args, env: {}, script_dir: bin|
    run = -> { Open3.capture3(env, RbConfig.ruby, File.join(script_dir, name), *args) }
    defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call
  end

  def git(dir, *args)
    out, err, st = Open3.capture3("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", *args)
    raise err unless st.success?
    out.strip
  end

  def fake_gh(body)
    fakes = File.join(@dir, "fakes")
    write(File.join(fakes, "gh"), "#!/bin/bash\n#{body}\n", mode: 0o755)
    { "PATH" => "#{fakes}:#{ENV.fetch("PATH")}" }
  end

  describe "bin/check-build-guards" do
    def checkout
      main = File.join(@dir, "reserved/main")
      FileUtils.mkdir_p(main)
      git(main, "init", "-q")
      git(main, "commit", "-q", "--allow-empty", "-m", "x")
      [main, git(main, "rev-parse", "HEAD")]
    end

    let(:clean) { { "WASI_SDK_PATH" => nil, "RUBY_WASM_ROOT" => nil } }

    it "passes a clean checkout at the Reserved path" do
      main, head = checkout
      out, err, st = script("check-build-guards", main, main, File.join(@dir, "release"), head, env: clean)
      expect(st).to be_success, out + err
      expect(out).to include("OK  guards")
    end

    it "refuses WASI_SDK_PATH" do
      main, head = checkout
      _o, err, st = script("check-build-guards", main, main, File.join(@dir, "release"), head, env: clean.merge("WASI_SDK_PATH" => "/x"))
      expect(st.exitstatus).to eq(1)
      expect(err).to include("WASI_SDK_PATH")
    end

    it "refuses a clone one directory deeper" do
      main, head = checkout
      _o, err, st = script("check-build-guards", main, File.join(@dir, "reserved"), File.join(@dir, "release"), head, env: clean)
      expect(st.exitstatus).to eq(1)
      expect(err).to include("not the Reserved path")
    end

    it "stops when it is not a repository" do
      _o, _e, st = script("check-build-guards", @dir, @dir, File.join(@dir, "release"), "a" * 40, env: clean)
      expect(st.exitstatus).to eq(2)
    end
  end

  describe "bin/compose-manifest-input" do
    def tree
      root = File.join(@dir, "main")
      write(File.join(root, "build/toolchain/binaryen/bin/wasm-opt"), "#!/bin/sh\necho 'wasm-opt version 108 (version_108)'\n", mode: 0o755)
      FileUtils.mkdir_p(File.join(root, "build/toolchain/wasi-sdk-22.0"))
      write(File.join(root, "build/checkouts/3.3/tool/wasm-clangw"), "wrapper\n")
      write(File.join(root, "build/some-target/wasi-vfs-0.6.2/libwasi_vfs.a"))
      root
    end

    it "writes what the Build's own tree says" do
      out_path = File.join(@dir, "input.yml")
      o, e, st = script("compose-manifest-input", tree, "3.3-some-target-minimal", "workflow", out_path)
      expect(st).to be_success, o + e
      input = YAML.safe_load_file(out_path)
      expect(input["tools"]["wasi_sdk"]).to eq("22.0")
      expect(input["tools"]["binaryen"]).to eq("wasm-opt version 108 (version_108)")
      expect(input["tools"]["cc_wrapper_sha256"]).to eq(Digest::SHA256.hexdigest("wrapper\n"))
      expect(input["capture"]).to eq("workflow")
    end

    it "stops when a tool is missing, having written nothing" do
      root = tree
      File.delete(File.join(root, "build/toolchain/binaryen/bin/wasm-opt"))
      out_path = File.join(@dir, "input.yml")
      _o, _e, st = script("compose-manifest-input", root, "3.3-some-target-minimal", "workflow", out_path)
      expect(st.exitstatus).to eq(2)
      expect(File.exist?(out_path)).to be(false)
    end
  end

  describe "bin/compare-reference" do
    before do
      @tree = File.join(@dir, "tree")
      write(File.join(@tree, "array.o"), "object\n")
      write(File.join(@tree, "ruby"), "binary\n")
      write(File.join(@tree, "install/usr/local/bin/ruby"), "binary\n")
      write(File.join(@tree, "Makefile"), "not selected\n")
      @ref = File.join(@dir, "ref")
      FileUtils.mkdir_p(@ref)
      %w[copy.build-ext-n.out tree.main-n.out copy.main-n.out].each { |n| FileUtils.cp(File.join(fixtures, "minimal", n), @ref) }
      lines = %w[./array.o ./install/usr/local/bin/ruby ./ruby].map do |p|
        "#{Digest::SHA256.file(File.join(@tree, p)).hexdigest}  #{p}\n"
      end
      write(File.join(@ref, "tree-before.sha256"), lines.join)
      selection = RubyWasm::ReleaseBundle::Capture.select(
        link_transcript: File.binread(File.join(@ref, "copy.build-ext-n.out")),
        main_transcript: File.binread(File.join(@ref, "tree.main-n.out")),
        copy_main_transcript: File.binread(File.join(@ref, "copy.main-n.out"))
      )
      @cap = File.join(@dir, "cap")
      write(File.join(@cap, "link.raw.txt"), selection.link_raw.to_s)
    end

    it "passes an exact reproduction, naming how much it compared" do
      out, err, st = script("compare-reference", @tree, @ref, @cap)
      expect(st).to be_success, out + err
      expect(out).to include("3 files in the reference, 3 in this Build")
    end

    it "says plainly when it compared nothing" do
      out, _e, st = script("compare-reference", @tree, "none", @cap)
      expect(st).to be_success
      expect(out).to include("no reference digests")
    end

    it "refuses a changed file and lists it" do
      File.write(File.join(@tree, "array.o"), "other\n")
      _o, err, st = script("compare-reference", @tree, @ref, @cap)
      expect(st.exitstatus).to eq(1)
      expect(err).to include("differs: ./array.o")
    end

    it "refuses an extra selected file" do
      write(File.join(@tree, "extra.a"), "x")
      _o, err, st = script("compare-reference", @tree, @ref, @cap)
      expect(st.exitstatus).to eq(1)
      expect(err).to include("only in this Build: ./extra.a")
    end

    it "refuses a different link recipe" do
      File.write(File.join(@cap, "link.raw.txt"), "something else\n")
      _o, err, st = script("compare-reference", @tree, @ref, @cap)
      expect(st.exitstatus).to eq(1)
      expect(err).to include("link recipe")
    end

    it "stops when the reference is missing, rather than comparing nothing" do
      _o, err, st = script("compare-reference", @tree, File.join(@dir, "absent"), @cap)
      expect(st.exitstatus).to eq(2)
      expect(err).to include("tree-before.sha256")
    end
  end

  describe "bin/pack-bundle" do
    Tag = "some-build-20261109.3"
    Stem = "ruby-some-build-lib-20261109.3"

    before do
      # pack-bundle runs the assemble-bundle beside it, so a copy with a
      # stand-in beside it needs no real capture.
      @bin = File.join(@dir, "bin")
      FileUtils.mkdir_p(@bin)
      FileUtils.cp(File.join(bin, "pack-bundle"), @bin)
      File.symlink(lib, File.join(@dir, "lib"))
      @input = write(File.join(@dir, "input.yml"), YAML.dump("build_name" => "some-build"))
    end

    def assembler(body) = write(File.join(@bin, "assemble-bundle"), "#{body}\n")

    good = 'd = ARGV[2]; require "fileutils"; FileUtils.mkdir_p(d + "/prefix/lib"); ' \
           'File.write(d + "/prefix/lib/libruby-static.a", "a"); FileUtils.mkdir_p(d + "/build"); ' \
           'File.symlink("../prefix/lib/libruby-static.a", d + "/build/libruby-static.a")'

    it "writes one top-level directory, keeps the symlink, and writes the sibling's exact form" do
      assembler(good)
      out = File.join(@dir, "out")
      o, e, st = script("pack-bundle", File.join(@dir, "cap"), @input, Tag, out, script_dir: @bin)
      expect(st).to be_success, o + e
      asset = File.join(out, "#{Stem}.tar.gz")
      listing, = Open3.capture2("tar", "tvzf", asset)
      expect(listing.lines.map { |l| l.split(" ")[5].split("/").first }.uniq).to eq([Stem])
      expect(listing).to match(%r{^l.*build/libruby-static\.a -> \.\./prefix/lib/libruby-static\.a})
      expect(File.binread("#{asset}.sha256")).to eq("#{Digest::SHA256.file(asset).hexdigest}  #{Stem}.tar.gz\n")
    end

    it "packs nothing when assembly fails" do
      assembler("exit 1")
      out = File.join(@dir, "out")
      _o, err, st = script("pack-bundle", File.join(@dir, "cap"), @input, Tag, out, script_dir: @bin)
      expect(st.exitstatus).to eq(1)
      expect(err).to include("nothing was packed")
      expect(Dir.glob("#{out}/*.tar.gz")).to be_empty
    end

    it "refuses a tag naming another Build" do
      assembler(good)
      _o, err, st = script("pack-bundle", File.join(@dir, "cap"), @input, "other-20261109.3", File.join(@dir, "out"), script_dir: @bin)
      expect(st.exitstatus).to eq(2)
      expect(err).to include("the tag names Build other")
    end
  end

  describe "bin/github-date" do
    it "prints GitHub's date, in UTC" do
      env = fake_gh(%q(printf 'HTTP/2.0 200 OK\r\nDate: Sun, 08 Nov 2026 16:58:12 GMT\r\n\r\n{}'))
      out, _e, st = script("github-date", "o/r", env: env)
      expect(st).to be_success
      expect(out.strip).to eq("20261108")
    end

    it "stops without a Date header, and prints no date" do
      env = fake_gh(%q(printf 'HTTP/2.0 200 OK\r\n\r\n{}'))
      out, _e, st = script("github-date", "o/r", env: env)
      expect(st.exitstatus).to eq(2)
      expect(out).to eq("")
    end
  end

  describe "bin/check-workflow-state" do
    it "passes the state asked for" do
      _o, _e, st = script("check-workflow-state", "o/r", "w.yml", "disabled_manually", env: fake_gh(%q(echo '{"state":"disabled_manually"}')))
      expect(st).to be_success
    end

    it "refuses any other state, naming it" do
      _o, err, st = script("check-workflow-state", "o/r", "w.yml", "disabled_manually", env: fake_gh(%q(echo '{"state":"active"}')))
      expect(st.exitstatus).to eq(1)
      expect(err).to include("is active")
    end

    it "treats another kind of disabled as another state" do
      _o, _e, st = script("check-workflow-state", "o/r", "w.yml", "disabled_manually", env: fake_gh(%q(echo '{"state":"disabled_fork"}')))
      expect(st.exitstatus).to eq(1)
    end

    it "stops when it could not be read" do
      _o, _e, st = script("check-workflow-state", "o/r", "w.yml", "disabled_manually", env: fake_gh("echo nope >&2; exit 1"))
      expect(st.exitstatus).to eq(2)
    end
  end

  describe "bin/publish-release" do
    Pub = "some-build-20261109.1"
    PubStem = "ruby-some-build-lib-20261109.1"

    def bundle(commit)
      out = File.join(@dir, "out")
      write(File.join(out, PubStem, "manifest.yml"), YAML.dump("release_commit" => commit))
      Open3.capture2("tar", "-czf", "#{PubStem}.tar.gz", PubStem, chdir: out)
      out
    end

    it "runs the command the preflight prints, targeting the bundle's commit" do
      log = File.join(@dir, "gh.log")
      env = fake_gh(%(printf '%s\\n' "$@" > #{log}))
      commit = "c" * 40
      out = bundle(commit)
      o, e, st = script("publish-release", Pub, out, env: env)
      expect(st).to be_success, o + e
      expect(File.readlines(log, chomp: true)).to eq(
        RubyWasm::ReleaseBundle::Preflight.publish_command(
          tag: Pub, dir: out, asset_name: "#{PubStem}.tar.gz", release_commit: commit
        ).drop(1)
      )
      expect(File.read(log)).to include("--latest=false", "--target\n#{commit}")
    end

    it "publishes nothing for a release_commit that is not a commit" do
      log = File.join(@dir, "gh.log")
      env = fake_gh(%(touch #{log}))
      _o, _e, st = script("publish-release", Pub, bundle("short"), env: env)
      expect(st.exitstatus).to eq(2)
      expect(File.exist?(log)).to be(false)
    end
  end

  describe "bin/ci-build-and-capture" do
    # A release checkout of stand-ins that log, and a stand-in bundle.
    before do
      @release = File.join(@dir, "release")
      @log = File.join(@dir, "log")
      %w[check-build-guards compose-manifest-input capture-recipes compare-reference].each do |name|
        write(File.join(@release, "bin", name), %(File.open(#{@log.inspect}, "a") { |f| f.puts(["#{name}", *ARGV].join(" ")) }\nexit((ENV["FAIL"] == "#{name}") ? 1 : 0)\n))
      end
      @env = {
        "PATH" => "#{File.dirname(write(File.join(@dir, "fakes/bundle"), %(#!/bin/bash\necho "bundle $*" >> #{@log}\necho "epoch ${SOURCE_DATE_EPOCH-unset}" >> #{@log}.epoch\n), mode: 0o755))}:#{ENV.fetch("PATH")}"
      }
      @checkout = File.join(@dir, "checkout")
      FileUtils.mkdir_p(@checkout)
      write(File.join(@release, "spec/fixtures/x/source-date-epoch"), "1794182400\n")
    end

    def run_it(reference = "none", env: {})
      Open3.capture3(
        @env.merge(env), File.join(bin_dir, "ci-build-and-capture"),
        @checkout, @release, @checkout, "3.3-a-b-c-minimal", "a" * 40, "workflow", reference,
        File.join(@dir, "cap"), File.join(@dir, "input.yml")
      )
    end

    define_method(:bin_dir) { bin }
    def log = File.readlines(@log, chomp: true).map { |l| l.split(" ").first(3).join(" ") }

    it "guards before building, and captures before comparing" do
      _o, e, st = run_it
      expect(st).to be_success, e
      expect(File.readlines(@log, chomp: true).map { |l| l.split(" ").first }).to eq(
        %w[bundle bundle check-build-guards bundle compose-manifest-input capture-recipes compare-reference]
      )
      expect(File.read(@log)).to include("bundle exec rake build:3.3-a-b-c-minimal\n")
    end

    it "derives the tree from the name" do
      run_it
      expect(File.read(@log)).to include("capture-recipes #{@checkout}/build/a-b-c/ruby-3.3-a-b-c-minimal ")
    end

    it "builds nothing when a guard fails" do
      _o, _e, st = run_it(env: { "FAIL" => "check-build-guards" })
      expect(st.success?).to be(false)
      expect(File.read(@log)).not_to include("rake build:")
      expect(File.read(@log)).not_to include("capture-recipes")
    end

    it "does not compare a Build whose capture stopped" do
      _o, _e, st = run_it(env: { "FAIL" => "capture-recipes" })
      expect(st.success?).to be(false)
      expect(File.read(@log)).not_to include("compare-reference")
    end

    it "builds under the reference's date, from the very first step" do
      _o, e, st = run_it("spec/fixtures/x")
      expect(st).to be_success, e
      expect(File.readlines("#{@log}.epoch", chomp: true).uniq).to eq(["epoch 1794182400"])
    end

    it "builds under no date with no reference, even one it inherited" do
      _o, e, st = run_it("none", env: { "SOURCE_DATE_EPOCH" => "1" })
      expect(st).to be_success, e
      expect(File.readlines("#{@log}.epoch", chomp: true).uniq).to eq(["epoch unset"])
    end

    it "builds nothing for a reference without the file" do
      File.delete(File.join(@release, "spec/fixtures/x/source-date-epoch"))
      _o, err, st = run_it("spec/fixtures/x")
      expect(st.exitstatus).to eq(2)
      expect(err).to include("source-date-epoch is not a file")
      expect(File.exist?(@log)).to be(false)
    end

    it "builds nothing for a file that is not a number" do
      write(File.join(@release, "spec/fixtures/x/source-date-epoch"), "yesterday\n")
      _o, err, st = run_it("spec/fixtures/x")
      expect(st.exitstatus).to eq(2)
      expect(err).to include("not a number of seconds")
      expect(File.exist?(@log)).to be(false)
    end

    it "resolves a reference inside the release checkout, and passes none as it is" do
      run_it("spec/fixtures/x")
      expect(File.read(@log)).to include("compare-reference #{@checkout}/build/a-b-c/ruby-3.3-a-b-c-minimal #{@release}/spec/fixtures/x ")
      File.delete(@log)
      run_it("none")
      expect(File.read(@log)).to include("ruby-3.3-a-b-c-minimal none ")
    end
  end
end
