require_relative '../../swmm_helper'

# The objects of a kind and their values (Collection, Element, Series, Frames, Record) on EPA's Example1.out: no engine.
# 8 subcatchments, 14 nodes (13 junctions, outfall "18"), 13 conduits, 2 pollutants (TSS, Lead), 36 hourly periods.
RSpec.describe Swmm::Collection do
  let(:path) { File.expand_path('../../fixtures/Example1.out', __dir__) }
  let(:out) { Swmm::OutputFile.read(path) }
  let(:links) { out.links }
  let(:link_vars) { %i[flow depth velocity volume capacity quality:TSS quality:Lead] }

  describe 'the objects' do
    it 'has the ids, Symbol variables and units the file saved, per kind' do
      expect(links.kind).to eq(:links)
      expect(links.ids.first(3)).to eq(%w[1 4 5])
      expect(links.variables).to eq(link_vars)
      expect(links.units).to eq(flow: 'CFS', depth: 'ft', velocity: 'ft/s', volume: 'ft3', capacity: 'fraction', 'quality:TSS': 'MG/L', 'quality:Lead': 'UG/L')
      expect(links.unit(:velocity)).to eq('ft/s')
      expect(links.unit('quality:Lead')).to eq('UG/L'), 'a variable may be a String'
      expect([out.subcatchments.size, out.nodes.size, links.size, out.system.size]).to eq([8, 14, 13, 1])
      expect(out.system.ids).to eq(['system'])
    end

    it 'is the same Collection for a kind as a Symbol, a String or its method, and on the Result' do
      expect(out[:links]).to equal(links)
      expect(out['links']).to equal(links)
      result = Swmm::Result.new(version: '5.1.0', raw: { code: 0 }, report: '', output: out, files: nil)
      expect(result.links).to equal(links)
      expect(result['nodes']).to equal(out.nodes)
    end

    it 'goes through its objects as Elements, in the order of ids' do
      expect(links.map(&:id)).to eq(links.ids)
      expect(links.each).to be_a(Enumerator)
      expect(links.each.size).to eq(13)
      expect(out.nodes.find { it.type == 'OUTFALL' }.id).to eq('18')
      expect(out.nodes.count { it.type == 'JUNCTION' }).to eq(13)
    end

    it 'gives the types of nodes and links, and how many of each' do
      expect(out.nodes.types['18']).to eq('OUTFALL')
      expect(out.nodes.count_by_type).to eq('JUNCTION' => 13, 'OUTFALL' => 1)
      expect(links.count_by_type).to eq('CONDUIT' => 13)
      expect(links['1'].type).to eq('CONDUIT')
      expect(out.subcatchments['1'].type).to be_nil
      expect(out.system['system'].type).to be_nil
    end

    it 'raises UnknownObject for what the file does not have' do
      expect { links['nope'] }.to raise_error(Swmm::UnknownObject, 'links has no "nope"')
      expect { links.unit(:nope) }.to raise_error(Swmm::UnknownObject, /links has no variable :nope \(flow, depth/)
      expect { links.frames(nil) }.to raise_error(Swmm::UnknownObject)
      expect { links.frames(1) }.to raise_error(Swmm::UnknownObject)
      expect { out.subcatchments.types }.to raise_error(Swmm::UnknownObject, 'subcatchments have no type')
      expect { out.system.count_by_type }.to raise_error(Swmm::UnknownObject, 'system have no type')
      expect { out[:pipes] }.to raise_error(Swmm::UnknownObject, 'unknown kind :pipes (subcatchments, nodes, links, system)')
    end

    it 'hands out ids, variables and units the caller cannot change' do
      expect(links.ids).to be_frozen
      expect(links.variables).to be_frozen
      expect(links.units).to be_frozen
      expect(out.system.ids).to be_frozen
    end
  end

  describe 'an Element and its Series' do
    it 'gives the values of one variable with their times and unit' do
      series = links['1'][:flow]
      expect(series).to be_a(Swmm::Series)
      expect([series.kind, series.id, series.variable, series.unit]).to eq([:links, '1', :flow, 'CFS'])
      expect(series.times).to eq(out.times)
      expect(series.size).to eq(36)
      expect(series.values).to eq(links.to_h['1'][:flow])
      expect(links['1']['flow']).to eq(series), 'a Series is a value: equal when its members are'
    end

    it 'goes through [time, value] pairs, and is a { time => value } Hash' do
      series = out.nodes['9'][:depth]
      expect(series.first).to eq([out.times.first, series.values.first])
      expect(series.to_a).to eq(out.times.zip(series.values))
      expect(series.to_h).to eq(out.times.zip(series.values).to_h)
      expect(series.each.size).to eq(36)
      expect(series.max_by { |_time, value| value }.last).to eq(series.values.max)
    end

    it 'gives every variable of the object' do
      all = links['1'].series
      expect(all.keys).to eq(link_vars)
      expect(all.transform_values(&:values)).to eq(links.to_h['1'])
    end

    it 'reads the system as its one object' do
      expect(out.system['system'][:rainfall].values.first(3)).to eq([0.25, 0.5, 0.8])
      expect(out.system['system'][:rainfall].unit).to eq('in/h')
    end
  end

  describe '#frames' do
    it 'gives one variable of every object, a row per period' do
      frames = links.frames(:depth)
      expect(frames).to be_a(Swmm::Frames)
      expect([frames.kind, frames.variable, frames.unit, frames.ids, frames.times]).to eq([:links, :depth, 'ft', links.ids, out.times])
      expect(frames.size).to eq(36)
      expect(frames.rows.transpose).to eq(links.ids.map { links.to_h[it][:depth] })
      expect(frames.first).to eq([out.times.first, frames.rows.first])
      expect(frames.to_h.keys).to eq(%i[kind variable unit times ids rows]), 'to_h is the members, as a Data'
    end
  end

  describe '#records' do
    it 'gives a Record per period and object, time-major, with a member per variable' do
      records = links.records
      expect(records).to be_a(Enumerator)
      expect(records.size).to eq(36 * 13)
      first = records.first
      expect(first).to be_a(Swmm::Record)
      expect([first.time, first.id]).to eq([out.times.first, '1'])
      expect(first.to_h.keys).to eq(%i[time id].concat(link_vars))
      expect(records.first(13).map(&:id)).to eq(links.ids)
      expect(records.map(&:time).uniq).to eq(out.times)
    end

    it 'holds the values the series hold' do
      by_id = links.records.group_by(&:id)
      expect(by_id['1'].map(&:flow)).to eq(links['1'][:flow].values)
      expect(by_id['4'].map { it[:'quality:TSS'] }).to eq(links['4'][:'quality:TSS'].values), 'a pollutant by name'
      expect(by_id['4'].map { it['depth'] }).to eq(links['4'][:depth].values), 'a String name too'
      expect(by_id['1'].first.values).to eq(links['1'].series.transform_values { it.values.first })
    end

    it 'reads a span of periods at a time, whatever its size' do
      saved = Swmm::OutputFile.chunk_bytes
      expected = out.nodes.records.map(&:to_h)
      Swmm::OutputFile.chunk_bytes = 1 # a period per span
      expect(Swmm::OutputFile.read(path).nodes.records.map(&:to_h)).to eq(expected)
      expect(Swmm::OutputFile.new(bytes: File.binread(path)).nodes.records.to_a).to eq(out.nodes.records.to_a), 'records of the same kind compare equal across readers'
    ensure
      Swmm::OutputFile.chunk_bytes = saved
    end

    it 'raises NoMethodError for a name that is not a member' do
      expect { links.records.first[:nope] }.to raise_error(NoMethodError)
    end
  end

  describe '#to_csv' do
    it 'is a row per record, under the header of the variables' do
      csv = links.to_csv.lines
      expect(csv.first).to eq("time,id,#{link_vars.join(',')}\n")
      expect(csv.size).to eq(1 + (36 * 13))
      first = links.records.first
      expect(csv[1]).to eq("1998-01-01T01:00:00,1,#{first.values.values.join(',')}\n")
      expect(links.to_csv(StringIO.new).string).to eq(links.to_csv)
    end
  end

  describe Swmm::OutputFile do
    it 'takes the bytes or the path by name, never both' do
      bytes = File.binread(path)
      expect(described_class.new(bytes: bytes).links.ids).to eq(links.ids)
      expect(described_class.new(path: path).path).to eq(path)
      expect { described_class.new(bytes: bytes, path: path) }.to raise_error(ArgumentError, /not both/)
      expect { described_class.new }.to raise_error(TypeError, /must be a String/)
      expect { described_class.new(bytes: 42) }.to raise_error(TypeError)
    end

    it 'shows what it holds' do
      expect(out.inspect).to eq("#<Swmm::OutputFile #{path}, 36 periods, 8 subcatchments, 14 nodes, 13 links, 1 system>")
      expect(links.inspect).to start_with('#<Swmm::Collection links: 13 (flow, depth,')
      expect(links['1'].inspect).to eq('#<Swmm::Element links "1">')
      expect(links['1'][:flow].inspect).to eq('#<Swmm::Series links "1" flow (CFS): 36 values>')
      expect(links.frames(:flow).inspect).to eq('#<Swmm::Frames links flow (CFS): 36 periods x 13 objects>')
      expect(links.records.first.inspect).to start_with('#<Swmm::Record time=1998-01-01 01:00:00 UTC, id="1", flow=0.0')
    end
  end
end
