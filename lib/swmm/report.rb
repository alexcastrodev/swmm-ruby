# frozen_string_literal: true

module Swmm
  # SWMM's text report (+.rpt+): what the engine says about the run. Needs neither the engine nor the +.out+. What the
  # report cannot say on its own (its report start, so the +max_time+ of the flooding rows) {Result} adds from the
  # +.out+.
  #
  # @example
  #   report = Swmm::Report.read("run.rpt")
  #   report.ok?                  # => true (no ERROR line)
  #   report.warnings             # => ["WARNING 02: maximum depth increased for Node J1"]
  #   report.continuity           # => { runoff: 0.0, flow_routing: -0.144, quality: 0.0 }
  #   report.analysis_options     # => { flow_units: "LPS", start_time: 2026-03-24 00:00:00 UTC, ..., flow_routing: "DYNWAVE" }
  #   report.node_flooding        # => [{ node: "J1", hours: 1.76, max_rate: 103.07, max_elapsed: 3600, ... }]
  class Report
    # Reads a +.rpt+ file.
    #
    # @param path [String] the +.rpt+
    # @return [Report]
    # @raise [ReportFormatError] for a file SWMM did not write (no +STORM WATER MANAGEMENT MODEL+ banner)
    # @raise [Errno::ENOENT] when the file is not there
    def self.read(path)
      report = new(File.binread(path))
      raise ReportFormatError, "not a SWMM report (no #{Parser::BANNER.inspect} banner): #{path}" unless report.swmm?

      report
    end

    # Any text is accepted (blank too, when the engine wrote none: then every reader answers as for a run that printed
    # nothing).
    #
    # @param text [String] the contents of a +.rpt+, in any encoding (read as UTF-8, invalid bytes replaced)
    # @raise [TypeError] when +text+ is not a String
    def initialize(text)
      @parser = Parser.new(text)
    end

    # @return [String] the text of the report (UTF-8, frozen)
    def text = @parser.text

    # @return [Boolean] whether the engine wrote it (it has the SWMM banner)
    def swmm? = @parser.swmm?

    # @return [String, nil] the engine version of the banner (+"Build 5.2.4"+ of EPA, +"VERSION v5.2.1"+ of OWA)
    def version = @parser.version

    # Input errors (2xx, with their line context) make the engine return 200, which the report never prints.
    #
    # @return [Integer] the error code of the run; 0 when it finished
    def error_code = @parser.error_code

    # @param code [Integer]
    # @return [String] the report's line of that error (+"ERROR 200: one or more errors in input file."+ for 200)
    def error_message(code = error_code) = @parser.error_message(code)

    # @return [Array<String>] every ERROR line, followed by the input line it is about when the report prints one
    def error_details = @parser.error_details

    # The engine's own code, when known, may differ: {Result#error} prefers the one the +.out+ saved.
    #
    # @return [Hash{Symbol => Object}, nil] +{ code:, message:, details: }+ as the report prints it; nil when it
    #   finished
    def error = @parser.error

    # @return [Boolean] whether the report has no error
    def ok? = @parser.ok?

    # @return [Array<String>] the warnings (+"WARNING 02: ..."+)
    def warnings = @parser.warnings

    # Like +swmm_getMassBalErr+: quality is the pollutant error with the largest absolute value (signed). From the
    # "Continuity Error (%)" lines (3 decimals; a block the report does not print is 0.0).
    #
    # @return [Hash{Symbol => Float}, nil] +{ runoff:, flow_routing:, quality: }+ in percent; nil when the run failed
    def continuity = @parser.continuity

    # @return [Hash{String => Integer}] the links of "Highest Flow Instability Indexes" (+{ "C1" => 12 }+); empty when
    #   all are stable
    def flow_instability = @parser.flow_instability

    # What the report prints of the run under "Analysis Options"; nil for what it does not print (a run that failed on
    # its input stops before them; the routing ones only with Flow Routing on, +surcharge_method+ only for DYNWAVE).
    #
    # @return [Hash{Symbol => Object}] +{ flow_units:, start_time:, end_time:, report_step:, flow_routing:,
    #   surcharge_method:, routing_step:, variable_step: }+: dates as UTC Times, steps as {TimeStep}s, +variable_step+
    #   true / false; the values as in {Options}
    def analysis_options = @parser.analysis_options

    # The "Node Flooding Summary": one row per node that flooded (water left the network there). +max_rate+ in the
    # flow units, +volume+ in m3 / ft3, +max_ponded_depth+ in m / ft; +max_elapsed+ in seconds from the report start,
    # as the report counts. The report keeps 2 decimals of the rate and resolves volumes to 1 m3 / 133.7 ft3.
    #
    # @param start [Time, nil] the report start (the report does not print its own: {Result#report_start})
    # @return [Array<Hash{Symbol => Object}>] +[{ node:, hours:, max_rate:, max_elapsed:, max_time:, volume:,
    #   max_ponded_depth: }]+ (+max_time+ = +start + max_elapsed+, nil without a +start+); empty when no node flooded
    def node_flooding(start: nil) = @parser.node_flooding(start:)

    # @return [Hash{Symbol => Object}] what the report says, as plain data
    def to_h
      {
        status: ok? ? 'ok' : 'error', swmm_version: version, error: error, warnings: warnings,
        continuity: continuity&.transform_values { it.finite? ? it : nil }, flow_instability: flow_instability,
        analysis_options: analysis_options, node_flooding: node_flooding
      }
    end
  end
end
