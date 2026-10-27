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

require "cgi"
require "digest"
require "json"
require "net/http"
require "uri"
require "yaml"

# The release monitor (propose-bump shape): checks each flavor's upstream
# for a newer release ON THE PINNED LINE and, when one resolves, rewrites
# the recipe's own literals to it — `upstream.version`, `upstream.build`,
# `upstream.tag`, each source's `url:` and `sha256:` — leaving every
# comment, key order, indentation, quoting style and every OTHER flavor's
# block byte-identical. The workflow (release-monitor.yml) turns the dirty
# tree into a pull request; nothing here merges, tags or publishes.
#
# The design rules this file obeys:
#
# 1. The recipe is the single owner of every pin. The monitor reads the
#    pinned version/build/tag and the declared sources from Tebakofile and
#    derives the upstream release repo, the tag grammar and each asset's
#    NAME SHAPE from those values — no asset name is typed twice, so a
#    changed upstream layout surfaces as a named error, never a guess.
# 2. The pinned line is a recipe value, never a monitor heuristic — see
#    FLAVOR_LINES for which recipe key carries it. A newer upstream
#    release on a NEWER line is reported as `newer_line` and deliberately
#    skipped, never rolled across.
# 3. Every digest is upstream's own: the release's published checksum
#    sidecar when it has one, else the archive's bytes hashed on the
#    stream (with the byte count printed). The monitor never invents one.
# 4. A rewrite that would touch a line it did not plan is a named error:
#    the diff is asserted to be exactly the planned set (assert_plan_only!).
# 5. Upstream calls are authenticated (GH_TOKEN/GITHUB_TOKEN, api.github.com
#    only). 403/429 are quota answers and 502/503/504 availability answers:
#    all are retried with Retry-After / x-ratelimit-reset and then NAMED;
#    a 404 stays a dead upstream (the bun release-monitor's 2026-10-23
#    lesson, tamatebako/tebako-runtime-bun#30).
#
# Everything except the Upstream edge is a pure function of (recipe text,
# upstream answers), which is what the offline cases prove — this repo's
# own cases sit where its config section says they do.
#
# Discovery reads the repo's TAG list and the chosen tag's release asset
# list, both cheap and both GitHub API; a tag's release is read for the
# bytes and the checksum sidecars, never to discover the version.

module ReleaseMonitor
  class MonitorError < StandardError; end

  # A candidate release whose asset list does not cover a declared source
  # is skipped (upstream publishes legs asynchronously); the caller names
  # it in the verdict's `skipped` list and tries the next candidate.
  class IncompleteRelease < MonitorError
    attr_reader :missing

    def initialize(missing)
      @missing = missing
      super("candidate release carries no asset matching #{missing.join(', ')}")
    end
  end

  ROOT = File.expand_path("../..", __dir__)
  RECIPE_BASENAME = "Tebakofile"

  # Per-flavor line derivation. `rule` names the RECIPE key that carries
  # the line, `token` is the release token the line is matched against.
  #   temurin — language_version is the JDK major (21): the Temurin line.
  #   graalvm — its own line is the GraalVM release line, upstream.build
  #             first two segments (25.3). GraalVM ships monthly releases
  #             that share the JDK update, and the asset grammar's 25iN
  #             segment tracks that release line (graal-25.3.4.1 ships
  #             25i3, graal-25.4.4.1.1 ships 25i4), so 25.4 is a line
  #             crossing a human decides — reported as newer_line, never
  #             rolled across.
  FLAVOR_LINES = {
    "temurin" => { rule: :language_version, token: :version },
    "graalvm" => { rule: :build_line, token: :build }
  }.freeze

  # Both flavors' sources are GitHub release assets, so the release repo
  # flows from the recipe's own URLs (adoptium/temurin21-binaries,
  # graalvm/graalvm-ce-builds). A flavor whose sources are not GitHub
  # release assets names its release repo here instead.
  RELEASE_REPOS = {}.freeze

  # The offline cases for this module live in spec/release_monitor_spec.rb
  # (this repo carries an rspec suite); tools/monitor has no --self-test here.

  Flavor = Struct.new(:name, :block, :range, :upstream_range, :version, :build,
                      :tag, :version_index, :build_index, :tag_index, :sources,
                      :rule, :line_token, :line, keyword_init: true)
  Source = Struct.new(:platform, :url, :digest, :first, :last, :url_index,
                      :digest_index, keyword_init: true)

  MARK = "\u0001"
  PLACEHOLDER = /\u0001([a-z]+)\u0001/
  API = "https://api.github.com"
  TOKEN_HOST = "api.github.com"
  MAX_ATTEMPTS = 3
  MAX_PAGES = 5
  MAX_REDIRECTS = 3

  Response = Struct.new(:code, :body, :headers, keyword_init: true)

  module_function

  def recipe_path(env = ENV)
    env["RECIPE_PATH"] || File.join(ROOT, RECIPE_BASENAME)
  end

  # The one entry point: read the recipe, check every flavor, rewrite the
  # actionable literals (unless dry_run), and return the JSON-shaped
  # verdict. `upstream:` is injectable so the cases run offline.
  def check(recipe_path: self.recipe_path, upstream: Upstream.new, dry_run: false)
    body = File.read(recipe_path)
    verdicts = read_flavors(body).map { |flavor| check_flavor(body, flavor, upstream) }
    edits = verdicts.flat_map { |verdict| verdict[:edits] }
    File.write(recipe_path, apply_plan(body, edits)) if !dry_run && !edits.empty?
    summarize(verdicts, dry_run: dry_run)
  end

  # --- the recipe (values from YAML, locations from the text) ---

  def read_flavors(body)
    data = parse_recipe(body)
    lines = body.lines
    data.fetch("flavors").map { |name, block| read_flavor(lines, name, block) }
  end

  def parse_recipe(body)
    data = YAML.safe_load(body)
    unless data.is_a?(Hash) && data["flavors"].is_a?(Hash) && !data["flavors"].empty?
      raise MonitorError, "NAMED FAILURE: #{RECIPE_BASENAME} carries no flavors: block — not a runtime recipe"
    end

    data
  end

  def read_flavor(lines, name, block)
    config = FLAVOR_LINES[name]
    unless config
      raise MonitorError,
            "NAMED FAILURE: flavors.#{name} has no line rule in this repo's monitor " \
            "(known: #{FLAVOR_LINES.keys.join(', ')}) — the monitor refuses to guess which release line a flavor pins"
    end
    upstream = block["upstream"]
    raise MonitorError, "NAMED FAILURE: flavors.#{name} carries no upstream: block" unless upstream.is_a?(Hash)

    range = flavor_range(lines, name)
    up_range = upstream_range(lines, name, range)
    version = scalar_value(upstream["version"], "flavors.#{name}.upstream.version")
    build = upstream["build"]&.to_s
    tag = upstream["tag"]&.to_s
    source_list = upstream["sources"]
    unless source_list.is_a?(Array) && !source_list.empty?
      raise MonitorError, "NAMED FAILURE: flavors.#{name}.upstream carries no sources: list"
    end

    Flavor.new(
      name: name, block: block, range: range, upstream_range: up_range,
      version: version, build: build, tag: tag,
      version_index: scalar_line(lines, up_range, "version"),
      build_index: build ? scalar_line(lines, up_range, "build") : nil,
      tag_index: tag ? scalar_line(lines, up_range, "tag") : nil,
      sources: source_entries(lines, up_range, source_list),
      rule: config.fetch(:rule), line_token: config.fetch(:token),
      line: line_for(config, block, version, build, tag)
    )
  end

  def scalar_value(value, where)
    text = value&.to_s
    return text if text && !text.empty?

    raise MonitorError, "NAMED FAILURE: #{where} missing"
  end

  # The [first, last] line indices of `flavors.<flavor>` (0-based, inclusive).
  def flavor_range(lines, flavor)
    head = lines.index { |line| line.chomp.match?(/\Aflavors:[ \t]*(?:#.*)?\z/) }
    raise MonitorError, "NAMED FAILURE: #{RECIPE_BASENAME} carries no top-level flavors: block" unless head

    ranges = {}
    current = nil
    (head + 1...lines.length).each do |index|
      text = lines[index].chomp
      if (match = text.match(/\A  ([A-Za-z0-9_.-]+):[ \t]*(?:#.*)?\z/))
        current = match[1]
        ranges[current] = [index, index]
      elsif text.match?(/\A\S/)
        break
      elsif current && !text.strip.empty?
        ranges[current][1] = index
      end
    end
    ranges.fetch(flavor) do
      raise MonitorError, "NAMED FAILURE: #{RECIPE_BASENAME} carries no flavors.#{flavor} block"
    end
  end

  # The flavor's own upstream: block. Its shallowest `upstream:` line is the
  # block; a nested or sibling key ends it (owner_smoke's version: keys stay
  # out, which is what keeps a bump from touching the owner pair's pins).
  def upstream_range(lines, flavor, (first, last))
    hits = (first..last).select { |index| lines[index].chomp.match?(/\A(\s+)upstream:[ \t]*(?:#.*)?\z/) }
    if hits.length != 1
      raise MonitorError,
            "NAMED FAILURE: flavors.#{flavor} carries #{hits.length} upstream: blocks — the monitor needs exactly one"
    end
    indent = lines[hits.first][/\A(\s+)/, 1].length
    stop = hits.first + 1
    while stop <= last
      text = lines[stop].chomp
      break if !text.strip.empty? && text[/\A(\s*)/, 1].length <= indent

      stop += 1
    end
    [hits.first, stop - 1]
  end

  def scalar_line(lines, (first, last), key)
    hits = (first..last).select do |index|
      lines[index].chomp.match?(/\A\s+#{Regexp.escape(key)}:[ \t]*(?:"[^"]*"|'[^']*'|[^#\s]+)/)
    end
    if hits.empty?
      raise MonitorError, "NAMED FAILURE: no upstream #{key}: literal in the flavor's upstream block"
    end
    if hits.length > 1
      raise MonitorError,
            "NAMED FAILURE: #{hits.length} upstream #{key}: literals in one upstream block — the monitor refuses to pick one"
    end

    hits.first
  end

  def source_entries(lines, (first, last), yaml_sources)
    heads = (first..last).select { |index| lines[index].chomp.match?(/\A\s+sources:[ \t]*(?:#.*)?\z/) }
    if heads.length != 1
      raise MonitorError, "NAMED FAILURE: the upstream block carries #{heads.length} sources: lists — the monitor needs exactly one"
    end

    entries = []
    (heads.first + 1..last).each do |index|
      text = lines[index].chomp
      if (match = text.match(/\A(\s*)- platform:[ \t]*["']?([A-Za-z0-9_.-]+)["']?[ \t]*(?:#.*)?\z/))
        entries << { platform: match[2], first: index, last: index }
      elsif (match = text.match(/\A\s+url:[ \t]*(.+?)[ \t]*\z/)) && entries.last
        entries.last[:url] = unquote(match[1])
        entries.last[:url_index] = index
      elsif (match = text.match(/\A\s+sha256:[ \t]*(.+?)[ \t]*\z/)) && entries.last
        entries.last[:digest] = unquote(match[1])
        entries.last[:digest_index] = index
      end
      entries.last[:last] = index unless entries.empty?
    end

    declared = yaml_sources.map { |source| source["platform"].to_s }
    found = entries.map { |entry| entry[:platform] }
    unless declared.sort == found.sort
      raise MonitorError,
            "NAMED FAILURE: the recipe declares platforms #{declared.join(', ')} but the sources: lines name " \
            "#{found.join(', ')} — the monitor refuses to guess which source is which"
    end
    entries.each do |entry|
      next if entry[:url] && entry[:digest]

      raise MonitorError,
            "NAMED FAILURE: the #{entry[:platform]} source carries no #{entry[:url] ? 'sha256' : 'url'}: literal"
    end
    entries.map do |entry|
      Source.new(platform: entry[:platform], url: entry[:url], digest: entry[:digest],
                 first: entry[:first], last: entry[:last],
                 url_index: entry[:url_index], digest_index: entry[:digest_index])
    end
  end

  def line_for(config, block, version, build, tag)
    line = case config.fetch(:rule)
           when :language_version then block["language_version"]
           when :abi_line then block["abi_line"]
           when :build_line then build&.split(".")&.first(2)&.join(".")
           when :tag_major then tag_version(tag)&.split(".")&.first
           else
             raise MonitorError, "NAMED FAILURE: unknown line rule #{config.fetch(:rule).inspect}"
           end
    unless line.is_a?(String) && !line.empty?
      raise MonitorError,
            "NAMED FAILURE: cannot derive the pinned line from the recipe (#{config.fetch(:rule)}) — " \
            "the key it reads is missing"
    end
    if config.fetch(:token) == :build && build.nil?
      raise MonitorError, "NAMED FAILURE: the #{config.fetch(:rule)} line rule reads upstream.build, which the recipe does not pin"
    end

    line
  end

  def tag_version(tag)
    tag&.to_s&.split("-")&.last
  end

  # --- masking: the pinned values are the only grammar we know ---

  def mask(text, tokens)
    masked = text.dup
    order = []
    tokens.sort_by { |name, value| -value.to_s.length }.each do |name, value|
      next if value.nil? || value.to_s.empty? || !masked.include?(value.to_s)

      masked = masked.gsub(value.to_s, "#{MARK}#{name}#{MARK}")
      order << name
    end
    [masked, order]
  end

  # A masked shape becomes an anchored regex: the literal text stays
  # literal, and each token placeholder matches a RELEASE NUMBER only
  # (digits and dots). The narrow class is what keeps shapes unambiguous —
  # with a free `.+?` the native flavor's
  # `truffleruby-community-<version>-macos-aarch64.tar.gz` would also
  # match the JVM-mode archive `truffleruby-community-jvm-34.1.0-…`, and
  # the monitor would be guessing which bytes to pin.
  def shape_regex(masked)
    order = []
    pattern = masked.split(/(\u0001[a-z]+\u0001)/).map do |part|
      if (match = part.match(/\A\u0001([a-z]+)\u0001\z/))
        order << match[1].to_sym
        '(\d+(?:\.\d+)*)'
      else
        Regexp.escape(part)
      end
    end.join
    [Regexp.new("\\A#{pattern}\\z"), order]
  end

  def fill(template, values)
    template.gsub(PLACEHOLDER) do |marker|
      name = marker[PLACEHOLDER, 1].to_sym
      values.fetch(name) do
        raise MonitorError, "NAMED FAILURE: the #{name} token has no upstream value to fill"
      end
    end
  end

  def humanize(masked)
    masked.gsub(PLACEHOLDER) { |marker| "<#{marker[PLACEHOLDER, 1]}>" }
  end

  def capture(regex, order, string)
    match = regex.match(string)
    return nil unless match

    order.each_with_index.each_with_object({}) { |(name, index), out| out[name] = match[index + 1] }
  end

  def unquote(value)
    text = value.to_s.strip
    if text.length > 1 && ((text.start_with?('"') && text.end_with?('"')) ||
                           (text.start_with?("'") && text.end_with?("'")))
      text[1..-2]
    else
      text
    end
  end

  # A release token is digits and dots (21.0.12, 8, 25.3.4.1, 10.1.1.0).
  # Anything else captured out of a tag or an asset name is not a release
  # number on the recipe's grammar — graal-25_ea-beta, for one.
  def release_token?(value)
    value.to_s.match?(/\A\d+(?:\.\d+)*\z/)
  end

  # --- the per-flavor check ---

  def check_flavor(body, flavor, upstream)
    lines = body.lines
    tokens = { version: flavor.version }
    tokens[:build] = flavor.build if flavor.build

    tag_text = flavor.tag || url_tag(flavor)
    tag_masked, = mask(tag_text, tokens)
    tag_regex, tag_order = shape_regex(tag_masked)
    repo = release_repo(flavor)

    current_key = sort_key(tokens, flavor.line_token)
    on_line = []
    newer = []
    upstream.tags(*repo).each do |tag|
      caps = capture(tag_regex, tag_order, tag)
      next unless caps
      # Only release-number captures are releases on this grammar; a tag
      # like graal-25_ea-beta matches the shape but is not one (and its
      # capture is not a version).
      next unless caps.values.all? { |value| release_token?(value) }

      key = sort_key(caps, flavor.line_token)
      next unless (key <=> current_key)&.positive?

      if on_line?(caps[flavor.line_token], flavor.line)
        on_line << { tag: tag, caps: caps, key: key }
      else
        newer << { version: caps[:version] || caps[:build], key: key }
      end
    end

    skipped = []
    bumped = nil
    on_line.sort_by { |candidate| candidate[:key] }.reverse_each do |candidate|
      begin
        bumped = resolve_candidate(flavor, tokens, tag_masked, tag_regex, tag_order, candidate, upstream)
      rescue IncompleteRelease => e
        skipped << { candidate: candidate[:caps][:version] || candidate[:caps][:build], missing: e.missing }
        next
      end
      break
    end

    if bumped.nil? && !skipped.empty?
      raise MonitorError,
            "NAMED FAILURE: flavors.#{flavor.name} has newer releases on line #{flavor.line} " \
            "(#{skipped.map { |entry| entry[:candidate] }.join(', ')}) but none resolves every declared source: " \
            "#{skipped.map { |entry| "#{entry[:candidate]} lacks #{entry[:missing].join(', ')}" }.join('; ')} " \
            "— the monitor never pins bytes upstream has not published"
    end

    newest_newer = newer.max_by { |entry| entry[:key] }
    verdict = {
      flavor: flavor.name, line: flavor.line, current: flavor.version,
      newer_line: newest_newer && newest_newer[:version], skipped: skipped, edits: []
    }
    if bumped
      edits = plan_edits(lines, flavor, bumped)
      verdict[:action] = "bump"
      verdict[:candidate] = bumped[:version]
      verdict[:build] = bumped[:build]
      verdict[:sources] = bumped[:resolved].length
      verdict[:assets] = bumped[:resolved].map { |row| row[:asset] }
      verdict[:digest_sources] = bumped[:resolved].map { |row| row[:digest_source] }.uniq
                                 .map { |kind| DIGEST_SOURCES.fetch(kind) }
      verdict[:edits] = edits
    else
      verdict[:action] = "current"
    end
    verdict
  end

  def on_line?(value, line)
    return false if value.nil?

    value == line || value.start_with?("#{line}.")
  end

  def sort_key(tokens, line_token)
    if line_token == :build
      value = tokens[:build]
      raise MonitorError, "NAMED FAILURE: the release carries no build token to order by" unless value

      [Gem::Version.new(value)]
    else
      value = tokens[:version]
      raise MonitorError, "NAMED FAILURE: the release carries no version token to order by" unless value

      key = [Gem::Version.new(value)]
      key << Gem::Version.new(tokens[:build]) if tokens[:build]
      key
    end
  end

  def url_tag(flavor)
    match = flavor.sources.first.url.match(%r{/releases/download/([^/]+)/})
    unless match
      raise MonitorError,
            "NAMED FAILURE: flavors.#{flavor.name} pins no upstream.tag and its sources carry no GitHub release " \
            "tag — the monitor cannot derive the tag grammar"
    end

    CGI.unescape(match[1])
  end

  def release_repo(flavor)
    configured = RELEASE_REPOS[flavor.name]
    return configured.split("/", 2) if configured

    repos = flavor.sources.filter_map do |source|
      match = source.url.match(%r{\Ahttps://github\.com/([^/]+)/([^/]+)/releases/download/})
      [match[1], match[2]] if match
    end.uniq
    unless repos.length == 1 && flavor.sources.all? { |source| source.url.match?(%r{/releases/download/}) }
      raise MonitorError,
            "NAMED FAILURE: flavors.#{flavor.name}'s sources name #{repos.length} GitHub release repos — " \
            "the monitor needs exactly one"
    end

    repos.first
  end

  # One candidate release, resolved end to end: the release's own asset
  # list is the only source of new names, the recipe's masked shapes the
  # only grammar. Every token must resolve and agree, else a named error.
  #
  # A source whose url: is not a GitHub release asset (jruby's Maven
  # Central dist artifacts) is resolved by masking the version tokens in
  # the URL itself; the release's asset list then plays no part in naming
  # it, and the digest probe (its own sidecar, or the download) is what
  # proves the artifact exists.
  def resolve_candidate(flavor, tokens, tag_masked, tag_regex, tag_order, candidate, upstream)
    tag = candidate[:tag]
    release_sources = flavor.sources.select { |source| release_asset_url?(source.url) }
    assets = nil
    unless release_sources.empty?
      assets = upstream.release_assets(*release_repo(flavor), tag)
      raise IncompleteRelease, ["a published release for #{tag}"] if assets.nil?
    end

    values = candidate[:caps].dup
    matched = {}
    missing = []
    release_sources.each do |source|
      masked = source_asset_mask(source, tokens)
      regex, groups = shape_regex(masked)
      hits = assets.select { |name| regex.match?(name) }
      if hits.empty?
        missing << humanize(masked)
        next
      end
      if hits.length > 1
        raise MonitorError,
              "NAMED FAILURE: #{tag} carries #{hits.length} assets matching #{humanize(masked)} " \
              "(#{hits.join(', ')}) — the monitor never guesses which bytes to pin"
      end

      capture(regex, groups, hits.first).each do |name, value|
        unless release_token?(value)
          raise MonitorError,
                "NAMED FAILURE: #{hits.first} names the #{name} token as #{value.inspect} — upstream layout changed"
        end
        if values[name] && values[name] != value
          raise MonitorError,
                "NAMED FAILURE: #{tag} names the #{name} token as both #{values[name]} and #{value} — upstream layout changed"
        end
        values[name] = value
      end
      matched[source] = hits.first
    end
    # Upstream publishes legs asynchronously: a release missing some of
    # the recipe's declared sources is skipped whole (never a partial
    # re-pin), and the caller tries the next candidate.
    raise IncompleteRelease, missing unless missing.empty?

    unresolved = tokens.keys - values.keys
    unless unresolved.empty?
      raise MonitorError,
            "NAMED FAILURE: #{tag}'s asset list resolves no #{unresolved.join(', ')} token — upstream layout changed"
    end

    tag_value = fill(tag_masked, values)
    unless tag_value == tag
      raise MonitorError,
            "NAMED FAILURE: #{tag} is not the recipe's tag grammar filled with the release's own tokens " \
            "(#{tag_value}) — upstream layout changed"
    end
    unless capture(tag_regex, tag_order, tag)
      raise MonitorError, "NAMED FAILURE: #{tag} does not match the recipe's tag grammar — upstream layout changed"
    end

    resolved = flavor.sources.map do |source|
      asset = matched[source] || File.basename(fill(mask(source.url, tokens).first, values))
      url = new_url(source, tag, asset, tokens, values)
      digest, digest_source = digest_for(url, asset, assets || [], upstream)
      { platform: source.platform, asset: asset, url: url, digest: digest,
        digest_source: digest_source, source: source }
    end

    { tag: tag, version: values[:version], build: values[:build], resolved: resolved }
  end

  def release_asset_url?(url)
    url.match?(%r{\Ahttps://github\.com/[^/]+/[^/]+/releases/download/})
  end

  # The shape a source's asset name takes with the pinned tokens masked;
  # a source whose asset name carries none of them cannot be matched
  # against an upstream listing, and that is a named refusal, not a guess.
  def source_asset_mask(source, tokens)
    masked, order = mask(File.basename(source.url), tokens)
    if order.empty?
      raise MonitorError,
            "NAMED FAILURE: the #{source.platform} source asset #{File.basename(source.url)} carries none " \
            "of the pinned tokens (#{tokens.keys.join(', ')}) — the monitor cannot derive its shape"
    end

    masked
  end

  def new_url(source, tag, asset, tokens, values)
    match = source.url.match(%r{\A(https://github\.com/[^/]+/[^/]+/releases/download)/([^/]+)/[^/]+\z})
    if match
      "#{match[1]}/#{tag_in_url(match[2], tag)}/#{asset}"
    else
      masked, order = mask(source.url, tokens)
      unless (order - values.keys).empty?
        raise MonitorError,
              "NAMED FAILURE: #{source.url} carries an unresolved token " \
              "(#{(order - values.keys).join(', ')}) — upstream layout changed"
      end
      fill(masked, values)
    end
  end

  # A GitHub release tag reaches the URL in the escape form the recipe
  # already uses (Adoptium's `jdk-…+8` rides as `%2B8`), so the rewrite
  # preserves the authored encoding rather than re-deriving it.
  def tag_in_url(old_segment, tag)
    CGI.unescape(old_segment) == old_segment ? tag : CGI.escape(tag)
  end

  # Digest sources, in the order upstream is asked: the release's own
  # checksum asset (`<asset>.sha256.txt`, then `<asset>.sha256`), then a
  # sidecar beside the download itself, then — only when upstream
  # publishes none at all (truffleruby) — the archive's bytes, hashed on
  # the stream. Each kind names where the digest came from, for the PR
  # body.
  DIGEST_SOURCES = {
    release_sha256_txt: "the release's per-asset `.sha256.txt` sidecars",
    release_sha256: "the release's per-asset `.sha256` sidecars",
    url_sidecar: "the per-asset `.sha256` sidecar beside each download",
    hashed: "the downloaded archives' own bytes (upstream publishes no checksum)"
  }.freeze

  def digest_for(url, asset, assets, upstream)
    if assets.include?("#{asset}.sha256.txt")
      digest, name = checksum_pair(upstream.text("#{url}.sha256.txt"), "#{url}.sha256.txt")
      if name && name != asset
        raise MonitorError,
              "NAMED FAILURE: #{url}.sha256.txt names #{name}, not #{asset} — upstream layout changed"
      end

      return [digest, :release_sha256_txt]
    end
    if assets.include?("#{asset}.sha256")
      return [checksum(upstream.text("#{url}.sha256"), "#{url}.sha256"), :release_sha256]
    end
    sidecar = upstream.optional_text("#{url}.sha256")
    return [checksum(sidecar, "#{url}.sha256"), :url_sidecar] if sidecar

    hashed = upstream.digest(url)
    warn "release-monitor: #{asset} carries no published checksum — hashed the download " \
         "(#{hashed[:bytes]} bytes, sha256 #{hashed[:sha256]})"
    [hashed[:sha256], :hashed]
  end

  def checksum(text, where)
    match = text.to_s.match(/(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])/)
    raise MonitorError, "NAMED FAILURE: #{where} carries no sha256 — upstream layout changed" unless match

    match[0]
  end

  def checksum_pair(text, where)
    match = text.to_s.match(/([0-9a-f]{64})\s+\*?(\S+)/)
    raise MonitorError, "NAMED FAILURE: #{where} carries no '<sha256> <file>' line — upstream layout changed" unless match

    [match[1], match[2]]
  end

  # --- the plan (and the guard that keeps it honest) ---

  def plan_edits(lines, flavor, bumped)
    edits = []
    upstream_scope = (flavor.upstream_range.first..flavor.upstream_range.last)
    add_edit = lambda do |index, key, value, scope|
      raise MonitorError, "NAMED FAILURE: the planned #{key} rewrite points outside the flavor block" unless scope.include?(index)

      old = lines.fetch(index)
      new = render_scalar(old, key, value)
      edits << { index: index, old: old, new: new, kind: key, flavor: flavor.name } unless new == old
    end

    add_edit.call(flavor.version_index, "version", bumped[:version], upstream_scope)
    add_edit.call(flavor.build_index, "build", bumped[:build], upstream_scope) if flavor.build
    add_edit.call(flavor.tag_index, "tag", bumped[:tag], upstream_scope) if flavor.tag
    bumped[:resolved].each do |row|
      scope = (row[:source].first..row[:source].last)
      add_edit.call(row[:source].url_index, "url", row[:url], scope)
      add_edit.call(row[:source].digest_index, "sha256", row[:digest], scope)
    end
    edits
  end

  # Replace one scalar's value, preserving the key, the authored quoting
  # style and the trailing comment (line 29's `# the Temurin build number`).
  def render_scalar(line, key, value)
    match = line.match(/\A(\s*#{Regexp.escape(key)}:[ \t]*)(["']?)([^"'#]*?)\2([ \t]*(?:#.*)?\n?\z)/)
    unless match
      raise MonitorError, "NAMED FAILURE: cannot locate the #{key}: literal in #{line.inspect}"
    end

    "#{match[1]}#{match[2]}#{value}#{match[2]}#{match[4]}"
  end

  def apply_plan(body, edits)
    lines = body.lines
    planned = {}
    edits.each do |edit|
      current = lines.fetch(edit[:index])
      unless current == edit[:old]
        raise MonitorError,
              "NAMED FAILURE: planned rewrite line #{edit[:index] + 1} is #{current.inspect}, not " \
              "#{edit[:old].inspect} — the recipe moved under the plan"
      end
      if planned.key?(edit[:index])
        raise MonitorError, "NAMED FAILURE: two planned rewrites target line #{edit[:index] + 1}"
      end

      planned[edit[:index]] = edit[:new]
    end
    updated = lines.each_with_index.map { |line, index| planned.fetch(index, line) }.join
    assert_plan_only!(body, updated, planned)
    updated
  end

  # The rewrite touched exactly the planned lines, each with exactly the
  # planned content. Anything else is a named error, never a silent write.
  def assert_plan_only!(old_body, new_body, planned)
    old_lines = old_body.lines
    new_lines = new_body.lines
    unless old_lines.length == new_lines.length
      raise MonitorError,
            "NAMED FAILURE: the rewrite changed the recipe's line count " \
            "(#{old_lines.length} → #{new_lines.length})"
    end

    changed = (0...old_lines.length).reject { |index| old_lines[index] == new_lines[index] }
    unplanned = changed - planned.keys
    unless unplanned.empty?
      raise MonitorError,
            "NAMED FAILURE: the rewrite touched lines it did not plan: #{unplanned.sort.map { |i| i + 1 }.join(', ')}"
    end
    stale = planned.keys - changed
    unless stale.empty?
      raise MonitorError,
            "NAMED FAILURE: planned rewrites changed nothing on lines #{stale.sort.map { |i| i + 1 }.join(', ')}"
    end
    planned.each do |index, expected|
      unless new_lines[index] == expected
        raise MonitorError,
              "NAMED FAILURE: line #{index + 1} is #{new_lines[index].inspect}, not the planned #{expected.inspect}"
      end
    end
    true
  end

  # --- the verdict (one JSON object; extra keys say what was skipped) ---

  def summarize(verdicts, dry_run: false)
    bumped = verdicts.select { |verdict| verdict[:action] == "bump" }
    primary = bumped.first || verdicts.first
    out = { action: bumped.empty? ? "current" : "bump", current: primary[:current] }
    out[:candidate] = primary[:candidate] if primary[:candidate]
    out[:build] = primary[:build] if primary[:build]
    out[:sources] = primary[:sources] if primary[:sources]
    out[:assets] = primary[:assets] if primary[:assets]
    out[:digest_sources] = primary[:digest_sources] if primary[:digest_sources]
    out[:flavor] = primary[:flavor]
    out[:line] = primary[:line]
    out[:newer_line] = primary[:newer_line] if primary[:newer_line]
    out[:skipped] = primary[:skipped] unless primary[:skipped].to_a.empty?
    out[:flavors] = verdicts.map { |verdict| public_verdict(verdict) } if verdicts.length > 1
    unless bumped.empty?
      out[:title] = "#{bumped.map { |verdict| "#{verdict[:flavor]} #{verdict[:candidate]}" }
                       .join(', ')} (release monitor)"
    end
    out[:dry_run] = true if dry_run
    out
  end

  def public_verdict(verdict)
    out = { flavor: verdict[:flavor], line: verdict[:line], action: verdict[:action],
            current: verdict[:current] }
    out[:candidate] = verdict[:candidate] if verdict[:candidate]
    out[:build] = verdict[:build] if verdict[:build]
    out[:sources] = verdict[:sources] if verdict[:sources]
    out[:assets] = verdict[:assets] if verdict[:assets]
    out[:digest_sources] = verdict[:digest_sources] if verdict[:digest_sources]
    out[:newer_line] = verdict[:newer_line] if verdict[:newer_line]
    out[:skipped] = verdict[:skipped] unless verdict[:skipped].to_a.empty?
    out
  end

  # --- the PR body (from a verdict file; no network, no clock) ---

  def pr_body(verdict)
    verdict = stringify(verdict)
    lines = ["Automated pin bump by the release monitor.", ""]
    flavors = verdict["flavors"] || [verdict]
    moved = flavors.select { |flavor| flavor["action"] == "bump" }
    moved.each do |flavor|
      lines << "**#{flavor['flavor']}** (line #{flavor['line']}): #{flavor['current']} → #{flavor['candidate']}" \
               "#{flavor['build'] ? " (build #{flavor['build']})" : ''}"
      lines << ""
      lines << "- #{flavor['sources']} source asset#{flavor['sources'] == 1 ? '' : 's'} re-pinned:"
      Array(flavor["assets"]).each { |asset| lines << "  - `#{asset}`" }
      lines << "- digests: #{Array(flavor['digest_sources']).join('; ')}"
      Array(flavor["skipped"]).each do |entry|
        shapes = Array(entry["missing"]).map { |shape| "`#{shape}`" }.join(", ")
        lines << "- skipped #{entry['candidate']}: no asset matching #{shapes}"
      end
      lines << ""
    end
    flavors.reject { |flavor| flavor["action"] == "bump" }.each do |flavor|
      text = "**#{flavor['flavor']}** (line #{flavor['line']}): current at #{flavor['current']}."
      text += " Newer line #{flavor['newer_line']} not crossed." if flavor["newer_line"]
      lines << text
    end
    lines << ""
    lines << "Only the literals above moved: the version/build/tag pins and the matching source `url:`/`sha256:` " \
             "lines. Every comment, key order, quoting style and every other flavor's block is untouched, and " \
             "the tools/wrapper pins stay put."
    lines << ""
    lines << "No pinned line was crossed. Merging runs the lint gate; the publish rides the factory's own " \
             "release cadence."
    # A skipped-flavor block can end with an empty line already; never emit
    # more than one blank separator.
    "#{lines.join("\n").gsub(/\n{3,}/, "\n\n")}\n"
  end

  def stringify(value)
    case value
    when Hash then value.each_with_object({}) { |(key, inner), out| out[key.to_s] = stringify(inner) }
    when Array then value.map { |inner| stringify(inner) }
    else value
    end
  end

  # --- the network edge (last: everything above is specable offline) ---

  class Upstream
    def initialize(raw_get: nil, sleeper: nil)
      @raw_get = raw_get || method(:net_http_get)
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    # Discovery reads the repo's TAG list, not its release list: the
    # releases listing embeds every asset of every release (adoptium's
    # temurin21-binaries answers 56 MB for one page of 100) and ties on
    # created_at, so it is both expensive and not newest-first. A tag page
    # is ~50 KB; sorting the tag names the recipe's own tag grammar admits
    # finds the newest on-line tag deterministically. The release behind
    # the chosen tag is then read for its asset list — that is where the
    # bytes and the checksum sidecars come from.
    def tags(owner, repo)
      out = []
      (1..MAX_PAGES).each do |page|
        batch = JSON.parse(get("#{API}/repos/#{owner}/#{repo}/tags?per_page=100&page=#{page}"))
        unless batch.is_a?(Array)
          raise MonitorError,
                "NAMED FAILURE: #{owner}/#{repo} tags page #{page} is not a list — " \
                "the monitor never guesses past a dead upstream"
        end
        out.concat(batch.map { |tag| tag["name"].to_s })
        break if batch.length < 100
      end
      out
    end

    # nil when the tag has no published release (a tag is not a release);
    # every other non-2xx keeps the dead-upstream rule.
    def release_assets(owner, repo, tag)
      body = get("#{API}/repos/#{owner}/#{repo}/releases/tags/#{CGI.escape(tag)}", optional: true)
      return nil if body.nil?

      assets = JSON.parse(body)["assets"]
      unless assets.is_a?(Array)
        raise MonitorError, "NAMED FAILURE: #{owner}/#{repo}@#{tag} carries no asset list"
      end

      assets.map { |asset| asset["name"].to_s }
    end

    def text(url, accept: nil)
      get(url, accept: accept)
    end

    # Only the OPTIONAL checksum probe treats 404 as "upstream publishes
    # none"; every other 404 stays a dead upstream.
    def optional_text(url, accept: nil)
      get(url, accept: accept, optional: true)
    end

    def digest(url, redirects: MAX_REDIRECTS)
      current = url
      loop do
        outcome = stream_once(current)
        return outcome unless outcome[:redirect]

        unless redirects.positive?
          raise MonitorError, "NAMED FAILURE: #{url} redirects more than #{MAX_REDIRECTS} times"
        end

        target = URI.join(current, outcome[:redirect])
        unless target.is_a?(URI::HTTPS)
          raise MonitorError, "NAMED FAILURE: redirect to '#{outcome[:redirect]}' — only https is followed"
        end

        current = target.to_s
        redirects -= 1
      end
    end

    private

    def get(url, accept: "application/vnd.github+json", optional: false, redirects: MAX_REDIRECTS, attempt: 1)
      uri = URI.parse(url)
      headers = {}
      headers["Accept"] = accept if accept
      # The token rides ONLY api.github.com: release assets and checksum
      # sidecars are github.com objects, and a token sent there would be a
      # credential leak for nothing.
      if uri.host == TOKEN_HOST && (token = ENV["GH_TOKEN"] || ENV["GITHUB_TOKEN"]) && !token.empty?
        headers["Authorization"] = "Bearer #{token}"
      end

      response = @raw_get.call(uri, headers)
      code = response.code.to_i
      if code.between?(300, 399) && response.headers["location"] && redirects.positive?
        location = URI.join(url, response.headers["location"])
        unless location.is_a?(URI::HTTPS)
          raise MonitorError, "NAMED FAILURE: redirect to '#{response.headers['location']}' — only https is followed"
        end

        return get(location.to_s, accept: accept, optional: optional, redirects: redirects - 1, attempt: attempt)
      end
      return response.body if code.between?(200, 299)
      return nil if optional && code == 404

      if transient_status?(code) && attempt < MAX_ATTEMPTS
        wait = retry_after(response) || attempt * 3
        warn "release-monitor: GET #{url} answered #{code} (an availability/quota answer, not a dead upstream) — " \
             "retrying in #{wait}s (attempt #{attempt}/#{MAX_ATTEMPTS})"
        @sleeper.call(wait)
        return get(url, accept: accept, optional: optional, redirects: redirects, attempt: attempt + 1)
      end
      hint = if transient_status?(code)
               " — an availability/quota answer survived #{MAX_ATTEMPTS} attempts; authenticate the call (GH_TOKEN) or retry later"
             else
               ""
             end
      raise MonitorError,
            "NAMED FAILURE: GET #{url} answered #{code}#{hint} — the monitor never guesses past a dead upstream"
    end

    # 403 is the shared-IP anonymous limit (and the token-scope refusal),
    # 429 the explicit throttling answer. Both are QUOTA answers.
    # 403 is the shared-IP anonymous limit (and the token-scope refusal),
    # 429 the explicit throttling answer; the 502/503/504 gateway answers
    # are the same "try again, never guess" class (the 2026-10-28 probe
    # took a 504 from the releases listing under load). A 404 is never in
    # this set: it is a dead upstream.
    def transient_status?(code)
      [403, 429, 502, 503, 504].include?(code)
    end

    def retry_after(response)
      if (value = response.headers["retry-after"]) && value.to_s.match?(/\A\d+\z/)
        return [value.to_i, 60].min
      end
      if (reset = response.headers["x-ratelimit-reset"]) && reset.to_s.match?(/\A\d+\z/)
        return [[reset.to_i - Time.now.to_i, 1].max, 60].min
      end

      nil
    end

    def net_http_get(uri, headers)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        headers.each { |name, value| request[name] = value }
        response = http.request(request)
        Response.new(code: response.code, body: response.body, headers: response.each_header.to_h)
      end
    end

    def stream_once(url)
      uri = URI.parse(url)
      outcome = nil
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri)) do |response|
          if response.is_a?(Net::HTTPRedirection)
            outcome = { redirect: response["location"] }
          elsif !response.is_a?(Net::HTTPSuccess)
            raise MonitorError,
                  "NAMED FAILURE: GET #{url} answered #{response.code} — the monitor will not invent a digest"
          else
            sha = Digest::SHA256.new
            bytes = 0
            response.read_body do |chunk|
              sha << chunk
              bytes += chunk.bytesize
            end
            outcome = { sha256: sha.hexdigest, bytes: bytes }
          end
        end
      end
      outcome || raise(MonitorError, "NAMED FAILURE: GET #{url} answered nothing — the monitor will not invent a digest")
    end
  end
end
