# frozen_string_literal: true

require "shellwords"

module RubyWasm
  module ReleaseBundle
    # Clause 6.5: the captures and the shipped prefix describe the same Build.
    #
    #   - The four _WASI_EMULATED_* defines on the compile recipe each appear in
    #     both CONFIG["CPPFLAGS"] and CONFIG["CFLAGS"] of the shipped
    #     rbconfig.rb.
    #   - The three WASM_*_STACK_BUFFER_SIZE defines on the compile recipe each
    #     appear in CONFIG["configure_args"].
    #   - The wasi-sdk path appears in CONFIG["configure_args"], as the word
    #     WASI_SDK_PATH=<path>. The path is the compile recipe's compiler word,
    #     <path>/bin/clang, with /bin/clang removed.
    #
    # Every value is read from the capture and looked for in the one key that
    # carries it, never in another key that happens to contain it. That is
    # 6.5's own trap twice over. configure_args has a CFLAGS= word that is not
    # CONFIG["CFLAGS"] (empty on the published bundle), and a CC= word that
    # contains the wasi-sdk path and is not WASI_SDK_PATH. A check that found a
    # value in either would pass a bundle where the clause fails.
    #
    # Matching is by whole word, never substring: "=24576" is inside
    # "=245760", and ".../wasi-sdk-22.0" is inside ".../wasi-sdk-22.0.1".
    #
    # rbconfig.rb comes out of a downloaded bundle, so it is read, not
    # executed. Each key 6.5 needs must be assigned exactly once, and assigned
    # a double-quoted string literal, which String#undump decodes. Anything
    # else is a refusal, not a guess.
    #
    # The defect this catches is ADR-0017's (builder): without
    # -D_WASI_EMULATED_SIGNAL, the shim and the archive disagree about what
    # wasi-libc declares. That links clean and then fails inside ruby_setup
    # without naming anything.
    class ConfigAgreement
      Refusal = Struct.new(:clause, :message)

      KEYS = %w[CPPFLAGS CFLAGS configure_args].freeze
      EMULATED = /\A-D_WASI_EMULATED_[A-Z_]+\z/
      STACK = /\A-D(?<name>WASM_[A-Z]+_STACK_BUFFER_SIZE)=(?<value>\d+)\z/
      COMPILER = %r{\A(?<sdk>/.+)/bin/clang\z}
      ASSIGNMENT = /\A\s*CONFIG\["(?<key>[^"]+)"\]\s*=\s*(?<value>.*?)\s*\z/

      def initialize(compile_raw:, rbconfig:)
        @compile_raw = compile_raw
        @rbconfig = rbconfig
        # @type var examined: Array[[String, String]]
        examined = []
        @examined = examined
        # @type var found: Array[Refusal]
        found = []
        @refusals = found
        @ran = false
      end

      # What is wrong. The check runs once, on whichever of this and #examined
      # is called first, so neither depends on the other having been called.
      def refusals
        run unless @ran
        @refusals
      end

      # Each [word, key] the check found, in the key it was found in: what a
      # passing result actually examined.
      def examined
        run unless @ran
        @examined
      end

      def pass?
        refusals.empty?
      end

      private

      def run
        @ran = true
        out = @refusals
        words = @compile_raw.split

        config, unread = read_config
        out.concat(unread)

        defines = words.grep(EMULATED).uniq
        if defines.size != 4
          out << refusal("the compile recipe carries four _WASI_EMULATED_* defines; found #{defines.size}: #{defines.inspect}")
        end

        stacks = stack_defines(words, out)
        sdk = wasi_sdk_path(words, out)

        cppflags = config["CPPFLAGS"]
        cflags = config["CFLAGS"]
        configure_args = config["configure_args"]

        if cppflags && cflags
          defines.each do |d|
            { "CPPFLAGS" => cppflags, "CFLAGS" => cflags }.each do |key, value|
              if value.split.include?(d)
                @examined << [d, key]
              else
                out << refusal("#{d} is on the compile recipe and not in CONFIG[\"#{key}\"]")
              end
            end
          end
        end

        if configure_args
          arg_words = configure_words(configure_args, out)
          if arg_words
            stacks.each do |word|
              if arg_words.include?(word)
                @examined << [word, "configure_args"]
              else
                out << refusal("#{word} is on the compile recipe and not in CONFIG[\"configure_args\"]")
              end
            end
            if sdk
              want = "WASI_SDK_PATH=#{sdk}"
              if arg_words.include?(want)
                @examined << [want, "configure_args"]
              else
                out << refusal("the compile recipe's compiler is #{sdk}/bin/clang, and #{want} is not a word of CONFIG[\"configure_args\"]")
              end
            end
          end
        end

        out
      end

      def refusal(message)
        Refusal.new("6.5", message)
      end

      # The literal values of the keys 6.5 reads, plus a refusal for each key
      # that is not assigned exactly once to a string literal.
      def read_config
        # @type var found: Hash[String, Array[String]]
        found = Hash.new { |h, k| h[k] = [] }
        @rbconfig.each_line do |line|
          m = ASSIGNMENT.match(line)
          next unless m
          key = m[:key].to_s
          found[key] << m[:value].to_s if KEYS.include?(key)
        end

        # @type var config: Hash[String, String]
        config = {}
        # @type var out: Array[Refusal]
        out = []
        KEYS.each do |key|
          rhs = found.fetch(key, [])
          if rhs.empty?
            out << refusal("CONFIG[\"#{key}\"] is not assigned in rbconfig.rb")
          elsif rhs.size > 1
            out << refusal("CONFIG[\"#{key}\"] is assigned twice or more in rbconfig.rb; which one holds is not read here")
          else
            value = literal(rhs.first.to_s)
            if value
              config[key] = value
            else
              out << refusal("CONFIG[\"#{key}\"] is assigned #{rhs.first.to_s[0, 80]}, not a string literal")
            end
          end
        end
        [config, out]
      end

      def literal(rhs)
        return nil unless rhs.start_with?("\"") && rhs.end_with?("\"") && rhs.length >= 2

        rhs.undump
      rescue RuntimeError
        nil
      end

      # Each -DWASM_*_STACK_BUFFER_SIZE=<n> word on the recipe, once each.
      def stack_defines(words, out)
        # @type var values: Hash[String, Array[String]]
        values = Hash.new { |h, k| h[k] = [] }
        words.each do |w|
          m = STACK.match(w)
          values[m[:name].to_s] << m[:value].to_s if m
        end

        values.each do |name, vs|
          if vs.uniq.size > 1
            out << refusal("the compile recipe gives #{name} two values: #{vs.uniq.join(", ")}")
          end
        end
        if values.size != 3
          out << refusal("the compile recipe carries three WASM_*_STACK_BUFFER_SIZE defines; found #{values.size}: #{values.keys.inspect}")
        end

        values.map { |name, vs| "-D#{name}=#{vs.first}" }
      end

      # The wasi-sdk path: the one recipe word that is <path>/bin/clang.
      def wasi_sdk_path(words, out)
        compilers = words.select { |w| COMPILER.match?(w) }.uniq
        if compilers.size != 1
          out << refusal(
            "the compile recipe should name one compiler <wasi-sdk>/bin/clang; " \
            "found #{compilers.size}: #{compilers.inspect}"
          )
          return nil
        end
        COMPILER.match(compilers.first.to_s)&.[](:sdk)
      end

      # configure_args' shell words, and the whitespace-separated words of
      # every VAR=value word's value (XCFLAGS carries the stack defines).
      def configure_words(configure_args, out)
        shell = Shellwords.split(configure_args)
        inner = shell.flat_map { |w| _name, sep, value = w.partition("="); sep.empty? ? [] : value.split }
        shell + inner
      rescue ArgumentError => e
        out << refusal("CONFIG[\"configure_args\"] is not shell words: #{e.message}")
        nil
      end
    end
  end
end
