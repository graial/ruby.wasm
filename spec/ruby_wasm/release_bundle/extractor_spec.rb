# frozen_string_literal: true

require "open3"
require "pathname"
require "tmpdir"
require "ruby_wasm/release_bundle/extractor"

RSpec.describe RubyWasm::ReleaseBundle::Extractor do
  subject(:extractor) { described_class.new(source: "recipe.txt") }

  def trace(text)
    extractor.extract(text)
  end

  describe "embedded paths (5.3)" do
    it "takes a path that is the whole word" do
      expect(trace("/a/b\n")).to eq(["/a/b"])
    end

    it "takes a path embedded after a flag" do
      expect(trace("-I/a/b\n")).to eq(["/a/b"])
    end

    it "takes a path after a long option name" do
      expect(trace("-isystem/a/b --sysroot=/c/d\n")).to eq(%w[/a/b /c/d])
    end

    it "takes a path after a comma or a redirect" do
      expect(trace("-Wl,-rpath,/a/b 2>/dev/null\n")).to eq(%w[/a/b /dev/null])
    end

    it "ignores relative words" do
      expect(trace("-L. -lruby-static main.o ext/extinit.o\n")).to eq([])
    end

    it "ignores a relative word whose separator sits mid-word" do
      # The maximal "/"-initial substring of ext/extinit.o is /extinit.o. That
      # word is on every link recipe, so admitting it would stop every capture.
      expect(trace("ext/extinit.o enc/libenc.a\n")).to eq([])
    end

    it "ignores a relative include directory" do
      # -I.ext/... is an option whose argument is relative. The "." is what
      # separates it from -I/opt/include: an option name is dashes then
      # letters only.
      expect(trace("-I.ext/include/wasm32-wasi -I../checkouts/3.3/include\n")).to eq([])
    end

    it "takes every path in a word, not only the first" do
      expect(trace(%(-DX="/a":"/b"\n))).to eq(%w[/a /b])
    end

    it "walks left to right within a line" do
      expect(trace("/z -I/a /m\n")).to eq(%w[/z /a /m])
    end

    it "walks lines in order and does not deduplicate" do
      expect(trace("/z\n/a\n/z\n")).to eq(%w[/z /a /z])
    end
  end

  describe "the terminator applies before maximality (5.3)" do
    it "ends a path at a double quote rather than absorbing it" do
      expect(trace(%(-DFOO="/a/b"\n))).to eq(["/a/b"])
    end

    it "ends a path at a single quote" do
      expect(trace(%(-DFOO='/a/b'\n))).to eq(["/a/b"])
    end

    it "ends a path at the other kind of quote inside a quoted word" do
      # Word splitting uses matching quotes; path termination uses the next
      # quote of either kind. The two rules differ deliberately.
      expect(trace(%(-DX='/a"b'\n))).to eq(["/a"])
    end
  end

  describe "stop conditions (5.3)" do
    it "stops on whitespace inside a quoted path" do
      expect { trace(%(-DFOO="/a b/c"\n)) }.to raise_error(
        RubyWasm::ReleaseBundle::ExtractionError,
        /path contains whitespace/
      )
    end

    it "stops on a colon inside a path rather than guessing" do
      # -Wl,-rpath,/a/b:/c/d anchors at the comma and runs to end of word, so
      # the value would be /a/b:/c/d — one value that is two paths, which a
      # root key still matches by prefix. Stopping is the only loud option.
      expect { trace("-Wl,-rpath,/a/b:/c/d\n") }.to raise_error(
        RubyWasm::ReleaseBundle::ExtractionError,
        /contains :/
      )
    end

    it "stops on a comma inside a path" do
      # The likeliest member of the class: --whole-archive around an archive
      # is an ordinary link-line shape, and the value would otherwise run from
      # the path into the flag that follows it.
      expect {
        trace("-Wl,--whole-archive,/a/lib.a,--no-whole-archive\n")
      }.to raise_error(
        RubyWasm::ReleaseBundle::ExtractionError,
        /contains ,/
      )
    end

    it "stops on an equals inside a path" do
      # -fdebug-prefix-map=OLD=NEW is two paths in one value.
      expect { trace("-fdebug-prefix-map=/a=/b\n") }.to raise_error(
        RubyWasm::ReleaseBundle::ExtractionError,
        /contains =/
      )
    end

    it "stops for the class rather than for a character" do
      # Every anchor that is not also a terminator, stated once.
      described_class::SEPARATORS.each do |char|
        expect { trace("-I/a#{char}b\n") }.to raise_error(
          RubyWasm::ReleaseBundle::ExtractionError,
          /anchors a path without terminating one/
        ), "expected #{char.inspect} to stop the release"
      end
    end

    it "does not stop on a colon outside any path" do
      expect(trace("/t/bin/wasm-opt -o ruby ruby ; :\n")).to eq(
        ["/t/bin/wasm-opt"]
      )
    end

    it "keeps the colon anchor, which a quote terminator cannot replace" do
      # The character before /b is the colon, not the quote, so without the
      # colon in the anchor set this path is dropped silently.
      expect(trace(%(-DX="/a":/b\n))).to eq(%w[/a /b])
    end

    it "stops on a line that does not tokenize" do
      expect { trace(%(-DFOO="/a/b\n)) }.to raise_error(
        RubyWasm::ReleaseBundle::ExtractionError,
        /does not tokenize/
      )
    end

    it "carries the position as data rather than only in the message" do
      trace(%(x "/a b"\n))
    rescue RubyWasm::ReleaseBundle::ExtractionError => e
      aggregate_failures do
        expect(e.source).to eq("recipe.txt")
        expect(e.line_number).to eq(1)
        expect(e.column).to eq(4)
        expect(e.word).to eq("/a b")
      end
    end

    it "raises rather than returning a partial trace" do
      expect { trace(%(/first\n-DFOO="/a b"\n)) }.to raise_error(
        RubyWasm::ReleaseBundle::ExtractionError
      )
    end
  end

  describe "shapes the superseded extract.pl got wrong (ADR-0031)" do
    it "finds a path after a comma-separated linker flag" do
      expect(trace("-Wl,-rpath,/a/b\n")).to eq(["/a/b"])
    end

    it "finds a path after an = rather than stopping" do
      expect(trace("--sysroot=/a/b\n")).to eq(["/a/b"])
    end

    it "does not stop on a quote in a word containing no path" do
      expect(trace(%(-DRUBY_PLATFORM="wasm32-wasi"\n))).to eq([])
    end
  end

  describe "captured recipe shapes (5.1)" do
    it "survives make's trailing semicolon and bare colon" do
      line = "/t/binaryen/bin/wasm-opt -o ruby ruby --pass-arg=x ; :\n"
      expect(trace(line)).to eq(["/t/binaryen/bin/wasm-opt"])
    end

    it "takes a redirect target, leaving 6.2 to judge it" do
      expect(trace("cc -o main.o 2>/dev/null\n")).to eq(["/dev/null"])
    end
  end

  describe "shed paths (5.3)" do
    def shed(text)
      extractor.shed(text)
    end

    it "sheds nothing from a word whose every path was admitted" do
      expect(shed("-I/a/b /c/d\n")).to be_empty
    end

    it "sheds the declined slash of a relative word, with its context" do
      # The shapes 5.3 names: ext/extinit.o is on every link recipe, and its
      # maximal "/"-initial substring is /extinit.o.
      entries = shed("ext/extinit.o\n")
      expect(entries.map(&:would_have_read)).to eq(["/extinit.o"])
      expect(entries.first.word).to eq("ext/extinit.o")
    end

    it "sheds each declined slash separately rather than summarising a run" do
      # -I.ext/include/wasm32-wasi is 5.3's other named shape. The anchor rule
      # decides per "/", so a list that reported only the outermost would be a
      # summary a reader has to un-summarise before it can be checked.
      expect(shed("-I.ext/include/wasm32-wasi\n").map(&:would_have_read)).to eq(
        %w[/include/wasm32-wasi /wasm32-wasi]
      )
    end

    it "does not shed the interior slashes of an admitted path" do
      # Without this the list is dominated by the insides of paths that were
      # read, which is noise rather than a reading of the anchor set.
      expect(shed("/a/b/c/d\n")).to be_empty
    end

    it "keeps admitting a later anchored slash inside a declined run" do
      # foo/bar=/baz sheds /bar=/baz and admits /baz. A shed walk that jumped to
      # the terminator would swallow the admitted one — a path shed by the shed
      # list itself.
      expect(trace("foo/bar=/baz\n")).to eq(["/baz"])
      expect(shed("foo/bar=/baz\n").map(&:would_have_read)).to eq(["/bar=/baz"])
    end

    it "reports the position in the same shape a refusal does" do
      entry = shed("cc ext/extinit.o\n").first
      expect(entry.at).to eq("recipe.txt:1:7")
    end

    it "raises exactly where extract raises" do
      # A shed list from a recipe that does not extract would be a partial
      # reading presented as a complete one.
      expect { shed(%(-DFOO="/a b"\n)) }.to raise_error(
        RubyWasm::ReleaseBundle::ExtractionError
      )
    end

    it "leaves the trace untouched" do
      text = "-I.ext/include/wasm32-wasi -I/a/b ext/extinit.o\n"
      expect(trace(text)).to eq(["/a/b"])
    end
  end

  describe ".shed_file" do
    it "names the file in the position" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "link.raw.txt")
        File.write(path, "ext/extinit.o\n")
        expect(described_class.shed_file(path).first.source).to eq(path)
      end
    end
  end


  describe ".extract_file" do
    it "names the file in the position" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "compile.raw.txt")
        File.write(path, %(-DFOO="/a b"\n))
        expect { described_class.extract_file(path) }.to raise_error(
          an_object_having_attributes(source: path, line_number: 1)
        )
      end
    end
  end
end

RSpec.describe "bin/extract-paths" do
  # Located by ascending to the repository root rather than by counting "..",
  # so the spec survives being moved. A wrong path here exits 1 with an empty
  # stdout, which is indistinguishable from the extractor refusing to read.
  def bin
    root =
      Pathname(__dir__).ascend.find { |dir| (dir / "ruby_wasm.gemspec").file? }
    raise "repository root not found above #{__dir__}" if root.nil?

    path = root / "bin" / "extract-paths"
    raise "not found: #{path}" unless path.file?

    # A truncated or library-only script runs, prints nothing and exits 0,
    # which is indistinguishable from four unrelated expectation failures.
    # Name it here instead.
    # UTF-8 explicitly, not the platform default. Ruby source is UTF-8 whatever
    # the locale says, but Pathname#read is not: under LANG=C the default
    # external encoding is US-ASCII and this raises on the first em dash in a
    # comment — turning a correct script into nine unrelated failures, which is
    # the outcome this guard exists to prevent.
    body = path.read(encoding: Encoding::UTF_8)

    if body.strip.empty?
      raise "empty: #{path}"
    elsif !body.include?("ARGV")
      raise "#{path} has no command line body (#{body.bytesize} bytes)"
    end

    path.to_s
  end

  # stderr is captured rather than discarded. A check that cannot say what it
  # examined reports the filter instead of the failure.
  def run(*args)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, bin, *args)
    [stdout, stderr, status.exitstatus]
  end

  def with_recipe(contents)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "recipe.txt")
      File.write(path, contents)
      yield path
    end
  end

  it "writes the trace and exits 0" do
    with_recipe("-I/a/b /c/d\n") do |path|
      stdout, stderr, code = run(path)
      expect(code).to eq(0), "exited #{code}, stderr: #{stderr}"
      expect(stdout).to eq("/a/b\n/c/d\n")
    end
  end

  it "writes nothing to stdout and exits 1 when it cannot read" do
    with_recipe(%(/first\n-DFOO="/a b"\n)) do |path|
      stdout, stderr, code = run(path)
      expect(code).to eq(1), "exited #{code}, stderr: #{stderr}"
      expect(stdout).to be_empty
      expect(stderr).to include("path contains whitespace")
    end
  end

  it "writes the shed list in three tab-separated columns under --shed" do
    with_recipe("ext/extinit.o -I/a/b\n") do |path|
      stdout, stderr, code = run("--shed", path)
      expect(code).to eq(0), "exited #{code}, stderr: #{stderr}"
      expect(stdout).to eq("#{path}:1:4\t/extinit.o\text/extinit.o\n")
    end
  end

  it "exits 0 under --shed even when the list is empty" do
    # A status that varied with the list would be a verdict this program has no
    # standing to give: 5.3 leaves judging a declined slash to a human.
    with_recipe("-I/a/b\n") do |path|
      stdout, stderr, code = run("--shed", path)
      expect(code).to eq(0), "exited #{code}, stderr: #{stderr}"
      expect(stdout).to be_empty
    end
  end

  it "writes nothing to stdout and exits 1 when --shed cannot read" do
    with_recipe(%(ext/extinit.o\n-DFOO="/a b"\n)) do |path|
      stdout, stderr, code = run("--shed", path)
      expect(code).to eq(1), "exited #{code}, stderr: #{stderr}"
      expect(stdout).to be_empty
      expect(stderr).to include("path contains whitespace")
    end
  end

  it "does not emit a trace under --shed" do
    # The two outputs must not be confusable: 6.2 consumes a trace and nothing
    # consumes a shed list.
    with_recipe("-I/a/b\n") do |path|
      shed_out, = run("--shed", path)
      trace_out, = run(path)
      expect(trace_out).to eq("/a/b\n")
      expect(shed_out).not_to include("/a/b\n")
    end
  end

  it "exits 2 on a missing file" do
    stdout, stderr, code = run("/nonexistent/recipe.txt")
    expect(code).to eq(2), "exited #{code}, stderr: #{stderr}"
    expect(stdout).to be_empty
  end

  it "exits 2 on wrong usage" do
    stdout, stderr, code = run
    expect(code).to eq(2), "exited #{code}, stderr: #{stderr}"
    expect(stdout).to be_empty
    expect(stderr).to include("usage:")
  end
end