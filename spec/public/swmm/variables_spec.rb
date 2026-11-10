require_relative '../../swmm_helper'

RSpec.describe Swmm::Variables do
  it 'has one constant per variable the .out saves, named after it' do
    Swmm::OutputReader::VARIABLES.each do |kind, names|
      mod = described_class.const_get(kind.to_s.capitalize)
      expect(mod.constants.to_h { [it, mod.const_get(it)] }).to eq(names.to_h { [it.upcase.to_sym, it.to_sym] }), kind.to_s
    end
    expect(described_class.constants).to match_array(Swmm::OutputFile::KINDS.map { it.to_s.capitalize.to_sym })
  end

  it 'reads series like the variable names do', :libswmm5 do
    Dir.mktmpdir do |dir|
      out = Swmm::OutputFile.new(bytes: File.binread(Swmm.run(SwmmFixtures.base, dir: dir).files[:out]))
      link = out.links.first
      expect(link[Swmm::Variables::Links::FLOW].values).to eq(link['flow'].values)
      expect(out.links.variables).to include(Swmm::Variables::Links::FLOW), 'the constants are the names the collections give'
      expect(out.nodes['J1'][Swmm::Variables::Nodes::DEPTH].values).to eq(out.nodes['J1']['depth'].values)
      expect(out.system['system'][Swmm::Variables::System::FLOODING].values).to eq(out.system['system']['flooding'].values)
    end
  end

  it 'is a NameError for a variable that does not exist' do
    expect { Swmm::Variables::Links::FLWO }.to raise_error(NameError)
    expect { Swmm::Variables::Pipes }.to raise_error(NameError)
  end
end
