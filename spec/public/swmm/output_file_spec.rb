require_relative '../../swmm_helper'

RSpec.describe Swmm::OutputFile, :libswmm5 do
  it 'rejects files that are not SWMM output' do
    expect { described_class.new(bytes: 'x' * 100) }.to raise_error(Swmm::OutputFormatError)
    expect { described_class.new(bytes: '') }.to raise_error(Swmm::OutputFormatError)
  end

  it 'rejects a truncated file' do
    Dir.mktmpdir do |dir|
      bytes = File.binread(Swmm.run(SwmmFixtures.base, dir: dir).files[:out])
      expect(described_class.new(bytes: bytes).periods).to eq(12)
      expect { described_class.new(bytes: bytes[0, bytes.bytesize - 100] + bytes[-24, 24]) }.to raise_error(Swmm::OutputFormatError)
    end
  end

  it 'fails loudly on series lookups' do
    Dir.mktmpdir do |dir|
      out = described_class.new(bytes: File.binread(Swmm.run(SwmmFixtures.base, dir: dir).files[:out]))
      expect { out.nodes['nope'][:depth].values }.to raise_error(Swmm::UnknownObject, 'nodes has no "nope"') { |error|
        expect(error).to be_a(Swmm::Error), 'one rescue Swmm::Error covers every reading error'
      }
      expect { out.nodes['J1'][:nope].values }.to raise_error(Swmm::UnknownObject, 'nodes has no variable :nope (depth, head, volume, lateral_inflow, total_inflow, overflow)')
      expect { out[:pipes]['J1'][:depth].values }.to raise_error(Swmm::UnknownObject, 'unknown kind :pipes (subcatchments, nodes, links, system)')
      expect { out[nil]['J1'][:depth].values }.to raise_error(Swmm::UnknownObject)
      expect { out[:pipes].to_h }.to raise_error(Swmm::UnknownObject)
      expect(out['nodes']['J1']['depth'].values).to eq(out.nodes['J1'][:depth].values), 'kinds and variables may be Strings'
    end
  end

  it 'gives every node and link the type of the input section it came from' do
    Dir.mktmpdir do |dir|
      model = SwmmFixtures.full(dir)
      result = Swmm.run(model, dir: dir)
      sections = { nodes: { junctions: 'JUNCTION', outfalls: 'OUTFALL', storage: 'STORAGE', dividers: 'DIVIDER' },
                   links: { conduits: 'CONDUIT', pumps: 'PUMP', orifices: 'ORIFICE', weirs: 'WEIR', outlets: 'OUTLET' } }
      sections.each do |kind, types|
        expected = types.flat_map { |section, type| Array(model[section]).map { [it[:name], type] } }.to_h
        expect(result[kind].types).to eq(expected), kind.to_s
        expect(result[kind].types.values.uniq).to match_array(described_class::TYPES.fetch(kind)), "every #{kind} type"
        expect(result[kind].count_by_type).to eq(expected.values.tally.sort_by { described_class::TYPES.fetch(kind).index(it.first) }.to_h)
        expect(result[kind].size).to eq(expected.size)
        expect(result[kind].map(&:type)).to eq(expected.values), 'each Element has its type'
      end
    end
  end

  it 'gives in to_h what each series gives for every object' do
    Dir.mktmpdir do |dir|
      out = described_class.new(bytes: File.binread(Swmm.run(SwmmFixtures.base, dir: dir).files[:out]))
      described_class::KINDS.each do |kind|
        all = out[kind].to_h
        expect(all.keys).to eq(out[kind].ids)
        all.each do |id, vars|
          expect(vars.keys).to eq(out[kind].variables)
          vars.each { |name, values| expect(values).to eq(out[kind][id][name].values), "#{kind} #{id} #{name}" }
        end
      end
    end
  end

  it 'gives in to_h read in Ractors what the sequential read gives' do
    Dir.mktmpdir do |dir|
      bytes = File.binread(Swmm.run(SwmmFixtures.base, dir: dir).files[:out])
      sequential = described_class.new(bytes: bytes)
      parallel = described_class.new(bytes: bytes)
      was = [described_class.ractors, described_class.parallel_from]
      described_class.ractors = 1
      expected = described_class::KINDS.to_h { [it, sequential[it].to_h] }
      described_class.ractors = 2 # 3 nodes over 2 Ractors: the last one gets the short chunk
      described_class.parallel_from = 0
      expect(described_class::KINDS.to_h { [it, parallel[it].to_h] }).to eq(expected)
      expect(parallel.nodes.to_h.dig('J1', :depth)).not_to be_frozen, 'callers get plain arrays'
    ensure
      described_class.ractors, described_class.parallel_from = was
    end
  end
end
