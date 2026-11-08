# frozen_string_literal: true

require "test_helper"

class OptionsTest < Minitest::Test
  def test_has_one_constant_per_value_the_input_accepts_named_after_it
    { FlowUnits: :flow_units, FlowRouting: :flow_routing, SurchargeMethod: :surcharge_method }.each do |name, option|
      mod = Swmm::Options.const_get(name)
      assert_equal Swmm::Schema::OPTIONS.fetch(option).to_h { [_1.to_sym, _1] }, mod.constants.to_h { [_1, mod.const_get(_1)] }, name.to_s
    end
    assert_equal Swmm::OutputFile::FLOW_UNITS.sort, Swmm::Options::FlowUnits.constants.map(&:to_s).sort, "as the .out names them"
  end

  def test_compares_with_what_the_report_reads
    report = Swmm::Report.new(<<~RPT)
      EPA STORM WATER MANAGEMENT MODEL - VERSION 5.2 (Build 5.2.4)
        Flow Units ............... LPS
        Flow Routing Method ...... DYNWAVE
        Surcharge Method ......... SLOT
    RPT
    options = report.analysis_options
    assert_equal Swmm::Options::FlowUnits::LPS, options[:flow_units]
    assert_equal Swmm::Options::FlowRouting::DYNWAVE, options[:flow_routing]
    assert_equal Swmm::Options::SurchargeMethod::SLOT, options[:surcharge_method]
  end

  def test_is_a_name_error_for_a_value_that_does_not_exist
    assert_raises(NameError) { Swmm::Options::FlowRouting::DYNAMIC }
  end
end
