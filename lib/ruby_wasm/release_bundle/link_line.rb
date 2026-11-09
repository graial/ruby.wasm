# frozen_string_literal: true

module RubyWasm
  module ReleaseBundle
    # Contract v3 2.1 and 3.1–3.3, as a rule: what the selected link recipe
    # names, read by a closed grammar (ADR-0069). Every word is placed, or the
    # capture stops. The members, the root Path keys and the inputs the
    # freshness and agreement checks read all come from this one reading.
    #
    # Pure. The caller supplies what the filesystem holds: which tree-relative
    # files exist, what each absolute -L root contains, and which archives the
    # wasi-sdk sysroot provides. Nothing here looks.
    module LinkLine
      Refusal = Struct.new(:clause, :message)

      # One word of the line and what the grammar made of it.
      #   kind: :compiler, :option, :option_argument, :search_root, :library,
      #         :flag, :token_file, :tree_file, :output
      #   file: for :library, :token_file and :tree_file, the file it names —
      #         tree-relative, or absolute for an outside root or token.
      Word = Struct.new(:index, :text, :kind, :file)

      # build_members: tree-relative paths that ship under build/ (main.o
      #   excluded; it is the consumer's).
      # root_keys: key name => { "value" => root, "archives" => [basename, …] }
      # inputs: every file the line resolves to except sysroot libraries, as
      #   labels — tree-relative, or absolute. What freshness and the Init_
      #   rule read.
      # ext_archives: the ext/**/*.a words, in line order.
      # sysroot: the -l names resolved in the sysroot.
      # wasi_sdk_path: from word 1, <path>/bin/clang.
      Classification =
        Struct.new(
          :words,
          :build_members,
          :root_keys,
          :inputs,
          :ext_archives,
          :sysroot,
          :wasi_sdk_path,
          :refusals
        )

      # Options whose next word is their argument and never a member.
      TAKES_ARGUMENT = %w[-o -Xlinker -z].freeze
      COMPILER = %r{\A(?<sdk>/.+)/bin/clang\z}
      ROOT = %r{\A(?<product>/.+)/opt/usr/local/lib\z}
      VERSIONED = /\A(?<name>[a-z][a-z0-9_]*?)-\d[^\/]*\z/
      MEMBER = /\.(o|a)\z/

      # line: the selected link recipe, one physical line, no "\n".
      # tree_files: tree-relative paths that exist in the Build tree.
      # token_keys: token key name => value; an absolute word must equal one.
      # root_listings: absolute -L root => basenames of the files in it.
      # sysroot_archives: basenames in <wasi_sdk>/share/wasi-sysroot/lib/wasm32-wasi.
      # existing_keys: key names already declared, which a root key may not take.
      def self.classify(
        line:,
        tree_files:,
        token_keys:,
        root_listings:,
        sysroot_archives:,
        existing_keys: []
      )
        # @type var out: Array[Refusal]
        out = []
        # Words are split on whitespace. A quote or backslash would make that
        # wrong, and 5.3 already stops on a quoted path, so stop here too
        # rather than read a different line from the one the shell runs.
        if (q = line[/['"\\]/])
          out << Refusal.new("2.1", "the link recipe contains #{q.inspect}; it is read as plain words, so it may hold no quoting")
          return Classification.new([], [], {}, [], [], [], nil, out)
        end
        texts = line.split(" ")
        tree = tree_files.to_h { |f| [f, true] }
        # @type var words: Array[Word]
        words = []

        if texts.length < 2
          out << Refusal.new("6.1", "the link recipe has #{texts.length} word(s); it needs two compiler words")
          return Classification.new(words, [], {}, [], [], [], nil, out)
        end

        unless token_keys.value?(texts[0])
          out << Refusal.new("2.1", "word 0, #{texts[0].inspect}, is not a declared token key; the compiler wrapper must be one")
        end
        sdk = COMPILER.match(texts[1].to_s)&.[](:sdk)
        if sdk.nil?
          out << Refusal.new("6.5", "word 1, #{texts[1].inspect}, is not <wasi-sdk>/bin/clang")
        end
        words << Word.new(0, texts[0], :compiler, nil) << Word.new(1, texts[1], :compiler, nil)

        # @type var roots: Array[String]
        roots = []
        # @type var libraries: Array[Word]
        libraries = []
        i = 2
        while i < texts.length
          text = texts[i].to_s
          if TAKES_ARGUMENT.include?(text)
            words << Word.new(i, text, :option, nil)
            arg = texts[i + 1]
            if arg.nil?
              out << Refusal.new("2.1", "#{text} at word #{i} is the last word; it takes an argument")
              break
            end
            if text == "-o"
              if arg == "ruby"
                words << Word.new(i + 1, arg, :output, nil)
              else
                out << Refusal.new("2.1", "-o at word #{i} names #{arg.inspect}; the link recipe's output is ruby")
              end
            else
              words << Word.new(i + 1, arg, :option_argument, nil)
            end
            i += 2
            next
          end

          if text.start_with?("-L")
            dir = text.delete_prefix("-L")
            if dir == "." || dir.start_with?("/")
              words << Word.new(i, text, :search_root, dir)
              roots << dir unless roots.include?(dir)
            else
              out << Refusal.new("2.1", "word #{i}, #{text.inspect}: a -L root must be . or absolute")
            end
          elsif text.start_with?("-l") && text.length > 2
            w = Word.new(i, text, :library, nil)
            words << w
            libraries << w
          elsif text.start_with?("-")
            words << Word.new(i, text, :flag, nil)
          elsif text.start_with?("/")
            if token_keys.value?(text)
              words << Word.new(i, text, :token_file, text)
            else
              out << Refusal.new("2.1", "word #{i}, #{text}, is an absolute file that is no declared token key")
            end
          elsif MEMBER.match?(text) && tree.key?(text)
            words << Word.new(i, text, :tree_file, text)
          elsif MEMBER.match?(text)
            out << Refusal.new("2.1", "word #{i}, #{text}, is not in the Build tree")
          else
            out << Refusal.new(
              "2.1",
              "word #{i}, #{text.inspect}, is none of the kinds a link recipe may hold; " \
              "if it is an option's argument, that option is not in the grammar"
            )
          end
          i += 1
        end

        # -l resolves through every -L root in line order, then the sysroot,
        # as the linker searches them: -L applies to every -l on the line.
        # @type var resolved_by: Hash[String, Array[String]]
        resolved_by = Hash.new { |h, k| h[k] = [] }
        # @type var sysroot: Array[String]
        sysroot = []
        libraries.each do |w|
          base = "lib#{w.text.delete_prefix("-l")}.a"
          root = roots.find do |r|
            r == "." ? tree.key?(base) : root_listings.fetch(r, []).include?(base)
          end
          if root
            w.file = root == "." ? base : "#{root}/#{base}"
            resolved_by[root] << base unless resolved_by[root].include?(base)
          elsif sysroot_archives.include?(base)
            w.file = nil
            sysroot << w.text.delete_prefix("-l") unless sysroot.include?(w.text.delete_prefix("-l"))
          else
            out << Refusal.new("2.1", "#{w.text} (word #{w.index}) resolves in no -L root and not in the sysroot")
          end
        end

        roots.each do |r|
          next if r == "."
          unless root_listings.key?(r)
            out << Refusal.new("2.1", "-L#{r} was not examined; its listing is missing")
          end
        end

        root_keys = root_keys_for(roots - ["."], resolved_by, existing_keys, out)

        build_members =
          words.select { |w| w.kind == :tree_file }.map(&:text).uniq.reject { |f| f == "main.o" }
        build_members << "libruby-static.a" if resolved_by["."].include?("libruby-static.a")
        # @type var inputs: Array[String]
        inputs = []
        words.each do |w|
          f = w.file
          next if f.nil? || w.kind == :search_root
          inputs << f unless inputs.include?(f)
        end
        ext_archives = words.select { |w| w.kind == :tree_file && w.text.start_with?("ext/") && w.text.end_with?(".a") }.map(&:text)

        Classification.new(words, build_members, root_keys, inputs, ext_archives, sysroot, sdk, out)
      end

      # ADR-0069's naming rule: <product>-<version>/opt/usr/local/lib gives
      # <product>_lib. Anything else stops.
      def self.root_key_name(root)
        m = ROOT.match(root)
        return nil if m.nil?
        base = File.basename(m[:product].to_s)
        v = VERSIONED.match(base)
        return nil if v.nil?
        "#{v[:name]}_lib"
      end

      def self.root_keys_for(roots, resolved_by, existing_keys, out)
        # @type var keys: Hash[String, Hash[String, untyped]]
        keys = {}
        roots.each do |r|
          archives = resolved_by.fetch(r, [])
          if archives.empty?
            out << Refusal.new("2.1", "-L#{r} resolves no -l on the line")
            next
          end
          name = root_key_name(r)
          if name.nil?
            out << Refusal.new(
              "4.7",
              "-L#{r} is not <product>-<version>/opt/usr/local/lib, so no root key name can be derived"
            )
            next
          end
          if keys.key?(name) || existing_keys.include?(name)
            out << Refusal.new("4.7", "root key #{name} (from #{r}) collides with another key")
            next
          end
          keys[name] = { "value" => r, "archives" => archives.sort }
        end
        keys
      end

      private_class_method :root_keys_for
    end
  end
end
