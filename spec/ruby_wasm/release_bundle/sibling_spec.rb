# frozen_string_literal: true

require "ruby_wasm/release_bundle/sibling"

RSpec.describe RubyWasm::ReleaseBundle::Sibling do
  # The first published sibling, byte for byte: 124 bytes, which is what
  # pipeline context has parsed since 19 September. A format that did not accept
  # this would be a format that disagrees with the only sibling that exists.
  PUBLISHED_NAME = "ruby-3.3-wasm32-unknown-icp-minimal-lib-20260919.1.tar.gz"
  PUBLISHED_DIGEST = "f744ba8497c1723e505b29fa68e1bc1fb20e4991c32c20d28ba8005f7c313560"
  PUBLISHED = "#{PUBLISHED_DIGEST}  #{PUBLISHED_NAME}\n"

  describe ".parse" do
    it "reads the published sibling" do
      expect(PUBLISHED.bytesize).to eq(124)
      entry = described_class.parse(PUBLISHED)
      expect(entry.digest).to eq(PUBLISHED_DIGEST)
      expect(entry.name).to eq(PUBLISHED_NAME)
    end

    # Each of these is something a digest tool writes in some configuration,
    # or an editor does to a file, and each is refused rather than repaired: a
    # parser that tolerates a variation is a parser that lets it be published.
    {
      "a bare digest" => PUBLISHED_DIGEST,
      "a bare digest and a newline" => "#{PUBLISHED_DIGEST}\n",
      "a CRLF line ending" => "#{PUBLISHED_DIGEST}  #{PUBLISHED_NAME}\r\n",
      "no trailing newline" => "#{PUBLISHED_DIGEST}  #{PUBLISHED_NAME}",
      "two trailing newlines" => "#{PUBLISHED}\n",
      "trailing whitespace" => "#{PUBLISHED_DIGEST}  #{PUBLISHED_NAME} \n",
      "one space as separator" => "#{PUBLISHED_DIGEST} #{PUBLISHED_NAME}\n",
      "a tab as separator" => "#{PUBLISHED_DIGEST}\t#{PUBLISHED_NAME}\n",
      "sha256sum's binary-mode marker" => "#{PUBLISHED_DIGEST} *#{PUBLISHED_NAME}\n",
      "BSD's tagged form" => "SHA256 (#{PUBLISHED_NAME}) = #{PUBLISHED_DIGEST}\n",
      "uppercase hex" => "#{PUBLISHED_DIGEST.upcase}  #{PUBLISHED_NAME}\n",
      "a 63-character digest" => "#{PUBLISHED_DIGEST[0, 63]}  #{PUBLISHED_NAME}\n",
      "a 65-character digest" => "#{PUBLISHED_DIGEST}0  #{PUBLISHED_NAME}\n",
      "a second line" => "#{PUBLISHED}#{PUBLISHED}",
      "a leading blank line" => "\n#{PUBLISHED}",
      "an empty file" => ""
    }.each do |what, contents|
      it "refuses #{what}" do
        expect(described_class.parse(contents)).to be_nil
      end
    end
  end

  describe ".line" do
    it "writes exactly the published sibling" do
      expect(described_class.line(PUBLISHED_DIGEST, PUBLISHED_NAME)).to eq(PUBLISHED)
    end

    it "round-trips through .parse" do
      entry = described_class.parse(described_class.line("0" * 64, "x.tar.gz"))
      expect([entry.digest, entry.name]).to eq(["0" * 64, "x.tar.gz"])
    end
  end
end
