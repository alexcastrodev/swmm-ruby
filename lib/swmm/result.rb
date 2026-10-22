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
  #   result.analysis_options     # { flow_units: "LPS", start: Time, end: Time, report_step: 600 } as the report prints them
  #   result.report_start         # Time the report's "days hr:min" count from (REPORT_START), from the .out
  #   result.times                # [Time, ...] one per reporting period (UTC; SWMM dates carry no zone)
  #   result.series(:nodes, "J1", :depth)   # [Float, ...] aligned with times
  #   result.to_h / to_json       # the whole contract as plain data
  #   result.to_csv(:links)       # wide CSV: time,id,<variables...>
  class Result
    attr_reader :version, :error, :warnings, :continuity, :flow_instability, :files, :report, :output

    BANNER = "STORM WATER MANAGEMENT MODEL" # first lines of every report the engine writes ("EPA ..." or "OWA ...")
    US_FLOW_UNITS = %w[CFS GPM MGD].freeze
    # the report's flood volumes are 10^6 ltr (SI) or 10^6 gal (US): to the volume unit of OutputFile#units, m3 / ft3
    FLOOD_VOLUME = { si: 1000.0, us: 133_680.555_6 }.freeze
    # "  J1   1.76   103.07   0  01:00   0.354   0.000": node, hours flooded, max rate, days hr:min of the max, volume,
    # max ponded depth (the "Node Flooding Summary" of SWMM 5.2)
    FLOODING_ROW = /\A\s*(\S+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\s+(\d+):(\d+)\s+([\d.]+)\s+([\d.]+)\s*\z/

    # A Result from files SWMM already wrote (the GUI, the swmm5 CLI or Swmm.run(dir:)); neither the engine nor the library is used.
    # rpt: is required. out: may be nil or missing when the run failed before writing it. The .inp is not needed.
    # What the files alone can say: the version comes from the .out (or the report banner); the error code from the .out
    # epilogue, or from the report when there is no .out (input errors, 2xx, are 200 as the engine reports them); the
    # continuity errors from the report's "Continuity Error (%)" lines (3 decimals; a block the report does not print is 0.0).
    # Raises ReportFormatError for a rpt: SWMM did not write, MismatchedFiles for an out: of another run.
    def self.from_files(rpt:, out: nil)
      report = File.binread(rpt).force_encoding(Encoding::UTF_8).scrub
      raise ReportFormatError, "not a SWMM report (no #{BANNER.inspect} banner): #{rpt}" unless report.include?(BANNER)

      output = OutputFile.new(File.binread(out)) if out && File.exist?(out)
      code = output ? output.engine_error : error_code_of(report)
      raise ArgumentError, "out file not found: #{out} (and the report shows no error)" if out && !output && code.zero?

      raw = { code: code, message: code.zero? ? "" : error_message_of(report, code), continuity: (continuity_of(report) if code.zero?) }
      result = new(version: output&.engine_version || version_of(report), raw: raw, report: report,
                   output: (output if code.zero?), files: { inp: nil, rpt: File.expand_path(rpt), out: out && File.expand_path(out) })
      same_run!(result.analysis_options, output) if result.output
      result
    end

    # "Build 5.2.4" in the EPA banner, "VERSION v5.2.1" in the OWA one
    def self.version_of(report) = report[/Build (\d+\.\d+\.\d+)/, 1] || report[/VERSION v?(\d+\.\d+\.\d+)/, 1]

    # A .out of another run would pass for this one's results: what the report prints of the run must match it. The .out
    # saves the simulation start, or a whole number of report steps after it when REPORT_START is later (see #report_start).
    def self.same_run!(options, output)
      units, step, start, finish = options.values_at(:flow_units, :report_step, :start, :end)
      differences = []
      differences << "flow units #{units} / #{output.flow_units}" if units && units != output.flow_units
      differences << "report step #{step} s / #{output.report_step} s" if step && step != output.report_step
      if start
        offset = output.start - start
        aligned = offset >= 0 && output.report_step.positive? && (offset % output.report_step).zero?
        differences << "start #{start} / #{output.start}" unless aligned
      end
      differences << "end #{finish} / last period #{output.times.last}" if finish && output.periods.positive? && output.times.last > finish
      raise MismatchedFiles, "the .rpt and the .out are not from the same run: #{differences.join(", ")}" if differences.any?
    end

    # Input errors (2xx, with their line context) make the engine return 200, which the report never prints.
    def self.error_code_of(report)
      codes = report.scan(/^\s*ERROR (\d+):/).flatten.map(&:to_i)
      codes.any? { _1.between?(200, 299) } ? 200 : codes.first.to_i
    end

    def self.error_message_of(report, code)
      report[/^\s*(ERROR #{code}:.*)$/, 1]&.strip || (code == 200 ? "ERROR 200: one or more errors in input file." : "ERROR #{code}")
    end

    # Like swmm_getMassBalErr: quality is the pollutant error with the largest absolute value (signed).
    def self.continuity_of(report)
      error = lambda do |title|
        report[/#{title}.*?Continuity Error \(%\) \.+([^\n]*)/m, 1].to_s.split.map(&:to_f).max_by(&:abs) || 0.0
      end
      { runoff: error.("Runoff Quantity Continuity"), flow_routing: error.("Flow Routing Continuity"), quality: error.("Quality Routing Continuity") }
    end
    private_class_method :error_code_of, :error_message_of, :continuity_of, :version_of, :same_run!

    # raw: Engine.run result; report: text of the .rpt; output: OutputFile | nil; files: { inp:, rpt:, out: } | nil
    def initialize(version:, raw:, report:, output:, files:)
      @version = version
      @report = report
      @output = output
      @files = files
      @continuity = raw[:continuity]
      @warnings = report.scan(/^\s*WARNING \d+:.*$/).map(&:strip)
      @flow_instability = flow_instability_of(report)
      @error = raw[:code].zero? ? nil : { code: raw[:code], message: raw[:message], details: error_details(report) }
    end

    def ok? = error.nil?

    # 5 % is a practical target from the SWMM literature, not an EPA rule; the engine does not judge it by itself.
    def continuity_ok?(tolerance: 5) = ok? && continuity.values.all? { _1.abs <= tolerance }

    def status = ok? ? "ok" : "error"

    def times = require_output.times

    def ids(kind)
      kind = OutputFile.kind!(kind)
      kind == :system ? ["system"] : require_output.ids.fetch(kind)
    end

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

    def to_json(*args) = to_h.to_json(*args)

    # What the report prints of the run under "Analysis Options"; nil for what it does not print (a run that failed on
    # its input stops before them). Dates are UTC, like #times.
    def analysis_options
      @analysis_options ||= begin
        step = report.match(/^\s*Report Time Step \.+ (\d+):(\d+):(\d+)\s*$/)
        {
          flow_units: report[/^\s*Flow Units \.+ (\S+)/, 1], start: report_time("Starting Date"), end: report_time("Ending Date"),
          report_step: step && ((step[1].to_i * 3600) + (step[2].to_i * 60) + step[3].to_i)
        }
      end
    end

    # When the report starts counting the elapsed times of its summary tables ("days hr:min"): the engine's report start,
    # which is REPORT_START, or the simulation start when REPORT_START is earlier or not given. The report does not print
    # it, so it comes from the start the .out saved: the simulation start, or one report step before the first possible
    # reported period when the report starts later. Exact when REPORT_START is the simulation start or a whole number of
    # report steps (at least two) after it; otherwise the files cannot tell it apart from an earlier one, and this is up
    # to one report step early (a REPORT_START one step after the start saves the same .out as none). nil without results.
    def report_start
      start = analysis_options[:start]
      return unless output && start

      output.start > start ? output.start + output.report_step : start
    end

    # The report's "Node Flooding Summary": one row per node that flooded (water left the network there), [] when none
    # did or the report has no such table (a run that failed).
    #   { node: "J1", hours: 1.76, max_rate: 103.07, max_elapsed: 3600, max_time: Time, volume: 354.0, max_ponded_depth: 0.0 }
    # max_rate in the flow units; volume in the volume unit of OutputFile#units (m3 / ft3); max_ponded_depth in m / ft;
    # max_elapsed: seconds from #report_start, as the report counts; max_time: report_start + max_elapsed, or nil
    # without results. The report keeps 2 decimals of the rate and resolves volumes to 1 m3 / 133.7 ft3.
    def node_flooding
      @node_flooding ||= begin
        section = report[/Node Flooding Summary\s*\*+\R(.*?)(?=^\s*\*{5,}|\z)/m, 1].to_s
        start = report_start
        factor = FLOOD_VOLUME.fetch(US_FLOW_UNITS.include?(output&.flow_units || analysis_options[:flow_units]) ? :us : :si)
        section.each_line.filter_map do |line|
          node, hours, rate, days, hour, minute, volume, depth = line.match(FLOODING_ROW)&.captures
          next unless node

          elapsed = (days.to_i * 86_400) + (hour.to_i * 3600) + (minute.to_i * 60)
          { node: node, hours: hours.to_f, max_rate: rate.to_f, max_elapsed: elapsed, max_time: start && start + elapsed,
            volume: (volume.to_f * factor).round(3), max_ponded_depth: depth.to_f }
        end
      end
    end

    def to_csv(kind)
      kind = OutputFile.kind!(kind)
      header = "time,id,#{variables(kind).map { csv_field(_1) }.join(",")}\n"
      header << output.csv_rows(kind, ids(kind).map { csv_field(_1) }, times.map { iso(_1) })
    end

    private

    # JSON has no NaN / Infinity (to_json would raise): in the exported data a non-finite continuity error is null.
    # #continuity keeps the real value, so continuity_ok? stays false for it.
    def json_safe(hash) = hash&.transform_values { _1.finite? ? _1 : nil }

    # "Highest Flow Instability Indexes" lists "  Link C1 (12)" (or "All links are stable."); the section stops at the next banner.
    def flow_instability_of(report)
      section = report[/Highest Flow Instability Indexes\s*\*+\n(.*?)(?=^\s*\*|\z)/m, 1].to_s
      section.scan(/^\s*Link (.+?) \((\d+)\)\s*$/).to_h { |id, turns| [id, turns.to_i] }
    end

    # "ERROR 209: undefined object X at line 14 of [CONDUIT] section:" is followed by the offending input line
    def error_details(report)
      lines = report.lines.map(&:strip)
      lines.each_with_index.filter_map do |l, i|
        next unless l.start_with?("ERROR")

        l.end_with?(":") ? "#{l} #{lines[i + 1]}" : l
      end
    end

    def require_output
      output || raise(Error, "no results: the simulation did not complete (#{error && error[:message]})")
    end

    # "  Starting Date ............ 03/24/2026 00:00:00" as a UTC Time: the engine always writes M/D/Y (swmm_open sets it)
    def report_time(label)
      m = report.match(%r{^\s*#{label} \.+ (\d+)/(\d+)/(\d+) (\d+):(\d+):(\d+)\s*$})
      m && Time.utc(m[3].to_i, m[1].to_i, m[2].to_i, m[4].to_i, m[5].to_i, m[6].to_i)
    rescue ArgumentError # out of range: not a date the engine wrote
      nil
    end

    def output_h(with_series)
      h = {
        flow_units: output.flow_units, start: iso(output.start), report_step: output.report_step,
        periods: output.periods, times: output.times.map { iso(_1) }, units: output.units
      }
      OutputFile::KINDS.each do |kind|
        h[kind] = with_series ? output.all_series(kind) : ids(kind).to_h { |id| [id, variables(kind).to_h { |v| [v, nil] }] }
      end
      h
    end

    def iso(time) = time.strftime("%Y-%m-%dT%H:%M:%S")

    def csv_field(v) = v.is_a?(String) && v.match?(/[",\n]/) ? %("#{v.gsub('"', '""')}") : v.to_s
  end
end
