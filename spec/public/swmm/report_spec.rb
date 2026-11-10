require_relative '../../swmm_helper'

# The .rpt alone: no engine, no .out.
RSpec.describe Swmm::Report do
  let(:ok) do
    <<~RPT

      EPA STORM WATER MANAGEMENT MODEL - VERSION 5.2 (Build 5.2.4)
      ------------------------------------------------------------

      WARNING 04: minimum elevation drop used for Conduit C1

      ****************
      Analysis Options
      ****************
      Flow Units ............... LPS
      Process Models:
        Flow Routing ........... YES
      Flow Routing Method ...... DYNWAVE
      Surcharge Method ......... EXTRAN
      Starting Date ............ 03/24/2026 00:00:00
      Ending Date .............. 03/24/2026 02:00:00
      Report Time Step ......... 00:10:00
      Routing Time Step ........ 5.00 sec
      Variable Time Step ....... NO

      **************************        Volume        Volume
      Flow Routing Continuity        hectare-m      10^6 ltr
      **************************     ---------     ---------
      Continuity Error (%) .....        -0.114

      ********************************
      Highest Flow Instability Indexes
      ********************************
      Link C1 (12)

      *********************
      Node Flooding Summary
      *********************
      --------------------------------------------------------------------------
      Node                 Flooded       LPS   days hr:min    10^6 ltr    Meters
      --------------------------------------------------------------------------
      J1                      1.76    103.07      1  01:00       0.354     0.000

      ***********************
      Outfall Loading Summary
      ***********************
    RPT
  end

  let(:failed) do
    <<~RPT
      EPA STORM WATER MANAGEMENT MODEL - VERSION 5.2 (Build 5.2.4)

      ERROR 209: undefined object X at line 14 of [CONDUITS] section:
        C1 J1 X 100 0.013
      ERROR 211: invalid number at line 15 of [CONDUITS] section:
    RPT
  end

  it 'reads what the report says of a run that finished' do
    report = described_class.new(ok)
    expect(report).to be_ok
    expect(report.version).to eq('5.2.4')
    expect(report.warnings).to eq(['WARNING 04: minimum elevation drop used for Conduit C1'])
    expect(report.continuity).to eq(runoff: 0.0, flow_routing: -0.114, quality: 0.0)
    expect(report.flow_instability).to eq('C1' => 12)
    expect(report.analysis_options).to eq(
      flow_units: 'LPS', start_time: Time.utc(2026, 3, 24), end_time: Time.utc(2026, 3, 24, 2), report_step: Swmm::TimeStep.new(600),
      flow_routing: 'DYNWAVE', surcharge_method: 'EXTRAN', routing_step: Swmm::TimeStep.new(5), variable_step: false
    )
  end

  it 'reads the routing a run without Flow Routing does not print' do
    report = described_class.new(ok.sub(/^\s*Flow Routing Method.*\n/, '').sub(/^\s*Surcharge Method.*\n/, '')
                                   .sub(/^\s*Routing Time Step.*\n/, '').sub(/^\s*Variable Time Step.*\n/, ''))
    expect(report.analysis_options).to include(flow_units: 'LPS', flow_routing: nil, surcharge_method: nil, routing_step: nil, variable_step: nil)
    expect(described_class.new(ok.sub('Variable Time Step ....... NO', 'Variable Time Step ....... YES')).analysis_options[:variable_step]).to be(true)
  end

  it 'places the flooding peak only when given the report start' do
    report = described_class.new(ok)
    row = { node: 'J1', hours: 1.76, max_rate: 103.07, max_elapsed: 90_000, max_time: nil, volume: 354.0, max_ponded_depth: 0.0 }
    expect(report.node_flooding).to eq([row])
    expect(report.node_flooding(start: Time.utc(2026, 3, 24))).to eq([row.merge(max_time: Time.utc(2026, 3, 25, 1))])
    expect(report.node_flooding).to eq([row]), 'a start given once is not remembered'
  end

  it 'reads the errors of a run that failed, 2xx as the 200 the engine returns' do
    report = described_class.new(failed)
    expect(report).not_to be_ok
    expect(report.error).to eq(
      code: 200, message: 'ERROR 200: one or more errors in input file.',
      details: ['ERROR 209: undefined object X at line 14 of [CONDUITS] section: C1 J1 X 100 0.013',
                'ERROR 211: invalid number at line 15 of [CONDUITS] section:']
    )
    expect(report.error_message(209)).to eq('ERROR 209: undefined object X at line 14 of [CONDUITS] section:')
    expect(report.continuity).to be_nil
    expect(report.node_flooding).to eq([])
    expect(report.to_h).to include(status: 'error', continuity: nil)
  end

  it 'exports itself as plain data' do
    h = described_class.new(ok).to_h
    expect(h).to include(status: 'ok', swmm_version: '5.2.4', error: nil, flow_instability: { 'C1' => 12 })
    expect(h[:node_flooding].first).to include(node: 'J1', max_time: nil)
    expect(JSON.parse(JSON.generate(h))['analysis_options']).to include('report_step' => 600, 'routing_step' => 5), 'steps as seconds'
    expect { JSON.generate(h) }.not_to raise_error
  end

  it 'answers a blank report as one that printed nothing' do
    report = described_class.new('')
    expect([report.swmm?, report.ok?, report.version, report.warnings, report.flow_instability]).to eq([false, true, nil, [], {}])
    expect(report.analysis_options).to eq(
      flow_units: nil, start_time: nil, end_time: nil, report_step: nil,
      flow_routing: nil, surcharge_method: nil, routing_step: nil, variable_step: nil
    )
  end

  it 'reads any encoding and refuses what is not text' do
    expect(described_class.new("#{ok}1000 m\xB3".b).text).to end_with('1000 m�')
    expect(described_class.new(ok.encode(Encoding::UTF_8)).text).to be_frozen
    expect { described_class.new(nil) }.to raise_error(TypeError)
  end

  it 'reads a file, and refuses one SWMM did not write' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'run.rpt'), ok)
      File.write(File.join(dir, 'other.txt'), 'hello')
      expect(described_class.read(File.join(dir, 'run.rpt')).continuity[:flow_routing]).to eq(-0.114)
      expect { described_class.read(File.join(dir, 'other.txt')) }.to raise_error(Swmm::ReportFormatError, /not a SWMM report/)
    end
  end

  it 'is what Result reads, without the .out', :libswmm5 do
    Dir.mktmpdir do |dir|
      result = Swmm.run(SwmmFixtures.flooded, dir: dir)
      report = described_class.read(result.files[:rpt])
      expect(result.rpt.text).to eq(report.text)
      expect(result.report).to eq(report.text), 'Result#report stays the text'
      expect([report.warnings, report.flow_instability, report.analysis_options]).to eq([result.warnings, result.flow_instability, result.analysis_options])
      expect(report.node_flooding(start: result.report_start)).to eq(result.node_flooding)
      expect(Swmm::OutputFile.read(result.files[:out]).nodes['J1'][:depth].values).to eq(result.nodes['J1'][:depth].values)
    end
  end
end
