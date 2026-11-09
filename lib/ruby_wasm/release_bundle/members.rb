# frozen_string_literal: true

module RubyWasm
  module ReleaseBundle
    # Contract v3 2.1 and 4.7, checked from a bundle alone: build/ and each
    # lib/<key>/ hold exactly what the link recipe names (ADR-0069).
    #
    # It reads link.raw.txt's first line, manifest path_keys,
    # manifest sysroot_libraries and hashes.txt's paths, which is everything a
    # downloaded bundle has. The producer also looked in the sysroot itself.
    module Members
      Refusal = Struct.new(:clause, :message)
      Result = Struct.new(:refusals)

      MEMBER = /\.(o|a)\z/
      TAKES_ARGUMENT = %w[-o -Xlinker -z].freeze

      # link_line: link.raw.txt's first line, without "\n".
      # path_keys: manifest path_keys, name => { "kind", "value", "accounted" }.
      # listed: the paths in hashes.txt.
      # sysroot_libraries: manifest sysroot_libraries (4.12): exactly the -l
      #   names, in line order, that resolve nowhere in the bundle.
      # sysroot_archives: the producer's listing of the wasi-sdk sysroot, or
      #   nil for a reader without one. With it, each of those names must also
      #   resolve there.
      def self.check(link_line:, path_keys:, listed:, sysroot_libraries:, sysroot_archives: nil)
        # @type var out: Array[Refusal]
        out = []
        have = listed.to_h { |p| [p, true] }
        words = link_line.split(" ")

        # @type var dirs: Array[[String, String]]
        dirs = []
        # @type var tree_words: Array[String]
        tree_words = []
        # @type var libs: Array[String]
        libs = []
        i = 2
        while i < words.length
          w = words[i].to_s
          if TAKES_ARGUMENT.include?(w)
            i += 2
            next
          end
          if w.start_with?("-L")
            root = w.delete_prefix("-L")
            if root == "."
              dirs << [".", "build"] unless dirs.any? { |(r, _)| r == "." }
            else
              name, key = path_keys.find { |_, k| k["kind"] == "root" && k["value"] == root }
              ref = key && key["accounted"]
              if name.nil?
                out << Refusal.new("4.7", "-L#{root} on the link recipe is no root path key")
              elsif ref != "lib/#{name}"
                out << Refusal.new("4.7", "root key #{name} is accounted #{ref.inspect}; a -L root's key is accounted lib/#{name}")
              else
                dirs << [root, "lib/#{name}"] unless dirs.any? { |(r, _)| r == root }
              end
            end
          elsif w.start_with?("-l") && w.length > 2
            libs << w.delete_prefix("-l") unless libs.include?(w.delete_prefix("-l"))
          elsif !w.start_with?("-", "/") && MEMBER.match?(w)
            tree_words << w unless tree_words.include?(w)
          end
          i += 1
        end

        # build/: every relative object or archive on the line except main.o,
        # plus the archive -lruby-static resolves through -L.
        # @type var resolved: Hash[String, Array[String]]
        resolved = Hash.new { |h, k| h[k] = [] }
        # @type var outside: Array[String]
        outside = []
        libs.each do |name|
          base = "lib#{name}.a"
          hit = dirs.find { |(_, d)| have.key?("#{d}/#{base}") }
          if hit
            resolved[hit[1]] << base
          else
            outside << name
            if sysroot_archives && !sysroot_archives.include?(base)
              out << Refusal.new("4.7", "-l#{name} resolves neither in the bundle nor in the sysroot")
            end
          end
        end

        if sysroot_libraries != outside
          out << Refusal.new(
            "4.12",
            "sysroot_libraries is #{sysroot_libraries.inspect}; the -l names on the link " \
            "recipe that resolve nowhere in the bundle are #{outside.inspect}"
          )
        end

        want_build = (tree_words - ["main.o"]).map { |w| "build/#{w}" }
        want_build.concat(resolved.fetch("build", []).map { |b| "build/#{b}" })
        got_build = listed.select { |p| p.start_with?("build/") }
        compare("2.1", "build/", want_build, got_build, out)

        dirs.each do |(_, d)|
          next if d == "build"
          want = resolved.fetch(d, []).map { |b| "#{d}/#{b}" }
          got = listed.select { |p| p.start_with?("#{d}/") }
          if want.empty?
            out << Refusal.new("4.7", "#{d}/ resolves no -l on the link recipe")
          end
          compare("4.7", "#{d}/", want, got, out)
        end
        listed.select { |p| p.start_with?("lib/") }.each do |p|
          next if dirs.any? { |(_, d)| p.start_with?("#{d}/") }
          out << Refusal.new("4.7", "#{p} is under lib/ and no -L root on the link recipe accounts for it")
        end

        Result.new(out)
      end

      def self.compare(clause, where, want, got, out)
        missing = want - got
        extra = got - want
        out << Refusal.new(clause, "#{where} lacks #{missing.join(", ")}, which the link recipe names") unless missing.empty?
        out << Refusal.new(clause, "#{where} holds #{extra.join(", ")}, which the link recipe does not name") unless extra.empty?
      end

      private_class_method :compare
    end
  end
end
