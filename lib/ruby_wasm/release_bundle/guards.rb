# frozen_string_literal: true

module RubyWasm
  module ReleaseBundle
    # What must hold before a Build is started, or its result is not the Build
    # it claims to be (ADR-0049). The Build takes tools from its
    # environment without warning, and a clone one directory deeper looks right
    # while defeating the Reserved path.
    #
    # Pure: it is handed the facts and returns what is wrong.
    module Guards
      COMMIT = /\A[0-9a-f]{40}\z/
      ENVIRONMENT = %w[WASI_SDK_PATH RUBY_WASM_ROOT BUNDLE_GEMFILE].freeze

      # toplevel: `git rev-parse --show-toplevel` of the Build's checkout.
      # reserved: the Reserved path. release: the release checkout.
      # head / main_commit: the checkout's HEAD and the commit asked for.
      # changes: `git status --porcelain --untracked-files=no`, one per line.
      # environment: the process environment.
      # wasm_opt_on_path: whether any wasm-opt is on PATH.
      # cached: what is in the checkout's rubies/ directory.
      def self.problems(toplevel:, reserved:, release:, head:, main_commit:, changes:, environment:, wasm_opt_on_path:, cached:)
        # @type var out: Array[String]
        out = []
        out << "the main commit #{main_commit.inspect} is not a full commit id" unless COMMIT.match?(main_commit)
        out << "the checkout's top level is #{toplevel}, not the Reserved path #{reserved}" unless toplevel == reserved
        if inside?(release, reserved) || inside?(reserved, release)
          out << "the release checkout #{release} and the Reserved path #{reserved} overlap"
        end
        out << "the checkout is at #{head}, not #{main_commit}" unless head == main_commit
        out << "the checkout has tracked changes: #{changes.join("; ")}" unless changes.empty?
        ENVIRONMENT.each { |name| out << "#{name} is set; the Build would take it" if environment.key?(name) }
        out << "a wasm-opt is on PATH; the Build would take it" if wasm_opt_on_path
        out << "rubies/ already holds #{cached.join(", ")}; the Build would return it" unless cached.empty?
        out
      end

      def self.inside?(path, parent)
        path == parent || path.start_with?("#{parent}/")
      end

      private_class_method :inside?
    end
  end
end
