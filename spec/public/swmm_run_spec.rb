require_relative '../swmm_helper'

RSpec.describe Swmm, '.run', :libswmm5 do
  it 'returns the output contract' do
    result = run_ok(SwmmFixtures.base)
    expect(result.version).to match(/\A5\.\d+\.\d+\z/)
    expect(result.status).to eq('ok')
    expect(result.error).to be_nil
    expect(result.times.size).to eq(12), '2 h at a 10 min report step'
    expect(result.times.first).to eq(Time.utc(2026, 3, 24, 0, 10))
    expect(result.nodes.ids).to eq(%w[J1 J2 O1])
    expect(result.continuity[:flow_routing]).to be_within(1).of(0)
    expect(result).to be_continuity_ok
    expect(result).not_to be_continuity_ok(tolerance: 0.01), 'the base model has about -0.14 % flow routing error'
    expect(result.flow_instability).to be_empty
    flow = result.links['C2'][:flow].values
    expect(flow.size).to eq(12)
    expect(flow.max).to be > 60, 'the 80 L/s hydrograph reaches the outlet'
    expect(result.to_h[:output][:units][:links].slice(:flow, :depth, :velocity)).to eq(flow: 'LPS', depth: 'm', velocity: 'm/s')
  end

  it 'carries the same data in to_h, JSON and CSV' do
    result = described_class.run(SwmmFixtures.base)
    data = JSON.parse(result.to_json, symbolize_names: true)
    expect(data.keys).to eq(%i[status swmm_version error warnings continuity flow_instability files output])
    expect(data[:output][:nodes][:J1][:depth]).to eq(result.nodes['J1'][:depth].values)
    expect(data[:output][:times].size).to eq(result.times.size)
    expect(described_class.run(SwmmFixtures.base).to_h(series: false)[:output][:nodes]['J1'][:depth]).to be_nil
    csv = result.links.to_csv.lines
    expect(csv.first).to eq("time,id,flow,depth,velocity,volume,capacity\n")
    expect(csv.size).to eq(1 + (12 * 2)), 'one row per link per period'
  end

  it 'gives engine errors back in the result' do
    model = SwmmFixtures.base.merge(conduits: [{ name: 'C1', from_node: 'J1', to_node: 'NOPE', length: 1, roughness: 0.01, in_offset: 0, out_offset: 0 }])
    result = described_class.run(model)
    expect(result).not_to be_ok
    expect(result.error[:code]).to eq(200)
    expect(result).not_to be_continuity_ok
    expect(result.flow_instability).to be_empty
    expect(result.error[:details].first).to match(/ERROR 209: undefined object NOPE at line \d+ of \[CONDUIT\] section: C1 J1 NOPE/)
    expect { result.times }.to raise_error(Swmm::Error)
  end

  it 'raises contract violations before the engine runs' do
    expect { described_class.run(junctions: [{ name: 'J' }]) }.to raise_error(Swmm::InvalidInput)
  end

  it 'keeps the files in dir: and runs an existing .inp' do
    Dir.mktmpdir do |dir|
      first = described_class.run(SwmmFixtures.base, dir: dir)
      expect(Dir.children(dir).sort).to eq(%w[model.inp model.out model.rpt])
      expect(first.files[:inp]).to eq(File.join(dir, 'model.inp'))
      again = described_class.run(first.files[:inp])
      expect(again.nodes['J2'][:depth].values).to eq(first.nodes['J2'][:depth].values)
      expect(again.files).to be_nil, 'no dir: => temp files are removed'
    end
  end

  it 'saves only the reported objects' do
    result = run_ok(SwmmFixtures.base.merge(report: { nodes: %w[J2], links: 'NONE' }))
    expect(result.nodes.ids).to eq(%w[J2])
    expect(result.links.ids).to be_empty
    expect(result.system['system'][:total_inflow].values.size).to eq(12), 'system results are always there'
  end

  it 'flags an unstable model that finishes ok' do
    short = SwmmFixtures.base.merge(
      options: SwmmFixtures.base[:options].merge(routing_step: 60, end_time: '06:00'),
      conduits: [{ name: 'C1', from_node: 'J1', to_node: 'J2', length: 3, roughness: 0.013, in_offset: 0, out_offset: 0 },
                 { name: 'C2', from_node: 'J2', to_node: 'O1', length: 3, roughness: 0.013, in_offset: 0, out_offset: 0 }],
      timeseries: [{ name: 'Q', points: [[0, 0], [0.5, 400], [1, 20], [1.5, 300], [2, 0], [3, 250], [4, 0]] }]
    )
    result = run_ok(short)
    expect(result).not_to be_continuity_ok, "flow routing error was #{result.continuity[:flow_routing]} %"
    expect(result.flow_instability).not_to be_empty
    expect(result.flow_instability.all? { |id, turns| id.start_with?('C') && turns.positive? }).to be(true)
  end

  it 'run_many matches sequential runs, in order' do
    models = [10, 20, 40, 80, 160].map { |q| SwmmFixtures.base.merge(timeseries: [{ name: 'Q', points: [[0, 0], [0.5, q / 2.0], [1, q], [2, 0]] }]) }
    bad = SwmmFixtures.base.merge(conduits: [{ name: 'C1', from_node: 'J1', to_node: 'NOPE', length: 1, roughness: 0.01, in_offset: 0, out_offset: 0 }])
    results = described_class.run_many(models.first(2) + [bad] + models.last(3), workers: 3)
    expect(results.map(&:ok?)).to eq([true, true, false, true, true, true])
    expect(results[2].error[:code]).to eq(200)
    (models.first(2) + models.last(3)).zip(results.values_at(0, 1, 3, 4, 5)).each do |model, result|
      expect(result.links['C2'][:flow].values).to eq(described_class.run(model).links['C2'][:flow].values)
    end
    expect(Swmm::Engine.pool(3).uniq.size).to eq(3), 'each worker has its own copy of the library'
  end

  it 'run_many checks every contract before running anything' do
    expect { described_class.run_many([SwmmFixtures.base, { junctions: [{ name: 'J' }] }]) }.to raise_error(Swmm::InvalidInput)
    expect(described_class.run_many([])).to eq([])
  end
end
