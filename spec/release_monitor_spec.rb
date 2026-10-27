# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../tools/lib", __dir__))
require "release_monitor"

# The release monitor's offline cases: a fixture recipe, an injected asset
# listing and injected sidecar text stand in for the upstream API, so every
# assertion here is deterministic. The live behaviour is exercised by
# `ruby tools/monitor --dry-run` (which writes nothing).
#
# What is locked here:
#   * a bump rewrites EXACTLY the planned literals — version, build, each
#     source's url:/sha256: — byte for byte, preserving comments, key order
#     and quoting, and leaving every other flavor's block identical;
#   * an unplanned diff is a named error, never a silent write;
#   * a newer release on a NEWER line is reported as newer_line and
#     deliberately skipped;
#   * a candidate release missing a declared source is skipped whole and
#     named in the verdict, never partially pinned;
#   * 403/429 are quota answers the Upstream edge retries; 404 is a dead
#     upstream.
RSpec.describe ReleaseMonitor do
  # The digest the graalvm case's sidecar carries (64 hex characters).
  GRAALVM_DIGEST = "a" * 64

  # One flavor per upstream repo, each with the pinned literals a bump
  # moves. graalvm carries an owner_smoke.version with the SAME value as
  # its upstream.version on purpose: a rewrite that reaches outside the
  # upstream: block would move it, and that is exactly what must not
  # happen.
  RECIPE = <<~YAML
    # A fixture recipe: two flavors, two upstream repos.
    name: "openjdk"
    flavors:
      temurin:
        implementation: "temurin"
        language_version: "21"
        upstream:
          version: "21.0.12"
          build: "8"            # the Temurin build number (21.0.12+8)
          sources:
            - platform: "aarch64-macos"
              url: "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12%2B8/OpenJDK21U-jre_aarch64_mac_hotspot_21.0.12_8.tar.gz"
              sha256: "36bb71d6fa5184e12a6483e7662783c2cbd383f5dca8034140f0a84dd5aa797d"
              strip_components: 3
            - platform: "x86_64-linux-gnu"
              url: "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12%2B8/OpenJDK21U-jre_x64_linux_hotspot_21.0.12_8.tar.gz"
              sha256: "8a379a67c91a3ae61ffb33d46e0a40c7ba35e70713c4db31cfca30492f792eff"
              strip_components: 1
      graalvm:
        implementation: "graalvm"
        language_version: "25"
        upstream:
          version: "25.0.4.1"     # the JDK line (JAVA_VERSION)
          build: "25.3.4.1"       # the GraalVM release id (tag graal-25.3.4.1)
          sources:
            - platform: "aarch64-macos"
              url: "https://github.com/graalvm/graalvm-ce-builds/releases/download/graal-25.3.4.1/graalvm-community-jdk-25i3-25.0.4.1_macos-aarch64_bin.tar.gz"
              sha256: "ebfab1d74420f355a459076162012d6835fa6068bd9d2f230f1fcaf7ee0dd923"
              strip_components: 3
        owner_smoke:
          repo: "tamatebako/tebako-runtime-openjdk"
          version: "25.0.4.1"
    runtime:
      wrapper_tebako: "2.8.62"
  YAML

  # The same fixture after the temurin bump: only temurin's version, build,
  # two url: lines and two sha256: lines moved. The graalvm block (its
  # owner_smoke.version included) and every comment are byte-identical.
  BUMPED = <<~YAML
    # A fixture recipe: two flavors, two upstream repos.
    name: "openjdk"
    flavors:
      temurin:
        implementation: "temurin"
        language_version: "21"
        upstream:
          version: "21.0.12.1"
          build: "1"            # the Temurin build number (21.0.12+8)
          sources:
            - platform: "aarch64-macos"
              url: "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jre_aarch64_mac_hotspot_21.0.12.1_1.tar.gz"
              sha256: "dec50fc6f9fcd4fe3ae8cabf5a5fa68f6afc48841f7698e468e9aa5d54beed84"
              strip_components: 3
            - platform: "x86_64-linux-gnu"
              url: "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jre_x64_linux_hotspot_21.0.12.1_1.tar.gz"
              sha256: "2413149700df0f7d440500a84a8f764c535f21e5a5e87d38328b64eec2c5b500"
              strip_components: 1
      graalvm:
        implementation: "graalvm"
        language_version: "25"
        upstream:
          version: "25.0.4.1"     # the JDK line (JAVA_VERSION)
          build: "25.3.4.1"       # the GraalVM release id (tag graal-25.3.4.1)
          sources:
            - platform: "aarch64-macos"
              url: "https://github.com/graalvm/graalvm-ce-builds/releases/download/graal-25.3.4.1/graalvm-community-jdk-25i3-25.0.4.1_macos-aarch64_bin.tar.gz"
              sha256: "ebfab1d74420f355a459076162012d6835fa6068bd9d2f230f1fcaf7ee0dd923"
              strip_components: 3
        owner_smoke:
          repo: "tamatebako/tebako-runtime-openjdk"
          version: "25.0.4.1"
    runtime:
      wrapper_tebako: "2.8.62"
  YAML

  # A graalvm-only recipe: the flavor's own release LINE (25.3) is what the
  # monitor must respect, and owner_smoke.version sits below the upstream
  # block with the same value as the pin.
  GRAALVM_RECIPE = <<~YAML
    name: "openjdk"
    flavors:
      graalvm:
        implementation: "graalvm"
        language_version: "25"
        upstream:
          version: "25.0.4.1"     # the JDK line (JAVA_VERSION)
          build: "25.3.4.1"       # the GraalVM release id (tag graal-25.3.4.1)
          sources:
            - platform: "aarch64-macos"
              url: "https://github.com/graalvm/graalvm-ce-builds/releases/download/graal-25.3.4.1/graalvm-community-jdk-25i3-25.0.4.1_macos-aarch64_bin.tar.gz"
              sha256: "ebfab1d74420f355a459076162012d6835fa6068bd9d2f230f1fcaf7ee0dd923"
              strip_components: 3
        owner_smoke:
          version: "25.0.4.1"
    runtime:
      wrapper_tebako: "2.8.62"
  YAML

  GRAALVM_BUMPED = <<~YAML
    name: "openjdk"
    flavors:
      graalvm:
        implementation: "graalvm"
        language_version: "25"
        upstream:
          version: "25.0.5.2"     # the JDK line (JAVA_VERSION)
          build: "25.3.5.2"       # the GraalVM release id (tag graal-25.3.4.1)
          sources:
            - platform: "aarch64-macos"
              url: "https://github.com/graalvm/graalvm-ce-builds/releases/download/graal-25.3.5.2/graalvm-community-jdk-25i3-25.0.5.2_macos-aarch64_bin.tar.gz"
              sha256: "#{GRAALVM_DIGEST}"
              strip_components: 3
        owner_smoke:
          version: "25.0.4.1"
    runtime:
      wrapper_tebako: "2.8.62"
  YAML

  TEMURIN_SHA_TXT = "https://github.com/adoptium/temurin21-binaries/releases/download/" \
                    "jdk-21.0.12.1%2B1/OpenJDK21U-jre_aarch64_mac_hotspot_21.0.12.1_1.tar.gz.sha256.txt"

  # A stand-in for ReleaseMonitor::Upstream: the tags, the release asset
  # lists and the sidecar text come from the case, never the network.
  class FakeUpstream
    def initialize(tags:, assets: {}, texts: {}, digests: {})
      @tags = tags
      @assets = assets
      @texts = texts
      @digests = digests
    end

    def tags(_owner, _repo)
      @tags
    end

    def release_assets(_owner, _repo, tag)
      @assets[tag]
    end

    def text(url, accept: nil)
      @texts.fetch(url) { raise "unexpected GET #{url} (accept: #{accept.inspect})" }
    end

    def optional_text(url, accept: nil)
      @texts[url]
    end

    def digest(url, redirects: 3)
      @digests.fetch(url) { raise "unexpected download #{url} (#{redirects})" }
    end
  end

  def with_recipe(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Tebakofile")
      File.write(path, text)
      yield path
    end
  end

  def temurin_upstream
    jdk_tag = "jdk-21.0.12.1%2B1"
    FakeUpstream.new(
      tags: ["jdk-21.0.13+9", "jdk-21.0.12.1+1", "jdk-21.0.12+8", "jdk-21.0.11+10",
             "jdk21u-2026-10-12-08-52-beta", "graal-25.4.4.1.1"],
      assets: {
        # 21.0.13+9 is published without the linux legs yet: skipped whole.
        "jdk-21.0.13+9" => ["OpenJDK21U-jre_aarch64_mac_hotspot_21.0.13_9.tar.gz",
                             "OpenJDK21U-jre_aarch64_mac_hotspot_21.0.13_9.tar.gz.sha256.txt"],
        "jdk-21.0.12.1+1" => ["OpenJDK21U-jre_aarch64_mac_hotspot_21.0.12.1_1.tar.gz",
                              "OpenJDK21U-jre_aarch64_mac_hotspot_21.0.12.1_1.tar.gz.sha256.txt",
                              "OpenJDK21U-jre_x64_linux_hotspot_21.0.12.1_1.tar.gz",
                              "OpenJDK21U-jre_x64_linux_hotspot_21.0.12.1_1.tar.gz.sha256.txt"],
        # graalvm's own repo: nothing newer on the 25.3 line.
        "graal-25.4.4.1.1" => []
      },
      texts: {
        TEMURIN_SHA_TXT =>
          "dec50fc6f9fcd4fe3ae8cabf5a5fa68f6afc48841f7698e468e9aa5d54beed84  " \
          "OpenJDK21U-jre_aarch64_mac_hotspot_21.0.12.1_1.tar.gz\n",
        TEMURIN_SHA_TXT.sub("aarch64_mac", "x64_linux") =>
          "2413149700df0f7d440500a84a8f764c535f21e5a5e87d38328b64eec2c5b500  " \
          "OpenJDK21U-jre_x64_linux_hotspot_21.0.12.1_1.tar.gz\n"
      }
    )
  end

  it "rewrites exactly the planned literals, byte for byte, and leaves the other flavor alone" do
    with_recipe(RECIPE) do |path|
      verdict = described_class.check(recipe_path: path, upstream: temurin_upstream)

      expect(File.read(path)).to eq(BUMPED)
      expect(verdict[:action]).to eq("bump")
      expect(verdict[:candidate]).to eq("21.0.12.1")
      expect(verdict[:sources]).to eq(2)
      expect(verdict[:title]).to eq("temurin 21.0.12.1 (release monitor)")
      graalvm = verdict[:flavors].find { |flavor| flavor[:flavor] == "graalvm" }
      expect(graalvm).to include(line: "25.3", action: "current", current: "25.0.4.1",
                                newer_line: "25.4.4.1.1")
    end
  end

  it "names an incomplete newer release and falls through to the next resolvable candidate" do
    with_recipe(RECIPE) do |path|
      verdict = described_class.check(recipe_path: path, upstream: temurin_upstream)

      expect(verdict[:skipped]).to eq(
        [{ candidate: "21.0.13",
           missing: ["OpenJDK21U-jre_x64_linux_hotspot_<version>_<build>.tar.gz"] }]
      )
      expect(verdict[:flavors].first[:digest_sources])
        .to eq(["the release's per-asset `.sha256.txt` sidecars"])
    end
  end

  it "writes nothing under --dry-run" do
    with_recipe(RECIPE) do |path|
      verdict = described_class.check(recipe_path: path, upstream: temurin_upstream, dry_run: true)

      expect(File.read(path)).to eq(RECIPE)
      expect(verdict[:action]).to eq("bump")
      expect(verdict[:dry_run]).to be(true)
    end
  end

  it "skips a newer release on the same family's newer line and names it, writing nothing" do
    with_recipe(GRAALVM_RECIPE) do |path|
      verdict = described_class.check(
        recipe_path: path,
        upstream: FakeUpstream.new(tags: ["graal-25.4.4.1.1", "graal-25.3.4.1"])
      )

      expect(File.read(path)).to eq(GRAALVM_RECIPE)
      expect(verdict).to include(action: "current", current: "25.0.4.1", line: "25.3")
      expect(verdict[:newer_line]).to eq("25.4.4.1.1")
      expect(verdict).not_to have_key(:candidate)
    end
  end

  it "skips a newer major line too, naming the newest release it did not cross to" do
    with_recipe(GRAALVM_RECIPE) do |path|
      verdict = described_class.check(
        recipe_path: path,
        upstream: FakeUpstream.new(tags: ["graal-40.0.0", "graal-25.3.4.1"])
      )

      expect(File.read(path)).to eq(GRAALVM_RECIPE)
      expect(verdict[:action]).to eq("current")
      expect(verdict[:newer_line]).to eq("40.0.0")
    end
  end

  it "bumps inside the flavor's own line and never touches the sibling owner_smoke pin" do
    sidecar = "https://github.com/graalvm/graalvm-ce-builds/releases/download/graal-25.3.5.2/" \
              "graalvm-community-jdk-25i3-25.0.5.2_macos-aarch64_bin.tar.gz.sha256"
    upstream = FakeUpstream.new(
      tags: ["graal-25.4.4.1.1", "graal-25.3.5.2", "graal-25.3.4.1"],
      assets: {
        "graal-25.3.5.2" => ["graalvm-community-jdk-25i3-25.0.5.2_macos-aarch64_bin.tar.gz",
                             "#{File.basename(sidecar)}"]
      },
      texts: { sidecar => "#{GRAALVM_DIGEST}\n" }
    )
    with_recipe(GRAALVM_RECIPE) do |path|
      verdict = described_class.check(recipe_path: path, upstream: upstream)

      expect(verdict[:action]).to eq("bump")
      expect(verdict[:candidate]).to eq("25.0.5.2")
      expect(verdict[:build]).to eq("25.3.5.2")
      expect(verdict[:digest_sources]).to eq(["the release's per-asset `.sha256` sidecars"])
      expect(File.read(path)).to eq(GRAALVM_BUMPED)
    end
  end

  it "raises when a rewrite would touch a line it did not plan" do
    planned = { 0 => "# planned\n" }
    tampered = RECIPE.sub("# A fixture recipe", "# planned").sub("  graalvm:", "  graalvm-edited:")

    expect { described_class.assert_plan_only!(RECIPE, tampered, planned) }
      .to raise_error(ReleaseMonitor::MonitorError, /touched lines it did not plan/)
  end

  it "raises when a planned line did not change" do
    expect { described_class.assert_plan_only!(RECIPE, RECIPE, { 4 => "# x\n" }) }
      .to raise_error(ReleaseMonitor::MonitorError, /changed nothing/)
  end

  it "retries a 403 quota answer and returns the body when it clears" do
    responses = [
      described_class::Response.new(code: 403, body: '{"message":"rate limit"}',
                                    headers: { "retry-after" => "0" }),
      described_class::Response.new(code: 200, body: "[]", headers: {})
    ]
    upstream = described_class::Upstream.new(
      raw_get: ->(_uri, _headers) { responses.shift },
      sleeper: ->(_seconds) { nil }
    )

    expect(upstream.tags("adoptium", "temurin21-binaries")).to eq([])
    expect(responses).to be_empty
  end

  it "retries a 429 the same way and names the quota when it survives every attempt" do
    upstream = described_class::Upstream.new(
      raw_get: ->(_uri, _headers) { described_class::Response.new(code: 429, body: "", headers: {}) },
      sleeper: ->(_seconds) { nil }
    )

    expect { upstream.tags("adoptium", "temurin21-binaries") }
      .to raise_error(ReleaseMonitor::MonitorError,
                      /NAMED FAILURE: .* answered 429 .*quota answer survived 3 attempts/m)
  end

  it "keeps a 404 a named dead upstream, never a quota answer" do
    upstream = described_class::Upstream.new(
      raw_get: ->(_uri, _headers) { described_class::Response.new(code: 404, body: "", headers: {}) },
      sleeper: ->(_seconds) { nil }
    )

    expect { upstream.tags("nope", "nope") }
      .to raise_error(ReleaseMonitor::MonitorError, /NAMED FAILURE: .* answered 404/)
  end
end
