# frozen_string_literal: true

require "yaml"

# ADR-0030: the pipeline carries no knowledge of what it is building for. This
# catches a regression on any push. The Acceptance run is what proves it.
RSpec.describe "the release pipeline" do
  root = File.expand_path("../../..", __dir__)
  dispatch = YAML.safe_load_file(File.join(root, ".github/workflows/cut-release-bundle.yml"), aliases: true)
  build = YAML.safe_load_file(File.join(root, ".github/workflows/cut-release-bundle-build.yml"), aliases: true)
  jobs = dispatch.fetch("jobs")

  scripts = %w[
    assemble-bundle capture-recipes check-config-agreement check-manifest.rb extract-paths
    preflight-release postflight-release check-build-guards compose-manifest-input
    compare-reference pack-bundle github-date check-workflow-state publish-release
    ci-build-and-capture
  ].map { |n| "bin/#{n}" }
  instruments = Dir.glob("lib/ruby_wasm/release_bundle/*.rb", base: root) +
    Dir.glob("sig/ruby_wasm/release_bundle/*.rbs", base: root) +
    scripts + %w[.github/workflows/cut-release-bundle.yml .github/workflows/cut-release-bundle-build.yml]

  it "scans something: a list that found nothing would pass" do
    expect(instruments.length).to be > 30
    instruments.each { |f| expect(File.file?(File.join(root, f))).to be(true), f }
  end

  instruments.each do |file|
    it "#{file} names no particular platform's target" do
      expect(File.binread(File.join(root, file))).not_to match(/icp|canister|internet computer/in)
    end
  end

  it "has one job that both a cut and an Acceptance run call" do
    expect(jobs["cut"]["uses"]).to eq(jobs["acceptance"]["uses"])
    expect(jobs["cut"]["with"].keys).to eq(jobs["acceptance"]["with"].keys)
  end

  it "has the Acceptance run on another triple, with no reference" do
    expect(jobs["acceptance"]["with"]["build_name"]).to eq("3.3-wasm32-unknown-wasip1-minimal")
    expect(jobs["acceptance"]["with"]["reference"]).to eq("none")
  end

  it "publishes only after the preflight, which needs both runs" do
    expect(jobs["preflight"]["needs"]).to contain_exactly("cut", "acceptance")
    expect(jobs["publish"]["needs"]).to include("preflight")
    expect(jobs["publish"]["if"]).to include("refs/heads/release")
  end

  it "defaults to a Rehearsal, and requires the ordinal and the reference" do
    inputs = dispatch.fetch(true).fetch("workflow_dispatch").fetch("inputs")
    expect(inputs["publish"]["default"]).to be(false)
    expect(inputs["ordinal"]["required"]).to be(true)
    expect(inputs["ordinal"]).not_to have_key("default")
    expect(inputs["reference"]["required"]).to be(true)
    expect(inputs["reference"]).not_to have_key("default")
  end

  it "gives write access only to the job that publishes" do
    writers = jobs.select { |_, j| j.fetch("permissions", {}).values.include?("write") }.keys
    expect(writers).to eq(["publish"])
    expect(dispatch["permissions"]).to eq({})
    expect(build["permissions"]).to eq("contents" => "read")
  end

  it "hands the secret to one step of one job" do
    text = File.read(File.join(root, ".github/workflows/cut-release-bundle.yml"))
    expect(text.scan("secrets.").length).to eq(1)
    step = jobs["preflight"]["steps"].find { |s| s["name"] == "Preflight" }
    expect(step["env"]["GH_TOKEN"]).to include("secrets.IMMUTABILITY_READ_TOKEN")
    expect(File.read(File.join(root, ".github/workflows/cut-release-bundle-build.yml"))).not_to include("secrets.")
  end

  it "publishes through the one command the preflight prints" do
    step = jobs["publish"]["steps"].find { |s| s["name"] == "Publish" }
    expect(step["run"]).to include("bin/publish-release")
  end

  it "mounts the Build's checkout at the Reserved path" do
    env = build["jobs"]["build"]["env"]
    expect(env["RESERVED"]).to eq("/home/shared/external/ladder/main")
    text = File.read(File.join(root, ".github/workflows/cut-release-bundle-build.yml"))
    expect(text).to include('build-checkout:$RESERVED')
    expect(text).not_to match(/actions\/cache/)
  end

  it "requires upstream's release workflow to be disabled" do
    run = jobs["guard"]["steps"].map { |s| s["run"].to_s }.join
    expect(run).to include("release.yml disabled_manually")
  end
end
