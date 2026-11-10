require_relative '../../swmm_helper'

# Report parsing, without the engine.
RSpec.describe Swmm::Result do
  let(:report) do
    <<~RPT
      ***************************
      Time-Step Critical Elements
      ***************************
      Link C9 (60.17%)

      ********************************
      Highest Flow Instability Indexes
      ********************************
      Link C1 (12)
      Link C 2 (3)

      *********************************
      Most Frequent Nonconverging Nodes
      *********************************
      Link C8 (7)
    RPT
  end

  let(:flooding) do
    <<~RPT
      ****************
      Analysis Options
      ****************
      Flow Units ............... LPS
      Flow Routing Method ...... DYNWAVE
      Starting Date ............ 03/24/2026 00:00:00
      Ending Date .............. 03/24/2026 02:00:00
      Antecedent Dry Days ...... 0.0
      Report Time Step ......... 00:10:00

      *********************
      Node Flooding Summary
      *********************

      Flooding refers to all water that overflows a node, whether it ponds or not.
      --------------------------------------------------------------------------
                                                                 Total   Maximum
                                     Maximum   Time of Max       Flood    Ponded
                            Hours       Rate    Occurrence      Volume     Depth
      Node                 Flooded       LPS   days hr:min    10^6 ltr    Meters
      --------------------------------------------------------------------------
      J1                      1.76    103.07      0  01:00       0.354     0.000
      5AVE228                 0.01     10.74      2  03:24       0.000     0.120


      ***********************
      Outfall Loading Summary
      ***********************
      O1                     99.99     88.88      0  00:00       0.111     0.000
    RPT
  end

  def result(report) = described_class.new(version: '5.2.4', raw: { code: 0, message: '', continuity: { runoff: 0.0, flow_routing: 7.5, quality: 0.0 } }, report: report, output: nil, files: nil)

  it 'reads flow instability from its own section only' do
    expect(result(report).flow_instability).to eq('C1' => 12, 'C 2' => 3)
    expect(result(report.sub(/Link C1.*\n.*\n/, "All links are stable.\n")).flow_instability).to be_empty
    expect(result('').flow_instability).to be_empty
  end

  it 'compares the worst continuity error with the tolerance' do
    expect(result('')).not_to be_continuity_ok
    expect(result('')).to be_continuity_ok(tolerance: 10)
  end

  # A run whose continuity is NaN (seen with libswmm5 on Linux when a subcatchment uses a snowpack) still has to export.
  it 'exports a non-finite continuity as null and is never ok' do
    raw = { code: 0, message: '', continuity: { runoff: Float::NAN, flow_routing: 6.4177, quality: Float::INFINITY } }
    r = described_class.new(version: '5.2.4', raw: raw, report: '', output: nil, files: nil)
    expect(r.continuity[:runoff]).to be_nan, 'the accessor keeps the real value'
    expect(r).not_to be_continuity_ok
    expect(r).not_to be_continuity_ok(tolerance: 100), 'NaN is never within a tolerance'
    expect(r.to_h[:continuity]).to eq(runoff: nil, flow_routing: 6.4177, quality: nil)
    expect(JSON.parse(r.to_json)['continuity']).to eq('runoff' => nil, 'flow_routing' => 6.4177, 'quality' => nil)
  end

  it 'reads node flooding from the report table' do
    expect(result(flooding).node_flooding).to eq([
                                                   { node: 'J1', hours: 1.76, max_rate: 103.07, max_elapsed: 3600, max_time: nil, volume: 354.0, max_ponded_depth: 0.0 },
                                                   { node: '5AVE228', hours: 0.01, max_rate: 10.74, max_elapsed: (2 * 86_400) + (3 * 3600) + (24 * 60), max_time: nil, volume: 0.0, max_ponded_depth: 0.12 }
                                                 ]), 'max_time needs the results (see report_start); the next section is not read'
    expect(result(flooding.gsub("\n", "\r\n")).node_flooding).to eq(result(flooding).node_flooding), 'CRLF reports'
  end

  it 'gives node flooding volumes in the unit system of the run' do
    us = result(flooding.sub('Flow Units ............... LPS', 'Flow Units ............... CFS')).node_flooding.first
    expect(us[:volume]).to eq(47_322.917), '10^6 gal in ft3'
  end

  it 'gives no node flooding without flooded nodes' do
    expect(result(flooding.sub(/^Flooding refers.*?(?=\n\n\n)/m, 'No nodes were flooded.')).node_flooding).to be_empty
    expect(result('').node_flooding).to be_empty
  end

  it 'reads the analysis options from the report' do
    expect(result(flooding).analysis_options).to include(flow_units: 'LPS', start_time: Time.utc(2026, 3, 24), end_time: Time.utc(2026, 3, 24, 2), report_step: Swmm::TimeStep.new(600))
    expect(result('').analysis_options.values).to all(be_nil)
    expect(result(flooding).report_start).to be_nil, 'it needs the start the .out saved'
  end

  it 'takes unknown kinds as an UnknownObject, before it looks for the results' do
    expect { result('')[:pipes] }.to raise_error(Swmm::UnknownObject, /unknown kind :pipes/)
    expect { result('')[nil] }.to raise_error(Swmm::UnknownObject)
    expect { result('')[1] }.to raise_error(Swmm::UnknownObject)
  end

  it 'needs the results for the objects of a kind' do
    expect { result('')['system'] }.to raise_error(Swmm::Error, /no results/)
    expect { result('').system }.to raise_error(Swmm::Error, /no results/)
    expect { result('').links }.to raise_error(Swmm::Error, /no results/)
    expect { result('').times }.to raise_error(Swmm::Error, /no results/)
  end

  it 'rejects, in Swmm.read, a report SWMM did not write' do
    Dir.mktmpdir do |dir|
      rpt = File.join(dir, 'notes.rpt')
      ["just some text\n", '', flooding].each do |text|
        File.write(rpt, text)
        expect { Swmm.read(rpt: rpt) }.to raise_error(Swmm::ReportFormatError, /not a SWMM report/)
      end
    end
  end

  it 'takes, in Swmm.read, the version from an OWA banner' do
    Dir.mktmpdir do |dir|
      rpt = File.join(dir, 'owa.rpt')
      File.write(rpt, "\r\n  OWA STORM WATER MANAGEMENT MODEL - VERSION v5.2.1 (OWA 2023-03-28)\r\n#{flooding}")
      expect(Swmm.read(rpt: rpt).version).to eq('5.2.1')
      File.write(rpt, "\n  EPA STORM WATER MANAGEMENT MODEL - VERSION 5.2 (Build 5.2.4)\n#{flooding}")
      expect(Swmm.read(rpt: rpt).version).to eq('5.2.4')
    end
  end

  it 'still exports a nil continuity for a failed run' do
    r = described_class.new(version: '5.2.4', raw: { code: 200, message: 'ERROR 200', continuity: nil }, report: '', output: nil, files: nil)
    expect(r.to_h[:continuity]).to be_nil
    expect(JSON.parse(r.to_json)['continuity']).to be_nil
  end
end
