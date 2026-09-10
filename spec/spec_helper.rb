# frozen_string_literal: true

# The spec suite's shared setup (tebako-runtime-python's spec_helper is
# the model): monkey patching off, partial doubles verified. This repo
# has no builder library — the scripts ride the spec's own $LOAD_PATH
# unshift.
REPO_ROOT = File.expand_path("..", __dir__).freeze

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
end
