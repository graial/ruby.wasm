# frozen_string_literal: true

require "ruby_wasm/release_bundle/postflight"
require "ruby_wasm/release_bundle/sibling"

RSpec.describe RubyWasm::ReleaseBundle::Postflight do
  P_BUILD = "3.3-wasm32-unknown-icp-full"
  P_TAG = "#{P_BUILD}-20261014.1"
  P_ASSET = "ruby-#{P_BUILD}-lib-20261014.1.tar.gz"
  P_DIGEST = "c" * 64
  P_TIP = "d" * 40

  # Shaped like GitHub's release object: only the fields read here, plus
  # created_at, which is present in every real response and must never be read.
  def release_json(**overrides)
    {
      "tag_name" => P_TAG,
      "draft" => false,
      "prerelease" => false,
      "immutable" => true,
      "created_at" => "2026-10-13T20:00:00Z",
      "published_at" => "2026-10-14T09:30:00Z",
      "assets" => [{ "name" => P_ASSET }, { "name" => "#{P_ASSET}.sha256" }]
    }.merge(overrides)
  end

  def postflight(json: release_json, **overrides)
    described_class.new(
      **{
        tag: P_TAG,
        release: described_class.release_from(json, tag: P_TAG),
        latest_tag: described_class::FROZEN_TAG,
        tag_target: P_TIP,
        release_tip: P_TIP,
        local_sha256: P_DIGEST,
        sibling: RubyWasm::ReleaseBundle::Sibling.line(P_DIGEST, P_ASSET),
        downloaded_sha256: P_DIGEST
      }.merge(overrides)
    )
  end

  def refusals(**overrides)
    postflight(**overrides).refusals
  end

  def clauses(**overrides)
    refusals(**overrides).map(&:clause)
  end

  describe "a correct publication" do
    it "passes" do
      expect(postflight).to be_pass
    end
  end

  describe ".release_from — the response is examined before it is read" do
    # A rate-limited request returns a JSON object that is not a release. Read
    # as one, it has no assets and no dates, and a check over nothing finds
    # nothing wrong. So a response that is not a release object for this tag
    # stops the postflight: it cannot pass what it did not examine.
    it "refuses a rate-limit body as unexamined, naming the registry's message" do
      body = { "message" => "API rate limit exceeded for 203.0.113.1.", "documentation_url" => "x" }
      expect { described_class.release_from(body, tag: P_TAG) }.to raise_error(
        described_class::Unexamined, /rate limit exceeded/
      )
    end

    it "refuses a list, which is what the releases index returns" do
      expect { described_class.release_from([release_json], tag: P_TAG) }.to raise_error(
        described_class::Unexamined
      )
    end

    it "refuses a release for another tag" do
      expect {
        described_class.release_from(release_json("tag_name" => "other-20261014.1"), tag: P_TAG)
      }.to raise_error(described_class::Unexamined, /other-20261014\.1/)
    end

    it "refuses a response with no immutable field, rather than reading absence as false" do
      json = release_json
      json.delete("immutable")
      expect { described_class.release_from(json, tag: P_TAG) }.to raise_error(
        described_class::Unexamined, /immutable/
      )
    end

    %w[draft prerelease immutable].each do |field|
      it "refuses a non-boolean #{field}" do
        expect { described_class.release_from(release_json(field => "false"), tag: P_TAG) }.to raise_error(
          described_class::Unexamined, /#{field}/
        )
      end
    end

    it "refuses assets that are not a list of named objects" do
      expect { described_class.release_from(release_json("assets" => [{ "id" => 1 }]), tag: P_TAG) }.to raise_error(
        described_class::Unexamined, /assets/
      )
    end

    it "accepts a draft with no published_at, since a draft has none" do
      release = described_class.release_from(release_json("draft" => true, "published_at" => nil), tag: P_TAG)
      expect(release.published_at).to be_nil
    end

    it "refuses a published release with no published_at" do
      expect { described_class.release_from(release_json("published_at" => nil), tag: P_TAG) }.to raise_error(
        described_class::Unexamined, /published_at/
      )
    end
  end

  describe "1.3 — the tag's date is the UTC date of published_at" do
    it "passes when the commit date differs, because created_at is never read" do
      # The first release: created_at 11:38:08Z (the commit), published_at
      # 16:42:49Z. Here the commit is the previous day entirely.
      expect(postflight).to be_pass
    end

    it "refuses a publication that crossed midnight UTC, and says it needs a new tag" do
      r = refusals(json: release_json("published_at" => "2026-10-15T00:00:03Z"))
      expect(r.map(&:clause)).to eq(["1.3"])
      expect(r.first.fix).to eq(:new_tag)
      expect(r.first.message).to include("20261014", "20261015")
    end

    it "reads published_at in UTC whatever offset it carries" do
      # 23:30 at -01:00 is 00:30 the next day in UTC.
      expect(clauses(json: release_json("published_at" => "2026-10-14T23:30:00-01:00"))).to eq(["1.3"])
    end
  end

  describe "1.2 — an ordinary, published release" do
    it "refuses a draft as fixable in place, and warns that publishing sets the date" do
      r = refusals(json: release_json("draft" => true, "published_at" => nil))
      expect(r.map(&:clause)).to eq(["1.2"])
      expect(r.first.fix).to eq(:in_place)
      expect(r.first.message).to include("gh release edit #{P_TAG} --draft=false", "published_at")
    end

    it "does not refuse a draft for being mutable, since immutability starts at publication" do
      expect(clauses(json: release_json("draft" => true, "published_at" => nil, "immutable" => false))).to eq(["1.2"])
    end

    it "refuses a pre-release as fixable in place" do
      r = refusals(json: release_json("prerelease" => true))
      expect(r.map(&:clause)).to eq(["1.2"])
      expect(r.first.fix).to eq(:in_place)
      expect(r.first.message).to include("gh release edit #{P_TAG} --prerelease=false")
    end
  end

  describe "1.7 — the release is immutable (ADR-0050)" do
    it "refuses a mutable release as needing a new tag" do
      r = refusals(json: release_json("immutable" => false))
      expect(r.map(&:clause)).to eq(["1.7"])
      expect(r.first.fix).to eq(:new_tag)
    end

    it "does not refuse the frozen tag, the one release ADR-0050 leaves mutable" do
      frozen = described_class::FROZEN_TAG
      asset = "ruby-3.3-wasm32-unknown-icp-minimal-lib-20260919.1.tar.gz"
      json = release_json(
        "tag_name" => frozen,
        "immutable" => false,
        "published_at" => "2026-09-19T16:42:49Z",
        "assets" => [{ "name" => asset }, { "name" => "#{asset}.sha256" }]
      )
      p = described_class.new(
        tag: frozen,
        release: described_class.release_from(json, tag: frozen),
        latest_tag: frozen,
        tag_target: P_TIP,
        release_tip: P_TIP,
        local_sha256: P_DIGEST,
        sibling: RubyWasm::ReleaseBundle::Sibling.line(P_DIGEST, asset),
        downloaded_sha256: P_DIGEST
      )
      expect(p).to be_pass
      expect(p.notes.join).to include("ADR-0050")
    end

    it "exempts that tag by its exact name only" do
      # Same Build and date, next ordinal: a later release, and not exempt.
      tag = "3.3-wasm32-unknown-icp-minimal-20260919.2"
      asset = "ruby-3.3-wasm32-unknown-icp-minimal-lib-20260919.2.tar.gz"
      json = release_json(
        "tag_name" => tag,
        "immutable" => false,
        "published_at" => "2026-09-19T20:00:00Z",
        "assets" => [{ "name" => asset }, { "name" => "#{asset}.sha256" }]
      )
      p = described_class.new(
        tag: tag,
        release: described_class.release_from(json, tag: tag),
        latest_tag: described_class::FROZEN_TAG,
        tag_target: P_TIP,
        release_tip: P_TIP,
        local_sha256: P_DIGEST,
        sibling: RubyWasm::ReleaseBundle::Sibling.line(P_DIGEST, asset),
        downloaded_sha256: P_DIGEST
      )
      expect(p.refusals.map(&:clause)).to eq(["1.7"])
    end
  end

  describe "1.6 — the latest pointer has not moved (ADR-0048)" do
    it "refuses a moved pointer as fixable in place, naming the command" do
      r = refusals(latest_tag: P_TAG)
      expect(r.map(&:clause)).to eq(["1.6"])
      expect(r.first.fix).to eq(:in_place)
      expect(r.first.message).to include("gh release edit #{described_class::FROZEN_TAG} --latest")
    end

    it "refuses when the redirect named no tag, rather than skipping the check" do
      expect(clauses(latest_tag: nil)).to eq(["1.6"])
    end
  end

  describe "ADR-0047 — the tag targets release's tip" do
    it "refuses a tag on another commit, as needing a new tag" do
      r = refusals(tag_target: "e" * 40)
      expect(r.map(&:clause)).to eq(["ADR-0047"])
      expect(r.first.fix).to eq(:new_tag)
    end

    it "refuses when either commit could not be read" do
      expect(clauses(tag_target: nil)).to eq(["ADR-0047"])
      expect(clauses(release_tip: nil)).to eq(["ADR-0047"])
    end
  end

  describe "1.4 — the assets" do
    it "refuses a third asset" do
      json = release_json("assets" => release_json["assets"] + [{ "name" => "notes.txt" }])
      expect(clauses(json: json)).to eq(["1.4"])
    end

    it "refuses a missing sibling asset" do
      expect(clauses(json: release_json("assets" => [{ "name" => P_ASSET }]))).to eq(["1.4"])
    end

    it "refuses a published sibling not in sha256sum form, through the preflight's parser" do
      expect(clauses(sibling: P_DIGEST)).to eq(["1.4"])
    end

    it "refuses a published sibling naming another file" do
      expect(clauses(sibling: "#{P_DIGEST}  other.tar.gz\n")).to eq(["1.4"])
    end
  end

  describe "1.4 — three digests, one number" do
    it "names the wrong file published, when asset and sibling agree with each other only" do
      other = "f" * 64
      r = refusals(sibling: RubyWasm::ReleaseBundle::Sibling.line(other, P_ASSET), downloaded_sha256: other)
      expect(r.map(&:clause)).to eq(["1.4"])
      expect(r.first.fix).to eq(:new_tag)
      expect(r.first.message).to include("local #{P_DIGEST}", "sibling #{other}", "downloaded #{other}")
      expect(r.first.message).to include("not the file checked here")
    end

    it "names a changed or corrupted upload, when the download disagrees with the sibling" do
      r = refusals(downloaded_sha256: "f" * 64)
      expect(r.first.message).to include("does not match its published sibling")
    end

    it "names a wrong sibling, when only the sibling disagrees" do
      r = refusals(sibling: RubyWasm::ReleaseBundle::Sibling.line("f" * 64, P_ASSET))
      expect(r.first.message).to include("sibling is wrong")
    end
  end

  it "reports every independent refusal at once, in-place fixes first" do
    r = refusals(
      json: release_json("prerelease" => true, "immutable" => false),
      latest_tag: P_TAG,
      tag_target: "e" * 40
    )
    expect(r.map(&:clause)).to eq(%w[1.2 1.6 1.7 ADR-0047])
    expect(r.map(&:fix)).to eq(%i[in_place in_place new_tag new_tag])
  end
end
