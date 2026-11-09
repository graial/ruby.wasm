# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "yaml"
require_relative "capture"
require_relative "link_line"
require_relative "agreement"

module RubyWasm
  module ReleaseBundle
    # One v3 Capture of one Build tree (contract 6.0, 6.1, 6.8; ADR-0068,
    # ADR-0069). This half gathers facts: it reads, hashes, copies and runs
    # `make -n`, llvm-nm and wasm-opt. Capture, LinkLine and Agreement decide.
    #
    # It never runs a make target in the Build tree except
    # `make -n -W main.c main.o`, which is a dry run in fact as well as in
    # name. `make -n build-ext` is not (F3), so it runs only in the copy.
    #
    # Writes into a capture directory that did not exist:
    #   link.raw.txt, compile.raw.txt       the Reference recipes
    #   capture.json                        the classification, extensions, and
    #                                       the facts the assembler needs
    #   transcripts/, tables/               everything read, for a human
    class CaptureRun
      Stop = Class.new(StandardError)

      HASHED = /\.(o|a)\z/

      attr_reader :refusals, :notes, :log

      # input: the manifest input (manifest-input.yml), whose path_keys
      #   declare the tokens and roots that are not derived.
      def initialize(tree:, checkout:, capture_dir:, input:)
        @tree = File.expand_path(tree)
        @checkout = File.expand_path(checkout)
        @cap = File.expand_path(capture_dir)
        @input = input
        @copy = "#{@tree}.capture-copy"
        # @type var refusals: Array[untyped]
        refusals = []
        @refusals = refusals
        # @type var notes: Array[String]
        notes = []
        @notes = notes
        # @type var log: Array[String]
        log = []
        @log = log
      end

      # true when the capture directory holds a capture every check passed.
      # A fact that cannot be gathered raises Stop; once the copy exists it is
      # caught here, so the real tree is still hashed after and the copy kept.
      def run
        @before = nil
        body
      rescue Stop => e
        before = @before
        raise if before.nil?
        finish(before, [Capture::Refusal.new("6.1", e.message)])
      end

      private

      def body
        raise Stop, "#{@cap} already exists; capture into a directory that does not" if File.exist?(@cap)
        keys = @input.fetch("path_keys")
        tokens = keys.select { |_, k| k["kind"] == "token" }.transform_values { |k| k["value"].to_s }

        changes = git("status", "--porcelain", "--untracked-files=no").lines.map(&:chomp)
        head = git("rev-parse", "HEAD").strip
        say "build tree   : #{@tree}"
        say "checkout     : #{@checkout}"
        say "fork_commit  : #{head}"

        pre = Capture.preconditions(
          tree_exists: File.directory?(@tree),
          ruby_mtime: mtime("ruby"),
          main_o_mtime: mtime("main.o"),
          checkout_changes: changes,
          copy_exists: File.exist?(@copy)
        )
        return stop(pre) unless pre.empty?

        FileUtils.mkdir_p(File.join(@cap, "transcripts"))
        FileUtils.mkdir_p(File.join(@cap, "tables"))

        before = tree_hashes
        @before = before
        say "hashed       : #{before.length} files in the real tree, before"

        _, err, st = Open3.capture3("cp", "-a", @tree, @copy)
        raise Stop, "cp -a #{@tree} #{@copy} failed: #{err.strip}" unless st.success?
        say "capture copy : #{@copy}"

        link_t = transcript(@copy, "copy.build-ext-n", "make", "-n", "build-ext")
        copy_main_t = transcript(@copy, "copy.main-n", "make", "-n", "-W", "main.c", "main.o")
        main_t = transcript(@tree, "tree.main-n", "make", "-n", "-W", "main.c", "main.o")

        sel = Capture.select(
          link_transcript: link_t, main_transcript: main_t,
          copy_main_transcript: copy_main_t, copy_path: @copy
        )
        @notes.concat(sel.notes)
        return finish(before, sel.refusals) unless sel.refusals.empty?
        line = sel.link_raw.to_s.lines.first.to_s.chomp
        opt_line = sel.link_raw.to_s.lines[1].to_s

        tree_files = Dir.glob("**/*", base: @tree).select { |f| HASHED.match?(f) && File.file?(File.join(@tree, f)) }
        roots = line.split(" ").filter_map { |w| w.delete_prefix("-L") if w.start_with?("-L/") }
        listings = roots.uniq.select { |r| File.directory?(r) }.to_h { |r| [r, Dir.children(r).sort] }
        sdk_decl = keys.dig("wasi_sdk_path", "value").to_s
        sysroot_dir = File.join(sdk_decl, "share/wasi-sysroot/lib/wasm32-wasi")
        # @type var sysroot: Array[String]
        sysroot = File.directory?(sysroot_dir) ? Dir.children(sysroot_dir).sort : []
        File.write(File.join(@cap, "tables", "sysroot.txt"), sysroot.join("\n") + "\n")

        cls = LinkLine.classify(
          line: line, tree_files: tree_files, token_keys: tokens,
          root_listings: listings, sysroot_archives: sysroot, existing_keys: keys.keys
        )
        # @type var found: Array[untyped]
        found = cls.refusals.dup
        if cls.wasi_sdk_path && cls.wasi_sdk_path != sdk_decl
          found << LinkLine::Refusal.new("4.7", "the line's compiler is under #{cls.wasi_sdk_path}; wasi_sdk_path declares #{sdk_decl}")
        end
        found << LinkLine::Refusal.new("6.8", "#{sysroot_dir} lists nothing") if sysroot.empty?
        return finish(before, found) unless found.empty?

        nm = "#{sdk_decl}/bin/llvm-nm"
        wasm_opt = tokens["wasm_opt"].to_s
        unless opt_line.start_with?("#{wasm_opt} ")
          found << LinkLine::Refusal.new("6.8", "the wasm-opt line does not run the wasm_opt token #{wasm_opt}")
        end
        [nm, wasm_opt].each do |tool|
          found << LinkLine::Refusal.new("6.8", "#{tool} is not an executable file") unless File.executable?(tool)
        end
        return finish(before, found) unless found.empty?

        symbols = cls.inputs.to_h do |label|
          path = label.start_with?("/") ? label : File.join(@tree, label)
          out, err, st = Open3.capture3(nm, "--defined-only", path, binmode: true)
          raise Stop, "#{nm} --defined-only #{path} exited #{st.exitstatus}: #{err.strip}" unless st.success?
          [label, Agreement.parse_nm(out)]
        end
        File.write(
          File.join(@cap, "tables", "inputs-init.nm"),
          symbols.flat_map { |f, ss| ss.select { |(_, n)| n.start_with?("Init_") }.map { |(t, n)| "#{f}\t#{t} #{n}\n" } }.join
        )

        map_out, map_err, st = Open3.capture3(wasm_opt, File.join(@tree, "ruby"), "--print-function-map", binmode: true)
        raise Stop, "#{wasm_opt} --print-function-map exited #{st.exitstatus}: #{map_err.strip}" unless st.success?
        File.binwrite(File.join(@cap, "tables", "ruby.function-map"), map_out)
        extinit_path = File.join(@tree, "ext/extinit.c")
        extinit = File.file?(extinit_path) ? File.binread(extinit_path) : nil

        agree = Agreement.check(
          inputs: cls.inputs, ext_archives: cls.ext_archives, words: cls.words,
          symbols: symbols, function_map: Agreement.parse_function_map(map_out), extinit_c: extinit
        )
        found.concat(agree.refusals)

        mtimes = (["main.o"] + cls.inputs).uniq.to_h do |label|
          path = label.start_with?("/") ? label : File.join(@tree, label)
          [label, File.file?(path) ? File.mtime(path) : nil]
        end
        found.concat(Agreement.freshness(ruby_mtime: mtime("ruby"), mtimes: mtimes))
        return finish(before, found) unless found.empty?

        finish(before, []) do
          File.binwrite(File.join(@cap, "link.raw.txt"), sel.link_raw.to_s)
          File.binwrite(File.join(@cap, "compile.raw.txt"), sel.compile_raw.to_s)
          File.write(
            File.join(@cap, "capture.json"),
            JSON.pretty_generate(
              "fork_commit" => head,
              "transcript_cwd" => @tree,
              "build_members" => cls.build_members,
              "root_keys" => cls.root_keys,
              "extensions" => agree.extensions,
              "inputs" => cls.inputs,
              "sysroot" => cls.sysroot,
              "wasi_sdk_path" => cls.wasi_sdk_path
            ) + "\n"
          )
          say "build/       : #{cls.build_members.length} member(s)"
          say "root keys    : #{cls.root_keys.keys.join(", ")}" unless cls.root_keys.empty?
          say "extensions   : #{agree.extensions.length}"
        end
      end

      # Hashes the real tree after, removes the copy only if it is untouched,
      # and runs the block, which writes the capture, only if nothing at all
      # was refused. A capture is never written ahead of its last check.
      def finish(before, found)
        after = tree_hashes
        untouched = Agreement.untouched(before: before, after: after)
        all = found + untouched
        if untouched.empty? && File.exist?(@copy)
          FileUtils.rm_rf(@copy)
          say "capture copy : removed"
        elsif File.exist?(@copy)
          say "capture copy : kept at #{@copy}, for diagnosis"
        end
        say "real tree    : #{untouched.empty? ? "byte-identical" : "CHANGED"} after (#{after.length} files)"
        yield if all.empty? && block_given?
        stop(all)
      end

      def stop(found)
        @refusals.concat(found)
        found.empty?
      end

      def say(text)
        @log << text
      end

      def git(*args)
        out, err, st = Open3.capture3("git", "-C", @checkout, *args)
        raise Stop, "git #{args.join(" ")} in #{@checkout} failed: #{err.strip}" unless st.success?
        out
      end

      def mtime(rel)
        path = File.join(@tree, rel)
        File.file?(path) ? File.mtime(path) : nil
      end

      def tree_hashes
        return {} unless File.directory?(@tree)
        Dir.glob("**/*", base: @tree).sort.filter_map do |f|
          path = File.join(@tree, f)
          next unless File.file?(path) && (HASHED.match?(f) || f == "ruby" || f == "ext/extinit.c")
          [f, Digest::SHA256.file(path).hexdigest]
        end.to_h
      end

      # One invocation, stdout and stderr each to a file, read back from the
      # file so that what is selected is what was saved.
      def transcript(dir, name, *cmd)
        out, err, st = Open3.capture3(*cmd, chdir: dir, binmode: true)
        base = File.join(@cap, "transcripts", name)
        File.binwrite("#{base}.out", out)
        File.binwrite("#{base}.err", err)
        say format("%-26s -> %d lines, exit %s", cmd.join(" "), out.lines.count, st.exitstatus.inspect)
        raise Stop, "`#{cmd.join(" ")}` in #{dir} exited #{st.exitstatus.inspect}; see #{name}.err" unless st.success?
        File.binread("#{base}.out")
      end
    end
  end
end
