# frozen_string_literal: true

require "ruby_wasm/release_bundle/agreement"
require_relative "v3_fixtures"

RSpec.describe RubyWasm::ReleaseBundle::Agreement do
  def check(profile, symbols: nil, function_map: nil, extinit_c: :fixture, line: nil)
    c = line ? V3Fixtures.classify(profile, line: line) : V3Fixtures.classify(profile)
    described_class.check(
      inputs: c.inputs,
      ext_archives: c.ext_archives,
      words: c.words,
      symbols: symbols || V3Fixtures.symbols(profile),
      function_map: function_map || described_class.parse_function_map(V3Fixtures.function_map(profile)),
      extinit_c: extinit_c == :fixture ? V3Fixtures.extinit_c(profile) : extinit_c
    )
  end

  def messages(r) = r.refusals.map(&:message)

  describe "parsers" do
    it "reads the name section's names, and finds 154 and 217 Init_ functions" do
      %w[minimal full].zip([154, 217]).each do |p, n|
        names = described_class.parse_function_map(V3Fixtures.function_map(p))
        expect(names.count { |x| x.start_with?("Init_") }).to eq(n)
      end
    end

    it "reads llvm-nm --defined-only output, skipping member headers" do
      out = "\narray.o:\n00006f35 T Init_Array\n000003e0 d Init_builtin_array.array_table\n\nruby.o:\n000006d2 W Init_extra_exts\n"
      expect(described_class.parse_nm(out)).to eq([%w[T Init_Array], %w[d Init_builtin_array.array_table], %w[W Init_extra_exts]])
    end

    it "reads extinit.c's calls in file order, and not its #define" do
      calls = described_class.parse_extinit(V3Fixtures.extinit_c("full").to_s)
      expect(calls.length).to eq(26)
      expect(calls.first).to eq(%w[Init_bigdecimal bigdecimal])
      expect(calls).to include(%w[Init_json_ext_generator json/ext/generator])
    end
  end

  describe "the real Builds agree with their lines" do
    it "minimal: every initialiser accounted for, no extensions" do
      r = check("minimal")
      expect(messages(r)).to be_empty
      expect(r.extensions).to eq([])
    end

    it "full: every initialiser accounted for, 26 extensions in extinit.c's order" do
      r = check("full")
      expect(messages(r)).to be_empty
      expect(r.extensions.length).to eq(26)
      expect(r.extensions.first(3)).to eq(%w[bigdecimal cgi/escape continuation])
      expect(r.extensions).to eq(described_class.parse_extinit(V3Fixtures.extinit_c("full").to_s).map(&:last))
    end
  end

  describe "an Init_ in ruby must be defined by a file on the line" do
    it "counts a weak definition: ruby.c's empty Init_extra_exts is what links" do
      strong_only = V3Fixtures.symbols("minimal").transform_values { |s| s.select { |(t, _)| t != "W" } }
      expect(messages(check("minimal", symbols: strong_only)).join).to include("Init_extra_exts")
    end

    it "refuses an initialiser that came from a file the line does not name" do
      map = described_class.parse_function_map(V3Fixtures.function_map("minimal")) + ["Init_zlib"]
      expect(messages(check("minimal", function_map: map)).join).to include("Init_zlib")
    end

    it "refuses an input with no symbol table rather than reading it as empty" do
      syms = V3Fixtures.symbols("minimal").reject { |k, _| k == "enc/libenc.a" }
      expect(messages(check("minimal", symbols: syms)).join).to include("no symbol table read")
    end

    it "refuses an empty function map: no name section is not evidence of no initialisers" do
      expect(messages(check("minimal", function_map: [])).join).to include("no name section")
    end
  end

  describe "encodings agree in both directions" do
    it "refuses enc/libenc.a on the line without Init_utf_16le in ruby" do
      map = described_class.parse_function_map(V3Fixtures.function_map("minimal")) - ["Init_utf_16le"]
      expect(messages(check("minimal", function_map: map)).join).to include("Init_utf_16le is not in ruby")
    end

    it "refuses Init_utf_16le in ruby without enc/libenc.a on the line" do
      line = V3Fixtures.link_line("minimal").sub(" enc/libenc.a", "")
      expect(messages(check("minimal", line: line)).join).to include("enc/libenc.a is not on the link recipe")
    end
  end

  describe "extensions match one to one" do
    it "is not fooled by basenames: 9 of the 26 do not follow them" do
      calls = described_class.parse_extinit(V3Fixtures.extinit_c("full").to_s)
      c = V3Fixtures.classify("full")
      basename = c.ext_archives.map { |a| "Init_#{File.basename(a, ".a")}" }
      expect(calls.map(&:first) - basename).to eq(
        %w[Init_cgi_escape Init_digest_bubblebabble Init_digest_md5 Init_digest_rmd160
           Init_digest_sha1 Init_digest_sha2 Init_json_ext_generator Init_json_ext_parser
           Init_rbconfig_sizeof]
      )
      expect(messages(check("full"))).to be_empty
    end

    it "refuses an extinit.c initialiser no archive on the line defines" do
      line = V3Fixtures.link_line("full").sub(" ext/zlib/zlib.a", "")
      expect(messages(check("full", line: line)).join).to include("Init_zlib (ext/extinit.c) is defined by 0 ext archive(s)")
    end

    it "refuses an archive defining none of extinit.c's initialisers (a swap)" do
      text = V3Fixtures.extinit_c("full").to_s.sub('init(Init_zlib, "zlib");', 'init(Init_other, "other");')
      out = messages(check("full", extinit_c: text)).join("\n")
      expect(out).to include("ext/zlib/zlib.a defines 0")
      expect(out).to include("Init_other is called by ext/extinit.c and is not in ruby")
    end

    it "counts strong definitions only: an extension stubbed weak was not linked" do
      syms = V3Fixtures.symbols("full")
      syms["ext/zlib/zlib.a"] = syms["ext/zlib/zlib.a"].map { |(t, n)| [n == "Init_zlib" ? "W" : t, n] }
      expect(messages(check("full", symbols: syms)).join).to include("Init_zlib (ext/extinit.c) is defined by 0")
    end

    it "refuses a duplicate extension name" do
      text = V3Fixtures.extinit_c("full").to_s.sub("}\n", "    init(Init_zlib, \"zlib\");\n}\n")
      expect(messages(check("full", extinit_c: text)).join).to include("names zlib more than once")
    end

    it "refuses ext/extinit.o on the line with no ext/extinit.c" do
      expect(messages(check("full", extinit_c: nil)).join).to include("no ext/extinit.c")
    end

    it "refuses dmyext.o on the line with an ext/extinit.c in the tree" do
      expect(messages(check("minimal", extinit_c: "void Init_ext(void){}\n")).join).to include("dmyext.o, and the tree has an ext/extinit.c")
    end
  end

  describe "freshness (6.0, second step)" do
    let(:m) { V3Fixtures.mtimes("full") }
    let(:tree_inputs) { V3Fixtures.classify("full").inputs.reject { |f| f.start_with?("/") } }

    it "holds on the real tree: ruby is newer than main.o and every tree input" do
      expect(described_class.freshness(ruby_mtime: m["ruby"], mtimes: tree_inputs.to_h { |f| [f, m[f]] })).to be_empty
    end

    it "refuses an input newer than ruby" do
      times = tree_inputs.to_h { |f| [f, m[f]] }.merge("libruby-static.a" => m["ruby"] + 1)
      expect(described_class.freshness(ruby_mtime: m["ruby"], mtimes: times).map(&:message).join).to include("libruby-static.a")
    end

    it "refuses an input that is absent, and an absent ruby" do
      expect(described_class.freshness(ruby_mtime: m["ruby"], mtimes: { "dmyext.o" => nil }).map(&:message).join).to include("absent")
      expect(described_class.freshness(ruby_mtime: nil, mtimes: {}).map(&:message)).to eq(["ruby is absent"])
    end
  end

  describe "the real tree is untouched" do
    it "holds on both real trees" do
      %w[minimal full].each do |p|
        expect(described_class.untouched(before: V3Fixtures.hashes(p, "before"), after: V3Fixtures.hashes(p, "after"))).to be_empty
      end
    end

    it "refuses a changed or deleted file, as F3's deletion would be" do
      before = V3Fixtures.hashes("full", "before")
      after = before.reject { |k, _| k == "./ext/extinit.o" }
      expect(described_class.untouched(before: before, after: after).map(&:message).join).to include("./ext/extinit.o")
    end

    it "refuses an empty before-set rather than comparing nothing with nothing" do
      expect(described_class.untouched(before: {}, after: {}).map(&:message).join).to include("no files were hashed")
    end
  end
end
