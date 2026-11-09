# frozen_string_literal: true

module RubyWasm
  module ReleaseBundle
    # The checks that hold the link recipe to the Build it claims to describe
    # (ADR-0068, as corrected; ADR-0069). Each compares the selected line with
    # an artifact: the archives' symbol tables, the generated ext/extinit.c,
    # the linked binary's name section, file times and file hashes.
    #
    # Pure. The caller reads the artifacts — llvm-nm for objects and archives,
    # the Build's own `wasm-opt --print-function-map` for ruby, stat, sha256 —
    # and this decides.
    module Agreement
      Refusal = Struct.new(:clause, :message)
      Result = Struct.new(:extensions, :refusals)

      NM_LINE = /\A\h+ (?<type>[A-Za-z]) (?<name>\S+)\z/
      MAP_LINE = /\A\d+:(?<name>.+)\z/
      INIT_CALL = /\binit\((?<func>Init_\w+),\s*"(?<name>[^"]*)"\)/
      WEAK_OR_ANY = /\A[A-Za-z]\z/

      # Defined symbols from `llvm-nm --defined-only <file>` output, as
      # [type, name]. Member headers ("x.o:") and blank lines carry none.
      def self.parse_nm(text)
        text.each_line.filter_map do |l|
          m = NM_LINE.match(l.chomp)
          m && [m[:type].to_s, m[:name].to_s]
        end
      end

      # Function names from `wasm-opt --print-function-map`, "<index>:<name>".
      def self.parse_function_map(text)
        text.each_line.filter_map { |l| MAP_LINE.match(l.chomp)&.[](:name) }
      end

      # [func, extension name] per init(…) call, in file order. The #define
      # line names `func, name` without quotes and is not a call.
      def self.parse_extinit(text)
        text.each_line.filter_map do |l|
          m = INIT_CALL.match(l)
          m && [m[:func].to_s, m[:name].to_s]
        end
      end

      # symbols: input label => [[type, name], …] for every input the line
      #   resolves (LinkLine::Classification#inputs); a missing label is a
      #   refusal, never an empty table.
      # function_map: the names in ruby's name section.
      # extinit_c: ext/extinit.c's text, or nil when the tree has none.
      def self.check(inputs:, ext_archives:, words:, symbols:, function_map:, extinit_c:)
        # @type var out: Array[Refusal]
        out = []
        # @type var extensions: Array[String]
        extensions = []

        missing = inputs.reject { |f| symbols.key?(f) }
        unless missing.empty?
          out << Refusal.new("6.8", "no symbol table read for #{missing.length} input(s): #{missing.first(5).join(", ")}")
        end
        if function_map.empty?
          out << Refusal.new(
            "6.8",
            "ruby's function map is empty: no name section was read, and an empty list " \
            "is not evidence that no initialiser is linked"
          )
          return Result.new(extensions, out)
        end
        in_ruby = function_map.to_h { |n| [n, true] }

        # Every Init_ function in ruby is defined by a file on the line. Any
        # defined type counts, weak included: ruby.c's empty weak
        # Init_extra_exts is what links when nothing overrides it.
        # @type var defined: Hash[String, bool]
        defined = {}
        inputs.each do |f|
          symbols.fetch(f, []).each { |(type, name)| defined[name] = true if WEAK_OR_ANY.match?(type) }
        end
        orphans = function_map.select { |n| n.start_with?("Init_") && !defined.key?(n) }
        unless orphans.empty?
          out << Refusal.new(
            "6.8",
            "#{orphans.length} Init_ function(s) in ruby are defined by no file on the link recipe: " \
            "#{orphans.first(5).join(", ")}; the binary was not linked from this line"
          )
        end

        # Encodings, both directions.
        libenc = words.any? { |w| w.kind == :tree_file && w.text == "enc/libenc.a" }
        utf16 = in_ruby.key?("Init_utf_16le")
        if libenc != utf16
          out << Refusal.new(
            "6.8",
            "enc/libenc.a is #{libenc ? "" : "not "}on the link recipe and Init_utf_16le is " \
            "#{utf16 ? "" : "not "}in ruby; they must agree"
          )
        end

        has_dmyext = words.any? { |w| w.kind == :tree_file && w.text == "dmyext.o" }
        has_extinit_o = words.any? { |w| w.kind == :tree_file && w.text == "ext/extinit.o" }

        if has_dmyext && has_extinit_o
          out << Refusal.new("6.8", "the link recipe names both dmyext.o and ext/extinit.o")
        end
        if has_dmyext
          out << Refusal.new("6.8", "the link recipe names dmyext.o, and the tree has an ext/extinit.c") if extinit_c
          unless ext_archives.empty?
            out << Refusal.new("6.8", "the link recipe names dmyext.o and #{ext_archives.length} ext/**/*.a")
          end
          return Result.new(extensions, out)
        end
        unless has_extinit_o
          out << Refusal.new("6.8", "the link recipe names neither dmyext.o nor ext/extinit.o")
          return Result.new(extensions, out)
        end
        if extinit_c.nil?
          out << Refusal.new("6.8", "the link recipe names ext/extinit.o and the tree has no ext/extinit.c")
          return Result.new(extensions, out)
        end

        calls = parse_extinit(extinit_c)
        names = calls.map(&:last)
        dups = names.tally.select { |_, n| n > 1 }.keys
        out << Refusal.new("4.10", "ext/extinit.c names #{dups.join(", ")} more than once") unless dups.empty?
        extensions = names

        # One to one, through strong definitions: each init(Init_X, …) is
        # defined by exactly one ext archive on the line, and each archive
        # defines exactly one of them.
        funcs = calls.map(&:first)
        by_archive = ext_archives.to_h do |a|
          strong = symbols.fetch(a, []).select { |(type, _)| type == "T" }.map(&:last)
          [a, strong & funcs]
        end
        funcs.each do |f|
          owners = by_archive.select { |_, fs| fs.include?(f) }.keys
          unless owners.length == 1
            out << Refusal.new(
              "6.8",
              "#{f} (ext/extinit.c) is defined by #{owners.length} ext archive(s) on the line" \
              "#{owners.empty? ? "" : ": #{owners.join(", ")}"}; it must be exactly one"
            )
          end
          out << Refusal.new("6.8", "#{f} is called by ext/extinit.c and is not in ruby") unless in_ruby.key?(f)
        end
        by_archive.each do |a, fs|
          next if fs.length == 1
          out << Refusal.new(
            "6.8",
            "#{a} defines #{fs.length} of ext/extinit.c's initialisers#{fs.empty? ? "" : " (#{fs.join(", ")})"}; it must be exactly one"
          )
        end

        Result.new(extensions, out)
      end

      # 6.0, second step: ruby is newer than main.o and every input the line
      # resolves. mtimes are the real tree's; nil means absent.
      def self.freshness(ruby_mtime:, mtimes:)
        # @type var out: Array[Refusal]
        out = []
        if ruby_mtime.nil?
          out << Refusal.new("6.0", "ruby is absent")
          return out
        end
        mtimes.each do |label, t|
          if t.nil?
            out << Refusal.new("6.0", "#{label} is named by the link recipe and absent")
          elsif !(ruby_mtime > t)
            out << Refusal.new("6.0", "ruby is not newer than #{label}: the binary did not come from the files the bundle ships")
          end
        end
        out
      end

      # The real tree is untouched: path => sha256, before and after.
      def self.untouched(before:, after:)
        # @type var out: Array[Refusal]
        out = []
        if before.empty?
          out << Refusal.new("6.1", "no files were hashed in the real tree before the capture")
          return out
        end
        changed = (before.keys | after.keys).select { |p| before[p] != after[p] }
        unless changed.empty?
          out << Refusal.new(
            "6.1",
            "the real Build tree changed during the capture: #{changed.length} file(s), " \
            "#{changed.first(5).join(", ")}"
          )
        end
        out
      end
    end
  end
end
