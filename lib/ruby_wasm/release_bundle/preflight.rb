# frozen_string_literal: true

require_relative "sibling"

module RubyWasm
  module ReleaseBundle
    # Refusals that stop a publication, per contract section 1.
    #
    # Pure: it is handed the intended tag, the tags that already exist, and what
    # the local artifacts look like, and it returns what is wrong. Nothing here
    # talks to a network or a filesystem, so every refusal below is reachable
    # from a spec — which matters more than usual, because a preflight that
    # cannot refuse is indistinguishable from one that found nothing wrong.
    #
    # The Build name a tag is checked against comes from the bundle itself —
    # the build_name in the tarball's own manifest.yml — and never from the tag.
    # An expected value derived from the thing being checked is the thing being
    # checked, and a comparison of a value with itself cannot fail.
    #
    # It refuses and reports. It does not choose. 1.3 says the ordinal carries
    # uniqueness and nothing else, and that publish time is not when to decide
    # what — so a preflight that silently incremented past a collision would be
    # making the decision it exists to surface. It names the next free ordinal
    # and stops.
    class Preflight
      # 1.3: Build name, date, ordinal, the ordinal always present.
      TAG = /\A(?<build>.+)-(?<date>\d{8})\.(?<ordinal>\d+)\z/

      Refusal = Struct.new(:clause, :message)

      # build_name: manifest.yml's build_name, read from inside the tarball;
      #   nil when it could not be read.
      # today: the UTC calendar date the preflight runs, as YYYYMMDD. Passed in
      #   rather than read from a clock, so the date refusal has a spec.
      # existing_tags: every tag name on the remote.
      # archive_members: the top-level entries inside the tarball (1.5).
      # sibling: the .sha256 sibling's whole contents, unparsed, so that its
      #   form is checked here and not assumed by whoever read it (1.4).
      # actual_sha256: the tarball's real digest.
      def initialize(
        tag:,
        build_name:,
        today:,
        existing_tags:,
        asset_name: nil,
        archive_members: nil,
        sibling: nil,
        actual_sha256: nil
      )
        @tag = tag
        @build_name = build_name
        @today = today
        @existing_tags = existing_tags
        @asset_name = asset_name
        @archive_members = archive_members
        @sibling = sibling
        @actual_sha256 = actual_sha256
      end

      def refusals
        # @type var out: Array[Refusal]
        out = []
        match = TAG.match(@tag)

        unless match
          out << Refusal.new(
            "1.3",
            "tag #{@tag.inspect} is not <build-name>-<YYYYMMDD>.<ordinal>; " \
            "the ordinal is always present, because a suffix that exists only " \
            "sometimes is a suffix whose absence means something"
          )
          return out
        end

        if @build_name.nil?
          out << Refusal.new(
            "1.3",
            "no build_name could be read from the tarball's manifest.yml, so the " \
            "tag's Build name has nothing to be checked against"
          )
        elsif match[:build] != @build_name
          out << Refusal.new(
            "1.3",
            "tag names Build #{match[:build].inspect}, the bundle's manifest.yml " \
            "says #{@build_name.inspect}"
          )
        end

        if match[:date] != @today
          out << Refusal.new(
            "1.3",
            "tag date #{match[:date]} is not today's UTC date #{@today}. The date " \
            "is the day the release is published; a bundle packed under another " \
            "date is assembled again, not renamed"
          )
        end

        if @existing_tags.include?(@tag)
          out << Refusal.new(
            "1.7",
            "tag #{@tag} already exists and tags are never moved or deleted. " \
            "Next free ordinal for #{match[:date]}: #{next_ordinal(match)}"
          )
        end

        out.concat(asset_refusals(match))
        out
      end

      def pass?
        refusals.empty?
      end

      # The lowest ordinal not taken for this Build on this date. Reported so an
      # operator can choose it, never applied.
      #
      # The namespace is the tag's own Build and date, which is what a
      # collision is a collision in.
      def next_ordinal(match = TAG.match(@tag))
        raise ArgumentError, "#{@tag.inspect} is not a tag, so it has no ordinals" if match.nil?

        prefix = "#{match[:build]}-#{match[:date]}."
        taken =
          @existing_tags.filter_map do |t|
            Integer(t.delete_prefix(prefix), exception: false) if t.start_with?(prefix)
          end
        n = 1
        n += 1 while taken.include?(n)
        n
      end

      # 1.3's asset name, 1.4's sibling, 1.5's single top-level directory.
      def self.asset_name_for(tag, match = TAG.match(tag))
        raise ArgumentError, "#{tag.inspect} is not a tag, so it names no asset" if match.nil?

        "ruby-#{match[:build]}-lib-#{match[:date]}.#{match[:ordinal]}.tar.gz"
      end

      def self.stem_for(asset_name)
        asset_name.delete_suffix(".tar.gz")
      end

      private

      def asset_refusals(match)
        # @type var out: Array[Refusal]
        out = []
        # A local, because a nil check on an instance variable does not narrow it.
        asset_name = @asset_name
        return out if asset_name.nil?

        expected = self.class.asset_name_for(@tag, match)
        if asset_name != expected
          out << Refusal.new("1.3", "asset is #{asset_name}, expected #{expected}")
          return out
        end

        out.concat(sibling_refusals(asset_name))

        unless @archive_members.nil?
          stem = self.class.stem_for(asset_name)
          if @archive_members != [stem]
            out << Refusal.new(
              "1.5",
              "tarball's top level is #{@archive_members.inspect}, expected " \
              "exactly [#{stem.inspect}] so --strip-components=1 lands " \
              "somewhere fixed"
            )
          end
        end

        out
      end

      # 1.4: the sibling exists, is in sha256sum form exactly, names this asset,
      # and records this tarball's digest. The name and the digest are reported
      # separately: a sibling copied from another bundle is wrong in both, and
      # knowing that is how a reader tells a copy from a corruption.
      def sibling_refusals(asset_name)
        # @type var out: Array[Refusal]
        out = []
        sibling = @sibling
        sidecar = "#{asset_name}.sha256"

        if sibling.nil?
          out << Refusal.new(
            "1.4",
            "no #{sidecar} sibling; a download that cannot be checked is a " \
            "download that is described"
          )
          return out
        end

        entry = Sibling.parse(sibling)
        if entry.nil?
          shown = sibling.length > 200 ? "#{sibling[0, 200]}..." : sibling
          out << Refusal.new(
            "1.4",
            "#{sidecar} is not in sha256sum form: expected " \
            "#{Sibling.line("<64 lowercase hex>", asset_name).inspect}, " \
            "found #{shown.inspect}"
          )
          return out
        end

        if entry.name != asset_name
          out << Refusal.new("1.4", "#{sidecar} names #{entry.name}, expected #{asset_name}")
        end

        actual = @actual_sha256
        if actual && entry.digest != actual
          out << Refusal.new("1.4", "#{sidecar} records #{entry.digest}, tarball is #{actual}")
        end

        out
      end
    end
  end
end