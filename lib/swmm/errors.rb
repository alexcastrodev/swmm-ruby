# frozen_string_literal: true

module Swmm
  class Error < StandardError; end

  # libswmm5 could not be loaded (see Swmm::Engine.library_candidates).
  class LibraryNotFound < Error; end

  # The binary .out file is not in the layout this reader understands.
  class OutputFormatError < Error; end

  # Input contract violation. +errors+ is [{path: "junctions[0].elevation", message: "is required"}, ...].
  class InvalidInput < Error
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      shown = errors.first(20).map { |e| "  #{e[:path]}: #{e[:message]}" }
      shown << "  ... and #{errors.size - 20} more" if errors.size > 20
      super("invalid SWMM input (#{errors.size} error#{"s" unless errors.size == 1}):\n#{shown.join("\n")}")
    end
  end
end
