#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of the Tebako project.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "bundler/setup"
require "octokit"
require "base64"
require "json"
require "yaml"

# CI log truth: flush every line so the runner's timestamps are the
# writes' real times (the 2026-08-20 wedge lesson, rt-python's
# upload_release.rb).
$stdout.sync = true

# The asset-platform → triplet mapping flows from the build workflow's
# matrix through the feedstock model — never a second hand-authored copy
# (spec 00 §10).
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "feedstock"

RUNTIME_REPO = "tamatebako/tebako-runtime-openjdk" unless defined?(RUNTIME_REPO)

# Renders this repo's tpkg-registry.yaml from a release's per-package
# .manifest.json shards (spec 13 §2a: the shard is the release's
# machine-readable unit; the registry is a spec 04 §2 MIRROR of
# resolution fields, derived — never hand-authored). Ported from
# tebako-runtime-ruby#161's tools/registry_update.rb to this repo's
# registry grammar:
#
# One payload entry per flavor (the spec 28 §8 implementation axis):
# `openjdk` for the default flavor (temurin), `openjdk-<implementation>`
# otherwise (graalvm). One version line per java version built by the
# release; per-triplet platform rows mirroring the shard's ENV IMAGE
# artifact + sha256 (the registry names the image; the wrapper exe is
# pinned per tebako product line); the version's release ref points at
# the release the shards came from. The merge is additive and
# write-once-friendly: existing versions keep their rows (new shards win
# per triplet), `status: withdrawn` marks (the only sanctioned hand-edit
# — spec 04 §2) survive every render, and `default:` tracks the newest
# non-withdrawn version.
#
# The workflow calls this in the release job and lands the result by bot
# PR against main — git arbitrates, never a force-push.
class RegistryUpdate # rubocop:disable Metrics/ClassLength
  class RegistryUpdateError < StandardError; end

  # The default flavor (recipe.yml's documented rule: "temurin is the
  # DEFAULT flavor") keeps the bare payload name; every other flavor's
  # payload is suffixed with its implementation.
  DEFAULT_IMPLEMENTATION = "temurin"
  PAYLOAD_PREFIX = "openjdk"
  SHARD_SUFFIX = ".manifest.json"
  REGISTRY_BASENAME = "tpkg-registry.yaml"

  HEADER = <<~HEADER
    # =============================================================================
    # tpkg-registry.yaml — the tebako-runtime-openjdk runtime registry (spec 04 §2)
    #
    # OWNED BY tools/registry_update.rb — rendered from a release's per-package
    # .manifest.json shards by the build-payload workflow's release job and
    # landed on main by bot PR (spec 13 §2a). NEVER hand-edit: the one sanctioned
    # manual mark is `status: withdrawn` on a version entry (spec 04 §2 — release
    # assets are immutable, so withdrawal is the only remedy for a bad published
    # artifact), and the renderer preserves those marks across renders.
    #
    # kind: runtime entries carry NO entrypoints key (the registry validator:
    # only apps and toolkits declare entrypoints). `implementation` is the spec
    # 28 §8 flavor axis: `openjdk` is the default flavor (temurin — every default
    # resolution channel points here), `openjdk-graalvm` serves `java:graalvm`
    # selectors.
    # =============================================================================
  HEADER

  def initialize(client: nil, env: ENV)
    @env = env
    @client = client || Octokit::Client.new(access_token: @env.fetch("GITHUB_TOKEN"), auto_paginate: true)
    @version = @env.fetch("TEBAKO_VERSION")
    @tag = "v#{@version}"
    @registry_path = @env["REGISTRY_PATH"] || File.join(Feedstock::REPO_ROOT, REGISTRY_BASENAME)
  end

  def run
    release = find_release
    merged = merge(current_registry, version_rows(release))
    path = write_registry(merged)
    puts "#{@tag}: registry rendered to #{path} " \
         "(#{merged.fetch("payloads").size} payload(s))"
    path
  end

  private

  def find_release
    @client.release_for_tag(RUNTIME_REPO, @tag)
  rescue Octokit::NotFound
    raise RegistryUpdateError, "NAMED FAILURE: no release found for tag #{@tag} — nothing to mirror"
  end

  # The release's shards, grouped into registry version lines per
  # (implementation, java version) — the two flavors ride one tag, and
  # the flavors' versions never share a payload.
  def version_rows(release) # rubocop:disable Metrics/MethodLength
    shards = @client.release_assets(release.url).select { |asset| asset.name.end_with?(SHARD_SUFFIX) }
    raise RegistryUpdateError, "NAMED FAILURE: #{@tag} carries no #{SHARD_SUFFIX} shards" if shards.empty?

    by_flavor = {}
    shards.each { |asset| accumulate_shard(by_flavor, asset) }
    by_flavor.map do |(implementation, java), platforms|
      {
        "payload" => payload_name(implementation),
        "implementation" => implementation,
        "version" => java,
        "platforms" => platforms.sort.to_h,
        "release" => { "ref" => "tfs:github:#{RUNTIME_REPO}:#{@tag}" }
      }
    end
  end

  # One shard folds into its flavor's platform rows: it must name THIS
  # release's tebako line (a stale shard from another line is a named
  # refusal, never silently mirrored), and two shards claiming one triplet
  # of one flavor is a named refusal (a row must never be a silent pick).
  def accumulate_shard(by_flavor, asset) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    entry = shard_entry(asset)
    unless entry["tebako_version"] == @version
      raise RegistryUpdateError,
            "NAMED FAILURE: shard #{asset.name} declares tebako_version " \
            "#{entry["tebako_version"].inspect} but this render is for #{@version} — " \
            "the release mixes lines; audit it before mirroring"
    end

    row = platform_row(asset.name, entry)
    key = [entry.fetch("implementation"), entry.fetch("java_version")]
    group = (by_flavor[key] ||= {})
    if group.key?(row.first)
      raise RegistryUpdateError,
            "NAMED FAILURE: two shards claim #{row.first} for #{key.join(" ")} on #{@tag}"
    end

    group[row.first] = row.last
  end

  def shard_entry(asset)
    entry = JSON.parse(@client.get(asset.browser_download_url).to_s)
    missing = %w[tebako_version java_version implementation platform image] - entry.keys
    unless missing.empty?
      raise RegistryUpdateError,
            "NAMED FAILURE: shard #{asset.name} is missing #{missing.join(", ")} — republish the leg"
    end
    image = entry["image"]
    unless image.is_a?(Hash) && image["filename"].is_a?(String) && image["sha256"].is_a?(String)
      raise RegistryUpdateError,
            "NAMED FAILURE: shard #{asset.name} carries no image {filename, sha256} block — " \
            "the registry mirrors the env image; republish the leg"
    end

    entry
  end

  # One shard → one (triplet, {artifact, sha256}) platform row mirroring
  # the ENV IMAGE. The triplet mapping is fail-closed: an asset platform
  # the build matrix does not pair can never become a silently wrong
  # registry row.
  def platform_row(asset_name, entry)
    asset_platform = entry.fetch("platform")
    triplet = asset_to_triplet[asset_platform]
    unless triplet
      raise RegistryUpdateError,
            "NAMED FAILURE: shard #{asset_name} names unknown platform #{asset_platform.inspect} — " \
            "the build matrix pairs no spec 03 §3 triplet with it"
    end

    image = entry.fetch("image")
    [triplet, { "artifact" => image.fetch("filename"), "sha256" => image.fetch("sha256") }]
  end

  def payload_name(implementation)
    implementation == DEFAULT_IMPLEMENTATION ? PAYLOAD_PREFIX : "#{PAYLOAD_PREFIX}-#{implementation}"
  end

  def asset_to_triplet
    @asset_to_triplet ||= Feedstock.matrix_platforms(@env).to_h { |leg| [leg.asset_platform, leg.triplet] }
  end

  # The current registry on main (contents API — the canonical published
  # state), or the seed document when the file does not exist yet.
  def current_registry
    res = @client.contents(RUNTIME_REPO, path: REGISTRY_BASENAME)
    data = YAML.safe_load(Base64.decode64(res.content.to_s))
    return seed unless data.is_a?(Hash)

    data
  rescue Octokit::NotFound
    seed
  end

  def seed
    { "schema_version" => 1, "payloads" => [] }
  end

  # Additive merge: upsert the payload entries, then per rendered
  # version — absent versions are inserted, present versions keep their
  # platform rows (new rows win per triplet) and any `status: withdrawn`
  # mark. Versions sort ascending; `default:` tracks the newest
  # non-withdrawn line, and a payload with none left says so loudly.
  def merge(registry, rendered) # rubocop:disable Metrics/AbcSize
    payloads = registry["payloads"] ||= []
    rendered.group_by { |row| row.fetch("payload") }.each do |name, rows|
      payload = payloads.find { |p| p["name"] == name }
      unless payload
        payload = { "name" => name, "kind" => "runtime", "versions" => [] }
        payloads << payload
      end
      versions = payload["versions"] ||= []
      rows.each { |row| merge_version(versions, row) }
      payload["versions"] = versions.sort_by { |v| version_sort_key(v.fetch("version")) }
      refresh_default(payload)
    end
    registry
  end

  # Numeric sort, never lexical ("21.10.x" must not sort before
  # "21.9.x"); a hand-edited unparseable version is a named refusal.
  def version_sort_key(version)
    Gem::Version.new(version)
  rescue ArgumentError
    raise RegistryUpdateError,
          "NAMED FAILURE: registry version #{version.inspect} is not a parseable version"
  end

  # One rendered version into the payload's version list: an existing
  # line unions platform rows (new wins per triplet) and keeps its status
  # mark; `platforms: universal` on an existing line can never mix with
  # the shards' per-triplet rows (spec 04 §2: a version carries one
  # shape).
  def merge_version(versions, row) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    existing = versions.find { |v| v["version"] == row["version"] }
    unless existing
      versions << { "version" => row["version"], "implementation" => row["implementation"],
                    "platforms" => row["platforms"], "release" => row["release"] }
      return
    end

    platforms = (existing["platforms"] ||= {})
    unless platforms.is_a?(Hash)
      raise RegistryUpdateError,
            "NAMED FAILURE: registry version #{row["version"].inspect} carries " \
            "`platforms: #{platforms.inspect}` but the shards render per-triplet rows — " \
            "the registry was hand-edited into a mixed shape (spec 04 §2: never both)"
    end

    row["platforms"].each { |triplet, artifact| platforms[triplet] = artifact }
    existing["platforms"] = platforms.sort.to_h
    existing["release"] = row["release"]
  end

  def refresh_default(payload)
    usable = payload["versions"].reject { |v| v["status"] == "withdrawn" }
    if usable.empty?
      warn "WARNING: every #{payload.fetch("name")} version is withdrawn — the registry carries no default"
      payload.delete("default")
    else
      payload["default"] = usable.last.fetch("version")
    end
  end

  def write_registry(registry)
    body = YAML.dump(registry).sub(/\A---\n/, "")
    File.write(@registry_path, "#{HEADER}#{body}")
    @registry_path
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    RegistryUpdate.new.run
  rescue RegistryUpdate::RegistryUpdateError, Feedstock::FeedstockError, KeyError => e
    warn e.message
    exit 1
  end
end
