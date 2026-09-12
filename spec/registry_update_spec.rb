# frozen_string_literal: true

require "spec_helper"
require "base64"
require "digest"
require "json"
require "tmpdir"
require "yaml"

# The tool under test rides the load path (the repo's no-require_relative
# rule; the sibling factories' $LOAD_PATH idiom). tools/lib joins through
# registry_update.rb's own unshift.
$LOAD_PATH.unshift(File.expand_path("../tools", __dir__))
require "registry_update"

# Recording stand-ins in the sign_release_spec idiom: the renderer accepts
# any client object, and every interaction is observable through the fake.
RegistrySpecRelease = Struct.new(:url, :tag_name)
RegistrySpecAsset = Struct.new(:name, :browser_download_url)
RegistrySpecContents = Struct.new(:content)

# The Octokit stand-in: one release carrying shard assets whose bodies are
# canned JSON, and a contents-API registry source that is a static
# document, a proc (so a spec can read back what the last run wrote), or
# Octokit::NotFound (no registry on main yet).
class FakeRegistryClient
  def initialize(release:, shards:, registry: nil)
    @release = release
    @shards = shards
    @registry = registry
  end

  def release_for_tag(_repo, _tag)
    @release
  end

  def release_assets(url)
    url == @release.url ? @shards.map(&:first) : []
  end

  def get(url)
    @shards.to_h { |asset, body| [asset.browser_download_url, body] }.fetch(url)
  end

  def contents(_repo, **)
    source = @registry.respond_to?(:call) ? @registry.call : @registry
    raise Octokit::NotFound if source.nil?

    RegistrySpecContents.new(Base64.strict_encode64(source))
  end
end

RSpec.describe RegistryUpdate do
  let(:version) { "9.9.9" }

  # The build-workflow fixture: the matrix block the asset-platform →
  # triplet mapping flows from (mirrors the real workflow's shape).
  MATRIX_FIXTURE = <<~YAML
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
  YAML

  # A release shard as tools/build writes it (the release's
  # machine-readable unit, spec 13 §2a): the exe pair's own fields plus
  # the `image` block the registry mirrors. `name_suffix` mints a second
  # asset claiming the same platform (the duplicate-triplet case).
  def shard(implementation:, java:, platform:, tebako_version: version, image: :default, name_suffix: "")
    exe_suffix = platform.start_with?("windows") ? ".exe" : ""
    stem = "tebako-runtime-#{tebako_version}-#{java}-#{platform}#{name_suffix}"
    body = { "tebako_version" => tebako_version, "java_version" => java,
             "implementation" => implementation, "platform" => platform,
             "filename" => "#{stem}#{exe_suffix}",
             "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}#{exe_suffix}") }
    case image
    when :default
      body["image"] = { "filename" => "#{stem}.tfs",
                        "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}.tfs") }
    when :absent
      # no image key at all — the missing-keys refusal
    else
      body["image"] = image
    end
    asset = RegistrySpecAsset.new("#{stem}.manifest.json", "https://download.test/#{stem}.manifest.json")
    [asset, JSON.generate(body)]
  end

  def shards_of(*list)
    list.map { |args| shard(**args) }
  end

  def render(shards, registry: nil, version_override: nil)
    ver = version_override || version
    Dir.mktmpdir do |dir|
      matrix_path = File.join(dir, "build-payload.yml")
      File.write(matrix_path, MATRIX_FIXTURE)
      path = File.join(dir, "tpkg-registry.yaml")
      release = RegistrySpecRelease.new("https://api.test/releases/1", "v#{ver}")
      client = FakeRegistryClient.new(release: release, shards: shards, registry: registry)
      described_class.new(client: client,
                          env: { "TEBAKO_VERSION" => ver, "REGISTRY_PATH" => path,
                                 "MATRIX_PATH" => matrix_path }).run
      yield path if block_given?
      return File.read(path)
    end
  end

  def payload_named(doc, name)
    doc["payloads"].find { |p| p["name"] == name }
  end

  it "derives the registry from the shards: a payload per flavor, image-mirroring triplet rows" do
    shards = shards_of({ implementation: "temurin", java: "21.0.9", platform: "macos-arm64" },
                       { implementation: "temurin", java: "21.0.12", platform: "macos-arm64" },
                       { implementation: "temurin", java: "21.0.12", platform: "windows-ucrt64" },
                       { implementation: "graalvm", java: "25.0.4.1", platform: "linux-gnu-x86_64" })
    doc = YAML.safe_load(render(shards))

    expect(doc["schema_version"]).to eq(1)
    expect(doc["payloads"].map { |p| p["name"] }).to contain_exactly("openjdk", "openjdk-graalvm")

    temurin = payload_named(doc, "openjdk")
    expect(temurin["kind"]).to eq("runtime")
    # Numeric sort, never lexical: 21.0.9 < 21.0.12.
    expect(temurin["versions"].map { |v| v["version"] }).to eq(["21.0.9", "21.0.12"])
    v = temurin["versions"].find { |x| x["version"] == "21.0.12" }
    expect(v["implementation"]).to eq("temurin")
    expect(v["platforms"].keys).to eq(%w[aarch64-macos x86_64-windows-ucrt])
    stem = "tebako-runtime-9.9.9-21.0.12-macos-arm64"
    # The row mirrors the ENV IMAGE (never the exe — that is this
    # registry's shipped grammar).
    expect(v["platforms"]["aarch64-macos"])
      .to eq("artifact" => "#{stem}.tfs", "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}.tfs"))
    expect(v["release"]).to eq("ref" => "tfs:github:tamatebako/tebako-runtime-openjdk:v9.9.9")
    expect(temurin["default"]).to eq("21.0.12")

    graalvm = payload_named(doc, "openjdk-graalvm")
    gv = graalvm["versions"].find { |x| x["version"] == "25.0.4.1" }
    expect(gv["implementation"]).to eq("graalvm")
    expect(gv["platforms"].keys).to eq(%w[x86_64-linux-gnu])
    expect(gv["platforms"]["x86_64-linux-gnu"]["artifact"])
      .to eq("tebako-runtime-9.9.9-25.0.4.1-linux-gnu-x86_64.tfs")
    expect(graalvm["default"]).to eq("25.0.4.1")
  end

  it "upserts into an existing registry, preserving other payloads and withdrawn marks" do
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: metanorma
          kind: app
          versions:
            - version: '1.2.3'
              platforms: universal
              release: {ref: tfs:github:tebako-packages/metanorma:1.2.3}
        - name: openjdk
          kind: runtime
          versions:
            - version: '21.0.11'
              implementation: temurin
              status: withdrawn
              platforms:
                aarch64-macos:
                  artifact: tebako-runtime-2.6.0-21.0.11-macos-arm64.tfs
                  sha256: 'aaaa'
              release: {ref: tfs:github:tamatebako/tebako-runtime-openjdk:v2.6.0}
          default: '21.0.11'
    YAML
    shards = shards_of({ implementation: "temurin", java: "21.0.12", platform: "linux-gnu-x86_64" })
    doc = YAML.safe_load(render(shards, registry: existing))

    expect(doc["payloads"].map { |p| p["name"] }).to contain_exactly("metanorma", "openjdk")
    payload = payload_named(doc, "openjdk")
    old = payload["versions"].find { |v| v["version"] == "21.0.11" }
    expect(old["status"]).to eq("withdrawn")
    expect(old["platforms"]).to have_key("aarch64-macos")
    new = payload["versions"].find { |v| v["version"] == "21.0.12" }
    stem = "tebako-runtime-9.9.9-21.0.12-linux-gnu-x86_64"
    expect(new["platforms"]).to eq("x86_64-linux-gnu" => {
                                     "artifact" => "#{stem}.tfs",
                                     "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}.tfs")
                                   })
    # The default moves off the withdrawn line onto the live one.
    expect(payload["default"]).to eq("21.0.12")
  end

  it "unions platform rows on a reline: new rows win per triplet, the release ref tracks the new tag" do
    first = render(shards_of({ implementation: "temurin", java: "21.0.12", platform: "macos-arm64" }))
    reline = shards_of({ implementation: "temurin", java: "21.0.12", platform: "macos-arm64",
                         tebako_version: "9.9.10" },
                       { implementation: "temurin", java: "21.0.12", platform: "linux-gnu-x86_64",
                         tebako_version: "9.9.10" })
    doc = YAML.safe_load(render(reline, registry: first, version_override: "9.9.10"))

    payload = payload_named(doc, "openjdk")
    row = payload["versions"].find { |v| v["version"] == "21.0.12" }
    expect(row["platforms"].keys).to eq(%w[aarch64-macos x86_64-linux-gnu])
    # The reline's artifact won the shared triplet.
    expect(row["platforms"]["aarch64-macos"]["artifact"])
      .to eq("tebako-runtime-9.9.10-21.0.12-macos-arm64.tfs")
    expect(row["release"]).to eq("ref" => "tfs:github:tamatebako/tebako-runtime-openjdk:v9.9.10")
    expect(payload["default"]).to eq("21.0.12")
  end

  it "is byte-idempotent: rendering over its own output changes nothing" do
    shards = shards_of({ implementation: "temurin", java: "21.0.12", platform: "macos-arm64" },
                       { implementation: "graalvm", java: "25.0.4.1", platform: "windows-ucrt64" })
    first = render(shards)
    second = render(shards, registry: -> { first })
    expect(second).to eq(first)
  end

  it "carries the ownership header (never hand-edit except status: withdrawn)" do
    output = render(shards_of({ implementation: "temurin", java: "21.0.12", platform: "macos-arm64" }))
    expect(output).to include("OWNED BY tools/registry_update.rb")
    expect(output).to include("status: withdrawn")
  end

  it "seeds the document when main carries no registry yet" do
    shards = shards_of({ implementation: "temurin", java: "21.0.12", platform: "macos-arm64" })
    doc = YAML.safe_load(render(shards, registry: nil))
    expect(doc["schema_version"]).to eq(1)
    expect(doc["payloads"].map { |p| p["name"] }).to eq(["openjdk"])
  end

  it "drops the default loudly when every version is withdrawn" do
    # The withdrawn entry's own release re-renders (the version key is
    # unchanged), the merge preserves the mark, and no live line remains
    # for `default:` to name.
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: openjdk
          kind: runtime
          versions:
            - version: '21.0.12'
              implementation: temurin
              status: withdrawn
              platforms:
                aarch64-macos:
                  artifact: tebako-runtime-9.9.9-21.0.12-macos-arm64.tfs
                  sha256: 'aaaa'
              release: {ref: tfs:github:tamatebako/tebako-runtime-openjdk:v9.9.9}
          default: '21.0.12'
    YAML
    shards = shards_of({ implementation: "temurin", java: "21.0.12", platform: "macos-arm64" })
    output = nil
    expect do
      output = render(shards, registry: existing)
    end.to output(/no default/).to_stderr
    payload = payload_named(YAML.safe_load(output), "openjdk")
    expect(payload).not_to have_key("default")
    expect(payload["versions"].first["status"]).to eq("withdrawn")
  end

  it "fails named when an existing version carries `platforms: universal` (never both shapes)" do
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: openjdk
          kind: runtime
          versions:
            - version: '21.0.12'
              implementation: temurin
              platforms: universal
              release: {ref: tfs:github:tamatebako/tebako-runtime-openjdk:v9.9.9}
    YAML
    shards = shards_of({ implementation: "temurin", java: "21.0.12", platform: "macos-arm64" })
    expect { render(shards, registry: existing) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /never both/)
  end

  it "fails named when a shard declares another tebako version" do
    shards = shards_of({ implementation: "temurin", java: "21.0.12", platform: "macos-arm64",
                         tebako_version: "0.0.1" })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /declares tebako_version "0\.0\.1"/)
  end

  it "fails named when a shard names an unknown platform" do
    shards = shards_of({ implementation: "temurin", java: "21.0.12", platform: "plan9-arm64" })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /unknown platform "plan9-arm64"/)
  end

  it "fails named when two shards claim the same triplet for one flavor" do
    shards = shards_of({ implementation: "temurin", java: "21.0.12", platform: "macos-arm64",
                         name_suffix: "-a" },
                       { implementation: "temurin", java: "21.0.12", platform: "macos-arm64",
                         name_suffix: "-b" })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /two shards claim aarch64-macos/)
  end

  it "fails named when a shard's image block is malformed (the registry mirrors the env image)" do
    shards = shards_of({ implementation: "temurin", java: "21.0.12", platform: "macos-arm64",
                         image: {} })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /carries no image \{filename, sha256\} block/)
  end

  it "fails named when a shard omits the image key entirely" do
    shards = shards_of({ implementation: "temurin", java: "21.0.12", platform: "macos-arm64",
                         image: :absent })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /is missing image/)
  end

  it "fails named when a shard is missing a required key" do
    asset, body = shard(implementation: "temurin", java: "21.0.12", platform: "macos-arm64")
    broken = JSON.generate(JSON.parse(body).reject { |key, _| key == "implementation" })
    expect { render([[asset, broken]]) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /is missing implementation/)
  end

  it "fails named when the tag has no release" do
    Dir.mktmpdir do |dir|
      matrix_path = File.join(dir, "build-payload.yml")
      File.write(matrix_path, MATRIX_FIXTURE)
      release = RegistrySpecRelease.new("https://api.test/releases/1", "v#{version}")
      client = FakeRegistryClient.new(release: release, shards: [])
      def client.release_for_tag(_repo, _tag)
        raise Octokit::NotFound
      end
      updater = described_class.new(client: client,
                                    env: { "TEBAKO_VERSION" => version,
                                           "REGISTRY_PATH" => File.join(dir, "r.yaml"),
                                           "MATRIX_PATH" => matrix_path })
      expect { updater.run }
        .to raise_error(RegistryUpdate::RegistryUpdateError, /no release found for tag v9\.9\.9/)
    end
  end

  it "fails named when the release carries no shards" do
    expect { render([]) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /carries no \.manifest\.json shards/)
  end
end
