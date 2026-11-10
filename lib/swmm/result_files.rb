# frozen_string_literal: true

module Swmm
  # Behind Result.from_files: a Result from files SWMM already wrote (the GUI, the swmm5 CLI or Swmm.run(dir:)), without
  # the engine or the library. What the files alone can say: the version comes from the .out (or the report banner);
  # the error code from the .out epilogue, or from the report when there is no .out (input errors, 2xx, are 200 as the
  # engine reports them); the continuity errors from the report's "Continuity Error (%)" lines (3 decimals; a block the
  # report does not print is 0.0).
  module ResultFiles
    module_function

    # rpt: is required; out: may be nil or missing when the run failed before writing it. ReportFormatError for a rpt:
    # SWMM did not write, MismatchedFiles for an out: of another run, ArgumentError for a missing out: of a run that
    # finished.
    def read(rpt:, out: nil)
      report = Report.read(rpt)
      output = OutputFile.read(out) if out && File.exist?(out)
      code = output ? output.engine_error : report.error_code
      raise ArgumentError, "out file not found: #{out} (and the report shows no error)" if out && !output && code.zero?

      raw = { code: code, message: code.zero? ? '' : report.error_message(code), continuity: (report.continuity if code.zero?) }
      result = Result.new(version: output&.engine_version || report.version, raw: raw, report: report, output: (output if code.zero?),
                          files: { inp: nil, rpt: File.expand_path(rpt), out: out && File.expand_path(out) })
      same_run!(options: result.analysis_options, output: result.output) if result.output
      result
    end

    # A .out of another run would pass for this one's results: what the report prints of the run must match it. The .out
    # saves the simulation start, or a whole number of report steps after it when REPORT_START is later (see
    # Result#report_start).
    def same_run!(options:, output:)
      units, step, start, finish = options.values_at(:flow_units, :report_step, :start_time, :end_time)
      differences = []
      differences << "flow units #{units} / #{output.flow_units}" if units && units != output.flow_units
      differences << "report step #{step} / #{output.report_step}" if step && step != output.report_step
      if start
        offset = output.start_time - start
        aligned = offset >= 0 && output.report_step.positive? && (offset % output.report_step.in_seconds).zero?
        differences << "start #{start} / #{output.start_time}" unless aligned
      end
      differences << "end #{finish} / last period #{output.times.last}" if finish && output.periods.positive? && output.times.last > finish
      raise MismatchedFiles, "the .rpt and the .out are not from the same run: #{differences.join(', ')}" if differences.any?
    end
  end
end
