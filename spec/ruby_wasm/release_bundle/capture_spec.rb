# frozen_string_literal: true

require "ruby_wasm/release_bundle/capture"
require_relative "v3_fixtures"

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
    described_class.select(link_transcript: ruby, main_transcript: main)
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

  describe "6.0 — preconditions on the Build tree, before the copy" do
    let(:t) { Time.at(1_000_000) }

    def pre(**overrides)
      described_class.preconditions(
        **{
          tree_exists: true,
          ruby_mtime: t + 120,
          main_o_mtime: t,
          checkout_changes: [],
          copy_exists: false
        }.merge(overrides)
      ).map(&:clause)
    end

    it "passes a linked tree over a clean checkout" do
      expect(pre).to be_empty
    end

    it "does not require ext/extinit.o: minimal's own link names dmyext.o (ADR-0068, F2)" do
      expect(described_class.method(:preconditions).parameters.map(&:last)).not_to include(:extinit_o_mtime)
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

    it "stops when ruby is not newer than main.o" do
      expect(pre(main_o_mtime: t + 120)).to eq(["6.0"])
    end

    it "stops when the Capture copy's path is already taken" do
      expect(pre(copy_exists: true)).to eq(["6.1"])
    end

    it "stops on a checkout with a tracked modification" do
      expect(pre(checkout_changes: [" M lib/ruby_wasm/cli.rb"])).to eq(["4.3"])
    end

    it "reports every independent refusal at once" do
      expect(pre(main_o_mtime: nil, checkout_changes: [" M x"])).to eq(%w[6.0 4.3])
    end
  end

  describe "v3 — the real transcripts" do
    %w[minimal full].each do |p|
      it "#{p}: selects one link line and its wasm-opt line from build-ext, taken in the copy" do
        s = V3Fixtures.selection(p)
        expect(s.refusals).to be_empty
        expect(s.link_raw.to_s.lines.length).to eq(2)
        expect(s.link_raw.to_s.lines.first).to end_with("-o ruby\n")
        expect(s.link_raw.to_s.lines.last).to start_with(V3Fixtures::WASM_OPT + " ")
        expect(s.notes.join).to include("immediately follows")
      end

      it "#{p}: the copy's compile recipe is the tree's, byte for byte" do
        expect(V3Fixtures.read(p, "copy.main-n.out")).to eq(V3Fixtures.read(p, "tree.main-n.out"))
      end
    end

    it "takes the compile recipe from the real tree" do
      s = V3Fixtures.selection("full")
      line = V3Fixtures.read("full", "tree.main-n.out").lines.grep(/-o main\.o /).first
      expect(s.compile_raw).to eq(line)
    end

    it "minimal's link line names dmyext.o and the enc/ objects, not ext/extinit.o" do
      line = V3Fixtures.link_line("minimal").split(" ")
      expect(line).to include("dmyext.o", "enc/encinit.o", "enc/libenc.a", "enc/libtrans.a")
      expect(line).not_to include("ext/extinit.o")
    end

    it "refuses a copy whose compile recipe differs from the tree's" do
      tree = V3Fixtures.read("full", "tree.main-n.out")
      s = described_class.select(
        link_transcript: V3Fixtures.read("full", "copy.build-ext-n.out"),
        main_transcript: tree,
        copy_main_transcript: tree.sub("-O3", "-O2")
      )
      expect(s.refusals.map(&:message).join).to include("not faithful")
    end

    it "refuses a selected recipe that names the Capture copy's path" do
      copy = "/home/shared/external/ladder/main/build/wasm32-unknown-icp/ruby-3.3-wasm32-unknown-icp-full.capture-copy"
      transcript = V3Fixtures.read("full", "copy.build-ext-n.out").sub(/ main\.o /, " #{copy}/main.o ")
      s = described_class.select(
        link_transcript: transcript,
        main_transcript: V3Fixtures.read("full", "tree.main-n.out"),
        copy_path: copy
      )
      expect(s.refusals.map(&:clause)).to eq(["4.6"])
    end

    it "accepts the real transcript, which names the copy only in make's own Entering lines" do
      copy = "/home/shared/external/ladder/main/build/wasm32-unknown-icp/ruby-3.3-wasm32-unknown-icp-full.capture-copy"
      transcript = V3Fixtures.read("full", "copy.build-ext-n.out")
      expect(transcript).to include(copy)
      s = described_class.select(link_transcript: transcript, main_transcript: V3Fixtures.read("full", "tree.main-n.out"), copy_path: copy)
      expect(s.refusals).to be_empty
    end
  end
end
