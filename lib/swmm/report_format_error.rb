# frozen_string_literal: true

module Swmm
  # The .rpt given to Swmm.read is not a report SWMM wrote (no "STORM WATER MANAGEMENT MODEL" banner).
  class ReportFormatError < Error; end
end
