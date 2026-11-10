require_relative '../../swmm_helper'

# The CONTENT of Result#to_csv, checked against an oracle that only uses the per-object reader (series), never all_series.
RSpec.describe Swmm::Result, '#to_csv', :libswmm5 do
  def expected_csv(result, kind)
    ids = result[kind].ids
    vars = result[kind].variables
    stamps = result.times.map { it.strftime('%Y-%m-%dT%H:%M:%S') }
    table = ids.to_h { |id| [id, vars.map { |v| result[kind][id][v].values }] }
    rows = stamps.each_index.flat_map do |i|
      ids.map { |id| [stamps[i], quote(id), *table[id].map { |col| col[i].to_s }].join(',') } # nil.to_s is ""
    end
    (["time,id,#{vars.map { quote(it) }.join(',')}"] + rows).join("\n") << "\n"
  end

  def quote(field) = field.match?(/[",\n]/) ? %("#{field.gsub('"', '""')}") : field

  it 'gives node, link and system rows that match the per-object reader' do
    result = run_ok(SwmmFixtures.base)
    %i[nodes links system].each do |kind|
      expect(result[kind].to_csv).to eq(expected_csv(result, kind)), kind.to_s
    end
    expect(result.system.to_csv.lines.first).to eq("time,id,#{result.system.variables.join(',')}\n")
    expect(result.system.to_csv.lines[1]).to match(/\A2026-03-24T00:10:00,system,/)
  end

  it 'gives subcatchments with their quality columns' do
    Dir.mktmpdir do |dir|
      result = run_ok(SwmmFixtures.full(dir), 'full model')
      expect(result.subcatchments.variables).to include(:'quality:TSS')
      expect(result.subcatchments.to_csv).to eq(expected_csv(result, :subcatchments))
      expect(result.nodes.to_csv).to eq(expected_csv(result, :nodes))
    end
  end

  it 'quotes ids with a comma' do
    model = SwmmFixtures.base.merge(
      junctions: [{ name: 'J,1', elevation: 10, max_depth: 3 }, { name: 'J2', elevation: 9.5, max_depth: 3 }],
      conduits: SwmmFixtures.base[:conduits].map { it[:name] == 'C1' ? it.merge(from_node: 'J,1') : it },
      inflows: [{ node: 'J,1', series: 'Q' }]
    )
    result = run_ok(model)
    expect(result.nodes.ids).to include('J,1')
    csv = result.nodes.to_csv
    expect(csv).to eq(expected_csv(result, :nodes))
    expect(csv.lines.count { it.include?(%(,"J,1",)) }).to eq(12), 'one quoted row per period'
    expect(csv.lines.count { it.include?(',J2,') }).to eq(12)
  end

  it 'gives the same CSV when the periods are split across Ractors' do
    Dir.mktmpdir do |dir|
      result = run_ok(SwmmFixtures.full(dir), 'full model')
      kinds = %i[subcatchments nodes links system]
      was = [Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from]
      Swmm::OutputFile.ractors = 1
      expected = kinds.to_h { [it, result[it].to_csv] }
      Swmm::OutputFile.ractors = 5 # 24 periods in chunks of 5: the last Ractor gets the short one
      Swmm::OutputFile.parallel_from = 0
      expect(kinds.to_h { [it, result[it].to_csv] }).to eq(expected)
    ensure
      Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from = was
    end
  end

  it 'gives only the header for a kind without objects' do
    csv = run_ok(SwmmFixtures.base).subcatchments.to_csv
    expect(csv.lines.size).to eq(1)
    expect(csv).to match(/\Atime,id,rainfall,/)
  end
end
