# frozen_string_literal: true

module Swmm
  # The binary .out file is not in the layout this reader understands.
  class OutputFormatError < Error; end
end
