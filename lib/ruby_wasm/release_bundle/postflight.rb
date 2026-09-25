# frozen_string_literal: true

require "time"
require_relative "preflight"
require_relative "sibling"

module RubyWasm
  module ReleaseBundle
    # Refusals about a publication that has already happened, read back from the
    # registry after `gh release create`.
    #
    # The preflight refuses before anything exists, so its refusals mean "do not
    # publish". By the time this runs, the tag is permanent (1.7), so each of
    # its refusals says which of two kinds of fix it needs:
    #
    #   :in_place  an edit an immutable release still allows: the latest and
    #              pre-release flags, and publishing a draft.
    #   :new_tag   anything else. The release stays published, gets a
    #              supersession notice in its body (1.8), and a corrected
    #              bundle is published under the next free ordinal.
    #
    # It names the fix and never applies it (ADR-0040's shape, carried past
    # publication). A tool that quietly moved the latest pointer back would
    # also erase the only record that a publication went out without
    # --latest=false.
    #
    # Pure: it is handed what was read from the registry, the remote and the
    # local tarball, and returns what is wrong. Everything a refusal depends on
    # is a constructor argument, so every refusal is reachable from a spec.
    class Postflight
      # ADR-0048: the latest pointer never moves from here. ADR-0050: the one
      # release left mutable, published before immutability was enabled.
      FROZEN_TAG = "3.3-wasm32-unknown-icp-minimal-20260919.1"

      Refusal = Struct.new(:clause, :fix, :message)

      # What was read from the release object. A plain class rather than a
      # Struct, for the reason Sibling::Entry gives.
      class Release
        attr_reader :tag_name, :draft, :prerelease, :immutable, :published_at, :asset_names

        def initialize(tag_name, draft, prerelease, immutable, published_at, asset_names)
          @tag_name = tag_name
          @draft = draft
          @prerelease = prerelease
          @immutable = immutable
          @published_at = published_at
          @asset_names = asset_names
        end
      end

      # The registry's response was not something this can examine. That is
      # not a refusal and it is not a pass. It stops the postflight, because a
      # check over a response it did not understand finds nothing wrong.
      class Unexamined < StandardError
      end

      # Reads GitHub's release object for `tag`. Raises Unexamined for anything
      # that is not one: a rate-limit body, an index listing, another tag's
      # release, or a field missing or of the wrong type. created_at is present
      # in every real response and deliberately never read (ADR-0042).
      def self.release_from(json, tag:)
        unless json.is_a?(Hash)
          raise Unexamined, "the registry returned a #{json.class}, not a release object"
        end

        unless json.key?("tag_name")
          said = json["message"]
          raise Unexamined,
                said.is_a?(String) ? "the registry said: #{said}" : "the response carries no tag_name"
        end

        if json["tag_name"] != tag
          raise Unexamined, "the response is the release for #{json["tag_name"].inspect}, not #{tag.inspect}"
        end

        flags =
          %w[draft prerelease immutable].to_h do |field|
            unless json.key?(field)
              raise Unexamined,
                    "the response has no #{field} field; absence is not false " \
                    "(an older API or client may not report it)"
            end
            value = json[field]
            unless value == true || value == false
              raise Unexamined, "#{field} is #{value.inspect}, not a boolean"
            end
            [field, value]
          end

        assets = json["assets"]
        unless assets.is_a?(Array) && assets.all? { |a| a.is_a?(Hash) && a["name"].is_a?(String) }
          raise Unexamined, "assets is not a list of named assets"
        end

        published_at = json["published_at"]
        if published_at.nil?
          raise Unexamined, "the release is published but has no published_at" unless flags["draft"]
        else
          unless published_at.is_a?(String)
            raise Unexamined, "published_at is #{published_at.inspect}, not a timestamp"
          end
          begin
            Time.iso8601(published_at)
          rescue ArgumentError
            raise Unexamined, "published_at #{published_at.inspect} is not ISO 8601"
          end
        end

        Release.new(
          json["tag_name"],
          flags["draft"],
          flags["prerelease"],
          flags["immutable"],
          published_at,
          assets.map { |a| a["name"] }
        )
      end

      # tag: the tag just published.
      # release: its Release, from .release_from.
      # latest_tag: the tag /releases/latest redirects to; nil when it named none.
      # tag_target / release_tip: the commit the tag resolves to and the remote
      #   release branch's head; nil when either could not be read.
      # local_sha256: the tarball the preflight checked, on this machine.
      # sibling: the published .sha256 asset's bytes, unparsed.
      # downloaded_sha256: the published tarball's digest, downloaded.
      def initialize(
        tag:,
        release:,
        latest_tag:,
        tag_target:,
        release_tip:,
        local_sha256:,
        sibling:,
        downloaded_sha256:
      )
        @tag = tag
        @release = release
        @latest_tag = latest_tag
        @tag_target = tag_target
        @release_tip = release_tip
        @local_sha256 = local_sha256
        @sibling = sibling
        @downloaded_sha256 = downloaded_sha256
        # @type var notes: Array[String]
        notes = []
        @notes = notes
        # @type var found: Array[Refusal]
        found = []
        @refusals = found
        @ran = false
      end

      # What is wrong, in-place fixes first. The check runs once, on whichever
      # of this and #notes is called first, so neither depends on the other.
      def refusals
        run unless @ran
        @refusals
      end

      # What was deliberately not refused, and why.
      def notes
        run unless @ran
        @notes
      end

      def pass?
        refusals.empty?
      end

      private

      def run
        @ran = true
        # @type var out: Array[Refusal]
        out = []
        match = Preflight::TAG.match(@tag)
        if match.nil?
          out << Refusal.new(
            "1.3", :new_tag,
            "tag #{@tag.inspect} is not <build-name>-<YYYYMMDD>.<ordinal>, and it is published"
          )
          @refusals = out
          return out
        end
        asset = Preflight.asset_name_for(@tag, match)

        out.concat(state_refusals(match))
        out.concat(latest_refusals)
        out.concat(target_refusals)
        out.concat(asset_refusals(asset))
        # In-place fixes first: they are what an operator can do now. The sort
        # is stable, so each group keeps the order above.
        @refusals = out.each_with_index.sort_by { |r, i| [r.fix == :in_place ? 0 : 1, i] }.map(&:first)
      end

      NEW_TAG =
        "This release stays published (1.7): add a supersession notice to its " \
        "body (1.8) and publish a corrected bundle under the next free ordinal."

      def state_refusals(match)
        # @type var out: Array[Refusal]
        out = []
        release = @release

        if release.draft
          out << Refusal.new(
            "1.2", :in_place,
            "the release is a draft. Fix: gh release edit #{@tag} --draft=false. Publishing " \
            "sets published_at to that moment, so if today's UTC date is no longer " \
            "#{match[:date]}, run this again: the date will then need a new tag"
          )
        end

        if release.prerelease
          out << Refusal.new(
            "1.2", :in_place,
            "the release is a pre-release. Fix: gh release edit #{@tag} --prerelease=false"
          )
        end

        # A draft has no publication date and is not yet immutable: both begin
        # when it is published, so neither is checked until then.
        return out if release.draft

        published_at = release.published_at
        if published_at
          published_on = Time.iso8601(published_at).utc.strftime("%Y%m%d")
          if published_on != match[:date]
            out << Refusal.new(
              "1.3", :new_tag,
              "the tag's date is #{match[:date]}, the release was published on " \
              "#{published_on} UTC (published_at #{published_at}). #{NEW_TAG}"
            )
          end
        end

        if !release.immutable
          if @tag == FROZEN_TAG
            @notes << "#{@tag} is not immutable: it was published before immutable " \
                      "releases were enabled, and ADR-0050 leaves it so. Consumers " \
                      "pinning it must keep re-fetching its sibling."
          else
            out << Refusal.new(
              "1.7", :new_tag,
              "the release is not immutable, so its assets can still be replaced " \
              "(ADR-0050). Check the repository's release immutability setting. " \
              "A published release cannot be made immutable in place. #{NEW_TAG}"
            )
          end
        end

        out
      end

      def latest_refusals
        return [] if @latest_tag == FROZEN_TAG

        found = @latest_tag.nil? ? "names no tag" : "resolves to #{@latest_tag}"
        [
          Refusal.new(
            "1.6", :in_place,
            "/releases/latest #{found}; it never moves from #{FROZEN_TAG} (ADR-0048). " \
            "Fix: gh release edit #{FROZEN_TAG} --latest"
          )
        ]
      end

      def target_refusals
        return [] if @tag_target && @tag_target == @release_tip

        [
          Refusal.new(
            "ADR-0047", :new_tag,
            "the tag resolves to #{@tag_target || "(unreadable)"}, release's tip is " \
            "#{@release_tip || "(unreadable)"}; a tag targets the release commit " \
            "that cut its bundle. #{NEW_TAG}"
          )
        ]
      end

      def asset_refusals(asset)
        # @type var out: Array[Refusal]
        out = []
        sidecar = "#{asset}.sha256"

        names = @release.asset_names
        if names.sort != [asset, sidecar].sort
          out << Refusal.new(
            "1.4", :new_tag,
            "the release's assets are #{names.inspect}, expected exactly " \
            "#{[asset, sidecar].inspect}. #{NEW_TAG}"
          )
        end

        entry = Sibling.parse(@sibling)
        if entry.nil?
          out << Refusal.new(
            "1.4", :new_tag,
            "the published #{sidecar} is not in sha256sum form: found #{@sibling[0, 200].inspect}. #{NEW_TAG}"
          )
          return out
        end

        if entry.name != asset
          out << Refusal.new(
            "1.4", :new_tag,
            "the published #{sidecar} names #{entry.name}, expected #{asset}. #{NEW_TAG}"
          )
        end

        digest_refusal = digests(entry.digest)
        out << digest_refusal if digest_refusal
        out
      end

      # Three numbers that must be one. Which pair disagrees says what broke.
      def digests(published)
        local = @local_sha256
        downloaded = @downloaded_sha256
        return nil if local == published && published == downloaded

        cause =
          if local == downloaded
            "the asset is the file checked here, but its published sibling is wrong"
          elsif published == downloaded
            "the published asset and its sibling agree with each other and not with " \
            "the local tarball: the release carries a file, but not the file checked here"
          else
            "the published asset does not match its published sibling: a changed or " \
            "corrupted upload"
          end

        Refusal.new(
          "1.4", :new_tag,
          "#{cause} (local #{local}, sibling #{published}, downloaded #{downloaded}). #{NEW_TAG}"
        )
      end
    end
  end
end
