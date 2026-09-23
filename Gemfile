# frozen_string_literal: true

source "https://rubygems.org"

require "yaml"

# The release machinery — the sign step's tebako-release exe.
# tamatebako/tebako-release-tooling is the signer's single owner
# (ecosystem invariant 10); the pin lives in Tebakofile's
# tools.release_tooling so the bump is one recipe edit, never a second
# hand-written copy of the machinery.
gem "tebako-release",
    git: "https://github.com/tamatebako/tebako-release-tooling.git",
    tag: YAML.load_file(File.expand_path("Tebakofile", __dir__)).fetch("tools").fetch("release_tooling")

# The release audit + registry render (tools/audit_release.rb,
# tools/registry_update.rb) talk to the releases API directly.
gem "octokit", "~> 7.1"

# octokit 7.x requires base64 without declaring it; a default gem on the
# CI ruby (3.3) but bundled-gems-only on 3.4+ hosts (the maintainer's
# local ruby), where the undeclared require LoadErrors.
gem "base64", "~> 0.2"

# The spec suite (tebako-runtime-python#12's minimal harness, mirrored).
group :development, :test do
  gem "rspec", "~> 3.13"
end
