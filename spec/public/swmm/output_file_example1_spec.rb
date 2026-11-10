require_relative '../../swmm_helper'

# Oracle 1 of spec/support/swmm_oracle.rb: EPA's Example1.out. Does not need the engine, so it must never skip.
# spec/fixtures/Example1.out: copied unchanged from tests/outfile/data/Example1.out of the EPA SWMM repository (tag v5.2.4), a
# US-government (EPA) test file written by SWMM 5.1.0 (output format code 51000).
# Expected numbers: tests/outfile/test_output.cpp of the same tree (indexes there are 0-based; EPA compares to 3 decimals).
RSpec.describe Swmm::OutputFile, 'with EPA Example1.out' do
  let(:bytes) { File.binread(File.expand_path('../../fixtures/Example1.out', __dir__)) }
  let(:out) { described_class.new(bytes: bytes) }

  # Weighted sums sum(value * (object index + 1) * (period + 1)) over the WHOLE file, per variable, computed once with EPA's
  # libswmm-output (SMO_get{Subcatch,Node,Link,System}Result, SWMM 5.2.4 src/outfile compiled from the same tag) over Example1.out.
  # The weights make a swapped object or period change the sum, not only a wrong variable.
  let(:golden_sums) do
    {
      subcatchments: [819.000012, 0, 0, 606.997588, 2515.04905, 0, 0, 0, 198_334.897, 39_666.9794],
      nodes: [19_040.8799, 69_179_145, 0, 3437.11439, 36_045.5913, 44.962549, 524_483.653, 104_896.731],
      links: [29_408.2135, 4418.14009, 67_986.6882, 1_421_569.67, 1918.51409, 389_519.254, 77_903.8507],
      system: [46_620, 22.7500003, 0, 14.8531609, 704.942831, 0, 0, 0, 0, 704.942831, 22.4812745, 686.429877, 176_337.893, 0]
    }
  end

  def expect_close(expected, actual, msg = nil)
    expect(actual.size).to eq(expected.size), msg
    expected.zip(actual).each_with_index do |(e, a), i|
      expect(a).to be_within(1e-5 * [1, e.abs].max).of(e), "#{msg} [#{i}]" # tighter than EPA's own 1e-3
    end
  end

  it 'is the EPA file' do
    expect(bytes.bytesize).to eq(44_018)
    expect(bytes.unpack1('l<', offset: 4)).to eq(51_000), 'SWMM 5.1.0 output format code (test_getVersion)'
  end

  it 'has the project size of test_getProjectSize' do
    expect([out.subcatchments.ids.size, out.nodes.ids.size, out.links.ids.size, out.pollutants.size]).to eq([8, 14, 13, 2])
  end

  it 'has the node and link types the input block saves' do
    expect(out.nodes.types.values.tally).to eq('JUNCTION' => 13, 'OUTFALL' => 1)
    expect(out.nodes['18'].type).to eq('OUTFALL')
    expect(out.subcatchments.first.type).to be_nil, 'subcatchments have no type'
    expect(out.links.types.values.tally).to eq('CONDUIT' => 13)
    expect(out.nodes.types.keys).to eq(out.nodes.ids)
    expect(out.nodes.count_by_type).to eq('JUNCTION' => 13, 'OUTFALL' => 1)
    expect(out.links.count_by_type).to eq('CONDUIT' => 13)
    expect([out.subcatchments.size, out.nodes.size, out.links.size, out.system.size, out.pollutants.size]).to eq([8, 14, 13, 1, 2])
    expect { out.subcatchments.types }.to raise_error(Swmm::UnknownObject, 'subcatchments have no type')
    expect { out.system.types }.to raise_error(Swmm::UnknownObject)
    expect { out.system.count_by_type }.to raise_error(Swmm::UnknownObject)
  end

  it 'has the names, pollutants and units of the C++ test' do
    expect(out.flow_units).to eq('CFS') # test_getFlowUnits: 0
    expect(out.pollutants).to eq(%w[TSS Lead])
    expect(out.nodes.ids[1]).to eq('10'), 'test_getElementName: node index 1'
    expect(out.nodes.units.select { |name, _| name.start_with?('quality:') }).to eq('quality:TSS': 'MG/L', 'quality:Lead': 'UG/L') # {SMO_MG, SMO_UG}
    expect(out.nodes.units[:depth]).to eq('ft'), 'unit system SMO_US'
    expect(out.nodes.unit('depth')).to eq('ft')
    expect(out.subcatchments.units[:rainfall]).to eq('in/h')
    expect(out.periods).to eq(36) # test_getTimes SMO_numPeriods
    expect(out.report_step.in_seconds).to eq(3600) # test_getTimes SMO_reportStep
    expect(out.start_time).to eq(Time.utc(1998, 1, 1)) # test_getStartDate: 35796.0 days since 1899-12-30
    expect(out.times.first).to eq(Time.utc(1998, 1, 1) + 3600)
    expect(out.times.last).to eq(Time.utc(1998, 1, 2, 12)), '36 periods of 1 h after the start'
    expect([out.start_time, out.end_time]).to eq([out.start_time, out.times.last])
    expect(out.times.each_cons(2).map { |a, b| b - a }.uniq).to eq([3600.0])
  end

  it 'has the series of test_getSubcatchSeries and test_getSystemSeries' do
    expect_close [0.0, 1.2438242, 2.5639679, 4.524055, 2.5115132, 0.69808137, 0.040894926, 0.011605669, 0.00509294, 0.0027438672],
                 out.subcatchments['2'][:runoff].values.first(10), 'subcatchment index 1, runoff_rate, periods 0-9'
    expect_close [0.0, 6.216825, 13.030855, 24.252975, 14.172027, 4.1949716, 0.322329, 0.056010, 0.024938, 0.012474],
                 out.system['system'][:runoff].values.first(10), 'system runoff_flow, periods 0-9'
  end

  it 'has one period of every kind as in the C++ result tests' do
    sub = out.subcatchments.to_h['2'] # test_getSubcatchResult(period 1, subcatchment 1)
    expect_close [0.5, 0.0, 0.0, 0.125, 1.2438242, 0.0, 0.0, 0.0, 33.481991, 6.6963983], out.subcatchments.variables.map { sub[it][1] }, 'subcatchment'
    node = out.nodes.to_h['13'] # test_getNodeResult(period 2, node 2)
    expect_close [0.296234, 995.296204, 0.0, 1.302650, 1.302650, 0.0, 15.361463, 3.072293], out.nodes.variables.map { node[it][2] }, 'node'
    link = out.links.to_h['6'] # test_getLinkResult(period 3, link 3): 4th link of the file
    expect_close [4.631762, 1.0, 5.8973422, 314.15927, 1.0, 19.070757, 3.8141515], out.links.variables.map { link[it][3] }, 'link'
    sys = out.system.to_h['system'] # test_getSystemResult(period 4)
    expect_close [70.0, 0.1, 0.0, 0.19042271, 14.172027, 0.0, 0.0, 0.0, 0.0, 14.172027, 0.55517411, 13.622702, 2913.0793, 0.0],
                 out.system.variables.map { sys[it][4] }, 'system'
  end

  it 'gives the same numbers through a series and to_h' do
    expect(out.nodes.to_h['13'][:total_inflow]).to eq(out.nodes['13'][:total_inflow].values)
    expect(out.system.variables.size).to eq(14), 'a 5.1 file has 14 system variables (5.2 adds potential_et)'
    expect(out.system.variables).not_to include(:potential_et)
  end

  it 'gives in frames, a row per period, what to_h gives per object' do
    described_class::KINDS.each do |kind|
      ids = out[kind].ids
      all = out[kind].to_h
      out[kind].variables.each do |name|
        frames = out[kind].frames(name).rows
        expect(frames.size).to eq(out.times.size), "#{kind} #{name}"
        expect(frames.transpose).to eq(ids.map { all[it][name] }), "#{kind} #{name}"
      end
    end
  end

  it 'gives the same frames read from the file, a span at a time' do
    saved = described_class.chunk_bytes
    described_class.chunk_bytes = 1 # a period per span
    file = described_class.read(File.expand_path('../../fixtures/Example1.out', __dir__))
    expect(file.links.frames(:flow).rows).to eq(out.links.frames(:flow).rows)
    expect(file.nodes.frames('depth').rows).to eq(out.nodes.frames('depth').rows)
  ensure
    described_class.chunk_bytes = saved
  end

  it 'fails loudly on frames of what the file does not have' do
    expect { out.links.frames(:nope).rows }.to raise_error(Swmm::UnknownObject, /links has no variable :nope/)
    expect { out[:pipes].frames(:flow).rows }.to raise_error(Swmm::UnknownObject, /unknown kind :pipes/)
  end

  it "agrees with EPA's libswmm-output on every value of the file" do
    golden_sums.each do |kind, sums|
      all = out[kind].to_h
      names = out[kind].variables
      expect(names.size).to eq(sums.size), kind.to_s
      names.each_with_index do |name, v|
        got = all.each_with_index.sum { |(_id, vars), i| vars[name].each_with_index.sum { |x, p| x * (i + 1) * (p + 1) } }
        expect(got).to be_within([sums[v].abs * 1e-6, 1e-9].max).of(sums[v]), "#{kind} #{name}"
      end
    end
  end
end
