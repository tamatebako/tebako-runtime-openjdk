# frozen_string_literal: true

source "https://rubygems.org"

# The release sign pass (scripts/sign_release.rb — build-payload.yml's
# sign job). The pin matches tebako-runtime-python's.
gem "octokit", "~> 7.1"

# octokit 7.x requires base64 without declaring it; a default gem on the
# CI ruby (3.3) but bundled-gems-only on 3.4+ hosts (the maintainer's
# local ruby), where the undeclared require LoadErrors.
gem "base64", "~> 0.2"

# The spec suite (tebako-runtime-python#12's minimal harness, mirrored):
# rspec arrived with the signing pass's coverage (spec/sign_release_spec.rb).
group :development, :test do
  gem "rspec", "~> 3.13"
end
