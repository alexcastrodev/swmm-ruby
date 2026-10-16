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
  #   result.times                # [Time, ...] one per reporting period (UTC; SWMM dates carry no zone)
  #   result.series(:nodes, "J1", :depth)   # [Float, ...] aligned with times
  #   result.to_h / to_json       # the whole contract as plain data
  #   result.to_csv(:links)       # wide CSV: time,id,<variables...>
  class Result
    attr_reader :version, :error, :warnings, :continuity, :flow_instability, :files, :report, :output

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

    def ids(kind) = kind.to_sym == :system ? ["system"] : require_output.ids.fetch(kind.to_sym)

    def variables(kind) = require_output.variables.fetch(kind.to_sym)

    def series(kind, id, variable) = require_output.series(kind, id, variable)

    def to_h(series: true)
      {
        status: status, swmm_version: version, error: error, warnings: warnings, continuity: continuity,
        flow_instability: flow_instability, files: files, output: output && output_h(series)
      }
    end

    def to_json(*args) = to_h.to_json(*args)

    def to_csv(kind)
      kind = kind.to_sym
      vars = variables(kind)
      stamps = times.map { _1.strftime("%Y-%m-%dT%H:%M:%S") }
      per_id = output.all_series(kind).to_h { |id, cols| [csv_field(id), cols.values_at(*vars).transpose] } # one row per period
      rows = stamps.each_index.flat_map { |i| per_id.map { |id, table| "#{stamps[i]},#{id},#{table[i].join(",")}" } }
      (["time,id,#{vars.map { csv_field(_1) }.join(",")}"] + rows).join("\n") << "\n"
    end

    private

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
