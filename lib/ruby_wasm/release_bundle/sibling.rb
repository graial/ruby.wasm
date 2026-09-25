# frozen_string_literal: true

module RubyWasm
  module ReleaseBundle
    # The .sha256 sibling a Release Bundle's tarball is published with (1.4):
    # sha256sum's form, exactly. That is the tarball's digest in 64 lowercase
    # hex characters, two spaces, the asset's file name, and one "\n".
    #
    # Exactly, because consumers parse it. Pipeline context records the digest
    # from this file rather than computing its own, and re-fetches it on every
    # run. A variation that the fork's tools tolerated would be one the fork
    # could publish, and the first to notice would be a consumer. So nothing
    # here repairs a near miss. A bare digest, a CRLF ending, a binary-mode "*"
    # or BSD's tagged form all parse as nothing.
    #
    # The preflight and the postflight both read siblings through this, so "the
    # form the fork refuses" has one definition, not two that agree today.
    module Sibling
      FORM = /\A(?<digest>[0-9a-f]{64}) {2}(?<name>[^\s]+)\n\z/

      # A plain class, not a Struct: Steep types a Struct subclass's .new by
      # Struct's own class-building signature, which only accepts strings and
      # symbols.
      class Entry
        attr_reader :digest, :name

        def initialize(digest, name)
          @digest = digest
          @name = name
        end
      end

      # The digest and file name a sibling states, or nil when it is not in the
      # form at all.
      def self.parse(contents)
        match = FORM.match(contents)
        return nil if match.nil?

        Entry.new(match[:digest].to_s, match[:name].to_s)
      end

      # What a sibling for this digest and asset contains, byte for byte.
      def self.line(digest, name)
        "#{digest}  #{name}\n"
      end
    end
  end
end
