# frozen_string_literal: true

module RubyWasm
  module ReleaseBundle
    # Composes manifest-input.yml for a Build the workflow has just made: what
    # bin/capture-recipes and bin/assemble-bundle read as stated. Each value is
    # read off the Build's own tree. The Build name is split, and nothing
    # branches on what it says.
    module ManifestInput
      Stop = Class.new(StandardError)

      NAME = /\A(?<version>[^-]+)-(?<target>.+)-(?<profile>[^-]+)\z/
      CAPTURES = %w[workflow manual].freeze

      def self.tree(checkout:, build_name:)
        match = NAME.match(build_name) || raise(Stop, "#{build_name.inspect} is not <version>-<triple>-<profile>")
        File.join(checkout, "build", match[:target].to_s, "ruby-#{build_name}")
      end

      # wasi_sdk_dirs: the matches of build/toolchain/wasi-sdk-*.
      # wasi_vfs_archives: the matches of build/*/wasi-vfs-*/libwasi_vfs.a.
      # binaryen: the Build's own `wasm-opt --version`, stripped.
      # cc_wrapper_sha256: the digest of ruby_src/tool/wasm-clangw.
      def self.compose(checkout:, build_name:, capture:, wasi_sdk_dirs:, wasi_vfs_archives:, binaryen:, cc_wrapper_sha256:)
        match = NAME.match(build_name) || raise(Stop, "#{build_name.inspect} is not <version>-<triple>-<profile>")
        raise Stop, "capture is #{capture.inspect}, not one of #{CAPTURES.join(", ")}" unless CAPTURES.include?(capture)

        sdk = only(wasi_sdk_dirs, "build/toolchain/wasi-sdk-*")
        vfs = only(wasi_vfs_archives, "build/*/wasi-vfs-*/libwasi_vfs.a")
        raise Stop, "wasm-opt --version printed nothing" if binaryen.empty?

        src = File.join(checkout, "build", "checkouts", match[:version].to_s)
        {
          "build_name" => build_name,
          "capture" => capture,
          "tools" => {
            "wasi_sdk" => version(File.basename(sdk), "wasi-sdk-"),
            "binaryen" => binaryen,
            "wasi_vfs" => version(File.basename(File.dirname(vfs)), "wasi-vfs-"),
            "cc_wrapper_sha256" => cc_wrapper_sha256
          },
          "path_keys" => {
            "wasi_sdk_path" => { "kind" => "root", "value" => sdk, "accounted" => "tools.wasi_sdk" },
            "ruby_src" => { "kind" => "root", "value" => src, "accounted" => nil },
            "cc_wrapper" => { "kind" => "token", "value" => File.join(src, "tool", "wasm-clangw"), "accounted" => "tools.cc_wrapper_sha256" },
            "wasi_vfs" => { "kind" => "token", "value" => vfs, "accounted" => "wasi-vfs/libwasi_vfs.a" },
            "wasm_opt" => { "kind" => "token", "value" => File.join(checkout, "build", "toolchain", "binaryen", "bin", "wasm-opt"), "accounted" => "tools.binaryen" }
          }
        }
      end

      def self.only(matches, pattern)
        raise Stop, "#{pattern} matched #{matches.length} paths, not one: #{matches.join(", ")}" unless matches.length == 1

        matches.first.to_s
      end

      def self.version(name, prefix)
        value = name.delete_prefix(prefix)
        raise Stop, "#{name} does not start with #{prefix}" if value == name || value.empty?

        value
      end

      private_class_method :only, :version
    end
  end
end
