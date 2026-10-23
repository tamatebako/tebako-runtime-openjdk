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

require "yaml"

# The feedstock's release-shape model (spec 00 §10 — SSOT flow, never a
# second hand-authored copy): the two release-time tools
# (tools/audit_release.rb, tools/registry_update.rb) read the expected
# (flavor × platform) matrix FROM the build workflow's own matrix block
# (the owner of what gets built) and the version pins FROM Tebakofile
# (the owner of every version/digest literal). Both readers fail closed:
# a shape they do not recognize is a named error, never a guess.
module Feedstock
  class FeedstockError < StandardError; end

  REPO_ROOT = File.expand_path("../..", __dir__).freeze
  RECIPE_BASENAME = "Tebakofile"
  MATRIX_RELPATH = ".github/workflows/build-payload.yml"

  # One platform leg of the build matrix: the spec 03 triplet (the
  # registry row key), the release-asset platform (the asset-name
  # segment), and the exe suffix — the platform's three spellings, paired
  # by the workflow matrix (their single owner in this repo).
  PlatformLeg = Struct.new(:triplet, :asset_platform, :exe_suffix)

  module_function

  def recipe_path(env = ENV)
    env["RECIPE_PATH"] || File.join(REPO_ROOT, RECIPE_BASENAME)
  end

  def matrix_path(env = ENV)
    env["MATRIX_PATH"] || File.join(REPO_ROOT, MATRIX_RELPATH)
  end

  def recipe(env = ENV)
    data = YAML.load_file(recipe_path(env))
    unless data.is_a?(Hash) && data["flavors"].is_a?(Hash) && data["runtime"].is_a?(Hash)
      raise FeedstockError, "NAMED FAILURE: #{recipe_path(env)} carries no flavors:/runtime: blocks — not a runtime recipe"
    end

    data
  end

  # The wrapper line the pairs build against (the release tag's bare
  # version — the tag IS the tebako product line).
  def wrapper_tebako(env = ENV)
    line = recipe(env).fetch("runtime")["wrapper_tebako"]
    return line if line.is_a?(String) && !line.empty?

    raise FeedstockError, "NAMED FAILURE: #{recipe_path(env)} runtime.wrapper_tebako missing"
  end

  # The flavor's published java version (Tebakofile's
  # flavors.<flavor>.upstream.version — the version pin's single owner).
  def flavor_version(flavor, env = ENV)
    version = recipe(env).dig("flavors", flavor, "upstream", "version")
    return version.to_s if version

    raise FeedstockError,
          "NAMED FAILURE: #{recipe_path(env)} carries no flavors.#{flavor}.upstream.version"
  end

  # The build legs' flavor axis, flowed from the build workflow's matrix
  # (the owner of what gets built). A matrix moved to include:-style (or
  # otherwise unrecognizable) is a named refusal.
  def matrix_flavors(env = ENV)
    flavors = matrix_block(env)["flavor"]
    return flavors if flavors.is_a?(Array) && flavors.all? { |f| f.is_a?(String) } && !flavors.empty?

    raise FeedstockError,
          "NAMED FAILURE: #{matrix_path(env)} build matrix carries no plain `flavor:` list — " \
          "the release tools read the leg set from it"
  end

  # The build legs' platforms, flowed from the build workflow's matrix as
  # PlatformLeg rows (triplet + asset_platform + exe_suffix, paired there
  # and nowhere else). A platform row missing any spelling is a named
  # refusal.
  def matrix_platforms(env = ENV)
    rows = matrix_block(env)["platform"]
    unless rows.is_a?(Array) && !rows.empty?
      raise FeedstockError,
            "NAMED FAILURE: #{matrix_path(env)} build matrix carries no plain `platform:` list — " \
            "the release tools read the leg set from it"
    end

    rows.map { |row| platform_leg(row, env) }
  end

  # The matrix's include: arm — the legs OUTSIDE the plain flavor ×
  # platform cartesian (the asymmetric surface: graalvm-ce-builds
  # publishes no musl assets and no macos-x64 / windows-aarch64 assets,
  # so the musl pair, x86_64-macos, and aarch64-windows-ucrt exist for
  # temurin only and ride include rows that pin flavor + a full platform
  # row). Each row must pair a flavor the axis declares with a platform
  # row carrying the three spellings; an include that re-pairs a
  # cartesian (flavor, triplet) is a named refusal (that leg belongs on
  # the plain axes —
  # GitHub would merge it into the existing leg, and the model would
  # double-count it). Absent include: is fine (the pre-musl shape); any
  # other unrecognized shape is a named refusal, never a guess.
  def matrix_include_legs(env = ENV)
    rows = matrix_block(env)["include"]
    return [] if rows.nil?
    unless rows.is_a?(Array)
      raise FeedstockError,
            "NAMED FAILURE: #{matrix_path(env)} build matrix include: is not a list — " \
            "the release tools read the extra legs from it"
    end

    cartesian = matrix_flavors(env).product(matrix_platforms(env))
    rows.map do |row|
      flavor = row.is_a?(Hash) && row["flavor"]
      platform = row.is_a?(Hash) && row["platform"]
      unless flavor.is_a?(String) && platform.is_a?(Hash)
        raise FeedstockError,
              "NAMED FAILURE: #{matrix_path(env)} build matrix include row lacks " \
              "flavor/platform: #{row.inspect}"
      end
      unless matrix_flavors(env).include?(flavor)
        raise FeedstockError,
              "NAMED FAILURE: #{matrix_path(env)} build matrix include row names unknown " \
              "flavor #{flavor.inspect} (the axis declares: #{matrix_flavors(env).join(', ')})"
      end

      leg = platform_leg(platform, env)
      if cartesian.any? { |f, l| f == flavor && l.triplet == leg.triplet }
        raise FeedstockError,
              "NAMED FAILURE: #{matrix_path(env)} build matrix include row re-pairs the " \
              "cartesian leg #{flavor}/#{leg.triplet} — that leg belongs on the plain axes"
      end

      [flavor, leg]
    end
  end

  # The whole leg set: the plain cartesian plus the include arm's extras.
  def matrix_legs(env = ENV)
    matrix_flavors(env).product(matrix_platforms(env)) + matrix_include_legs(env)
  end

  # The flavor's distribution identity (Tebakofile's
  # flavors.<flavor>.implementation — tebako#716's language segment of the
  # runtime pair's name; the registry row's implementation key).
  def flavor_implementation(flavor, env = ENV)
    implementation = recipe(env).dig("flavors", flavor, "implementation")
    return implementation if implementation.is_a?(String) && implementation.match?(/\A[a-z0-9]+\z/)

    raise FeedstockError,
          "NAMED FAILURE: #{recipe_path(env)} carries no flavors.#{flavor}.implementation " \
          "(a dash-free [a-z0-9]+ segment) — the pair's name composes it"
  end

  # The spec 13 release-asset stem grammar over recipe-owned values —
  # tebako-runtime-<line>-<implementation>-<ver>-<asset-platform>
  # (tebako#716's language segment is the flavor's implementation;
  # tools/pins.rb and tools/build compose the same grammar).
  def runtime_stem(flavor, asset_platform, env = ENV)
    "tebako-runtime-#{wrapper_tebako(env)}-#{flavor_implementation(flavor, env)}" \
      "-#{flavor_version(flavor, env)}-#{asset_platform}"
  end

  # The write-once names one leg owns (spec 13 §2a): the pair (wrapper
  # exe + env image), each asset's .sha256 sidecar, and the package's
  # .manifest.json shard.
  def leg_asset_names(flavor, leg, env = ENV)
    stem = runtime_stem(flavor, leg.asset_platform, env)
    exe = "#{stem}#{leg.exe_suffix}"
    # The blksum sidecar and its own .sha256 are SERVED names (spec 39 §3):
    # the lazy mount verifies the sidecar against the row's pin before the
    # first range read, and delta has nothing to compare without it
    # (tebako#868).
    [exe, "#{exe}.sha256",
     "#{stem}.tfs", "#{stem}.tfs.sha256",
     "#{stem}.tfs.blksum.json", "#{stem}.tfs.blksum.json.sha256",
     "#{stem}.manifest.json"]
  end

  # Every leg's write-once names across the whole build matrix (the plain
  # cartesian plus the include arm).
  def expected_asset_names(env = ENV)
    matrix_legs(env).flat_map do |flavor, leg|
      leg_asset_names(flavor, leg, env)
    end.sort
  end

  def matrix_block(env = ENV)
    workflow = YAML.load_file(matrix_path(env))
    block = workflow.is_a?(Hash) && workflow.dig("jobs", "build", "strategy", "matrix")
    return block if block.is_a?(Hash)

    raise FeedstockError,
          "NAMED FAILURE: #{matrix_path(env)} carries no jobs.build.strategy.matrix block — " \
          "the release tools read the leg set from it"
  end

  # One platform row → one PlatformLeg, fail-closed on the three
  # spellings (shared by the platform: axis and the include: arm).
  def platform_leg(row, env)
    triplet = row.is_a?(Hash) && row["triplet"]
    asset = row.is_a?(Hash) && row["asset_platform"]
    suffix = row.is_a?(Hash) && row["exe_suffix"]
    unless triplet.is_a?(String) && asset.is_a?(String) && suffix.is_a?(String)
      raise FeedstockError,
            "NAMED FAILURE: #{matrix_path(env)} build matrix platform row lacks " \
            "triplet/asset_platform/exe_suffix: #{row.inspect}"
    end

    PlatformLeg.new(triplet, asset, suffix)
  end
end
