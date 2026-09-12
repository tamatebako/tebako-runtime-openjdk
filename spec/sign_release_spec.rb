# frozen_string_literal: true

require "spec_helper"
require "base64"
require "digest"
require "json"
require "pathname"
require "time"
require "tmpdir"

# The script under test rides the load path (the repo's no-require_relative
# rule; the sibling factories' $LOAD_PATH idiom).
$LOAD_PATH.unshift(File.expand_path("../scripts", __dir__))
require "sign_release"

# Recording stand-ins in the release_manager_spec idiom: the signer
# accepts any client/executor object, and every publish interaction
# becomes observable through the fakes' public collections.
SignSpecAsset = Struct.new(:id, :name, :digest, :updated_at, :url)
SignSpecRelease = Struct.new(:url, :tag_name)

# The Octokit stand-in: release listings per release URL, uploads and
# deletes recorded AND reflected in the listing (an uploaded .asc joins
# the assets with the digest of its bytes, so the convergence poll sees
# exactly what the real edge would).
class FakeSignClient
  attr_reader :uploads, :deletes

  def initialize(release:, assets:, tool_release:, tool_assets:)
    @release = release
    @assets = assets
    @tool_release = tool_release
    @tool_assets = tool_assets
    @uploads = []
    @deletes = []
  end

  def release_for_tag(_repo, _tag)
    @release
  end

  def latest_release(_repo)
    @tool_release
  end

  def release_assets(url)
    url == @release.url ? @assets : @tool_assets
  end

  def delete_release_asset(id)
    @deletes << id
    @assets.reject! { |asset| asset.id == id }
  end

  def upload_asset(_url, path, content_type:, name:)
    @uploads << { name: name, content_type: content_type }
    asset = SignSpecAsset.new(@assets.map(&:id).max + 1, name,
                              "sha256:#{Digest::SHA256.file(path).hexdigest}",
                              Time.now, "u/#{name}")
    @assets << asset
    asset
  end
end

# The command seam stand-in: `gh release download` materializes the
# requested patterns as canned bytes ("BYTES-<name>" — the specs' asset
# digests are computed over exactly these bytes, so the digest-verified
# signing path can pass honestly); `tebako-pkg sign` writes the .asc the
# way the real tool does; `tebako-pkg verify` succeeds.
class FakeSignExecutor
  attr_reader :calls

  def initialize(tool_sha_ok: true)
    @calls = []
    @tool_sha_ok = tool_sha_ok
  end

  def run(*argv, chdir: ".")
    @calls << [argv, chdir]
    if argv[0] == "gh"
      materialize_download(argv)
    elsif argv[1] == "sign"
      File.write(File.join(chdir, "#{argv.last}.asc"), "ASC-#{argv.last}")
    end
    ""
  end

  def sign_calls
    @calls.select { |argv, _| argv[1] == "sign" }.map { |argv, _| argv.last }
  end

  def download_patterns
    @calls.select { |argv, _| argv[0] == "gh" }.flat_map { |argv, _| patterns_from(argv) }
  end

  private

  def patterns_from(argv)
    argv.each_with_index.with_object([]) { |(arg, i), acc| acc << argv[i + 1] if arg == "--pattern" }
  end

  def materialize_download(argv) # rubocop:disable Metrics/AbcSize
    dir = argv[argv.index("--dir") + 1]
    patterns = patterns_from(argv)
    patterns.each { |name| File.write(File.join(dir, name), "BYTES-#{name}") }
    sidecar = patterns.find { |name| name.end_with?(".sha256") }
    tool = patterns.find { |name| !name.end_with?(".sha256") }
    return unless sidecar && tool

    sha = @tool_sha_ok ? Digest::SHA256.file(File.join(dir, tool)).hexdigest : "0" * 64
    File.write(File.join(dir, sidecar), "#{sha}  #{tool}\n")
  end
end

RSpec.describe ReleaseSigner do
  let(:version) { "9.9.9" }
  let(:release) { SignSpecRelease.new("https://api.test/releases/1", "v#{version}") }
  let(:tool_release) { SignSpecRelease.new("https://api.test/releases/2", "v2.7.0") }
  let(:tool_assets) do
    [SignSpecAsset.new(901, "tebako-pkg-2.7.0-linux-gnu-x86_64", nil, Time.utc(2026, 9, 1), "u/t"),
     SignSpecAsset.new(902, "tebako-pkg-2.7.0-linux-gnu-x86_64.sha256", nil, Time.utc(2026, 9, 1), "u/t.sha")]
  end
  let(:enabled_env) do
    { "TEBAKO_RELEASE_SIGNING_ENABLED" => "true",
      "TEBAKO_RELEASE_SIGNING_KEY" => Base64.strict_encode64("SIGNING-KEY-BYTES"),
      "TEBAKO_PKG_HOST_ID" => "linux-gnu-x86_64",
      "TEBAKO_VERSION" => version }
  end

  # The listing's digest of the canned bytes the fake download serves —
  # the digest the signer's provenance check compares against.
  def asset(id, name, updated_at)
    SignSpecAsset.new(id, name, "sha256:#{Digest::SHA256.hexdigest("BYTES-#{name}")}", updated_at, "u/#{name}")
  end

  def signer_for(assets, env: enabled_env, executor: FakeSignExecutor.new)
    client = FakeSignClient.new(release: release, assets: assets,
                                tool_release: tool_release, tool_assets: tool_assets)
    [ReleaseSigner.new(client: client, executor: executor, env: env), client, executor]
  end

  it "targets this feedstock's release and the tebako product's tool release" do
    # The rename-sweep guard (PRs #34/#35): the port's two repo constants
    # are the whole reason a copy from a sibling factory can sign the
    # WRONG release — pin them.
    expect(RUNTIME_REPO).to eq("tamatebako/tebako-runtime-openjdk")
    expect(TEBAKO_REPO).to eq("tamatebako/tebako")
  end

  it "is a quiet no-op when the gate is disarmed (unsigned stays first-class)" do
    client = FakeSignClient.new(release: release, assets: [], tool_release: tool_release, tool_assets: [])
    executor = FakeSignExecutor.new
    signer = ReleaseSigner.new(client: client, executor: executor,
                               env: { "TEBAKO_VERSION" => version })
    expect(signer.sign_release).to eq(:disarmed)
    expect(executor.calls).to be_empty
    expect(client.uploads).to be_empty
  end

  it "fails fast and named when armed without the key secret" do
    signer, = signer_for([], env: { "TEBAKO_RELEASE_SIGNING_ENABLED" => "true",
                                    "TEBAKO_RELEASE_SIGNING_KEY" => "",
                                    "TEBAKO_VERSION" => version })
    expect { signer.sign_release }
      .to raise_error(ReleaseSigner::SigningGateError, /TEBAKO_RELEASE_SIGNING_KEY secret is not set/)
  end

  it "fails named when the key secret is not valid base64 (the decode is real)" do
    signer, = signer_for([], env: enabled_env.merge("TEBAKO_RELEASE_SIGNING_KEY" => "!!! not base64 !!!"))
    expect { signer.sign_release }
      .to raise_error(ReleaseSigner::SigningGateError, /not valid base64/)
  end

  it "targets every served name except the .asc files themselves (spec 09 §5's no-fold rule)" do
    signer, = signer_for([])
    stem = "tebako-runtime-9.9.9-21.0.12-linux-gnu-x86_64"
    names = [stem, "#{stem}.tfs", "#{stem}.sha256", "#{stem}.tfs.sha256",
             "#{stem}.manifest.json", "#{stem}.asc",
             "tebako-runtime-9.9.9-25.0.4.1-windows-ucrt64.exe"]
    expect(signer.signature_targets(names)).to eq(
      [stem, "#{stem}.manifest.json", "#{stem}.sha256", "#{stem}.tfs", "#{stem}.tfs.sha256",
       "tebako-runtime-9.9.9-25.0.4.1-windows-ucrt64.exe"]
    )
  end

  it "scopes the targets to SIGN_ONLY_STEMS (the in-leg case), comma- or space-separated" do
    stem = "tebako-runtime-9.9.9-21.0.12-linux-gnu-x86_64"
    other = "tebako-runtime-9.9.9-25.0.4.1-macos-arm64"
    signer, = signer_for([], env: enabled_env.merge("SIGN_ONLY_STEMS" => "#{stem}, #{other}"))
    names = [stem, "#{stem}.tfs", "#{stem}.sha256", "#{stem}.tfs.sha256", "#{stem}.manifest.json",
             "#{stem}.asc",
             other, "#{other}.tfs", "#{other}.manifest.json",
             # A stem-sharing prefix that is NOT the stem: never swallowed.
             "tebako-runtime-9.9.9-21.0.12-linux-gnu-x86_64-b",
             "tebako-runtime-9.9.9-21.0.12-macos-arm64"]
    expect(signer.signature_targets(names)).to eq(
      [stem, "#{stem}.manifest.json", "#{stem}.sha256", "#{stem}.tfs", "#{stem}.tfs.sha256",
       other, "#{other}.manifest.json", "#{other}.tfs"]
    )
  end

  it "re-signs only assets whose .asc is absent or older than the asset" do
    old = Time.utc(2026, 9, 1)
    new = Time.utc(2026, 9, 9)
    assets = [asset(1, "fresh", new), asset(2, "fresh.asc", new), # converged
              asset(3, "stale", new), asset(4, "stale.asc", old), # re-sign
              asset(5, "unsigned", new)]                          # sign
    signer, = signer_for(assets)
    stale = signer.stale_targets(%w[fresh stale unsigned], assets)
    expect(stale).to contain_exactly("stale", "unsigned")
  end

  it "signs every stale target, verifies it, and converges each .asc onto the release" do
    stub_const("ReleaseSigner::CONVERGENCE_DELAYS", [0, 0, 0])
    old = Time.utc(2026, 9, 1)
    new = Time.utc(2026, 9, 9)
    assets = [asset(1, "pkg-a", new), asset(2, "pkg-a.asc", new),
              asset(3, "pkg-b", new), asset(4, "pkg-b.asc", old),
              asset(5, "pkg-b.sha256", new), asset(6, "pkg-b.manifest.json", new)]
    signer, client, executor = signer_for(assets)

    expect(signer.sign_release).to eq(:signed)

    # pkg-a was already converged — never re-signed, never re-uploaded.
    expect(executor.sign_calls).to contain_exactly("pkg-b", "pkg-b.sha256", "pkg-b.manifest.json")
    expect(client.uploads.map { |u| u[:name] })
      .to contain_exactly("pkg-b.asc", "pkg-b.sha256.asc", "pkg-b.manifest.json.asc")
    # The stale .asc was deleted before the replacement landed.
    expect(client.deletes).to contain_exactly(4)
    # Every upload is the plain-text detached signature shape.
    expect(client.uploads.map { |u| u[:content_type] }.uniq).to eq(["text/plain"])
  end

  it "signs the leg's local bytes (SIGN_LOCAL_DIR) without a download when they hash to the listing's digest" do
    stub_const("ReleaseSigner::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    assets = [asset(1, "pkg-local", new)]
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "pkg-local"), "BYTES-pkg-local")
      signer, _client, executor = signer_for(assets, env: enabled_env.merge("SIGN_LOCAL_DIR" => dir))
      expect(signer.sign_release).to eq(:signed)
      expect(executor.sign_calls).to eq(["pkg-local"])
      # The tool itself downloads; the payload never does.
      expect(executor.download_patterns).to contain_exactly(
        "tebako-pkg-2.7.0-linux-gnu-x86_64", "tebako-pkg-2.7.0-linux-gnu-x86_64.sha256"
      )
    end
  end

  it "re-downloads when the local bytes disagree with the listing's digest" do
    stub_const("ReleaseSigner::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    assets = [asset(1, "pkg-drifted", new)]
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "pkg-drifted"), "STALE-LOCAL-BYTES")
      signer, _client, executor = signer_for(assets, env: enabled_env.merge("SIGN_LOCAL_DIR" => dir))
      expect(signer.sign_release).to eq(:signed)
      expect(executor.sign_calls).to eq(["pkg-drifted"])
      expect(executor.download_patterns).to include("pkg-drifted")
    end
  end

  it "refuses to sign a download whose bytes disagree with the listing's digest" do
    new = Time.utc(2026, 9, 9)
    # The listing claims a digest the served bytes cannot have.
    lying = SignSpecAsset.new(1, "pkg-a", "sha256:#{"1" * 64}", new, "u/pkg-a")
    signer, = signer_for([lying])
    expect { signer.sign_release }
      .to raise_error(ReleaseSigner::SigningGateError, /refusing to sign bytes the release does not serve/)
  end

  it "fails named when the listing carries no digest for a target" do
    new = Time.utc(2026, 9, 9)
    digestless = SignSpecAsset.new(1, "pkg-a", nil, new, "u/pkg-a")
    signer, = signer_for([digestless])
    expect { signer.sign_release }
      .to raise_error(ReleaseSigner::SigningGateError, /carries no digest for pkg-a/)
  end

  it "fetches the signing tool for this runner's platform (windows carries the .exe suffix)" do
    stub_const("ReleaseSigner::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    windows_tool_assets = [
      SignSpecAsset.new(911, "tebako-pkg-2.7.0-windows-ucrt64.exe", nil, new, "u/tw"),
      SignSpecAsset.new(912, "tebako-pkg-2.7.0-windows-ucrt64.exe.sha256", nil, new, "u/tw.sha")
    ]
    client = FakeSignClient.new(release: release, assets: [asset(1, "pkg-win", new)],
                                tool_release: tool_release, tool_assets: windows_tool_assets)
    executor = FakeSignExecutor.new
    signer = ReleaseSigner.new(client: client, executor: executor,
                               env: enabled_env.merge("TEBAKO_PKG_HOST_ID" => "windows-ucrt64"))
    expect(signer.sign_release).to eq(:signed)
    expect(executor.download_patterns).to include("tebako-pkg-2.7.0-windows-ucrt64.exe",
                                                  "tebako-pkg-2.7.0-windows-ucrt64.exe.sha256")
  end

  it "names a detected host id when the tool asset is missing (no TEBAKO_PKG_HOST_ID)" do
    new = Time.utc(2026, 9, 9)
    # A tool release serving only a platform detection can never produce:
    # whatever this runner detects, the lookup misses — deterministic on
    # every host (a linux tool asset would PASS on a linux runner).
    odd_tool_assets = [
      SignSpecAsset.new(921, "tebako-pkg-2.7.0-plan9-arm64", nil, new, "u/t9"),
      SignSpecAsset.new(922, "tebako-pkg-2.7.0-plan9-arm64.sha256", nil, new, "u/t9.sha")
    ]
    env = enabled_env.reject { |k, _| k == "TEBAKO_PKG_HOST_ID" }
    client = FakeSignClient.new(release: release, assets: [asset(1, "pkg-a", new)],
                                tool_release: tool_release, tool_assets: odd_tool_assets)
    signer = ReleaseSigner.new(client: client, executor: FakeSignExecutor.new, env: env)
    expect { signer.sign_release }
      .to raise_error(ReleaseSigner::SigningGateError, /no tebako-pkg \S+ asset on v2\.7\.0/)
  end

  it "refuses to run a signing tool whose provenance digest disagrees" do
    new = Time.utc(2026, 9, 9)
    signer, = signer_for([asset(1, "pkg-a", new)], executor: FakeSignExecutor.new(tool_sha_ok: false))
    expect { signer.sign_release }
      .to raise_error(ReleaseSigner::SigningGateError, /provenance check/)
  end

  it "fails named when an upload never converges" do
    stub_const("ReleaseSigner::CONVERGENCE_DELAYS", [0, 0, 0])
    new = Time.utc(2026, 9, 9)
    assets = [asset(1, "pkg-a", new)]
    # An upload that never joins the listing: the convergence poll can
    # never see the .asc's digest.
    client = FakeSignClient.new(release: release, assets: assets,
                                tool_release: tool_release, tool_assets: tool_assets)
    def client.upload_asset(_url, _path, content_type:, name:)
      @uploads << { name: name, content_type: content_type }
      nil
    end
    signer = ReleaseSigner.new(client: client, executor: FakeSignExecutor.new, env: enabled_env)
    expect { signer.sign_release }
      .to raise_error(ReleaseSigner::SigningGateError, /did not converge/)
  end
end
