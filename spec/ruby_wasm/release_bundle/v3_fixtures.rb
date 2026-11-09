# frozen_string_literal: true

require "zlib"
require "time"
require "ruby_wasm/release_bundle/capture"
require "ruby_wasm/release_bundle/link_line"

# Reads spec/fixtures/v3, the real transcripts and tables of the two v3 Builds
# (see its README). Everything a spec asserts about "the real line" comes from
# these files, never from a transcription of them.
module V3Fixtures
  DIR = File.expand_path("../../fixtures/v3", __dir__)
  ROOT = "/home/shared/external/ladder/main/build"
  CC_WRAPPER = "#{ROOT}/checkouts/3.3/tool/wasm-clangw"
  WASI_SDK = "#{ROOT}/toolchain/wasi-sdk-22.0"
  WASI_VFS = "#{ROOT}/wasm32-unknown-wasip1/wasi-vfs-0.6.2/libwasi_vfs.a"
  WASM_OPT = "#{ROOT}/toolchain/binaryen/bin/wasm-opt"
  TOKENS = { "cc_wrapper" => CC_WRAPPER, "wasi_vfs" => WASI_VFS, "wasm_opt" => WASM_OPT }.freeze
  # The sysroot archives the line's system -l words need. The fixture set has
  # no sysroot listing, so this is the one stated input; every name here is
  # wasi-sdk 22's.
  SYSROOT = %w[
    libc.a libdl.a libcrypt.a libm.a
    libwasi-emulated-mman.a libwasi-emulated-signal.a
    libwasi-emulated-getpid.a libwasi-emulated-process-clocks.a
  ].freeze

  module_function

  def read(profile, name)
    File.binread(File.join(DIR, profile, name))
  end

  def exist?(profile, name)
    File.exist?(File.join(DIR, profile, name))
  end

  def selection(profile)
    RubyWasm::ReleaseBundle::Capture.select(
      link_transcript: read(profile, "copy.build-ext-n.out"),
      main_transcript: read(profile, "tree.main-n.out"),
      copy_main_transcript: read(profile, "copy.main-n.out")
    )
  end

  def link_line(profile)
    selection(profile).link_raw.to_s.lines.first.to_s.chomp
  end

  def inputs_list(profile)
    read(profile, "inputs.list").lines.map(&:chomp).reject(&:empty?)
  end

  # Tree-relative files that exist, from the tree half of inputs.list.
  def tree_files(profile)
    inputs_list(profile).select { |l| l.start_with?("./") }.map { |l| l.delete_prefix("./") }
  end

  # Absolute -L roots and their files, from the outside half of inputs.list.
  def root_listings(profile)
    inputs_list(profile)
      .select { |l| l.include?("/opt/usr/local/lib/") }
      .group_by { |l| File.dirname(l) }
      .transform_values { |ls| ls.map { |l| File.basename(l) } }
  end

  def classify(profile, **overrides)
    RubyWasm::ReleaseBundle::LinkLine.classify(
      line: overrides.fetch(:line) { link_line(profile) },
      tree_files: overrides.fetch(:tree_files) { tree_files(profile) },
      token_keys: overrides.fetch(:token_keys) { TOKENS },
      root_listings: overrides.fetch(:root_listings) { root_listings(profile) },
      sysroot_archives: overrides.fetch(:sysroot_archives) { SYSROOT },
      existing_keys: overrides.fetch(:existing_keys) { %w[wasi_sdk_path ruby_src cc_wrapper wasi_vfs wasm_opt] }
    )
  end

  # label => [[type, name], …]. Every file in inputs.list was read; the table
  # keeps only Init_ lines, so a file with none maps to [].
  def symbols(profile)
    table = Hash.new { |h, k| h[k] = [] }
    inputs_list(profile).each { |l| table[l.delete_prefix("./")] }
    read(profile, "inputs-init-all.nm").each_line do |l|
      file, nm = l.chomp.split("\t", 2)
      next if nm.nil?
      _addr, type, name = nm.split(" ")
      table[file.to_s.delete_prefix("./")] << [type.to_s, name.to_s]
    end
    table.to_h
  end

  def function_map(profile)
    Zlib.gunzip(read(profile, "ruby.function-map.gz"))
  end

  def extinit_c(profile)
    exist?(profile, "ext_extinit.c") ? read(profile, "ext_extinit.c") : nil
  end

  # label => Time, for the tree half; "./" stripped.
  def mtimes(profile)
    read(profile, "tree-mtimes.txt").each_line.to_h do |l|
      stamp, path = l.chomp.split("  ", 2)
      [path.to_s.delete_prefix("./"), Time.strptime(stamp.to_s, "%Y-%m-%d %H:%M:%S.%N %z")]
    end
  end

  def hashes(profile, which)
    read(profile, "tree-#{which}.sha256").each_line.to_h do |l|
      sha, path = l.chomp.split("  ", 2)
      [path.to_s, sha.to_s]
    end
  end
end
