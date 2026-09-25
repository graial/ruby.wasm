# frozen_string_literal: true

require "ruby_wasm/release_bundle/preflight"
require "ruby_wasm/release_bundle/sibling"

RSpec.describe RubyWasm::ReleaseBundle::Preflight do
  BUILD = "3.3-wasm32-unknown-icp-minimal"
  TAG = "#{BUILD}-20260911.1"
  ASSET = "ruby-3.3-wasm32-unknown-icp-minimal-lib-20260911.1.tar.gz"
  STEM = "ruby-3.3-wasm32-unknown-icp-minimal-lib-20260911.1"
  DIGEST = "a" * 64
  SIBLING = "#{DIGEST}  #{ASSET}\n"

  def preflight(**overrides)
    described_class.new(
      **{
        tag: TAG,
        build_name: BUILD,
        today: "20260911",
        existing_tags: [],
        asset_name: ASSET,
        archive_members: [STEM],
        sibling: SIBLING,
        actual_sha256: DIGEST
      }.merge(overrides)
    )
  end

  def clauses(**overrides)
    preflight(**overrides).refusals.map(&:clause)
  end

  describe "a correct publication" do
    it "passes against an empty registry" do
      expect(preflight).to be_pass
    end

    it "passes when other tags exist but not this one" do
      # The fork carried no tags at all when this was written, so the
      # not-a-collision case is the one that would otherwise go untested until
      # the day it stops being true.
      expect(preflight(existing_tags: ["#{BUILD}-20260901.1", "other-20260911.1"])).to be_pass
    end
  end

  describe "1.7 — tags are never moved or deleted" do
    it "refuses a tag that already exists" do
      expect(clauses(existing_tags: [TAG])).to include("1.7")
    end

    it "names the next free ordinal rather than applying it" do
      p = preflight(existing_tags: [TAG, "#{BUILD}-20260911.2"])
      expect(p.next_ordinal).to eq(3)
      expect(p.refusals.first.message).to include("Next free ordinal for 20260911: 3")
    end

    it "finds a hole rather than the highest ordinal plus one" do
      expect(preflight(existing_tags: [TAG, "#{BUILD}-20260911.3"]).next_ordinal).to eq(2)
    end

    it "ignores ordinals from other dates and other Builds" do
      expect(
        preflight(
          existing_tags: ["#{BUILD}-20260910.9", "3.3-wasm32-unknown-wasip1-minimal-20260911.9"]
        ).next_ordinal
      ).to eq(1)
    end
  end

  describe "1.3 — the ordinal is always present" do
    it "refuses a tag with no ordinal" do
      expect(clauses(tag: "#{BUILD}-20260911")).to eq(["1.3"])
    end

    it "refuses a tag with no date" do
      expect(clauses(tag: "#{BUILD}.1")).to eq(["1.3"])
    end

    it "refuses a tag naming a different Build" do
      expect(clauses(tag: "3.3-wasm32-unknown-wasip1-minimal-20260911.1")).to include("1.3")
    end

    it "refuses an asset name that does not follow the tag" do
      expect(clauses(asset_name: "ruby-icp-minimal.tar.gz")).to include("1.3")
    end

    it "stops at the grammar rather than reporting consequences of it" do
      # A malformed tag makes every later check meaningless, so only the first
      # is reported: a refusal list whose entries are artefacts of an earlier
      # entry is a list a reader has to triage.
      expect(clauses(tag: "nonsense", existing_tags: ["nonsense"])).to eq(["1.3"])
    end
  end

  describe "1.3 — the tag's Build name is checked against the bundle's" do
    # bin/preflight-release once passed the tag's own Build name as the expected
    # one, so this refusal was reachable here and nowhere else. The expected
    # name now comes from manifest.yml inside the tarball.
    it "refuses a bundle whose manifest names a different Build" do
      expect(clauses(build_name: "3.3-wasm32-unknown-wasip1-minimal")).to eq(["1.3"])
    end

    it "refuses when no build_name could be read, rather than skipping the check" do
      expect(clauses(build_name: nil)).to eq(["1.3"])
    end

    it "counts ordinals in the tag's Build, whatever the manifest says" do
      p = preflight(build_name: "other", existing_tags: [TAG])
      expect(p.next_ordinal).to eq(2)
    end
  end

  describe "1.3 — the date is today's UTC date" do
    it "refuses yesterday's date, which is a bundle packed and not published in time" do
      expect(clauses(today: "20260912")).to eq(["1.3"])
    end

    it "names the publication, not the creation, as the date's event" do
      # ADR-0042: "created" is the word that leads a reader to created_at,
      # which records the commit rather than the publication.
      message = preflight(today: "20260912").refusals.first.message
      expect(message).to include("published")
      expect(message).not_to include("created")
    end

    it "refuses a date that is not a calendar date, since it cannot be today" do
      expect(clauses(tag: "#{BUILD}-20260231.1", today: "20260911")).to include("1.3")
    end

    it "reports the date alongside independent refusals" do
      expect(clauses(today: "20260912", existing_tags: [TAG])).to eq(%w[1.3 1.7])
    end
  end

  describe "1.4 — the sibling" do
    it "refuses a missing .sha256" do
      expect(clauses(sibling: nil)).to eq(["1.4"])
    end

    it "refuses a digest that does not match the tarball" do
      expect(clauses(actual_sha256: "b" * 64)).to eq(["1.4"])
    end

    # bin/preflight-release once took the first whitespace-separated field of
    # the sibling, so a bare digest passed here and failed at every consumer
    # parsing the sha256sum form. The whole file is now handed over and read
    # by Sibling, the same parser the postflight uses.
    it "refuses a bare digest, even the right one" do
      expect(clauses(sibling: DIGEST)).to eq(["1.4"])
    end

    it "refuses a CRLF line ending, even with the right digest and name" do
      expect(clauses(sibling: "#{DIGEST}  #{ASSET}\r\n")).to eq(["1.4"])
    end

    it "says what the form should be, and what it found" do
      message = preflight(sibling: DIGEST).refusals.first.message
      expect(message).to include("sha256sum form")
      expect(message).to include(DIGEST.inspect)
    end

    it "refuses a sibling naming another file" do
      # A sibling copied from another bundle carries a well-formed line about
      # the wrong asset.
      expect(clauses(sibling: "#{DIGEST}  other.tar.gz\n")).to eq(["1.4"])
    end

    it "reports a wrong name and a wrong digest separately" do
      expect(clauses(sibling: "#{"b" * 64}  other.tar.gz\n")).to eq(%w[1.4 1.4])
    end
  end

  describe "1.5 — one top-level directory named for the asset stem" do
    it "refuses two top-level entries" do
      expect(clauses(archive_members: [STEM, "README"])).to eq(["1.5"])
    end

    it "refuses a top-level directory named something else" do
      expect(clauses(archive_members: ["ruby"])).to eq(["1.5"])
    end

    it "refuses an empty tarball" do
      expect(clauses(archive_members: [])).to eq(["1.5"])
    end
  end

  it "reports every independent refusal at once" do
    # Independent failures are reported together so one publication attempt
    # surfaces all of them, rather than one per attempt.
    expect(
      clauses(existing_tags: [TAG], sibling: nil, archive_members: ["ruby"])
    ).to eq(%w[1.7 1.4 1.5])
  end
end