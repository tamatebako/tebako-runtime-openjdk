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

# CI log truth: flush every line so the runner's timestamps are the
# writes' real times (the 2026-08-20 wedge lesson, rt-python's
# upload_release.rb).
$stdout.sync = true

# The expected (flavor × platform) matrix flows from the build workflow +
# recipe.yml through the feedstock model — never a second hand-authored
# copy (spec 00 §10).
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "feedstock"

RUNTIME_REPO = "tamatebako/tebako-runtime-openjdk" unless defined?(RUNTIME_REPO)

# The release audit (spec 13 §2a — completeness is a QUERY, not a gate
# that mutates): strictly read-only. The build legs publish and sign
# their own write-once names in-leg (the de-rendezvous, roadmap 85); this
# is the coordinator's whole-matrix check that every leg's names actually
# landed. The expected set is derived from the build workflow's own
# matrix × recipe.yml's version pins: every leg's pair (wrapper exe + env
# image), each asset's .sha256 sidecar, and the package's
# .manifest.json shard must be listed; on signing-enabled lines every
# served name additionally owes its own .asc (spec 09 §5's no-fold rule).
# The retired monoliths (manifest.json, SHA256SUMS.txt) must be ABSENT —
# they are consumer-side derivations now (`tebako-pkg release-index`),
# never release assets. Any gap is a named failure listing every missing
# (or forbidden) name; the release is never touched.
class ReleaseAudit
  class AuditError < StandardError; end

  # The retired shared mutable names (spec 13 §2a's de-rendezvous): never
  # release assets again.
  MONOLITH_NAMES = ["manifest.json", "SHA256SUMS.txt"].freeze

  def initialize(client: nil, env: ENV)
    @env = env
    @client = client || Octokit::Client.new(access_token: @env.fetch("GITHUB_TOKEN"), auto_paginate: true)
    @version = @env.fetch("TEBAKO_VERSION")
    @tag = "v#{@version}"
  end

  def run
    release = find_release
    present = @client.release_assets(release.url).map(&:name)
    missing = expected_names(signing: signing_enabled?) - present
    monoliths = MONOLITH_NAMES & present
    report(missing, monoliths)
    return :clean if missing.empty? && monoliths.empty?

    raise AuditError, "NAMED FAILURE: release #{@tag} failed the audit " \
                      "(#{missing.size} missing, #{monoliths.size} forbidden) — see above"
  end

  # The whole-matrix expectation: the pair + sidecars + shard per
  # (flavor × platform) leg — plus every name's .asc when the line signs.
  def expected_names(signing: false)
    names = Feedstock.expected_asset_names(@env)
    names += names.map { |name| "#{name}.asc" } if signing
    names
  end

  private

  def signing_enabled?
    @env["TEBAKO_RELEASE_SIGNING_ENABLED"] == "true"
  end

  def find_release
    @client.release_for_tag(RUNTIME_REPO, @tag)
  rescue Octokit::NotFound
    raise AuditError, "NAMED FAILURE: no release found for tag #{@tag} — nothing to audit"
  end

  def report(missing, monoliths)
    if missing.empty?
      puts "#{@tag}: audit clean — the expected matrix is served" \
           "#{signing_enabled? ? " (with full .asc coverage — spec 09 §5)" : ""}"
    else
      puts "::error::Release #{@tag} is incomplete: #{missing.size} expected asset(s) missing"
      missing.sort.each { |name| puts "::error::Missing asset: #{name}" }
    end
    return if monoliths.empty?

    monoliths.each do |name|
      puts "::error::#{name} is present on #{@tag} — the monoliths are NEVER release assets " \
           "(spec 13 §2a; they are consumer-side derivations, `tebako-pkg release-index`)"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    ReleaseAudit.new.run
  rescue ReleaseAudit::AuditError, Feedstock::FeedstockError, KeyError => e
    warn e.message
    exit 1
  end
end
