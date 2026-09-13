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
# (the owner of what gets built) and the version pins FROM recipe.yml
# (the owner of every version/digest literal). Both readers fail closed:
# a shape they do not recognize is a named error, never a guess.
module Feedstock
  class FeedstockError < StandardError; end

  REPO_ROOT = File.expand_path("../..", __dir__).freeze
  RECIPE_BASENAME = "recipe.yml"
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

  # The flavor's published java version (recipe.yml's
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

    rows.map do |row|
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

  # The spec 13 release-asset stem grammar (tebako-runtime-<line>-<ver>-
  # <asset-platform>) over recipe-owned values.
  def runtime_stem(flavor, asset_platform, env = ENV)
    "tebako-runtime-#{wrapper_tebako(env)}-#{flavor_version(flavor, env)}-#{asset_platform}"
  end

  # The write-once names one leg owns (spec 13 §2a): the pair (wrapper
  # exe + env image), each asset's .sha256 sidecar, and the package's
  # .manifest.json shard.
  def leg_asset_names(flavor, leg, env = ENV)
    stem = runtime_stem(flavor, leg.asset_platform, env)
    exe = "#{stem}#{leg.exe_suffix}"
    [exe, "#{exe}.sha256", "#{stem}.tfs", "#{stem}.tfs.sha256", "#{stem}.manifest.json"]
  end

  # Every leg's write-once names across the whole build matrix.
  def expected_asset_names(env = ENV)
    matrix_flavors(env).product(matrix_platforms(env)).flat_map do |flavor, leg|
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
end
