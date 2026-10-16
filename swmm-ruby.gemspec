# frozen_string_literal: true

require_relative "lib/swmm/version"

Gem::Specification.new do |spec|
  spec.name = "swmm-ruby"
  spec.version = Swmm::VERSION
  spec.summary = "Ruby wrapper for EPA SWMM5 with typed input and output contracts"
  spec.description = "Builds a SWMM .inp from a validated Ruby/JSON contract, runs libswmm5 through FFI " \
                     "and returns a Result with the engine status, continuity errors and every saved time series."
  spec.authors = ["Alexandro Castro"]
  spec.required_ruby_version = ">= 4.0"
  spec.files = Dir["lib/**/*.rb", "README.md", "docs/*.md"]
  spec.add_dependency "ffi", "~> 1.15"
end
