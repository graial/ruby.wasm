# frozen_string_literal: true

require "ruby_wasm/release_bundle/guards"

RSpec.describe RubyWasm::ReleaseBundle::Guards do
  COMMIT_ID_G = "a" * 40

  def problems(**overrides)
    described_class.problems(
      **{
        toplevel: "/reserved/main", reserved: "/reserved/main", release: "/elsewhere/release",
        head: COMMIT_ID_G, main_commit: COMMIT_ID_G, changes: [],
        environment: { "PATH" => "/usr/bin" }, wasm_opt_on_path: false, cached: []
      }.merge(overrides)
    )
  end

  it "passes a clean checkout at the Reserved path" do
    expect(problems).to be_empty
  end

  it "refuses a clone one directory deeper" do
    expect(problems(toplevel: "/reserved/main/main").join).to include("not the Reserved path")
  end

  it "refuses a release checkout inside the Reserved path, or around it" do
    expect(problems(release: "/reserved/main/release").join).to include("overlap")
    expect(problems(release: "/reserved").join).to include("overlap")
    expect(problems(release: "/reserved/main").join).to include("overlap")
  end

  it "does not read a sibling that shares a prefix as an overlap" do
    expect(problems(release: "/reserved/main-release")).to be_empty
  end

  it "refuses a HEAD other than the commit asked for" do
    expect(problems(head: "b" * 40).join).to include("not #{COMMIT_ID_G}")
  end

  it "refuses an abbreviated commit" do
    expect(problems(main_commit: "abc1234", head: "abc1234").join).to include("not a full commit id")
  end

  it "refuses tracked changes" do
    expect(problems(changes: [" M Cargo.lock"]).join).to include("Cargo.lock")
  end

  described_class::ENVIRONMENT.each do |name|
    it "refuses #{name} in the environment, even empty" do
      expect(problems(environment: { name => "" }).join).to include(name)
    end
  end

  it "refuses a wasm-opt on PATH" do
    expect(problems(wasm_opt_on_path: true).join).to include("wasm-opt")
  end

  it "refuses a cached ruby" do
    expect(problems(cached: ["x.tar.gz"]).join).to include("x.tar.gz")
  end

  it "reports everything at once" do
    expect(problems(wasm_opt_on_path: true, cached: ["x"], changes: ["y"]).length).to eq(3)
  end
end
