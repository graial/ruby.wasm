# frozen_string_literal: true

# Extracts the absolute paths embedded in a build recipe captured from
# `make -n`, as a Path trace: one entry per occurrence, in the order walked.
#
# This implements section 5.3 of the Release Bundle contract, and is the single
# extractor of 5.6 — every bundle is cut with it, whether a workflow or a hand
# invoked it, which is what makes `capture: manual` a weaker guarantee about
# the applying rather than about what was applied.
#
# It is a reader, not an assertion. A word it cannot classify under 5.3 is a
# *reading* failure, upstream of every check in the contract's section 6, all
# of which take a complete trace as input and judge it. So it raises rather
# than returning a partial trace: a partial trace flowing into a coverage
# assertion is how a path gets shed quietly.
module RubyWasm
  module ReleaseBundle
    # Raised for anything section 5.3 does not classify. Carries the position as
    # data so a caller reports it without parsing a message — an exit status is
    # not a diagnosis, and neither is a string a caller has to scrape.
    class ExtractionError < StandardError
      attr_reader :source, :line_number, :column, :word, :reason

      def initialize(reason, source:, line_number:, column:, word: nil)
        @reason = reason
        @source = source
        @line_number = line_number
        @column = column
        @word = word
        at = "#{source}:#{line_number}:#{column}"
        super(word.nil? ? "#{at}: #{reason}" : "#{at}: #{reason}: #{word}")
      end
    end

    # One shell word, and the zero-based column it began at, so a failure
    # inside a word is reported against the line rather than against the word.
    # A word is only built once it has a character, so the offset is always
    # known by then.
    class Word
      attr_reader :text, :offset

      def initialize(text, offset)
        @text = text
        @offset = offset
      end
    end

    # One "/" the anchor rule declined, with the word it sat in and the value
    # that would have been read had it been admitted.
    #
    # 5.3 calls the anchor set the weakest clause in the contract, and says why:
    # everywhere else in section 5 being wrong is loud, because an
    # unclassifiable word stops the release. Here it is quiet — a word carrying
    # an absolute path the anchors do not admit yields no path, and nothing
    # stops. A shed path is that silence made enumerable.
    #
    # The word is carried because a declined "/" is only judgeable in context:
    # "/extinit.o" means one thing inside `ext/extinit.o` and another on its own.
    class ShedPath
      attr_reader :source, :line_number, :column, :word, :would_have_read

      def initialize(source:, line_number:, column:, word:, would_have_read:)
        @source = source
        @line_number = line_number
        @column = column
        @word = word
        @would_have_read = would_have_read
      end

      # The position in the same shape ExtractionError prints, so a shed entry
      # and a refusal name a place the same way.
      def at
        "#{source}:#{line_number}:#{column}"
      end
    end

    class Extractor
      # A quote both anchors a path and terminates one.
      QUOTES = ['"', "'"].freeze
      BLANKS = [" ", "\t"].freeze

      # These anchor a path and do not terminate one, so each can appear
      # inside an extracted value. That is the whole class the stop below
      # covers, stated once rather than a clause per character.
      SEPARATORS = ["=", ",", ":", ">", "<"].freeze
      SEPARATOR_PATTERN = Regexp.union(SEPARATORS)

      # A "/" begins an embedded path only where it is anchored: at the start
      # of a word, after one of these characters, or after an option name.
      ANCHORS = (QUOTES + SEPARATORS).freeze

      # An option name is one or more dashes then letters only. That is what
      # separates -I/opt/include, where the path is the option's argument,
      # from -I.ext/include and ext/extinit.o, where it is not a path at all.
      OPTION_NAME = /\A-+[A-Za-z]*\z/

      # +source+ names the thing being read and appears in every error. It
      # defaults to "-" so a caller reading from somewhere unnamed still gets a
      # well-formed position.
      def initialize(source: "-")
        @source = source
      end

      def self.extract_file(path)
        new(source: path).extract(File.read(path))
      end

      def self.shed_file(path)
        new(source: path).shed(File.read(path))
      end

      # Returns the Path trace: every embedded path in +text+, one entry per
      # occurrence, left to right within a line and lines in order. Not sorted,
      # not deduplicated — the order is the contract (5.5).
      #
      # The whole text is walked before anything is returned, so a caller cannot
      # stream a trace that later turns out to be partial.
      def extract(text)
        walk(text).first
      end

      # The shed paths of +text+: every "/" the anchor rule declined, one entry
      # per occurrence, in the order walked.
      #
      # **A report, never an assertion, and never a Path trace.** 5.5 fixes what
      # a trace is and 6.2 consumes it; this is a diagnostic a human reads.
      # Deciding whether a declined "/" was really a path is a reading, and 5.3
      # is explicit that the anchor set was derived from the shapes CRuby's
      # recipes are known to carry rather than from a transcript. Code that
      # failed on a non-empty shed list would be judging what the contract says
      # a human must, and it would stop every correct capture, since
      # `ext/extinit.o` sheds "/extinit.o" on every link recipe ever taken.
      #
      # It is also not a bundle member. 6.6 fixes the member set and asserts it
      # in both directions, so a shed list written into a bundle tree would
      # change what a v1 bundle is.
      #
      # It reports non-admission only. A path silently *truncated* at a quote is
      # the other quiet failure in 5.3 and does not appear here; that one
      # surfaces as a trace carrying more entries than the consumer's.
      #
      # It raises exactly where +extract+ raises, because both read one walk. A
      # shed list taken from a recipe whose extraction failed would be a partial
      # reading presented as a complete one, which is 5.6's objection to a
      # partial trace arriving beside a warning.
      def shed(text)
        walk(text).last
      end

      private

      # The one walk. +extract+ and +shed+ are two readings of it rather than
      # two traversals, so they cannot disagree about which "/" was admitted.
      # A second pass that recomputed the admitted spans would be a second
      # reading of 5.3, which is what 5.6 ships one extractor to prevent.
      def walk(text)
        # @type var trace: Array[String]
        trace = []
        # @type var shed: Array[ShedPath]
        shed = []
        text.each_line.with_index(1) do |line, line_number|
          split_words(line.chomp, line_number).each do |word|
            admitted, declined = paths_in(word, line_number)
            trace.concat(admitted)
            shed.concat(declined)
          end
        end
        [trace, shed]
      end

      # A shell word is delimited by unquoted whitespace. Quote state here uses
      # *matching* quotes, because that is what decides whether a space splits a
      # word. Path termination, below, deliberately uses a different rule.
      #
      # Word text is kept raw, quotes included, because the quotes are what
      # terminate a path.
      def split_words(line, line_number)
        # @type var words: Array[Word]
        words = []
        buffer = +""
        offset = nil
        open_quote = nil

        line.each_char.with_index do |char, index|
          if open_quote
            buffer << char
            open_quote = nil if char == open_quote
          elsif QUOTES.include?(char)
            offset ||= index
            buffer << char
            open_quote = char
          elsif BLANKS.include?(char)
            next if buffer.empty?
            words << Word.new(buffer, offset || 0)
            buffer = +""
            offset = nil
          else
            offset ||= index
            buffer << char
          end
        end

        if open_quote
          raise ExtractionError.new(
                  "unbalanced #{open_quote} - the line does not tokenize",
                  source: @source,
                  line_number: line_number,
                  column: (offset || 0) + 1,
                  word: buffer
                )
        end

        words << Word.new(buffer, offset || 0) unless buffer.empty?
        words
      end

      # Within a word, every anchored "/"-initial substring is an embedded
      # path. The terminator applies before maximality: a path runs from "/"
      # to the next quote of either kind, or the end of the word. A quote ends
      # a path and is never inside one, so -DFOO="/a/b" yields /a/b.
      #
      # Scanning resumes past a terminator, because one word may carry more
      # than one path.
      def paths_in(word, line_number)
        text = word.text
        # @type var found: Array[String]
        found = []
        # @type var shed: Array[ShedPath]
        shed = []
        index = 0

        while index < text.length
          unless text[index] == "/"
            index += 1
            next
          end

          unless anchored?(text, index)
            shed << ShedPath.new(
              source: @source,
              line_number: line_number,
              column: word.offset + index + 1,
              word: text,
              would_have_read: text[index...terminator(text, index)].to_s
            )
            # Advance one character, not to the terminator. A later "/" inside
            # the same declined run can still be anchored — `foo/bar=/baz`
            # sheds "/bar=/baz" and admits "/baz" — and skipping ahead would
            # swallow the admitted one, which is a path shed by the shed list
            # itself.
            index += 1
            next
          end

          stop = terminator(text, index)
          path = text[index...stop].to_s

          if path.match?(/[ \t]/)
            raise ExtractionError.new(
                    "path contains whitespace and can be neither matched nor reassembled",
                    source: @source,
                    line_number: line_number,
                    column: word.offset + index + 1,
                    word: path
                  )
          end

          # A character that anchors a path without terminating one can sit
          # inside an extracted value, and nothing in the word says whether it
          # separates two paths or belongs to a filename. Treating it as a
          # separator truncates a name; treating it as ordinary runs one value
          # past the path into a flag or a second path, which a root key still
          # matches by prefix. Both are quiet, so neither is guessed at.
          separator = path[SEPARATOR_PATTERN]
          unless separator.nil?
            raise ExtractionError.new(
                    "path contains #{separator}, which anchors a path without terminating one - " \
                    "a separator and a filename character cannot be told apart",
                    source: @source,
                    line_number: line_number,
                    column: word.offset + index + 1,
                    word: path
                  )
          end

          found << path
          index = stop + 1
        end

        [found, shed]
      end

      # Where a path beginning at +index+ ends: the next quote of either kind,
      # or the end of the word. Stated once because an admitted path and a
      # declined one have to be read to the same place — a shed entry reported
      # against a different terminator than the extractor uses would describe a
      # value the extractor would never have produced.
      def terminator(text, index)
        stop = index
        stop += 1 while stop < text.length && !QUOTES.include?(char_at(text, stop))
        stop
      end

      # Without this, the maximal "/"-initial substring of the relative word
      # ext/extinit.o is /extinit.o, which no key covers — so the coverage
      # assertion would stop every capture, since that word is on every link
      # recipe.
      def anchored?(text, index)
        return true if index.zero?
        return true if ANCHORS.include?(char_at(text, index - 1))
        OPTION_NAME.match?(text[0, index].to_s)
      end

      # String#[] is nil-returning at the type level even where the caller has
      # already bounds-checked, so the bound is stated once here rather than
      # asserted at five call sites.
      def char_at(text, index)
        text[index] || ""
      end
    end
  end
end