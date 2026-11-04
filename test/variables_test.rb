# frozen_string_literal: true

require "test_helper"

class VariablesTest < Minitest::Test
  def test_one_constant_per_variable_the_out_saves_named_after_it
    Swmm::OutputFile::VARIABLES.each do |kind, names|
      mod = Swmm::Variables.const_get(kind.to_s.capitalize)
      assert_equal names.to_h { [_1.upcase.to_sym, _1.to_sym] }, mod.constants.to_h { [_1, mod.const_get(_1)] }, kind.to_s
    end
    assert_equal Swmm::OutputFile::KINDS.map { _1.to_s.capitalize.to_sym }.sort, Swmm::Variables.constants.sort
  end

  def test_series_read_by_constant_equal_series_read_by_name
    skip "libswmm5 not found: run `rake swmm:build`" unless Swmm::Engine.available?

    Dir.mktmpdir do |dir|
      out = Swmm::OutputFile.read(Swmm.run(Fixtures.base, dir: dir).files[:out])
      link = out.ids[:links].first
      assert_equal out.series(:links, link, "flow"), out.series(:links, link, Swmm::Variables::Links::FLOW)
      assert_equal out.series(:nodes, "J1", "depth"), out.series(:nodes, "J1", Swmm::Variables::Nodes::DEPTH)
      assert_equal out.series(:system, nil, "flooding"), out.series(:system, nil, Swmm::Variables::System::FLOODING)
    end
  end

  def test_a_variable_that_does_not_exist_is_a_name_error
    assert_raises(NameError) { Swmm::Variables::Links::FLWO }
    assert_raises(NameError) { Swmm::Variables::Pipes }
  end
end
