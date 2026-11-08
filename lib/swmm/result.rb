# frozen_string_literal: true

require "json"

module Swmm
  # Output contract. Swmm.run always returns one, whether the engine succeeded or not.
  #
  #   result.ok?                  # engine finished without error
  #   result.error                # nil | { code: 200, message: "...", details: ["ERROR 203: ...", ...] }
  #   result.warnings             # ["WARNING 02: ...", ...] from the report
  #   result.continuity           # { runoff:, flow_routing:, quality: } percent errors (nil on failure)
  #   result.continuity_ok?       # run finished and every continuity error is within 5 % (tolerance: to change)
  #   result.flow_instability     # { "C1" => 12, ... } links the report flags (flow reversals); {} when all are stable
  #   result.node_flooding        # [{ node: "J1", hours: 1.76, max_rate: 103.07, max_time: Time, volume: 354.0, ... }]
  #   result.analysis_options     # { flow_units: "LPS", start_time: Time, end_time: Time, report_step: TimeStep, flow_routing: "DYNWAVE", ... }
  #                               # as the report prints them (see Report#analysis_options)
  #   result.report_start         # Time the report's "days hr:min" count from (REPORT_START), from the .out
  #   result.times                # [Time, ...] one per reporting period (UTC; SWMM dates carry no zone)
  #   result.series(:nodes, "J1", :depth)   # [Float, ...] aligned with times
  #   result.to_h / to_json       # the whole contract as plain data
  #   result.to_csv(:links)       # wide CSV: time,id,<variables...>
  #   result.rpt / result.output  # the two files' own contracts: Swmm::Report (.rpt) and Swmm::OutputFile (.out)
  #
  # Each file can also be read alone (Swmm::Report.read, Swmm::OutputFile.read); a Result joins them and adds what only
  # both together say: the engine's error code, that they come from the same run, and the report start.
  class Result
    attr_reader :version, :error, :continuity, :files, :rpt, :output

    # A Result from files SWMM already wrote (the GUI, the swmm5 CLI or Swmm.run(dir:)); neither the engine nor the library is used.
    # rpt: is required. out: may be nil or missing when the run failed before writing it. The .inp is not needed.
    # What the files alone can say: the version comes from the .out (or the report banner); the error code from the .out
    # epilogue, or from the report when there is no .out (input errors, 2xx, are 200 as the engine reports them); the
    # continuity errors from the report's "Continuity Error (%)" lines (3 decimals; a block the report does not print is 0.0).
    # Raises ReportFormatError for a rpt: SWMM did not write, MismatchedFiles for an out: of another run.
    def self.from_files(rpt:, out: nil)
      report = Report.read(rpt)
      output = OutputFile.read(out) if out && File.exist?(out)
      code = output ? output.engine_error : report.error_code
      raise ArgumentError, "out file not found: #{out} (and the report shows no error)" if out && !output && code.zero?

      raw = { code: code, message: code.zero? ? "" : report.error_message(code), continuity: (report.continuity if code.zero?) }
      result = new(version: output&.engine_version || report.version, raw: raw, report: report,
                   output: (output if code.zero?), files: { inp: nil, rpt: File.expand_path(rpt), out: out && File.expand_path(out) })
      same_run!(result.analysis_options, output) if result.output
      result
    end

    # A .out of another run would pass for this one's results: what the report prints of the run must match it. The .out
    # saves the simulation start, or a whole number of report steps after it when REPORT_START is later (see #report_start).
    def self.same_run!(options, output)
      units, step, start, finish = options.values_at(:flow_units, :report_step, :start_time, :end_time)
      differences = []
      differences << "flow units #{units} / #{output.flow_units}" if units && units != output.flow_units
      differences << "report step #{step} / #{output.report_step}" if step && step != output.report_step
      if start
        offset = output.start - start
        aligned = offset >= 0 && output.report_step.positive? && (offset % output.report_step.in_seconds).zero?
        differences << "start #{start} / #{output.start}" unless aligned
      end
      differences << "end #{finish} / last period #{output.times.last}" if finish && output.periods.positive? && output.times.last > finish
      raise MismatchedFiles, "the .rpt and the .out are not from the same run: #{differences.join(", ")}" if differences.any?
    end

    private_class_method :same_run!

    # raw: Engine.run result; report: Report or the text of the .rpt; output: OutputFile | nil; files: { inp:, rpt:, out: } | nil
    def initialize(version:, raw:, report:, output:, files:)
      @version = version
      @rpt = report.is_a?(Report) ? report : Report.new(report)
      @output = output
      @files = files
      @continuity = raw[:continuity]
      @error = raw[:code].zero? ? nil : { code: raw[:code], message: raw[:message], details: rpt.error_details }
    end

    # Text of the .rpt ('' when the engine wrote none); #rpt is the same file read (Swmm::Report)
    def report = rpt.text

    def warnings = rpt.warnings

    def flow_instability = rpt.flow_instability

    def analysis_options = rpt.analysis_options

    def ok? = error.nil?

    # 5 % is a practical target from the SWMM literature, not an EPA rule; the engine does not judge it by itself.
    def continuity_ok?(tolerance: 5) = ok? && continuity.values.all? { it.abs <= tolerance }

    def status = ok? ? "ok" : "error"

    def times = require_output.times

    def ids(kind)
      kind = OutputFile.kind!(kind)
      kind == :system ? ["system"] : require_output.ids.fetch(kind)
    end

    def types(kind) = require_output.types(kind)
    def counts = require_output.counts
    def count_nodes = require_output.count_nodes
    def count_links = require_output.count_links
    def count_nodes_junction = require_output.count_nodes_junction
    def count_nodes_outfall = require_output.count_nodes_outfall
    def count_nodes_storage = require_output.count_nodes_storage
    def count_nodes_divider = require_output.count_nodes_divider
    def count_links_conduit = require_output.count_links_conduit
    def count_links_pump = require_output.count_links_pump
    def count_links_orifice = require_output.count_links_orifice
    def count_links_weir = require_output.count_links_weir
    def count_links_outlet = require_output.count_links_outlet
    def total_nodes = require_output.total_nodes
    def total_links = require_output.total_links
    def total_subcatchments = require_output.total_subcatchments
    def total_pollutants = require_output.total_pollutants

    def variables(kind)
      kind = OutputFile.kind!(kind)
      require_output.variables.fetch(kind)
    end

    def series(kind, id, variable) = require_output.series(kind, id, variable)

    def to_h(series: true)
      {
        status: status, swmm_version: version, error: error, warnings: warnings, continuity: json_safe(continuity),
        flow_instability: flow_instability, files: files, output: output && output_h(series)
      }
    end

    def to_json(*) = to_h.to_json(*)

    # When the report starts counting the elapsed times of its summary tables ("days hr:min"): the engine's report start,
    # which is REPORT_START, or the simulation start when REPORT_START is earlier or not given. The report does not print
    # it, so it comes from the start the .out saved: the simulation start, or one report step before the first possible
    # reported period when the report starts later. Exact when REPORT_START is the simulation start or a whole number of
    # report steps (at least two) after it; otherwise the files cannot tell it apart from an earlier one, and this is up
    # to one report step early (a REPORT_START one step after the start saves the same .out as none). nil without results.
    def report_start
      start = analysis_options[:start_time]
      return unless output && start

      output.start > start ? output.start + output.report_step.in_seconds : start
    end

    # Swmm::Report#node_flooding with the max_time of each row: report_start + max_elapsed (nil without results).
    #   { node: "J1", hours: 1.76, max_rate: 103.07, max_elapsed: 3600, max_time: Time, volume: 354.0, max_ponded_depth: 0.0 }
    def node_flooding = @node_flooding ||= rpt.node_flooding(start: report_start)

    # The CSV of a kind as a String; given an +io+ (a File, $stdout, ...), written to it a span of periods at a time,
    # never whole in memory, and the io comes back.
    def to_csv(kind, io = nil)
      kind = OutputFile.kind!(kind)
      header = "time,id,#{variables(kind).map { csv_field(it) }.join(",")}\n"
      rows = ->(to) { output.csv_rows(kind, ids(kind).map { csv_field(it) }, times.map { iso(it) }, to) }
      return header << rows.call(nil) unless io

      io.write(header)
      rows.call(io)
    end

    # Each period of a kind, one at a time: see OutputFile#each_period
    def each_period(kind, &) = require_output.each_period(kind, &)

    private

    # JSON has no NaN / Infinity (to_json would raise): in the exported data a non-finite continuity error is null.
    # #continuity keeps the real value, so continuity_ok? stays false for it.
    def json_safe(hash) = hash&.transform_values { it.finite? ? it : nil }

    def require_output
      output || raise(Error, "no results: the simulation did not complete (#{error && error[:message]})")
    end

    def output_h(with_series)
      h = {
        flow_units: output.flow_units, start: iso(output.start), report_step: output.report_step.to_i,
        periods: output.periods, times: output.times.map { iso(it) }, units: output.units # rubocop:disable Performance/TimesMap -- times is the Array of report times
      }
      OutputFile::KINDS.each do |kind|
        h[kind] = with_series ? output.all_series(kind) : ids(kind).to_h { |id| [id, variables(kind).to_h { |v| [v, nil] }] }
      end
      h
    end

    def iso(time) = time.strftime("%Y-%m-%dT%H:%M:%S")

    def csv_field(value) = value.is_a?(String) && value.match?(/[",\n]/) ? %("#{value.gsub('"', '""')}") : value.to_s
  end
end
