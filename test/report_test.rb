# frozen_string_literal: true

require "test_helper"

# The .rpt alone: no engine, no .out.
class ReportTest < Minitest::Test
  OK = <<~RPT

    EPA STORM WATER MANAGEMENT MODEL - VERSION 5.2 (Build 5.2.4)
    ------------------------------------------------------------

    WARNING 04: minimum elevation drop used for Conduit C1

    ****************
    Analysis Options
    ****************
    Flow Units ............... LPS
    Process Models:
      Flow Routing ........... YES
    Flow Routing Method ...... DYNWAVE
    Surcharge Method ......... EXTRAN
    Starting Date ............ 03/24/2026 00:00:00
    Ending Date .............. 03/24/2026 02:00:00
    Report Time Step ......... 00:10:00
    Routing Time Step ........ 5.00 sec
    Variable Time Step ....... NO

    **************************        Volume        Volume
    Flow Routing Continuity        hectare-m      10^6 ltr
    **************************     ---------     ---------
    Continuity Error (%) .....        -0.114

    ********************************
    Highest Flow Instability Indexes
    ********************************
    Link C1 (12)

    *********************
    Node Flooding Summary
    *********************
    --------------------------------------------------------------------------
    Node                 Flooded       LPS   days hr:min    10^6 ltr    Meters
    --------------------------------------------------------------------------
    J1                      1.76    103.07      1  01:00       0.354     0.000

    ***********************
    Outfall Loading Summary
    ***********************
  RPT

  FAILED = <<~RPT
    EPA STORM WATER MANAGEMENT MODEL - VERSION 5.2 (Build 5.2.4)

    ERROR 209: undefined object X at line 14 of [CONDUITS] section:
      C1 J1 X 100 0.013
    ERROR 211: invalid number at line 15 of [CONDUITS] section:
  RPT

  def test_reads_what_the_report_says_of_a_run_that_finished
    report = Swmm::Report.new(OK)
    assert_predicate report, :ok?
    assert_equal "5.2.4", report.version
    assert_equal ["WARNING 04: minimum elevation drop used for Conduit C1"], report.warnings
    assert_equal({ runoff: 0.0, flow_routing: -0.114, quality: 0.0 }, report.continuity)
    assert_equal({ "C1" => 12 }, report.flow_instability)
    assert_equal({ flow_units: "LPS", start_time: Time.utc(2026, 3, 24), end_time: Time.utc(2026, 3, 24, 2), report_step: Swmm::TimeStep.new(600),
                   flow_routing: "DYNWAVE", surcharge_method: "EXTRAN", routing_step: Swmm::TimeStep.new(5), variable_step: false },
                 report.analysis_options)
  end

  def test_reads_the_routing_a_run_without_flow_routing_does_not_print
    text = OK.sub(/^\s*Flow Routing Method.*\n/, "").sub(/^\s*Surcharge Method.*\n/, "")
             .sub(/^\s*Routing Time Step.*\n/, "").sub(/^\s*Variable Time Step.*\n/, "")
    options = Swmm::Report.new(text).analysis_options
    assert_equal [nil, nil, nil, nil], options.values_at(:flow_routing, :surcharge_method, :routing_step, :variable_step)
    assert_equal "LPS", options[:flow_units]
    assert Swmm::Report.new(OK.sub("Variable Time Step ....... NO", "Variable Time Step ....... YES")).analysis_options[:variable_step]
  end

  def test_the_flooding_peak_is_placed_only_when_given_the_report_start
    report = Swmm::Report.new(OK)
    row = { node: "J1", hours: 1.76, max_rate: 103.07, max_elapsed: 90_000, max_time: nil, volume: 354.0, max_ponded_depth: 0.0 }
    assert_equal [row], report.node_flooding
    assert_equal [row.merge(max_time: Time.utc(2026, 3, 25, 1))], report.node_flooding(start: Time.utc(2026, 3, 24))
    assert_equal [row], report.node_flooding, "a start given once is not remembered"
  end

  def test_reads_the_errors_of_a_failed_run_2xx_as_the_200_the_engine_returns
    report = Swmm::Report.new(FAILED)
    refute_predicate report, :ok?
    assert_equal({ code: 200, message: "ERROR 200: one or more errors in input file.",
                   details: ["ERROR 209: undefined object X at line 14 of [CONDUITS] section: C1 J1 X 100 0.013",
                             "ERROR 211: invalid number at line 15 of [CONDUITS] section:"] }, report.error)
    assert_equal "ERROR 209: undefined object X at line 14 of [CONDUITS] section:", report.error_message(209)
    assert_nil report.continuity
    assert_equal [], report.node_flooding
    assert_equal "error", report.to_h[:status]
    assert_nil report.to_h[:continuity]
  end

  def test_exports_itself_as_plain_data
    h = Swmm::Report.new(OK).to_h
    assert_equal ["ok", "5.2.4", nil, { "C1" => 12 }], h.values_at(:status, :swmm_version, :error, :flow_instability)
    assert_equal ["J1", nil], h[:node_flooding].first.values_at(:node, :max_time)
    assert_equal [600, 5], JSON.parse(JSON.generate(h)).fetch("analysis_options").values_at("report_step", "routing_step"), "steps as seconds"
  end

  def test_a_blank_report_answers_as_one_that_printed_nothing
    report = Swmm::Report.new("")
    assert_equal [false, true, nil, [], {}], [report.swmm?, report.ok?, report.version, report.warnings, report.flow_instability]
    assert_equal({ flow_units: nil, start_time: nil, end_time: nil, report_step: nil,
                   flow_routing: nil, surcharge_method: nil, routing_step: nil, variable_step: nil }, report.analysis_options)
  end

  def test_reads_any_encoding_and_refuses_what_is_not_text
    assert Swmm::Report.new("#{OK}1000 m\xB3".b).text.end_with?("1000 m�"), "invalid bytes are replaced"
    assert_predicate Swmm::Report.new(OK).text, :frozen?
    assert_raises(TypeError) { Swmm::Report.new(nil) }
  end

  def test_reads_a_file_and_refuses_one_swmm_did_not_write
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "run.rpt"), OK)
      File.write(File.join(dir, "other.txt"), "hello")
      assert_in_delta(-0.114, Swmm::Report.read(File.join(dir, "run.rpt")).continuity[:flow_routing])
      error = assert_raises(Swmm::ReportFormatError) { Swmm::Report.read(File.join(dir, "other.txt")) }
      assert_match(/not a SWMM report/, error.message)
    end
  end

  def test_is_what_result_reads_without_the_out
    skip "libswmm5 not found: run `rake swmm:build`" unless Swmm::Engine.available?

    Dir.mktmpdir do |dir|
      result = Swmm.run(Fixtures.flooded, dir: dir)
      report = Swmm::Report.read(result.files[:rpt])
      assert_equal report.text, result.rpt.text
      assert_equal report.text, result.report, "Result#report stays the text"
      assert_equal [result.warnings, result.flow_instability, result.analysis_options], [report.warnings, report.flow_instability, report.analysis_options]
      assert_equal result.node_flooding, report.node_flooding(start: result.report_start)
      assert_equal result.series(:nodes, "J1", :depth), Swmm::OutputFile.read(result.files[:out]).series(:nodes, "J1", :depth)
    end
  end
end
