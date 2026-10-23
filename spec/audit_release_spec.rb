# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The tool under test rides the load path (the repo's no-require_relative
# rule; the sibling factories' $LOAD_PATH idiom). tools/lib joins through
# audit_release.rb's own unshift.
$LOAD_PATH.unshift(File.expand_path("../tools", __dir__))
require "audit_release"

# A read-only Octokit stand-in: the audit is strictly a QUERY (spec 13
# §2a — it never mutates the release), and the fake enforces that by
# construction — there are no upload/delete methods to call.
AuditSpecRelease = Struct.new(:url)
AuditSpecAsset = Struct.new(:name)

class FakeAuditClient
  def initialize(release:, asset_names:)
    @release = release
    @asset_names = asset_names
  end

  def release_for_tag(_repo, _tag)
    @release
  end

  def release_assets(_url)
    @asset_names.map { |name| AuditSpecAsset.new(name) }
  end
end

RSpec.describe ReleaseAudit do
  let(:version) { "9.9.9" }
  let(:release) { AuditSpecRelease.new("https://api.test/releases/1") }

  # The feedstock fixtures: a mini Tebakofile + a mini build-payload
  # workflow whose matrix block mirrors the real one's shape (2 flavors ×
  # 3 platforms + the include arm's 4 temurin-only legs: the musl pair,
  # x86_64-macos, aarch64-windows-ucrt). Feedstock
  # parses these; the expected names below are written out literally, so
  # a misread fixture fails the clean case.
  RECIPE_FIXTURE = <<~YAML
    runtime:
      wrapper_tebako: "9.9.9"
    flavors:
      temurin:
        implementation: temurin
        upstream: {version: "21.0.12"}
      graalvm:
        implementation: graalvm
        upstream: {version: "25.0.4.1"}
  YAML

  # AUDIT_MATRIX_FIXTURE, not MATRIX_FIXTURE: constants assigned inside a
  # describe block land on Object (blocks open no cref), and
  # registry_update_spec.rb carries its own MATRIX_FIXTURE — the shared
  # name would load-order-clobber this one.
  AUDIT_MATRIX_FIXTURE = <<~YAML
    name: build-payload
    jobs:
      build:
        strategy:
          matrix:
            flavor: [temurin, graalvm]
            platform:
              - {triplet: aarch64-macos, asset_platform: macos-arm64, exe_suffix: ""}
              - {triplet: x86_64-windows-ucrt, asset_platform: windows-ucrt64, exe_suffix: .exe}
              - {triplet: x86_64-linux-gnu, asset_platform: linux-gnu-x86_64, exe_suffix: ""}
            include:
              - flavor: temurin
                platform: {triplet: x86_64-linux-musl, asset_platform: linux-musl-x86_64, exe_suffix: ""}
              - flavor: temurin
                platform: {triplet: aarch64-linux-musl, asset_platform: linux-musl-arm64, exe_suffix: ""}
              - flavor: temurin
                platform: {triplet: x86_64-macos, asset_platform: macos-x86_64, exe_suffix: ""}
              - flavor: temurin
                platform: {triplet: aarch64-windows-ucrt, asset_platform: windows-ucrt-arm64, exe_suffix: .exe}
  YAML

  # tebako#716: the stem carries the flavor's implementation (the
  # distribution segment) between the tebako line and the java version.
  def leg_names(implementation, java_version, asset_platform, exe_suffix)
    stem = "tebako-runtime-#{version}-#{implementation}-#{java_version}-#{asset_platform}"
    exe = "#{stem}#{exe_suffix}"
    [exe, "#{exe}.sha256",
     "#{stem}.tfs", "#{stem}.tfs.sha256",
     "#{stem}.tfs.blksum.json", "#{stem}.tfs.blksum.json.sha256",
     "#{stem}.manifest.json"]
  end

  # The whole expected matrix, written out: (2 flavors × 3 platforms +
  # the include arm's 4 temurin-only legs) × the pair + sidecars + shard
  # = 70 write-once names (spec 13 §2a; the blksum pair is tebako#868's).
  def all_names
    [%w[temurin 21.0.12 macos-arm64], ["temurin", "21.0.12", "windows-ucrt64", ".exe"], %w[temurin 21.0.12 linux-gnu-x86_64],
     %w[temurin 21.0.12 linux-musl-x86_64], %w[temurin 21.0.12 linux-musl-arm64],
     %w[temurin 21.0.12 macos-x86_64], ["temurin", "21.0.12", "windows-ucrt-arm64", ".exe"],
     %w[graalvm 25.0.4.1 macos-arm64], ["graalvm", "25.0.4.1", "windows-ucrt64", ".exe"], %w[graalvm 25.0.4.1 linux-gnu-x86_64]]
      .flat_map { |impl, java, platform, suffix| leg_names(impl, java, platform, suffix.to_s) }
  end

  def audit_for(asset_names, env_extra: {}, matrix: AUDIT_MATRIX_FIXTURE)
    Dir.mktmpdir do |dir|
      recipe_path = File.join(dir, "Tebakofile")
      matrix_path = File.join(dir, "build-payload.yml")
      File.write(recipe_path, RECIPE_FIXTURE)
      File.write(matrix_path, matrix)
      env = { "TEBAKO_VERSION" => version,
              "RECIPE_PATH" => recipe_path,
              "MATRIX_PATH" => matrix_path }.merge(env_extra)
      client = FakeAuditClient.new(release: release, asset_names: asset_names)
      yield ReleaseAudit.new(client: client, env: env)
    end
  end

  it "targets this feedstock's release (the rename-sweep guard)" do
    expect(RUNTIME_REPO).to eq("tamatebako/tebako-runtime-openjdk")
  end

  it "derives the expected matrix from the workflow matrix x recipe pins" do
    audit_for(all_names) do |audit|
      expect(audit.expected_names).to match_array(all_names)
      expect(audit.expected_names.size).to eq(70)
    end
  end

  it "reads the matrix include: arm's legs — and never invents the graalvm legs it omits" do
    audit_for(all_names) do |audit|
      expect(audit.expected_names)
        .to include("tebako-runtime-9.9.9-temurin-21.0.12-linux-musl-x86_64.tfs",
                    "tebako-runtime-9.9.9-temurin-21.0.12-linux-musl-arm64.tfs",
                    "tebako-runtime-9.9.9-temurin-21.0.12-macos-x86_64.tfs",
                    "tebako-runtime-9.9.9-temurin-21.0.12-windows-ucrt-arm64.tfs")
      expect(audit.expected_names.grep(/graalvm.*(musl|macos-x86_64|ucrt-arm64)/)).to be_empty
    end
  end

  it "refuses an include row naming a flavor the axis does not declare" do
    bad = AUDIT_MATRIX_FIXTURE.sub("- flavor: temurin\n", "- flavor: temurn\n")
    audit_for(all_names, matrix: bad) do |audit|
      expect { audit.expected_names }
        .to raise_error(Feedstock::FeedstockError, /include row names unknown flavor "temurn"/)
    end
  end

  it "refuses an include row whose platform lacks the three spellings" do
    bad = AUDIT_MATRIX_FIXTURE.sub("platform: {triplet: aarch64-linux-musl, asset_platform: linux-musl-arm64, exe_suffix: \"\"}",
                             "platform: {triplet: aarch64-linux-musl, asset_platform: linux-musl-arm64}")
    audit_for(all_names, matrix: bad) do |audit|
      expect { audit.expected_names }
        .to raise_error(Feedstock::FeedstockError, /lacks triplet\/asset_platform\/exe_suffix/)
    end
  end

  it "refuses an include row re-pairing a cartesian leg (it belongs on the plain axes)" do
    bad = AUDIT_MATRIX_FIXTURE.sub("platform: {triplet: x86_64-linux-musl, asset_platform: linux-musl-x86_64, exe_suffix: \"\"}",
                             "platform: {triplet: aarch64-macos, asset_platform: macos-arm64, exe_suffix: \"\"}")
    audit_for(all_names, matrix: bad) do |audit|
      expect { audit.expected_names }
        .to raise_error(Feedstock::FeedstockError, /re-pairs the cartesian leg temurin\/aarch64-macos/)
    end
  end

  it "adds every served name's own .asc when the line signs (spec 09 §5's no-fold rule)" do
    audit_for(all_names, env_extra: { "TEBAKO_RELEASE_SIGNING_ENABLED" => "true" }) do |audit|
      expected = audit.expected_names(signing: true)
      expect(expected.size).to eq(140)
      expect(expected).to include("tebako-runtime-9.9.9-temurin-21.0.12-macos-arm64.tfs.asc",
                                  "tebako-runtime-9.9.9-graalvm-25.0.4.1-windows-ucrt64.exe.asc")
    end
  end

  it "passes clean when every leg's names are served (unsigned line)" do
    audit_for(all_names) do |audit|
      expect { expect(audit.run).to eq(:clean) }.to output(/audit clean/).to_stdout
    end
  end

  it "is a subset check, never equality: extra non-monolith names are tolerated" do
    audit_for(all_names + ["tebako-runtime-9.9.9-temurin-21.0.12-linux-musl-x86_64.tfs"]) do |audit|
      expect(audit.run).to eq(:clean)
    end
  end

  it "fails named, listing the gap, when a leg's asset is missing" do
    missing = "tebako-runtime-9.9.9-temurin-21.0.12-macos-arm64.tfs"
    audit_for(all_names - [missing]) do |audit|
      expect { audit.run }
        .to output(/Missing asset: #{Regexp.escape(missing)}/).to_stdout
        .and(raise_error(ReleaseAudit::AuditError, /failed the audit \(1 missing, 0 forbidden\)/))
    end
  end

  it "passes clean on a signing-enabled line when every name's .asc rides along" do
    signed = all_names + all_names.map { |name| "#{name}.asc" }
    audit_for(signed, env_extra: { "TEBAKO_RELEASE_SIGNING_ENABLED" => "true" }) do |audit|
      expect { expect(audit.run).to eq(:clean) }.to output(/full \.asc coverage/).to_stdout
    end
  end

  it "fails named on a signing-enabled line when an .asc is missing" do
    signed = all_names + all_names.map { |name| "#{name}.asc" }
    gap = "tebako-runtime-9.9.9-graalvm-25.0.4.1-linux-gnu-x86_64.manifest.json.asc"
    audit_for(signed - [gap], env_extra: { "TEBAKO_RELEASE_SIGNING_ENABLED" => "true" }) do |audit|
      expect { audit.run }
        .to output(/Missing asset: #{Regexp.escape(gap)}/).to_stdout
        .and(raise_error(ReleaseAudit::AuditError, /failed the audit/))
    end
  end

  it "refuses the retired monoliths: they are NEVER release assets (spec 13 §2a)" do
    audit_for(all_names + %w[manifest.json SHA256SUMS.txt]) do |audit|
      expect { audit.run }
        .to output(/NEVER release assets/).to_stdout
        .and(raise_error(ReleaseAudit::AuditError, /failed the audit \(0 missing, 2 forbidden\)/))
    end
  end

  it "fails named when the tag has no release" do
    client = FakeAuditClient.new(release: nil, asset_names: [])
    def client.release_for_tag(_repo, _tag)
      raise Octokit::NotFound
    end
    audit = ReleaseAudit.new(client: client, env: { "TEBAKO_VERSION" => version })
    expect { audit.run }
      .to raise_error(ReleaseAudit::AuditError, /no release found for tag v9\.9\.9/)
  end
end
