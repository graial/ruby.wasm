# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "yaml"
require_relative "extractor"
require_relative "members"

module RubyWasm
  module ReleaseBundle
    # Assembles one Release Bundle tree under contract v3 (2.1–2.5, 4, 6.6)
    # from a capture directory and the manifest input, into a directory that
    # did not exist (2.5). Every member comes from the capture's
    # classification, named and never found by exclusion (ADR-0069), and
    # Members checks the result, with the producer's sysroot listing, before
    # anything is reported done.
    class Assembly
      Stop = Class.new(StandardError)

      # What a human states. Everything else in the manifest is derived, and
      # an input that tries to state it is refused rather than overridden.
      STATED = %w[build_name capture tools path_keys].freeze
      DECLARED_KEYS = %w[wasi_sdk_path ruby_src cc_wrapper wasi_vfs wasm_opt].freeze
      CONTRACT_VERSION = 3

      attr_reader :log, :refusals, :notes

      def initialize(capture_dir:, input:, dest:, release_checkout:)
        @cap = File.expand_path(capture_dir)
        @input = input
        @dest = File.expand_path(dest)
        @release = File.expand_path(release_checkout)
        # @type var log: Array[String]
        log = []
        @log = log
        # @type var refusals: Array[untyped]
        refusals = []
        @refusals = refusals
        # @type var notes: Array[String]
        notes = []
        @notes = notes
      end

      def run
        raise Stop, "#{@dest} already exists; 2.5 assembles into a directory that does not" if File.exist?(@dest)
        extra = @input.keys - STATED
        raise Stop, "manifest input states derived field(s) #{extra.join(", ")}" unless extra.empty?
        keys = @input.fetch("path_keys")
        undeclared = DECLARED_KEYS - keys.keys
        raise Stop, "manifest input lacks path key(s) #{undeclared.join(", ")}" unless undeclared.empty?

        meta = JSON.parse(File.read(File.join(@cap, "capture.json")))
        tree = meta.fetch("transcript_cwd")
        prefix_src = File.join(tree, "install", "usr", "local")
        raise Stop, "no install prefix at #{prefix_src}" unless File.directory?(prefix_src)

        status, = git(@release, "status", "--porcelain", "--untracked-files=no")
        raise Stop, "the release checkout #{@release} has tracked modifications; release_commit would name a tree nobody has" unless status.empty?
        release_commit = git(@release, "rev-parse", "HEAD").first.strip

        FileUtils.mkdir_p(@dest)
        copy_tree(prefix_src, File.join(@dest, "prefix"))
        archive = File.join(@dest, "prefix/lib/libruby-static.a")
        raise Stop, "prefix/lib/libruby-static.a is absent" unless File.file?(archive)

        meta.fetch("build_members").each do |m|
          if m == "libruby-static.a"
            tree_sha = Digest::SHA256.file(File.join(tree, m)).hexdigest
            if tree_sha != Digest::SHA256.file(archive).hexdigest
              raise Stop, "the Build tree's libruby-static.a differs from the installed one; 2.3 ships one archive"
            end
            FileUtils.mkdir_p(File.join(@dest, "build"))
            File.symlink("../prefix/lib/libruby-static.a", File.join(@dest, "build/libruby-static.a"))
          else
            put(File.join(tree, m), File.join(@dest, "build", m))
          end
        end
        put(keys.dig("wasi_vfs", "value"), File.join(@dest, "wasi-vfs/libwasi_vfs.a"))

        # @type var path_keys: Hash[String, untyped]
        path_keys = keys.dup
        meta.fetch("root_keys").each do |name, k|
          k.fetch("archives").each { |a| put(File.join(k.fetch("value"), a), File.join(@dest, "lib", name, a)) }
          path_keys[name] = { "kind" => "root", "value" => k.fetch("value"), "accounted" => "lib/#{name}" }
        end

        %w[link compile].each do |r|
          FileUtils.cp(File.join(@cap, "#{r}.raw.txt"), File.join(@dest, "#{r}.raw.txt"))
          trace = Extractor.extract_file(File.join(@dest, "#{r}.raw.txt"))
          File.write(File.join(@dest, "#{r}.paths.txt"), trace.map { |t| "#{t}\n" }.join)
        end

        manifest = {
          "contract_version" => CONTRACT_VERSION,
          "build_name" => @input.fetch("build_name"),
          "fork_commit" => meta.fetch("fork_commit"),
          "release_commit" => release_commit,
          "capture" => @input.fetch("capture"),
          "archive" => "prefix/lib/libruby-static.a",
          "transcript_cwd" => tree,
          "extensions" => meta.fetch("extensions"),
          "tools" => @input.fetch("tools"),
          "path_keys" => path_keys
        }
        text = manifest_text(manifest)
        if YAML.safe_load(text) != manifest
          raise Stop, "manifest.yml does not read back as the manifest it was written from"
        end
        File.write(File.join(@dest, "manifest.yml"), text)

        File.write(File.join(@dest, "hashes.txt"), hashes_text)
        listed = File.readlines(File.join(@dest, "hashes.txt"), chomp: true).map { |l| l.split("  ", 2)[1].to_s }

        sysroot = File.readlines(File.join(@cap, "tables/sysroot.txt"), chomp: true).reject(&:empty?)
        result = Members.check(
          link_line: File.readlines(File.join(@dest, "link.raw.txt"), chomp: true).first.to_s,
          path_keys: path_keys, listed: listed, sysroot_archives: sysroot
        )
        @refusals.concat(result.refusals)
        @notes.concat(result.notes)
        @log << "assembled    : #{@dest} (#{listed.length} hashed paths)"
        @refusals.empty?
      end

      private

      def git(dir, *args)
        out, err, st = Open3.capture3("git", "-C", dir, *args)
        raise Stop, "git #{args.join(" ")} in #{dir} failed: #{err.strip}" unless st.success?
        [out, err]
      end

      def put(src, dst)
        raise Stop, "#{src} is not a file" unless src && File.file?(src)
        FileUtils.mkdir_p(File.dirname(dst))
        FileUtils.cp(src, dst)
      end

      def copy_tree(src, dst)
        _, err, st = Open3.capture3("cp", "-a", src, dst)
        raise Stop, "cp -a #{src} #{dst} failed: #{err.strip}" unless st.success?
        Dir.glob("**/*", File::FNM_DOTMATCH, base: dst).each do |f|
          path = File.join(dst, f)
          next unless File.symlink?(path)
          target = File.expand_path(File.readlink(path), File.dirname(path))
          raise Stop, "prefix/#{f} is a symlink resolving outside the bundle" unless target.start_with?(@dest + "/")
        end
      end

      # 6.6: sha256sum format, sorted by path, every member but itself; a
      # symlink carries its target's hash.
      def hashes_text
        files = Dir.glob("**/*", File::FNM_DOTMATCH, base: @dest).reject { |f| f.end_with?("/.", "/..") || f == "." }
        files = files.select { |f| File.file?(File.join(@dest, f)) && f != "hashes.txt" }.sort
        files.map { |f| "#{Digest::SHA256.file(File.join(@dest, f)).hexdigest}  #{f}\n" }.join
      end

      def manifest_text(m)
        scalar = ->(v) { v.nil? ? "null" : (v.is_a?(Integer) ? v.to_s : JSON.generate(v.to_s)) }
        out = +""
        %w[contract_version build_name fork_commit release_commit capture archive transcript_cwd].each do |k|
          out << "#{k}: #{scalar.call(m[k])}\n"
        end
        out << "extensions:#{m["extensions"].empty? ? " []" : ""}\n"
        m["extensions"].each { |e| out << "  - #{scalar.call(e)}\n" }
        out << "\ntools:\n"
        m["tools"].each { |k, v| out << "  #{k}: #{scalar.call(v)}\n" }
        out << "\npath_keys:\n"
        m["path_keys"].each do |k, v|
          out << "  #{k}: { kind: #{v["kind"]}, value: #{scalar.call(v["value"])}, accounted: #{scalar.call(v["accounted"])} }\n"
        end
        out
      end
    end
  end
end
