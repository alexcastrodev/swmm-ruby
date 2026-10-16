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

    # A Result from files SWMM already wrote (the GUI, the swmm5 CLI or Swmm.run(dir:)); neither the engine nor the library is used.
    # rpt: is required. out: may be nil or missing when the run failed before writing it. The .inp is not needed.
    # What the files alone can say: the version comes from the .out (or the report banner); the error code from the .out
    # epilogue, or from the report when there is no .out (input errors, 2xx, are 200 as the engine reports them); the
    # continuity errors from the report's "Continuity Error (%)" lines (3 decimals; a block the report does not print is 0.0).
    def self.from_files(rpt:, out: nil)
      report = File.binread(rpt).force_encoding(Encoding::UTF_8).scrub
      output = OutputFile.new(File.binread(out)) if out && File.exist?(out)
      code = output ? output.engine_error : error_code_of(report)
      raise ArgumentError, "out file not found: #{out} (and the report shows no error)" if out && !output && code.zero?

      raw = { code: code, message: code.zero? ? "" : error_message_of(report, code), continuity: (continuity_of(report) if code.zero?) }
      new(version: output&.engine_version || report[/Build (\d+\.\d+\.\d+)/, 1], raw: raw, report: report,
          output: (output if code.zero?), files: { inp: nil, rpt: File.expand_path(rpt), out: out && File.expand_path(out) })
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
    private_class_method :error_code_of, :error_message_of, :continuity_of

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
      header = "time,id,#{variables(kind).map { csv_field(_1) }.join(",")}\n"
      header << output.csv_rows(kind, ids(kind).map { csv_field(_1) }, times.map { iso(_1) })
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
