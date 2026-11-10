require_relative '../../swmm_helper'

RSpec.describe Swmm::Model do
  let(:per_type) do
    %w[nodes_junction nodes_outfall nodes_storage nodes_divider links_conduit links_pump links_orifice links_weir links_outlet].map { :"count_#{it}" }
  end
  let(:totals) { %i[total_nodes total_links total_subcatchments total_pollutants] }

  it 'is what Input.read / .parse give, and still the Hash Input takes' do
    model = Swmm::Input.parse(Swmm::Input.new(SwmmFixtures.base).to_inp)
    expect(model).to be_a(described_class).and be_a(Hash)
    model[:options][:end_time] = '01:00'
    expect(Swmm::Input.new(model).to_inp).to include('END_TIME             01:00')
    expect(model).to eq(model.to_h), 'equal to the plain Hash'
  end

  it 'counts its objects per type and in total, as the .out does', :libswmm5 do
    Dir.mktmpdir do |dir|
      hash = SwmmFixtures.full(dir)
      model = Swmm::Input.parse(Swmm::Input.new(hash).to_inp)
      output = Swmm.run(hash, dir: dir).output
      expect(model.count_nodes).to eq(%i[junctions outfalls storage dividers].zip(%w[JUNCTION OUTFALL STORAGE DIVIDER]).to_h { |section, type| [type, hash[section].size] })
      expect(model.count_links.keys).to eq(%w[CONDUIT PUMP ORIFICE WEIR OUTLET])
      expect(model.total_nodes).to eq(model.count_nodes.values.sum)
      expect(model.count_nodes).to eq(output.nodes.count_by_type)
      expect(model.count_links).to eq(output.links.count_by_type)
      per_type.each do |name|
        kind, type = name.to_s.delete_prefix('count_').split('_')
        expect(model.public_send(name)).to eq(output[kind].count_by_type.fetch(type.upcase, 0)), name.to_s
      end
      expect(totals.map { model.public_send(it) }).to eq([output.nodes.size, output.links.size, output.subcatchments.size, output.pollutants.size])
      expect(per_type.map { model.public_send(it) }).to all(be_positive), 'the full model has every type'
    end
  end

  it 'counts a Hash of its own: String keys, raw rows, types it has none of' do
    model = described_class['junctions' => [{ name: 'J1', elevation: 1 }, %w[J2 1]], outfalls: [{ name: 'O1', elevation: 0, type: 'FREE' }], conduits: []]
    expect(model.count_nodes).to eq('JUNCTION' => 2, 'OUTFALL' => 1)
    expect(model.count_links).to eq({})
    expect([model.total_nodes, model.total_links, model.total_subcatchments, model.total_pollutants]).to eq([3, 0, 0, 0])
    expect([model.count_nodes_junction, model.count_nodes_divider, model.count_links_conduit]).to eq([2, 0, 0])
    expect(described_class[{}].count_nodes).to eq({})
  end
end
