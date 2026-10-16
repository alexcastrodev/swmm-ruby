# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "json"
require "swmm"
require_relative "fixtures"

# Tests that need the real engine skip themselves when libswmm5 has not been built.
module NeedsEngine
  def setup
    skip "libswmm5 not found: run `rake swmm:build`" unless Swmm::Engine.available?
  end

  def assert_runs(model, label = nil)
    result = Swmm.run(model)
    assert result.ok?, "#{label}: #{result.error&.fetch(:details, nil)&.join("; ")}"
    result
  end
end
