# frozen_string_literal: true

module Swmm
  # Input contract violation. +errors+ is [{ path: "junctions[0].elevation", message: "is required" }, ...].
  class InvalidInput < Error
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      shown = errors.first(20).map { |e| "  #{e[:path]}: #{e[:message]}" }
      shown << "  ... and #{errors.size - 20} more" if errors.size > 20
      super("invalid SWMM input (#{errors.size} error#{'s' unless errors.size == 1}):\n#{shown.join("\n")}")
    end
  end
end
