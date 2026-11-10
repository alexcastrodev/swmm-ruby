require_relative '../../swmm_helper'

RSpec.describe Swmm::Options do
  it 'has one constant per value the input accepts, named after it' do
    { FlowUnits: :flow_units, FlowRouting: :flow_routing, SurchargeMethod: :surcharge_method }.each do |name, option|
      mod = described_class.const_get(name)
      expect(mod.constants.to_h { [it, mod.const_get(it)] }).to eq(Swmm::Schema::OPTIONS.fetch(option).to_h { [it.to_sym, it] }), name.to_s
    end
    expect(described_class::FlowUnits.constants.map(&:to_s)).to match_array(Swmm::OutputReader::FLOW_UNITS), 'as the .out names them'
  end

  it 'compares with what the report reads' do
    report = Swmm::Report.new(<<~RPT)
      EPA STORM WATER MANAGEMENT MODEL - VERSION 5.2 (Build 5.2.4)
        Flow Units ............... LPS
        Flow Routing Method ...... DYNWAVE
        Surcharge Method ......... SLOT
    RPT
    expect(report.analysis_options).to include(flow_units: Swmm::Options::FlowUnits::LPS, flow_routing: Swmm::Options::FlowRouting::DYNWAVE,
                                               surcharge_method: Swmm::Options::SurchargeMethod::SLOT)
  end

  it 'is a NameError for a value that does not exist' do
    expect { Swmm::Options::FlowRouting::DYNAMIC }.to raise_error(NameError)
  end
end
