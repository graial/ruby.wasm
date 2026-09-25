# frozen_string_literal: true

require "ruby_wasm/release_bundle/config_agreement"

RSpec.describe RubyWasm::ReleaseBundle::ConfigAgreement do
  FIXTURES = File.expand_path("../../fixtures/config_agreement", __dir__)

  # The published bundle's own files (…minimal-20260919.1, f744ba84…):
  # compile.raw.txt whole (baa93dcc…), and the three rbconfig.rb lines 6.5
  # reads, verbatim. The rest of rbconfig.rb is framing added below.
  RECIPE = File.binread(File.join(FIXTURES, "compile.raw.txt"))
  LINES = File.binread(File.join(FIXTURES, "rbconfig.lines"))

  def rbconfig(lines = LINES)
    "# encoding: ascii-8bit\nmodule RbConfig\n  CONFIG = {}\n" \
      "  CONFIG[\"DESTDIR\"] = DESTDIR\n#{lines}  CONFIG[\"EXEEXT\"] = \".wasm\"\nend\n"
  end

  def check(recipe: RECIPE, lines: LINES)
    described_class.new(compile_raw: recipe, rbconfig: rbconfig(lines))
  end

  def messages(**kw)
    check(**kw).refusals.map(&:message)
  end

  # Replace text inside one of the three published lines.
  def edit(key, from, to)
    line = LINES.lines.find { |l| l.include?("CONFIG[\"#{key}\"]") }
    raise "no #{key} line" unless line
    raise "#{from.inspect} not in #{key}" unless line.include?(from)
    LINES.sub(line, line.sub(from, to))
  end

  describe "the published bundle" do
    it "passes" do
      expect(check.refusals).to eq([])
    end

    it "reports what it examined, in the key it examined it in" do
      found = check.examined
      expect(found).to include(
        ["-D_WASI_EMULATED_SIGNAL", "CPPFLAGS"],
        ["-D_WASI_EMULATED_SIGNAL", "CFLAGS"],
        ["-DWASM_SETJMP_STACK_BUFFER_SIZE=24576", "configure_args"],
        ["WASI_SDK_PATH=/home/shared/external/ladder/main/build/toolchain/wasi-sdk-22.0", "configure_args"]
      )
      expect(found.size).to eq(4 * 2 + 3 + 1)
    end
  end

  describe "the four _WASI_EMULATED_* defines, in CPPFLAGS and CFLAGS" do
    it "refuses a define missing from CFLAGS, naming the define and the key" do
      m = messages(lines: edit("CFLAGS", " -D_WASI_EMULATED_SIGNAL", ""))
      expect(m.size).to eq(1)
      expect(m.first).to include("-D_WASI_EMULATED_SIGNAL", "CONFIG[\"CFLAGS\"]")
    end

    it "refuses a define missing from CPPFLAGS" do
      expect(messages(lines: edit("CPPFLAGS", "-D_WASI_EMULATED_MMAN ", "")).size).to eq(1)
    end

    # The trap 6.5's v2 wording closes: configure_args has its own CFLAGS=
    # word. Here the define is missing from CONFIG["CFLAGS"] and present in
    # configure_args' CFLAGS=. A check reading configure_args would pass.
    it "does not accept a define found in configure_args' CFLAGS= word instead" do
      lines = edit("CFLAGS", " -D_WASI_EMULATED_SIGNAL", "")
      lines = lines.sub("'CFLAGS='", "'CFLAGS=-D_WASI_EMULATED_SIGNAL'")
      expect(messages(lines: lines).size).to eq(1)
    end

    it "passes with configure_args' CFLAGS= empty, as published" do
      expect(LINES).to include("'CFLAGS='")
      expect(check.refusals).to eq([])
    end

    it "matches whole words, not substrings" do
      lines = edit("CFLAGS", "-D_WASI_EMULATED_SIGNAL", "-D_WASI_EMULATED_SIGNALS")
      expect(messages(lines: lines).size).to eq(1)
    end

    it "refuses a recipe that does not carry exactly four such defines" do
      recipe = RECIPE.gsub(" -D_WASI_EMULATED_GETPID", "")
      expect(messages(recipe: recipe).join).to include("four", "found 3")
    end
  end

  describe "the three WASM_*_STACK_BUFFER_SIZE values, in configure_args" do
    it "refuses a value configure was given differently" do
      lines = edit("configure_args", "-DWASM_FIBER_STACK_BUFFER_SIZE=24576", "-DWASM_FIBER_STACK_BUFFER_SIZE=16384")
      m = messages(lines: lines)
      expect(m.size).to eq(1)
      expect(m.first).to include("-DWASM_FIBER_STACK_BUFFER_SIZE=24576", "configure_args")
    end

    it "matches whole words: 245760 is not 24576" do
      lines = edit("configure_args", "-DWASM_SCAN_STACK_BUFFER_SIZE=24576", "-DWASM_SCAN_STACK_BUFFER_SIZE=245760")
      expect(messages(lines: lines).size).to eq(1)
    end

    it "refuses a recipe that does not carry exactly three" do
      recipe = RECIPE.sub(" -DWASM_SCAN_STACK_BUFFER_SIZE=24576", "")
      expect(messages(recipe: recipe).join).to include("three", "found 2")
    end

    it "refuses a recipe that gives one of them two values" do
      recipe = RECIPE.sub(" -U_FORTIFY_SOURCE", " -DWASM_SCAN_STACK_BUFFER_SIZE=8192 -U_FORTIFY_SOURCE")
      expect(messages(recipe: recipe).join).to include("WASM_SCAN_STACK_BUFFER_SIZE", "two values")
    end
  end

  describe "the wasi-sdk path, as the word WASI_SDK_PATH=<path> in configure_args" do
    SDK = "/home/shared/external/ladder/main/build/toolchain/wasi-sdk-22.0"

    it "refuses a different WASI_SDK_PATH" do
      lines = edit("configure_args", "'WASI_SDK_PATH=#{SDK}'", "'WASI_SDK_PATH=/opt/wasi-sdk-22.0'")
      m = messages(lines: lines)
      expect(m.size).to eq(1)
      expect(m.first).to include("WASI_SDK_PATH=#{SDK}")
    end

    it "matches whole words: wasi-sdk-22.0.1 is not wasi-sdk-22.0" do
      lines = edit("configure_args", "'WASI_SDK_PATH=#{SDK}'", "'WASI_SDK_PATH=#{SDK}.1'")
      expect(messages(lines: lines).size).to eq(1)
    end

    # CC= carries the path too, and is a different setting: finding the value
    # under a key that does not carry it is 6.5's own trap.
    it "does not accept the path found only in CC=" do
      lines = edit("configure_args", " 'WASI_SDK_PATH=#{SDK}'", "")
      expect(lines).to include("CC=#{SDK}/bin/clang")
      expect(messages(lines: lines).size).to eq(1)
    end

    it "refuses a recipe whose compiler is not <wasi-sdk>/bin/clang, rather than guessing" do
      recipe = RECIPE.sub("#{SDK}/bin/clang ", "/usr/bin/cc ")
      expect(messages(recipe: recipe).join).to include("/bin/clang")
    end

    it "refuses a recipe naming two such compilers" do
      recipe = RECIPE.sub(" -o main.o", " /opt/sdk/bin/clang -o main.o")
      expect(messages(recipe: recipe).join).to include("/bin/clang")
    end
  end

  describe "reading rbconfig.rb without executing it" do
    it "refuses a key 6.5 reads that is not assigned" do
      lines = LINES.lines.reject { |l| l.include?("CONFIG[\"CPPFLAGS\"]") }.join
      expect(messages(lines: lines).join).to include("CONFIG[\"CPPFLAGS\"]", "not assigned")
    end

    it "refuses a key assigned twice, rather than choosing one" do
      line = LINES.lines.find { |l| l.include?("CONFIG[\"CFLAGS\"]") }
      expect(messages(lines: LINES + line).join).to include("CONFIG[\"CFLAGS\"]", "twice")
    end

    it "refuses a key assigned something other than a string literal" do
      lines = LINES + "  CONFIG[\"CFLAGS\"] = ENV.fetch(\"CFLAGS\")\n"
      lines = lines.lines.reject { |l| l.include?("CONFIG[\"CFLAGS\"] = \"") }.join
      expect(messages(lines: lines).join).to include("CONFIG[\"CFLAGS\"]", "not a string literal")
    end

    it "does not execute the file" do
      lines = LINES + "  CONFIG[\"x\"] = (raise \"executed\")\n"
      expect { check(lines: lines).refusals }.not_to raise_error
    end
  end
end
