require_relative '../../swmm_helper'
require_relative '../../support/swmm_oracle'

# R6: golden contract of Result#to_h / #to_json (see SwmmGolden)
RSpec.describe Swmm::Result, 'output contract', :libswmm5 do
  def expect_golden(golden, actual, what)
    problems = SwmmGolden.diff(golden, actual)
    expect(problems).to be_empty, "#{what}: the output contract changed (update the golden only on purpose):\n  #{problems.first(25).join("\n  ")}"
  end

  it 'gives the golden contract in to_h without series' do
    result = run_ok(SwmmFixtures.base)
    expect_golden SwmmGolden.golden(series: false), result.to_h(series: false), 'to_h(series: false)'
  end

  it 'gives the same structure, with Float arrays, in to_h with series' do
    result = run_ok(SwmmFixtures.base)
    expect_golden SwmmGolden.golden(series: true), result.to_h, 'to_h'
    expect_golden SwmmGolden.golden(series: true), result.to_h(series: true), 'to_h(series: true)'
  end

  it 'gives the golden contract as plain JSON in to_json' do
    result = run_ok(SwmmFixtures.base)
    json = JSON.parse(result.to_json)
    stringify = lambda do |g|
      case g
      when Hash then g.to_h { |k, v| [k.to_s, stringify.call(v)] }
      when Array then g.map { stringify.call(it) }
      else g
      end
    end
    expect_golden stringify.call(SwmmGolden.golden(series: true)), json, 'to_json'
    expect(json).to eq(JSON.parse(JSON.generate(result.to_h))), 'to_json is the JSON of to_h'
    expect(JSON.parse(JSON.generate(result))).to eq(json), 'JSON.generate(result) uses to_json'
    expect(JSON.parse(JSON.pretty_generate(result))).to eq(json), 'pretty_generate too'
    json['output']['nodes'].each_value { |vars| vars.each_value { |a| expect(a.size).to eq(12) } }
    expect(json['output']['nodes']['J1']['depth']).to eq(result.nodes['J1'][:depth].values), 'floats survive the JSON round trip'
  end

  it 'has leaf values of the documented types' do
    h = run_ok(SwmmFixtures.base).to_h
    expect(h[:status]).to be_an_instance_of(String)
    expect(h[:swmm_version]).to be_an_instance_of(String)
    expect(h[:warnings]).to be_an_instance_of(Array)
    expect(h[:output][:report_step]).to be_an_instance_of(Integer)
    expect(h[:output][:periods]).to be_an_instance_of(Integer)
    expect(h[:output][:times].all?(String)).to be(true)
    expect(h[:output][:times].all? { it.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\z/) }).to be(true), 'ISO 8601 without zone: SWMM dates carry none'
    expect(h[:output][:times]).to eq(h[:output][:times].sort)
    expect(h[:output][:times].size).to eq(h[:output][:periods])
  end

  it 'has the documented shape for a failure' do
    model = SwmmFixtures.base.merge(conduits: [{ name: 'C1', from_node: 'J1', to_node: 'NOPE', length: 100, roughness: 0.013, in_offset: 0, out_offset: 0 }])
    h = Swmm.run(model).to_h
    expect_golden({ status: 'error', swmm_version: '5.2.4', error: { code: 200, message: 'ERROR 200: one or more errors in input file.', details: Array },
                    warnings: [], continuity: nil, flow_instability: {}, files: nil, output: nil }, h, 'failed run')
    expect(h[:error][:details].all?(String)).to be(true)
    expect(JSON.parse(Swmm.run(model).to_json)).to eq(JSON.parse(JSON.generate(h))), 'to_json of a failed run'
  end

  it 'has the documented shapes of files and flow_instability on the full model' do
    Dir.mktmpdir do |dir|
      result = Swmm.run(SwmmFixtures.full(dir), dir: File.join(dir, 'kept'))
      h = result.to_h(series: false)
      expect_golden({ inp: String, rpt: String, out: String }, h[:files], 'files')
      expect(h[:files].values.map { File.basename(it) }).to eq(%w[model.inp model.rpt model.out])
      expect(h[:files].values.all? { File.file?(it) }).to be(true)
      expect(h[:flow_instability]).not_to be_empty, 'the full model is unstable (links W1, W2, OR1, C3, C4 at the time of writing)'
      expect(h[:flow_instability].all? { |k, v| k.is_a?(String) && v.is_a?(Integer) }).to be(true)
      expect(h[:continuity].keys).to eq(%i[runoff flow_routing quality])
      expect(h[:continuity].values.all?(Float)).to be(true)
      expect(h[:output][:subcatchments].keys).to eq(%w[S1 S2 S3])
      expect(h[:output][:subcatchments]['S1'].keys).to include(:'quality:TSS')
      expect(h[:output][:subcatchments]['S1'][:'quality:TSS']).to be_nil
    end
  end
end
