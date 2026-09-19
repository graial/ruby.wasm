# frozen_string_literal: true

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
    # It refuses and reports. It does not choose. 1.3 says the ordinal carries
    # uniqueness and nothing else, and that publish time is not when to decide
    # what — so a preflight that silently incremented past a collision would be
    # making the decision it exists to surface. It names the next free ordinal
    # and stops.
    class Preflight
      # 1.3: Build name, date, ordinal, the ordinal always present.
      TAG = /\A(?<build>.+)-(?<date>\d{8})\.(?<ordinal>\d+)\z/

      Refusal = Struct.new(:clause, :message)

      # existing_tags: every tag name on the remote.
      # archive_members: the top-level entries inside the tarball (1.5).
      # recorded_sha256 / actual_sha256: the sibling file's content and the
      #   tarball's real digest (1.4).
      def initialize(
        tag:,
        build_name:,
        existing_tags:,
        asset_name: nil,
        archive_members: nil,
        recorded_sha256: nil,
        actual_sha256: nil
      )
        @tag = tag
        @build_name = build_name
        @existing_tags = existing_tags
        @asset_name = asset_name
        @archive_members = archive_members
        @recorded_sha256 = recorded_sha256
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

        if match[:build] != @build_name
          out << Refusal.new(
            "1.3",
            "tag names Build #{match[:build].inspect}, expected #{@build_name.inspect}"
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
      def next_ordinal(match = TAG.match(@tag))
        prefix = "#{@build_name}-#{match[:date]}."
        taken =
          @existing_tags.filter_map do |t|
            Integer(t.delete_prefix(prefix), exception: false) if t.start_with?(prefix)
          end
        (1..).find { |n| !taken.include?(n) }
      end

      # 1.3's asset name, 1.4's sibling, 1.5's single top-level directory.
      def self.asset_name_for(tag, match = TAG.match(tag))
        "ruby-#{match[:build]}-lib-#{match[:date]}.#{match[:ordinal]}.tar.gz"
      end

      def self.stem_for(asset_name)
        asset_name.delete_suffix(".tar.gz")
      end

      private

      def asset_refusals(match)
        # @type var out: Array[Refusal]
        out = []
        return out if @asset_name.nil?

        expected = self.class.asset_name_for(@tag, match)
        if @asset_name != expected
          out << Refusal.new("1.3", "asset is #{@asset_name}, expected #{expected}")
          return out
        end

        if @recorded_sha256.nil?
          out << Refusal.new(
            "1.4",
            "no #{@asset_name}.sha256 sibling; a download that cannot be " \
            "checked is a download that is described"
          )
        elsif @actual_sha256 && @recorded_sha256 != @actual_sha256
          out << Refusal.new(
            "1.4",
            "#{@asset_name}.sha256 records #{@recorded_sha256}, tarball is #{@actual_sha256}"
          )
        end

        unless @archive_members.nil?
          stem = self.class.stem_for(@asset_name)
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
    end
  end
end