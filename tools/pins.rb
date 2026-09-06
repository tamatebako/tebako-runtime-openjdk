#!/usr/bin/env ruby
# frozen_string_literal: true

# pins.rb — read recipe.yml's `tools:` block (the repo's toolchain pin
# SSOT) and emit KEY=VALUE lines for $GITHUB_ENV. The workflow carries NO
# version or digest literals — every value flows from the recipe.
#
#   ruby tools/pins.rb <tool-platform> [flavor] [--env]
#   ruby tools/pins.rb --release-only [flavor]
#
# <tool-platform> is the tebako release asset platform (macos-arm64,
# linux-gnu-x86_64, windows-ucrt64). [flavor] is the recipe's flavor key
# (spec 28 §8's implementation axis; default "temurin" — the pre-flavor
# call shape keeps working). --release-only emits just
# TEBAKO_RELEASE/PKG_NAME/PKG_VERSION. A tool listed in tools.sha256
# without a pin for the requested platform is a named error, never a
# guess (spec 00 §9).
#
# Runtime-promotion additions (the kind: runtime pair): the wrapper exe
# pin flows from recipe.yml's runtime.wrapper_tebako (WRAPPER_RELEASE /
# WRAPPER_ASSET / RUNTIME_STEM_BASE) and the POSIX legs get PRELOAD_SHIM
# (the extracted link-unit tarball's libtfs_preload path). The sha256
# map is data-driven: every tool key under tools.sha256 emits
# <TOOL>_ASSET/<TOOL>_SHA256 (link-unit names a .tar.gz, the CLIs name
# bare binaries).
#
# NEVER emit a bare TEBAKO_VERSION: in the sibling feedstocks tools/build
# uses that name for the RUNTIME release line with an env override, so a
# tools-version export silently clobbers the runtime pin (the 2026-08-27
# metanorma collision: the press resolved runtime release v0.3.1, exit
# 124). The tools version lives inside the computed ASSET names.

require "yaml"

def die(msg)
  warn "pins.rb: #{msg}"
  exit 64
end

root = File.expand_path("..", __dir__)
recipe = YAML.load_file(File.join(root, "recipe.yml"))
tools = recipe.fetch("tools")
release = tools.fetch("release")
version = release.sub(/\Av/, "")
die "recipe.yml tools.sha256 missing" unless tools["sha256"].is_a?(Hash)

# The flavor axis (spec 28 §8): the flavor key names the recipe's
# flavors:<flavor> block (default temurin). Positional after the
# tool-platform (`pins.rb macos-arm64 graalvm --env`), or the sole
# positional in --release-only mode (`pins.rb --release-only graalvm`).
# PKG_VERSION, RUNTIME_STEM_BASE and IMPLEMENTATION follow the selected
# flavor.
positional = ARGV - ["--env", "--release-only"]
flavor = if ARGV.include?("--release-only")
           positional[0] || ENV["FLAVOR"] || "temurin"
         else
           positional[1] || ENV["FLAVOR"] || "temurin"
         end
flavors = recipe.fetch("flavors") do
  die "recipe.yml flavors block missing"
end
flavor_block = flavors[flavor] or
  die "recipe.yml: unknown flavor '#{flavor}' (have: #{flavors.keys.join(', ')})"

runtime = recipe.fetch("runtime")
wrapper_tebako = runtime.fetch("wrapper_tebako")
pkg_version = flavor_block.dig("upstream", "version") ||
              die("recipe.yml flavors.#{flavor}.upstream.version missing")

pairs = {
  "TEBAKO_RELEASE" => release,
  "PKG_NAME" => recipe.fetch("name"),
  "PKG_VERSION" => pkg_version,
  "FLAVOR" => flavor,
  "IMPLEMENTATION" => flavor_block.fetch("implementation"),
}

unless ARGV.include?("--release-only")
  platform = ARGV[0] or die "usage: pins.rb <tool-platform> [--env] | pins.rb --release-only"
  exe = platform.start_with?("windows") ? ".exe" : ""
  # Tools the recipe pins for POSIX legs only (the windows image omits
  # the preload grant): a missing platform pin warns + skips; for every
  # other tool a missing pin is a named error, never a guess.
  posix_only = %w[link-unit]
  tools.fetch("sha256").each do |tool, shas|
    sha = shas[platform]
    if sha.nil?
      die "recipe.yml: no tools.sha256.#{tool}.#{platform} pin" unless posix_only.include?(tool)
      warn "pins.rb: #{tool} has no #{platform} pin (POSIX-only tool — skipped)"
      next
    end
    key = tool.upcase.tr("-", "_")
    asset = if tool == "link-unit"
              "#{tool}-#{version}-#{platform}.tar.gz"
            else
              "#{tool}-#{version}-#{platform}#{exe}"
            end
    pairs["#{key}_ASSET"] = asset
    pairs["#{key}_SHA256"] = sha
  end
  # The wrapper exe (spec 29): the recipe's runtime.wrapper_tebako names
  # the line (ships since tebako v2.1.0); runtime.wrapper_sha256 is its
  # per-platform trust anchor — a missing pin is a named error, never a
  # guess (the launcher ships as the runtime pair's entry point).
  pairs["WRAPPER_RELEASE"] = "v#{wrapper_tebako}"
  pairs["WRAPPER_ASSET"] = "tebako-runtime-launcher-#{wrapper_tebako}-#{platform}#{exe}"
  wrapper_shas = runtime.fetch("wrapper_sha256")
  pairs["WRAPPER_SHA256"] = wrapper_shas[platform] ||
                            die("recipe.yml: no runtime.wrapper_sha256.#{platform} pin")
  pairs["RUNTIME_STEM_BASE"] = "tebako-runtime-#{wrapper_tebako}-#{pkg_version}"
  pairs["RUNTIME_STEM"] = "#{pairs['RUNTIME_STEM_BASE']}-#{platform}"
  # The extracted preload shim (POSIX legs only; the windows image omits
  # the grant — see manifests/layout.yaml). The tarball's internal top
  # dir is VERSION-LESS (link-unit-<platform>/; the version lives in the
  # asset name) — link-unit-stage.sh has tarred it that way since the
  # script exists; the 08-30 legs died at the wrapper 404 before ever
  # exercising this path, so the versioned guess was latent until v2.1.0.
  unless platform.start_with?("windows")
    dl_ext = platform.include?("macos") ? "dylib" : "so"
    pairs["PRELOAD_SHIM"] = ".packager/link-unit-#{platform}/libtfs_preload.#{dl_ext}"
  end
end

if ARGV.include?("--env") || ARGV.include?("--release-only")
  pairs.each { |k, v| puts "#{k}=#{v}" }
else
  pairs.each { |k, v| puts "export #{k}=#{v}" }
end
