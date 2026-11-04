# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Report parsing, without the engine.
class ResultTest < Minitest::Test
  REPORT = <<~RPT
    ***************************
    Time-Step Critical Elements
    ***************************
    Link C9 (60.17%)

    ********************************
    Highest Flow Instability Indexes
    ********************************
    Link C1 (12)
    Link C 2 (3)

    *********************************
    Most Frequent Nonconverging Nodes
    *********************************
    Link C8 (7)
  RPT

  FLOODING = <<~RPT
    ****************
    Analysis Options
    ****************
    Flow Units ............... LPS
    Flow Routing Method ...... DYNWAVE
    Starting Date ............ 03/24/2026 00:00:00
    Ending Date .............. 03/24/2026 02:00:00
    Antecedent Dry Days ...... 0.0
    Report Time Step ......... 00:10:00

    *********************
    Node Flooding Summary
    *********************

    Flooding refers to all water that overflows a node, whether it ponds or not.
    --------------------------------------------------------------------------
                                                               Total   Maximum
                                   Maximum   Time of Max       Flood    Ponded
                          Hours       Rate    Occurrence      Volume     Depth
    Node                 Flooded       LPS   days hr:min    10^6 ltr    Meters
    --------------------------------------------------------------------------
    J1                      1.76    103.07      0  01:00       0.354     0.000
    5AVE228                 0.01     10.74      2  03:24       0.000     0.120


    ***********************
    Outfall Loading Summary
    ***********************
    O1                     99.99     88.88      0  00:00       0.111     0.000
  RPT

  def result(report) = Swmm::Result.new(version: "5.2.4", raw: { code: 0, message: "", continuity: { runoff: 0.0, flow_routing: 7.5, quality: 0.0 } }, report: report, output: nil, files: nil)

  def test_flow_instability_is_read_from_its_own_section_only
    assert_equal({ "C1" => 12, "C 2" => 3 }, result(REPORT).flow_instability)
    assert_empty result(REPORT.sub(/Link C1.*\n.*\n/, "All links are stable.\n")).flow_instability
    assert_empty result("").flow_instability
  end

  def test_continuity_ok_compares_the_worst_error_with_the_tolerance
    refute result("").continuity_ok?
    assert result("").continuity_ok?(tolerance: 10)
  end

  # A run whose continuity is NaN (seen with libswmm5 on Linux when a subcatchment uses a snowpack) still has to export.
  def test_a_non_finite_continuity_exports_as_null_and_is_never_ok
    raw = { code: 0, message: "", continuity: { runoff: Float::NAN, flow_routing: 6.4177, quality: Float::INFINITY } }
    r = Swmm::Result.new(version: "5.2.4", raw: raw, report: "", output: nil, files: nil)
    assert_predicate r.continuity[:runoff], :nan?, "the accessor keeps the real value"
    refute r.continuity_ok?
    refute r.continuity_ok?(tolerance: 100), "NaN is never within a tolerance"
    assert_equal({ runoff: nil, flow_routing: 6.4177, quality: nil }, r.to_h[:continuity])
    assert_equal({ "runoff" => nil, "flow_routing" => 6.4177, "quality" => nil }, JSON.parse(r.to_json)["continuity"])
  end

  def test_node_flooding_reads_the_report_table
    assert_equal [
      { node: "J1", hours: 1.76, max_rate: 103.07, max_elapsed: 3600, max_time: nil, volume: 354.0, max_ponded_depth: 0.0 },
      { node: "5AVE228", hours: 0.01, max_rate: 10.74, max_elapsed: (2 * 86_400) + (3 * 3600) + (24 * 60), max_time: nil, volume: 0.0, max_ponded_depth: 0.12 }
    ], result(FLOODING).node_flooding, "max_time needs the results (see report_start); the next section is not read"
    assert_equal result(FLOODING).node_flooding, result(FLOODING.gsub("\n", "\r\n")).node_flooding, "CRLF reports"
  end

  def test_node_flooding_volumes_follow_the_unit_system
    us = result(FLOODING.sub("Flow Units ............... LPS", "Flow Units ............... CFS")).node_flooding.first
    assert_equal 47_322.917, us[:volume], "10^6 gal in ft3"
  end

  def test_node_flooding_is_empty_without_flooded_nodes
    assert_empty result(FLOODING.sub(/^Flooding refers.*?(?=\n\n\n)/m, "No nodes were flooded.")).node_flooding
    assert_empty result("").node_flooding
  end

  def test_analysis_options_are_read_from_the_report
    assert_equal({ flow_units: "LPS", start: Time.utc(2026, 3, 24), end: Time.utc(2026, 3, 24, 2), report_step: 600 }, result(FLOODING).analysis_options)
    assert_equal({ flow_units: nil, start: nil, end: nil, report_step: nil }, result("").analysis_options)
    assert_nil result(FLOODING).report_start, "it needs the start the .out saved"
  end

  def test_unknown_kinds_are_an_unknown_object
    assert_equal ["system"], result("").ids(:system), "the system needs no results"
    assert_equal ["system"], result("").ids("system")
    assert_raises(Swmm::UnknownObject) { result("").ids(:pipes) }
    assert_raises(Swmm::UnknownObject) { result("").variables(nil) }
    assert_raises(Swmm::UnknownObject) { result("").to_csv(:pipes) }
  end

  def test_read_rejects_a_report_swmm_did_not_write
    Dir.mktmpdir do |dir|
      rpt = File.join(dir, "notes.rpt")
      ["just some text\n", "", FLOODING].each do |text|
        File.write(rpt, text)
        error = assert_raises(Swmm::ReportFormatError) { Swmm.read(rpt: rpt) }
        assert_match(/not a SWMM report/, error.message)
      end
    end
  end

  def test_read_takes_the_version_from_an_owa_banner
    Dir.mktmpdir do |dir|
      rpt = File.join(dir, "owa.rpt")
      File.write(rpt, "\r\n  OWA STORM WATER MANAGEMENT MODEL - VERSION v5.2.1 (OWA 2023-03-28)\r\n#{FLOODING}")
      assert_equal "5.2.1", Swmm.read(rpt: rpt).version
      File.write(rpt, "\n  EPA STORM WATER MANAGEMENT MODEL - VERSION 5.2 (Build 5.2.4)\n#{FLOODING}")
      assert_equal "5.2.4", Swmm.read(rpt: rpt).version
    end
  end

  def test_a_failed_run_still_exports_a_nil_continuity
    r = Swmm::Result.new(version: "5.2.4", raw: { code: 200, message: "ERROR 200", continuity: nil }, report: "", output: nil, files: nil)
    assert_nil r.to_h[:continuity]
    assert_nil JSON.parse(r.to_json)["continuity"]
  end
end
