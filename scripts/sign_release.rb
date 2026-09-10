#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "octokit"
require "digest"
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"

# CI log truth: flush every line so the runner's timestamps are the
# writes' real times (the 2026-08-20 wedge lesson, rt-python's
# upload_release.rb).
$stdout.sync = true

RUNTIME_REPO = "tamatebako/tebako-runtime-openjdk" unless defined?(RUNTIME_REPO)
TEBAKO_REPO = "tamatebako/tebako"

# Signs one tebako-runtime-openjdk release (tebako spec 09 §2): every
# runtime pair artifact (the wrapper exes and the .tfs env images), plus
# the two monolithic index files (SHA256SUMS.txt, manifest.json), ships a
# detached OpenPGP .asc made by the tamatebako release signing subkey. The
# signing tool is the LATEST tamatebako/tebako release's tebako-pkg,
# pinned by asset name and sha256-verified against that release's own
# sidecar before it runs.
#
# The derived metadata — the per-asset .sha256 sidecars and the per-pair
# .manifest.json shards — is NOT separately signed: each sidecar is a
# line of the signed SHA256SUMS.txt and each shard folds into the signed
# manifest.json (the tebako repo's sign-release.sh rule, applied to this
# release's shape).
#
# Gate (the spec 31 §5 house style): TEBAKO_RELEASE_SIGNING_ENABLED=true
# arms the pass; armed + an empty TEBAKO_RELEASE_SIGNING_KEY is a fast
# named failure; disarmed exits 0 and the release ships unsigned
# (unsigned stays first-class — spec 09 §3).
#
# Ported from tebako-runtime-python's scripts/sign_release.rb (0c81b92,
# PR #12 — itself rt-ruby#154's script plus the rt-ruby#156 fix): the
# release shape is the same (trr#140's shard/sidecar/monolith grammar),
# so the port is the repo constant, the local-bytes dir, and the comments
# — and it carries the python port's proven fix: materialize_key
# base64-DECODES the secret (never `[key].pack("m0")`, which re-encodes).
class ReleaseSigner # rubocop:disable Metrics/ClassLength
  # Armed-but-cannot, provenance, and coverage failures: the pass never
  # ships a partially signed release silently.
  class SigningGateError < StandardError; end

  # The signing tool asset on a tamatebako/tebako release (the sign job's
  # runner is ubuntu-latest — linux-gnu x86_64).
  TOOL_ASSET_PATTERN = /\Atebako-pkg-\d+\.\d+\.\d+-linux-gnu-x86_64\z/

  # The two derived index files that DO carry their own .asc (all other
  # derived metadata — the .sha256 sidecars and the .manifest.json shards
  # — is covered by the signed indexes).
  INDEX_FILES = ["SHA256SUMS.txt", "manifest.json"].freeze

  # This run's fresh pair bytes, materialized by the sign job's
  # payload-* artifact download (merge-multiple flattens the per-leg
  # dirs) — signing prefers them over a re-download (the derived
  # monoliths, built in the release job and never in the artifacts, are
  # the download case; so is any backfill onto an older release).
  LOCAL_PACKAGES_DIR = "release-assets"

  # upload convergence: a tiny metadata asset either lands or cycles;
  # three bounded polls then a named failure.
  CONVERGENCE_DELAYS = [5, 15, 30].freeze

  def initialize(client: nil, executor: nil, env: ENV)
    @env = env
    @client = client || Octokit::Client.new(access_token: @env.fetch("GITHUB_TOKEN"), auto_paginate: true)
    @executor = executor || ShellExecutor.new
    @tag = "v#{@env.fetch("TEBAKO_VERSION")}"
  end

  # The one public verb. Returns :disarmed or :signed.
  def sign_release # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    unless enabled?
      puts "release signing disarmed (TEBAKO_RELEASE_SIGNING_ENABLED != 'true') — unsigned-first (spec 09 §3)"
      return :disarmed
    end
    if signing_key.empty?
      raise SigningGateError,
            "NAMED FAILURE: TEBAKO_RELEASE_SIGNING_ENABLED=true but the TEBAKO_RELEASE_SIGNING_KEY secret is not set"
    end

    release = find_release
    Dir.mktmpdir do |dir|
      work = Pathname.new(dir)
      tool = fetch_verified_tool(work)
      key_file = materialize_key(work)
      assets = @client.release_assets(release.url)
      targets = signature_targets(assets.map(&:name))
      missing_indexes = INDEX_FILES - targets
      unless missing_indexes.empty?
        raise SigningGateError,
              "NAMED FAILURE: #{@tag} lacks the index files #{missing_indexes.join(", ")} — " \
              "the publish job must land them before signing"
      end

      stale = stale_targets(targets, assets)
      puts "#{@tag}: #{targets.size} signature targets, #{stale.size} need (re)signing"
      stale.each { |name| sign_one(work, key_file, tool, release, name) }
      assert_coverage!(release, targets)
    end
    :signed
  end

  # The asset names that carry a .asc: everything that is not derived
  # metadata (class comment) — the wrapper exes, the env images, and the
  # two index files. The shard suffix would swallow the monolithic
  # manifest.json itself, so it excludes by shape, not by suffix alone.
  def signature_targets(asset_names)
    asset_names.reject do |name|
      next true if name.end_with?(".sha256", ".contract.yaml", ".asc")

      name.end_with?(".manifest.json") && name != "manifest.json"
    end.sort
  end

  # The targets whose .asc is absent or older than the asset itself: a
  # replaced asset invalidates its signature (new bytes), an untouched
  # asset keeps it (a detached signature over unchanged bytes stays
  # valid — re-signing would only churn the release).
  def stale_targets(targets, assets)
    by_name = assets.to_h { |asset| [asset.name, asset] }
    targets.select do |name|
      asc = by_name["#{name}.asc"]
      asc.nil? || asc.updated_at < by_name.fetch(name).updated_at
    end
  end

  private

  def enabled?
    @env["TEBAKO_RELEASE_SIGNING_ENABLED"] == "true"
  end

  def signing_key
    (@env["TEBAKO_RELEASE_SIGNING_KEY"] || "").strip
  end

  def find_release
    @client.release_for_tag(RUNTIME_REPO, @tag)
  rescue Octokit::NotFound
    raise SigningGateError, "NAMED FAILURE: no release found for tag #{@tag} — nothing to sign"
  end

  # The signing subkey export, base64-DECODED to a 0600 file that lives
  # and dies with the pass's tmpdir. Documented deviation from
  # rt-ruby#154: its `[key].pack("m0")` base64-ENCODES the already-base64
  # secret (Array#pack is the encoder), so an armed run can only die on
  # rnp's BadFormat — the spec fakes never run the real tebako-pkg, and
  # the python port's rehearsal did (rt-ruby#156 landed the same fix
  # upstream). Garbage secrets fail named, never raw.
  def materialize_key(work)
    key_file = work.join("release-key.asc")
    begin
      key_file.write(signing_key.unpack1("m0"))
    rescue ArgumentError
      raise SigningGateError, "NAMED FAILURE: the TEBAKO_RELEASE_SIGNING_KEY secret is not valid base64"
    end
    key_file.chmod(0o600)
    key_file
  end

  # The latest tebako release's tebako-pkg, provenance-pinned: downloaded
  # with its .sha256 sidecar and executed only when the digest matches.
  def fetch_verified_tool(work) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    latest = @client.latest_release(TEBAKO_REPO)
    names = @client.release_assets(latest.url).map(&:name)
    tool_name = names.find { |name| name.match?(TOOL_ASSET_PATTERN) }
    raise SigningGateError, "NAMED FAILURE: no tebako-pkg linux-gnu-x86_64 asset on #{latest.tag_name}" unless tool_name

    tool_dir = work.join("tool")
    FileUtils.mkdir_p(tool_dir)
    @executor.run("gh", "release", "download", latest.tag_name, "--repo", TEBAKO_REPO,
                  "--pattern", tool_name, "--pattern", "#{tool_name}.sha256",
                  "--dir", tool_dir.to_s, "--clobber")
    tool = tool_dir.join(tool_name)
    want = tool_dir.join("#{tool_name}.sha256").read.split.first
    actual = Digest::SHA256.file(tool).hexdigest
    unless want == actual
      raise SigningGateError,
            "NAMED FAILURE: the signing tool #{tool_name} failed its provenance check " \
            "(expected #{want}, got #{actual})"
    end

    tool.chmod(0o755)
    tool.to_s
  end

  # One stale target: bytes from this run's workspace when present (the
  # sign job already materialized them), a targeted download only for
  # the monolith/backfill case; sign, verify against the freshly
  # registered key, then converge the .asc onto the release.
  def sign_one(work, key_file, tool, release, name) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    local = Pathname.new(LOCAL_PACKAGES_DIR).join(name)
    dir = work.join("assets")
    FileUtils.mkdir_p(dir)
    target = if local.exist?
               local
             else
               @executor.run("gh", "release", "download", @tag, "--repo", RUNTIME_REPO,
                             "--pattern", name, "--dir", dir.to_s, "--clobber")
               dir.join(name)
             end
    @executor.run(tool, "sign", "--key-file", key_file.to_s, "--no-sums", name, chdir: File.dirname(target.to_s))
    @executor.run(tool, "verify", name, chdir: File.dirname(target.to_s))
    converge_asc(release, Pathname.new(File.join(File.dirname(target.to_s), "#{name}.asc")))
    puts "#{name}: signed and converged"
  end

  # A tiny metadata upload, converged: replace whatever the name serves,
  # then poll until the listing's digest is our bytes (the edge cache
  # lesson of rt-python's upload_release.rb, bounded).
  def converge_asc(release, asc_file)
    sha = Digest::SHA256.file(asc_file).hexdigest
    converged = false
    CONVERGENCE_DELAYS.each do |pause|
      converged = asc_converged?(release, asc_file, sha)
      break if converged

      puts "#{asc_file.basename} has not converged on the release yet; cycling in #{pause}s"
      sleep pause
    end
    raise SigningGateError, "NAMED FAILURE: #{asc_file.basename} did not converge on #{@tag}" unless converged
  end

  # One convergence cycle: the listing already serving our bytes is done;
  # anything else is deleted/replaced and re-uploaded for the next poll.
  # A 422 mid-replace is the deletion-propagation race (upload_release.rb's
  # wedge lesson): the name unblocks within a cycle, so it rides along as
  # not-yet-converged instead of crashing the pass.
  def asc_converged?(release, asc_file, sha) # rubocop:disable Metrics/AbcSize
    existing = @client.release_assets(release.url).find { |asset| asset.name == asc_file.basename.to_s }
    return true if existing && listed_sha(existing) == sha

    @client.delete_release_asset(existing.id) if existing
    @client.upload_asset(release.url, asc_file.to_s,
                         content_type: "text/plain",
                         name: asc_file.basename.to_s)
    false
  rescue Octokit::UnprocessableEntity => e
    puts "#{asc_file.basename}: replace raced the 422 propagation window (#{e.class}) — cycling"
    false
  end

  # The coverage assertion: after the pass, every target has a .asc on
  # the release — a partially signed release is a named failure, never a
  # quiet state.
  def assert_coverage!(release, targets)
    names = @client.release_assets(release.url).map(&:name)
    missing = targets.reject { |name| names.include?("#{name}.asc") }
    return if missing.empty?

    raise SigningGateError,
          "NAMED FAILURE: #{missing.size} signature(s) missing on #{@tag}: #{missing.join(", ")}"
  end

  # The listing's digest field is "sha256:<hex>" when the API serves one.
  def listed_sha(asset)
    asset.digest.to_s.sub(/\Asha256:/, "")
  end

  # The default command seam: argv in, stdout out, named failure on a
  # non-zero exit. Specs inject a recording stand-in.
  class ShellExecutor
    def run(*argv, chdir: ".")
      out, err, status = Open3.capture3(*argv, chdir: chdir)
      unless status.success?
        raise SigningGateError,
              "NAMED FAILURE: `#{argv.join(" ")}` exited #{status.exitstatus}: #{err.strip}"
      end

      out
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    ReleaseSigner.new.sign_release
  rescue ReleaseSigner::SigningGateError, KeyError => e
    warn e.message
    exit 1
  end
end
