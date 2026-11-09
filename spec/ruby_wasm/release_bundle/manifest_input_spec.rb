# frozen_string_literal: true

require "ruby_wasm/release_bundle/manifest_input"
require "ruby_wasm/release_bundle/assembly"

RSpec.describe RubyWasm::ReleaseBundle::ManifestInput do
  ROOT_M = "/reserved/main"
  NAME_M = "3.3-wasm32-unknown-wasip1-minimal"

  def compose(**overrides)
    described_class.compose(
      **{
        checkout: ROOT_M, build_name: NAME_M, capture: "workflow",
        wasi_sdk_dirs: ["#{ROOT_M}/build/toolchain/wasi-sdk-22.0"],
        wasi_vfs_archives: ["#{ROOT_M}/build/wasm32-unknown-wasip1/wasi-vfs-0.6.2/libwasi_vfs.a"],
        binaryen: "wasm-opt version 108 (version_108)", cc_wrapper_sha256: "c" * 64
      }.merge(overrides)
    )
  end

  it "states the tools and the five declared keys, and nothing derived" do
    input = compose
    expect(input.keys).to eq(RubyWasm::ReleaseBundle::Assembly::STATED)
    expect(input["path_keys"].keys).to eq(RubyWasm::ReleaseBundle::Assembly::DECLARED_KEYS)
    expect(input["tools"]).to eq(
      "wasi_sdk" => "22.0", "binaryen" => "wasm-opt version 108 (version_108)",
      "wasi_vfs" => "0.6.2", "cc_wrapper_sha256" => "c" * 64
    )
  end

  it "accounts each key as the contract's example does" do
    keys = compose["path_keys"]
    expect(keys.transform_values { |k| k["accounted"] }).to eq(
      "wasi_sdk_path" => "tools.wasi_sdk", "ruby_src" => nil, "cc_wrapper" => "tools.cc_wrapper_sha256",
      "wasi_vfs" => "wasi-vfs/libwasi_vfs.a", "wasm_opt" => "tools.binaryen"
    )
  end

  it "takes ruby_src from the name's version" do
    expect(compose["path_keys"]["ruby_src"]["value"]).to eq("#{ROOT_M}/build/checkouts/3.3")
    expect(compose["path_keys"]["cc_wrapper"]["value"]).to eq("#{ROOT_M}/build/checkouts/3.3/tool/wasm-clangw")
  end

  it "finds the tree from the name alone, for any triple" do
    expect(described_class.tree(checkout: ROOT_M, build_name: NAME_M))
      .to eq("#{ROOT_M}/build/wasm32-unknown-wasip1/ruby-#{NAME_M}")
    expect(described_class.tree(checkout: ROOT_M, build_name: "3.3-a-b-c-full"))
      .to eq("#{ROOT_M}/build/a-b-c/ruby-3.3-a-b-c-full")
  end

  it "refuses a name it cannot split" do
    expect { compose(build_name: "nothing") }.to raise_error(described_class::Stop)
    expect { described_class.tree(checkout: ROOT_M, build_name: "nothing") }.to raise_error(described_class::Stop)
  end

  it "refuses a capture that is neither word" do
    expect { compose(capture: "ci") }.to raise_error(described_class::Stop, /capture/)
  end

  it "refuses no match and two matches" do
    expect { compose(wasi_sdk_dirs: []) }.to raise_error(described_class::Stop, /0 paths/)
    expect { compose(wasi_vfs_archives: %w[/a/wasi-vfs-1/libwasi_vfs.a /b/wasi-vfs-2/libwasi_vfs.a]) }
      .to raise_error(described_class::Stop, /2 paths/)
  end

  it "refuses a directory that does not name its version" do
    expect { compose(wasi_sdk_dirs: ["/x/wasi-sdk-"]) }.to raise_error(described_class::Stop)
  end

  it "refuses an empty wasm-opt version" do
    expect { compose(binaryen: "") }.to raise_error(described_class::Stop, /printed nothing/)
  end
end
