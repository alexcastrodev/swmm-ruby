# frozen_string_literal: true

module Swmm
  # The .rpt and the .out given to Swmm.read are not from the same run (flow units, report step, start or end differ).
  class MismatchedFiles < Error; end
end
