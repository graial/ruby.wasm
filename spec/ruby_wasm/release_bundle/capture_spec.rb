# frozen_string_literal: true

require "ruby_wasm/release_bundle/capture"

RSpec.describe RubyWasm::ReleaseBundle::Capture do
  # Shaped like the real transcripts: the link recipe, then the wasm-opt line
  # (which also contains "-o ruby"), with other activity around them.
  let(:link) { "/r/tool/wasm-clangw /r/wasi-sdk-22.0/bin/clang main.o ext/extinit.o -L. -lruby-static   -o ruby" }
  let(:wasm_opt) { "/r/binaryen/bin/wasm-opt --asyncify -O3 -g -o ruby ruby; :" }
  let(:compile) { "/r/tool/wasm-clangw /r/wasi-sdk-22.0/bin/clang -I. -o main.o -c /r/3.3/main.c" }

  let(:ruby_transcript) do
    ["echo linking", "rm -f ruby", link, wasm_opt, "echo done"].map { |l| "#{l}\n" }.join
  end
  let(:main_transcript) { "echo compiling main.c\n#{compile}\n" }

  def selection(ruby: ruby_transcript, main: main_transcript)
    described_class.select(ruby_transcript: ruby, main_transcript: main)
  end

  def clauses(**kw)
    selection(**kw).refusals.map(&:clause)
  end

  describe "6.1 and 5.1 — a correct capture" do
    it "writes the link recipe followed by the wasm-opt line, and the compile recipe" do
      s = selection
      expect(s.refusals).to be_empty
      expect(s.link_raw).to eq("#{link}\n#{wasm_opt}\n")
      expect(s.compile_raw).to eq("#{compile}\n")
    end

    it "reports adjacency rather than requiring it" do
      spaced = [link, "echo between", wasm_opt].map { |l| "#{l}\n" }.join
      s = selection(ruby: spaced)
      expect(s.refusals).to be_empty
      expect(s.notes.join).to include("with 1 line(s) between them")
      expect(selection.notes.join).to include("immediately follows")
    end

    it "keeps every byte of the selected lines" do
      # 5.1: no rewriting, no reformatting, no trimming. Trailing whitespace
      # and doubled spaces are the recipe's, not noise.
      odd = "/r/clang  -o main.o -c main.c   "
      expect(selection(main: "#{odd}\n").compile_raw).to eq("#{odd}\n")
    end
  end

  describe "6.1 — each pattern matches exactly once" do
    it "anchors the link pattern, so the wasm-opt line's own -o ruby is not a second match" do
      # The reason the pattern is anchored. Unanchored, this transcript would
      # stop a correct release.
      expect(clauses).to be_empty
    end

    it "stops on no link recipe" do
      expect(clauses(ruby: "#{wasm_opt}\n")).to eq(["6.1"])
    end

    it "stops on two link recipes, and names both lines" do
      s = selection(ruby: "#{link}\n#{link}\n#{wasm_opt}\n")
      expect(s.refusals.map(&:clause)).to eq(["6.1"])
      expect(s.refusals.first.message).to include("matched 2 time(s)", "lines 1, 2")
    end

    it "stops on no wasm-opt line" do
      expect(clauses(ruby: "#{link}\n")).to eq(["6.1"])
    end

    it "stops on no compile recipe, which is what a warm tree without -W gives" do
      expect(clauses(main: "make: 'main.o' is up to date.\n")).to eq(["6.1"])
    end

    it "stops on two compile recipes" do
      expect(clauses(main: "#{compile}\n#{compile}\n")).to eq(["6.1"])
    end

    it "stops on an empty transcript rather than reading it as nothing to object to" do
      expect(clauses(ruby: "", main: "")).to eq(%w[6.1 6.1 6.1])
    end

    it "does not clean up a CRLF transcript into a match" do
      crlf = "#{link}\r\n#{wasm_opt}\r\n"
      expect(clauses(ruby: crlf)).to eq(["6.1"])
    end
  end

  describe "6.1 — a selected recipe is a single physical line" do
    it "stops on a selected line ending in a backslash" do
      expect(clauses(main: "/r/clang -o main.o -c \\\n  main.c\n")).to eq(["6.1"])
    end

    it "stops on a selected line that continues the line before it" do
      # The line matches on its own, but it is the tail of a recipe that
      # began a line earlier. Taking it would publish half a recipe.
      expect(clauses(main: "/r/clang -I. \\\n  -o main.o -c main.c\n")).to eq(["6.1"])
    end
  end

  describe "5.1 — the wasm-opt line comes after the link recipe" do
    it "stops when the transcript has it before" do
      expect(clauses(ruby: "#{wasm_opt}\n#{link}\n")).to eq(["5.1"])
    end
  end

  it "hands nothing on when anything is refused" do
    s = selection(ruby: "#{wasm_opt}\n#{link}\n")
    expect([s.link_raw, s.compile_raw]).to eq([nil, nil])
  end

  it "reports every independent refusal at once" do
    expect(clauses(ruby: "#{wasm_opt}\n#{link}\n", main: "")).to eq(%w[6.1 5.1])
  end

  describe "6.0 — preconditions on the Build tree" do
    let(:t) { Time.at(1_000_000) }

    def pre(**overrides)
      described_class.preconditions(
        **{
          tree_exists: true,
          ruby_mtime: t + 120,
          main_o_mtime: t,
          extinit_o_mtime: t + 60,
          checkout_changes: []
        }.merge(overrides)
      ).map(&:clause)
    end

    it "passes a completed tree over a clean checkout" do
      expect(pre).to be_empty
    end

    it "stops on a tree that does not exist, and reports nothing else about it" do
      expect(pre(tree_exists: false, ruby_mtime: nil)).to eq(["6.0"])
    end

    it "stops when ruby is absent" do
      expect(pre(ruby_mtime: nil)).to eq(["6.0"])
    end

    it "stops when main.o is absent" do
      expect(pre(main_o_mtime: nil)).to eq(["6.0"])
    end

    it "stops when ext/extinit.o is absent, which is the build driver's success without make ruby" do
      expect(pre(extinit_o_mtime: nil)).to eq(["6.0"])
    end

    it "stops when ruby is not newer than main.o" do
      expect(pre(main_o_mtime: t + 120)).to eq(["6.0"])
    end

    it "stops when ruby is not newer than ext/extinit.o" do
      expect(pre(extinit_o_mtime: t + 300)).to eq(["6.0"])
    end

    it "stops on a checkout with a tracked modification" do
      expect(pre(checkout_changes: [" M lib/ruby_wasm/cli.rb"])).to eq(["4.3"])
    end

    it "reports every independent refusal at once" do
      expect(pre(extinit_o_mtime: nil, checkout_changes: [" M x"])).to eq(%w[6.0 4.3])
    end
  end
end
