# frozen_string_literal: true

require "test_helper"

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
end
