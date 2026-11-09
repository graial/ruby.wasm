# frozen_string_literal: true

module RubyWasm
  module ReleaseBundle
    # Compares a Build with a Reference fixture: a committed record of an
    # earlier Build at the Reserved path, which it must reproduce byte for byte.
    # Pure, and it lists every difference, not the first.
    module Reference
      LINE = /\A(?<digest>[0-9a-f]{64})  (?<path>.+)\z/

      # The fixture sheet's selection, which includes install/usr/local/bin/ruby
      # and so is wider than the Capture's own hashing: a regular file named
      # *.o, *.a or ruby, or ext/extinit.c, as a path starting "./".
      def self.selected?(path)
        name = File.basename(path)
        name.end_with?(".o", ".a") || name == "ruby" || path == "./ext/extinit.c"
      end

      # text: the fixture's tree-before.sha256. Nil for a line that is not
      # sha256sum form, because a list misread as shorter would pass.
      def self.parse(text)
        # @type var out: Hash[String, String]
        out = {}
        text.each_line(chomp: true) do |line|
          match = LINE.match(line)
          return nil if match.nil?
          out[match[:path].to_s] = match[:digest].to_s
        end
        out
      end

      # want / have: path => digest. want_link / have_link: the selected link
      # recipe, verbatim.
      def self.differences(want:, have:, want_link:, have_link:)
        # @type var out: Array[String]
        out = []
        (want.keys - have.keys).sort.each { |p| out << "only in the reference: #{p}" }
        (have.keys - want.keys).sort.each { |p| out << "only in this Build: #{p}" }
        (want.keys & have.keys).sort.each do |p|
          out << "differs: #{p} reference #{want[p]} this Build #{have[p]}" if want[p] != have[p]
        end
        out << "the selected link recipe differs from the reference's" if want_link != have_link
        out
      end
    end
  end
end
