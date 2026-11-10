# frozen_string_literal: true

require 'json'

module Swmm
  # The results of a simulation: what the report (+.rpt+, a {Report}) and the results file (+.out+, an {OutputFile})
  # say, joined. {Swmm.run} always returns one, whether the engine succeeded or not: an engine failure is {#error}, not
  # an exception. Each file can also be read alone ({Report.read}, {OutputFile.read}); a Result adds what only both
  # together say: the engine's error code, that they come from the same run, and the {#report_start}.
  #
  # @example
  #   result = Swmm.run(model)        # or Swmm.read(rpt: "model.rpt", out: "model.out")
  #   result.ok?                      # => true
  #   result.continuity_ok?           # => true (every continuity error within 5 %)
  #   result.links["C1"][:flow]       # => #<Swmm::Series links "C1" flow (LPS): 12 values>
  #   result.nodes.frames(:depth)     # => #<Swmm::Frames nodes depth (m): 12 periods x 609 objects>
  #   result.links.records.first      # => #<Swmm::Record time=..., id="C1", flow=0.0, ...>
  #   result.to_json                  # the whole contract as plain data
  class Result
    # @return [String, nil] the engine version (+"5.2.4"+)
    attr_reader :version

    # @return [Hash{Symbol => Object}, nil] +{ code: 200, message: "...", details: ["ERROR 203: ...", ...] }+; nil when
    #   the engine finished
    attr_reader :error

    # @return [Hash{Symbol => Float}, nil] the continuity errors in percent (+{ runoff:, flow_routing:, quality: }+);
    #   nil when the engine failed
    attr_reader :continuity

    # @return [Hash{Symbol => String}, nil] +{ inp:, rpt:, out: }+ when the files were kept (+Swmm.run(dir:)+,
    #   {Swmm.read}); nil for a temporary run
    attr_reader :files

    # @return [Report] the +.rpt+ read
    attr_reader :rpt

    # @return [OutputFile, nil] the +.out+ read; nil when the engine failed
    attr_reader :output

    # A Result from files SWMM already wrote (the GUI, the +swmm5+ CLI or +Swmm.run(dir:)+); neither the engine nor the
    # library is used, and the +.inp+ is not needed.
    #
    # @param rpt [String] the +.rpt+
    # @param out [String, nil] the +.out+; nil or missing when the run failed before writing it
    # @return [Result]
    # @raise [ReportFormatError] for a +rpt+ SWMM did not write
    # @raise [MismatchedFiles] for an +out+ of another run
    # @raise [ArgumentError] for a missing +out+ of a run that finished
    def self.from_files(rpt:, out: nil) = ResultFiles.read(rpt:, out:)

    # @api private
    # @param version [String, nil]
    # @param raw [Hash] what the engine returned: +{ code:, message:, continuity: }+
    # @param report [Report, String] the report, or its text
    # @param output [OutputFile, nil]
    # @param files [Hash, nil] +{ inp:, rpt:, out: }+
    def initialize(version:, raw:, report:, output:, files:)
      @version = version
      @rpt = report.is_a?(Report) ? report : Report.new(report)
      @output = output
      @files = files
      @continuity = raw[:continuity]
      @error = raw[:code].zero? ? nil : { code: raw[:code], message: raw[:message], details: rpt.error_details }
    end

    # @return [String] the text of the +.rpt+ (+''+ when the engine wrote none); {#rpt} is the same file read
    def report = rpt.text

    # @return [Array<String>] the report's warnings (+"WARNING 02: ..."+)
    def warnings = rpt.warnings

    # @return [Hash{String => Integer}] the links the report flags as unstable (flow reversals); empty when all are stable
    def flow_instability = rpt.flow_instability

    # @return [Hash{Symbol => Object}] the report's "Analysis Options" (see {Report#analysis_options})
    def analysis_options = rpt.analysis_options

    # @return [Boolean] whether the engine finished without error (not that the model is good: see {#continuity_ok?})
    def ok? = error.nil?

    # 5 % is a practical target from the SWMM literature, not an EPA rule; the engine does not judge it by itself.
    #
    # @param tolerance [Numeric] the largest continuity error accepted, in percent
    # @return [Boolean] whether the run finished and every continuity error is within +tolerance+
    def continuity_ok?(tolerance: 5) = ok? && continuity.values.all? { it.abs <= tolerance }

    # @return [String] +"ok"+ or +"error"+
    def status = ok? ? 'ok' : 'error'

    # @return [Array<Time>] the time of each reporting period (UTC)
    # @raise [Error] when the simulation did not complete
    def times = require_output.times

    # @return [Collection] the subcatchments the +.out+ saved
    # @raise [Error] when the simulation did not complete
    def subcatchments = require_output.subcatchments

    # @return [Collection] the nodes the +.out+ saved
    # @raise [Error] when the simulation did not complete
    def nodes = require_output.nodes

    # @return [Collection] the links the +.out+ saved
    # @raise [Error] when the simulation did not complete
    def links = require_output.links

    # @return [Collection] the system (one object, +"system"+)
    # @raise [Error] when the simulation did not complete
    def system = require_output.system

    # @param kind [Symbol, String] one of {OutputFile::KINDS}
    # @return [Collection] the objects of that kind
    # @raise [UnknownObject] for another kind
    # @raise [Error] when the simulation did not complete
    def [](kind)
      kind = OutputReader.kind!(kind)
      require_output[kind]
    end

    # The whole contract as plain data (Symbols, Strings, numbers, nil, Arrays and Hashes).
    #
    # @param series [Boolean] with the values of every variable (false: the ids and variables, values nil)
    # @return [Hash{Symbol => Object}]
    def to_h(series: true)
      {
        status: status, swmm_version: version, error: error, warnings: warnings, continuity: json_safe(continuity),
        flow_instability: flow_instability, files: files, output: output && output_h(series)
      }
    end

    # @return [String] {#to_h} as JSON
    def to_json(*) = to_h.to_json(*)

    # When the report starts counting the elapsed times of its summary tables ("days hr:min"): the engine's report
    # start, which is +REPORT_START+, or the simulation start when +REPORT_START+ is earlier or not given. The report does
    # not print it, so it comes from the start the +.out+ saved. Exact when +REPORT_START+ is the simulation start or a
    # whole number of report steps (at least two) after it; otherwise the files cannot tell it apart from an earlier
    # one, and this is up to one report step early.
    #
    # @return [Time, nil] nil without results
    def report_start
      start = analysis_options[:start_time]
      return unless output && start

      output.start_time > start ? output.start_time + output.report_step.in_seconds : start
    end

    # {Report#node_flooding} with the +max_time+ of each row (+report_start + max_elapsed+; nil without results).
    #
    # @return [Array<Hash{Symbol => Object}>] +[{ node: "J1", hours: 1.76, max_rate: 103.07, max_elapsed: 3600,
    #   max_time: Time, volume: 354.0, max_ponded_depth: 0.0 }]+; empty when no node flooded
    def node_flooding = @node_flooding ||= rpt.node_flooding(start: report_start)

    private

    # JSON has no NaN / Infinity (to_json would raise): in the exported data a non-finite continuity error is null.
    # #continuity keeps the real value, so continuity_ok? stays false for it.
    def json_safe(hash) = hash&.transform_values { it.finite? ? it : nil }

    def require_output
      output || raise(Error, "no results: the simulation did not complete (#{error && error[:message]})")
    end

    def output_h(with_series)
      h = {
        flow_units: output.flow_units, start: iso(output.start_time), report_step: output.report_step.to_i,
        periods: output.periods, times: output.times.map { iso(it) }, # rubocop:disable Performance/TimesMap -- times is the Array of report times
        units: OutputFile::KINDS.to_h { [it, output[it].units] }
      }
      OutputFile::KINDS.each do |kind|
        objects = output[kind]
        h[kind] = with_series ? objects.to_h : objects.ids.to_h { |id| [id, objects.variables.to_h { [it, nil] }] }
      end
      h
    end

    def iso(time) = time.strftime('%Y-%m-%dT%H:%M:%S')
  end
end
