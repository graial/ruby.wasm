# frozen_string_literal: true

module RubyWasm
  module ReleaseBundle
    # Whether a Build tree may be captured (contract 6.0), and which lines of its
    # `make -n` transcripts are the Reference recipes (6.1, 5.1).
    #
    # Pure, for the reason Preflight is. bin/capture-recipes gathers the facts —
    # three mtimes, the checkout's `git status`, two transcripts — and this
    # decides. Every refusal is therefore reachable from a spec without a Build
    # tree or a `make`, and a capture whose refusals are untested is a capture
    # nobody has seen stop.
    #
    # It selects by rule and never by judgement. 6.1: "Selecting by a rule that
    # must match once is stating a fact. Selecting a line that looked right is a
    # judgement." So there is no fallback, no "closest match", and no joining of
    # continued lines: every way the rule fails to pick exactly one whole
    # physical line is a refusal.
    class Capture
      Refusal = Struct.new(:clause, :message)

      # What a successful selection produces. link_raw and compile_raw are the
      # exact bytes of link.raw.txt and compile.raw.txt, and are nil whenever
      # refusals is non-empty — a partial capture is not handed to anything.
      Selection = Struct.new(:link_raw, :compile_raw, :refusals, :notes)

      # 6.1's table. The contract states these as grep patterns applied one
      # line at a time. Here they are applied to one physical line at a time,
      # with its "\n" removed, so grep's `$` is `\z`. The link pattern is
      # anchored because the wasm-opt line also contains "-o ruby".
      LINK = /-o ruby\z/
      WASM_OPT = %r{bin/wasm-opt }
      COMPILE = /-o main\.o /

      # 6.0, including its third bullet: the checkout is tracked-clean per 4.3.
      #
      # mtimes are nil when the file is absent. checkout_changes is the output
      # of `git status --porcelain --untracked-files=no`, one entry per line.
      def self.preconditions(
        tree_exists:,
        ruby_mtime:,
        main_o_mtime:,
        extinit_o_mtime:,
        checkout_changes:
      )
        # @type var out: Array[Refusal]
        out = []

        unless tree_exists
          out << Refusal.new("6.0", "the Build tree does not exist")
          return out
        end

        if ruby_mtime.nil?
          out << Refusal.new(
            "6.0",
            "ruby is absent: no completed link, and a printed recipe is not a completed link"
          )
        end
        if main_o_mtime.nil?
          out << Refusal.new("6.0", "main.o is absent")
        end
        if extinit_o_mtime.nil?
          out << Refusal.new(
            "6.0",
            "ext/extinit.o is absent. It is generated at link time, so `make ruby` " \
            "has not completed. The build driver reports success before it has."
          )
        end

        if ruby_mtime && main_o_mtime && !(ruby_mtime > main_o_mtime)
          out << Refusal.new("6.0", "ruby is not newer than main.o")
        end
        if ruby_mtime && extinit_o_mtime && !(ruby_mtime > extinit_o_mtime)
          out << Refusal.new("6.0", "ruby is not newer than ext/extinit.o")
        end

        unless checkout_changes.empty?
          shown = checkout_changes.first(5).join("; ")
          out << Refusal.new(
            "4.3",
            "the checkout has #{checkout_changes.length} tracked modification(s) " \
            "(#{shown}); a fork_commit recorded from a modified tree names a tree nobody has"
          )
        end

        out
      end

      # 6.1 and 5.1. ruby_transcript is `make -n ruby`; main_transcript is
      # `make -n -W main.c main.o`. Each is one invocation's whole stdout, and
      # counting and selecting both read it — never a second invocation.
      def self.select(ruby_transcript:, main_transcript:)
        # @type var refusals: Array[Refusal]
        refusals = []
        # @type var notes: Array[String]
        notes = []

        ruby_lines = physical_lines(ruby_transcript)
        main_lines = physical_lines(main_transcript)

        link = pick(ruby_lines, LINK, "link recipe", "make -n ruby", refusals)
        wasm_opt = pick(ruby_lines, WASM_OPT, "wasm-opt line", "make -n ruby", refusals)
        compile = pick(main_lines, COMPILE, "compile recipe", "make -n -W main.c main.o", refusals)

        # 5.1: the wasm-opt line *after* the link recipe. The file is written in
        # the link-then-wasm-opt order, so that order has to be the transcript's
        # and not just the order the patterns were tried in.
        if link && wasm_opt
          link_at = link[0]
          opt_at = wasm_opt[0]
          if opt_at <= link_at
            refusals << Refusal.new(
              "5.1",
              "the wasm-opt line is transcript line #{opt_at + 1} and the link recipe " \
              "is line #{link_at + 1}; 5.1 requires the wasm-opt line after it"
            )
          else
            # Adjacency is reported, not required: 5.1 says "after", and a rule
            # stricter than the clause would stop a release the contract permits.
            gap = opt_at - link_at
            notes << (
              if gap == 1
                "the wasm-opt line (#{opt_at + 1}) immediately follows the link recipe (#{link_at + 1})"
              else
                "the wasm-opt line (#{opt_at + 1}) follows the link recipe (#{link_at + 1}) " \
                "with #{gap - 1} line(s) between them"
              end
            )
          end
        end

        return Selection.new(nil, nil, refusals, notes) unless refusals.empty?

        # Only reached with all three selected, which the guard above ensures.
        link_line = link&.last.to_s
        opt_line = wasm_opt&.last.to_s
        compile_line = compile&.last.to_s
        Selection.new(
          "#{link_line}\n#{opt_line}\n",
          "#{compile_line}\n",
          refusals,
          notes
        )
      end

      # Physical lines, without their "\n". Exactly "\n": String#chomp("\n")
      # also strips "\r\n", which would clean a CRLF transcript up into a match
      # grep does not make. A line ending "\r" keeps it and fails the anchored
      # link pattern loudly.
      def self.physical_lines(text)
        text.each_line.map { |line| line.delete_suffix("\n") }
      end

      # [index, line] for the one line matching pattern, or nil after recording
      # why there is not exactly one whole physical line to take.
      def self.pick(lines, pattern, label, source, refusals)
        hits = lines.each_index.select { |i| pattern.match?(lines[i]) }

        unless hits.length == 1
          where = hits.empty? ? "" : " (lines #{hits.map { |i| i + 1 }.join(", ")})"
          refusals << Refusal.new(
            "6.1",
            "#{label}: #{pattern.inspect} matched #{hits.length} time(s) in the " \
            "#{source} transcript of #{lines.length} line(s)#{where}; it must match exactly once"
          )
          return nil
        end

        at = hits.fetch(0)
        line = lines[at]

        # Continuation in either direction. A selected line ending in a
        # backslash is the head of a longer recipe; a selected line whose
        # predecessor ends in one is the tail of a recipe that began earlier.
        # Either way the line is not the whole recipe, and 6.1 stops rather
        # than joining.
        if line.end_with?("\\")
          refusals << Refusal.new(
            "6.1",
            "#{label} (#{source} line #{at + 1}) ends in a backslash continuation; " \
            "a selected recipe must be a single physical line"
          )
          return nil
        end
        if at.positive? && lines[at - 1].end_with?("\\")
          refusals << Refusal.new(
            "6.1",
            "#{label} (#{source} line #{at + 1}) continues line #{at}, which ends in a " \
            "backslash; a selected recipe must be a single physical line"
          )
          return nil
        end

        [at, line]
      end

      private_class_method :physical_lines, :pick
    end
  end
end
