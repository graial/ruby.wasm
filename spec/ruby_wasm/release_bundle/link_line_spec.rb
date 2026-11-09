# frozen_string_literal: true

require "ruby_wasm/release_bundle/link_line"
require_relative "v3_fixtures"

RSpec.describe RubyWasm::ReleaseBundle::LinkLine do

  def messages(c)
    c.refusals.map(&:message)
  end

  describe "the real minimal line" do
    subject(:c) { V3Fixtures.classify("minimal") }

    it "places every word" do
      expect(messages(c)).to be_empty
    end

    it "ships dmyext.o and the three enc/ objects, and not ext/extinit.o or main.o" do
      expect(c.build_members).to eq(%w[dmyext.o enc/encinit.o enc/libenc.a enc/libtrans.a libruby-static.a])
    end

    it "has no root key and no extension archive" do
      expect(c.root_keys).to eq({})
      expect(c.ext_archives).to eq([])
    end

    it "takes the wasi-sdk path from word 1" do
      expect(c.wasi_sdk_path).to eq(V3Fixtures::WASI_SDK)
    end

    it "resolves -lruby-static through -L. and the system libraries in the sysroot" do
      expect(c.inputs).to include("libruby-static.a", V3Fixtures::WASI_VFS, "main.o")
      expect(c.sysroot).to eq(%w[dl crypt m wasi-emulated-mman wasi-emulated-signal wasi-emulated-getpid wasi-emulated-process-clocks])
    end

    it "reads -Xlinker, -z and -o as taking the next word, never as members" do
      args = c.words.select { |w| w.kind == :option_argument }.map(&:text)
      expect(args).to include("--stack-first", "-z", "stack-size=16777216")
      expect(c.words.find { |w| w.kind == :output }&.text).to eq("ruby")
    end
  end

  describe "the real full line" do
    subject(:c) { V3Fixtures.classify("full") }

    it "places every word" do
      expect(messages(c)).to be_empty
    end

    it "ships ext/extinit.o, the 26 extension archives, the three enc/ objects and the archive" do
      expect(c.build_members.length).to eq(31)
      expect(c.ext_archives.length).to eq(26)
      expect(c.build_members).to include("ext/extinit.o", "ext/cgi/escape/escape.a", "enc/encinit.o", "libruby-static.a")
      expect(c.build_members).not_to include("main.o")
    end

    it "derives three root keys by the naming rule, each with only the archives the line resolves there" do
      expect(c.root_keys.transform_values { |k| k["archives"] }).to eq(
        "openssl_lib" => %w[libcrypto.a libssl.a],
        "yaml_lib" => %w[libyaml.a],
        "zlib_lib" => %w[libz.a]
      )
      expect(c.root_keys["openssl_lib"]["value"]).to eq("#{V3Fixtures::ROOT}/wasm32-unknown-icp/openssl-3.2.0/opt/usr/local/lib")
    end

    it "ships only resolved archives, not whatever else the root holds" do
      listings = V3Fixtures.root_listings("full")
      root = c.root_keys["openssl_lib"]["value"]
      listings[root] += %w[libunused.a]
      expect(V3Fixtures.classify("full", root_listings: listings).root_keys["openssl_lib"]["archives"]).to eq(%w[libcrypto.a libssl.a])
    end
  end

  describe "a word the grammar cannot place stops the capture" do
    let(:line) { V3Fixtures.link_line("minimal") }

    def with(line) = V3Fixtures.classify("minimal", line: line)

    it "stops on a bare word left over by an argument-taking option nobody listed" do
      expect(messages(with(line.sub(" -o ruby", " -mllvm opaque -o ruby"))).join).to include("\"opaque\"")
    end

    it "stops on a relative object that is not in the tree" do
      expect(messages(with(line.sub(" main.o", " main.o ghost.o"))).join).to include("ghost.o, is not in the Build tree")
    end

    it "stops on an absolute file no token key declares" do
      expect(messages(with(line.sub(" main.o", " /opt/x/libextra.a main.o"))).join).to include("no declared token key")
    end

    it "stops on a -l that resolves nowhere" do
      expect(messages(with(line.sub(" -o ruby", " -lnowhere -o ruby"))).join).to include("-lnowhere")
    end

    it "stops on an output other than ruby" do
      expect(messages(with(line.sub(/-o ruby\z/, "-o miniruby"))).join).to include("miniruby")
    end

    it "stops on a relative -L root" do
      expect(messages(with(line.sub(" -L.", " -Llib"))).join).to include("must be . or absolute")
    end

    it "stops on quoting rather than reading a different line from the shell's" do
      expect(messages(with(line.sub(" main.o", " 'main.o'"))).join).to include("no quoting")
    end

    it "stops when word 1 is not <wasi-sdk>/bin/clang" do
      expect(messages(with(line.sub("#{V3Fixtures::WASI_SDK}/bin/clang", "/usr/bin/cc"))).join).to include("word 1")
    end

    it "stops when word 0 is not a declared token key" do
      expect(messages(with(line.sub(V3Fixtures::CC_WRAPPER, "/usr/bin/env"))).join).to include("word 0")
    end
  end

  describe "root keys" do
    it "names a root by its product, without its version" do
      expect(described_class.root_key_name("/b/wasm32-unknown-icp/openssl-3.2.0/opt/usr/local/lib")).to eq("openssl_lib")
      expect(described_class.root_key_name("/b/wasm32-unknown-icp/zlib-1.3.1/opt/usr/local/lib")).to eq("zlib_lib")
    end

    it "derives no name for a root of another shape" do
      expect(described_class.root_key_name("/usr/lib")).to be_nil
      expect(described_class.root_key_name("/b/openssl/opt/usr/local/lib")).to be_nil
    end

    let(:full) { V3Fixtures.link_line("full") }

    it "stops on a root that was not examined" do
      listings = V3Fixtures.root_listings("full").reject { |r, _| r.include?("yaml") }
      expect(messages(V3Fixtures.classify("full", root_listings: listings)).join).to include("was not examined")
    end

    it "stops on a root that resolves no -l" do
      expect(messages(V3Fixtures.classify("full", line: full.sub(" -lyaml", ""))).join).to include("resolves no -l")
    end

    it "stops on a root whose shape gives no name" do
      bad = "/b/vendored/lib"
      listings = V3Fixtures.root_listings("full").merge(bad => %w[libextra.a])
      line = full.sub(" main.o", " -L#{bad} main.o").sub(" -o ruby", " -lextra -o ruby")
      expect(messages(V3Fixtures.classify("full", line: line, root_listings: listings)).join).to include("no root key name")
    end

    it "stops on a derived name that collides with a declared key" do
      expect(messages(V3Fixtures.classify("full", existing_keys: %w[zlib_lib])).join).to include("collides")
    end
  end
end
