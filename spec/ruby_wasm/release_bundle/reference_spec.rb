# frozen_string_literal: true

require "ruby_wasm/release_bundle/reference"

RSpec.describe RubyWasm::ReleaseBundle::Reference do
  FIXTURES_R = File.expand_path("../../fixtures/v3", __dir__)

  describe ".selected?" do
    it "takes .o, .a, anything named ruby, and ext/extinit.c" do
      %w[./array.o ./enc/libenc.a ./ruby ./install/usr/local/bin/ruby ./ext/extinit.c].each do |p|
        expect(described_class.selected?(p)).to be(true), p
      end
    end

    it "leaves everything else, including another extinit.c" do
      %w[./Makefile ./foo/extinit.c ./rubyx ./array.oo].each do |p|
        expect(described_class.selected?(p)).to be(false), p
      end
    end

    # The selection has to be the fixture sheet's, which is the trap in the
    # handoff: two hash sets over "the same tree" can differ in scope.
    { "minimal" => 189, "full" => 294 }.each do |profile, count|
      it "#{profile}: every path the fixture lists is one it selects, #{count} of them" do
        list = described_class.parse(File.binread(File.join(FIXTURES_R, profile, "tree-before.sha256")))
        expect(list.keys).to all(satisfy { |p| described_class.selected?(p) })
        expect(list.length).to eq(count)
        expect(list).to include("./install/usr/local/bin/ruby")
      end
    end
  end

  %w[minimal full].each do |profile|
    it "#{profile}: the fixture states the date its Build was made under" do
      expect(File.read(File.join(FIXTURES_R, profile, "source-date-epoch"))).to match(/\A\d+\n\z/)
    end
  end

  describe ".parse" do
    it "reads sha256sum form" do
      expect(described_class.parse("#{"a" * 64}  ./x.o\n")).to eq("./x.o" => "a" * 64)
    end

    it "gives nil for any other line, rather than a shorter list" do
      expect(described_class.parse("#{"a" * 64}  ./x.o\nbroken\n")).to be_nil
    end
  end

  describe ".differences" do
    def differences(**overrides)
      described_class.differences(
        **{ want: { "./a.o" => "1", "./b.o" => "2" }, have: { "./a.o" => "1", "./b.o" => "2" }, want_link: "L", have_link: "L" }
          .merge(overrides)
      )
    end

    it "is empty on an exact match" do
      expect(differences).to be_empty
    end

    it "reports a digest that differs" do
      expect(differences(have: { "./a.o" => "1", "./b.o" => "9" }).join).to include("differs: ./b.o")
    end

    it "reports files on either side alone" do
      out = differences(have: { "./a.o" => "1", "./c.o" => "3" })
      expect(out).to include("only in the reference: ./b.o", "only in this Build: ./c.o")
    end

    it "reports the link recipe" do
      expect(differences(have_link: "M").join).to include("link recipe")
    end

    it "reports every difference, not the first" do
      out = differences(have: { "./a.o" => "X", "./b.o" => "Y" }, have_link: "M")
      expect(out.length).to eq(3)
    end
  end
end
