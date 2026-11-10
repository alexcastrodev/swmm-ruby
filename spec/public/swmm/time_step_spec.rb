require_relative '../../swmm_helper'

RSpec.describe Swmm::TimeStep do
  it 'gives its seconds and its hh:mm:ss' do
    step = described_class.new(300)
    expect([step.in_seconds, step.formatted, step.to_s]).to eq([300.0, '00:05:00', '00:05:00'])
    expect(step.in_seconds).to be_an_instance_of(Float)
    expect([step.to_i, step.whole?]).to eq([300, true])
    expect(described_class.new(90_061).formatted).to eq('25:01:01')
    expect(described_class.new(360_000).formatted).to eq('100:00:00')
    expect(described_class.new(0).formatted).to eq('00:00:00')
  end

  it 'keeps a fraction of a second (a routing step of 0.5 s)' do
    step = described_class.new(0.5)
    expect([step.in_seconds, step.formatted, step.whole?]).to eq([0.5, '00:00:00.5', false])
    expect(step.to_i).to eq(0), 'to_i truncates'
    expect(described_class.new(1.5).to_i).to eq(1)
    expect(described_class.new(Rational(1, 4)).in_seconds).to eq(0.25).and be_an_instance_of(Float)
    expect(described_class.new(-0.5).whole?).to be(false)
  end

  it 'reads H:MM[:SS] and decimal seconds or hours' do
    expect(described_class.parse('0:05:00')).to eq(described_class.new(300))
    expect(described_class.parse('1:30')).to eq(described_class.new(5400))
    expect(described_class.parse('5.00')).to eq(described_class.new(5))
    expect(described_class.parse('0.25', decimal: :hours)).to eq(described_class.new(900))
    expect { described_class.parse('5 min') }.to raise_error(ArgumentError)
  end

  it 'takes what the input takes' do
    expect(described_class.from(60)).to eq(described_class.new(60))
    expect(described_class.from('0:01:00')).to eq(described_class.new(60))
    step = described_class.new(60)
    expect(described_class.from(step)).to be(step)
    expect { described_class.from(nil) }.to raise_error(ArgumentError)
    expect { described_class.new(Float::INFINITY) }.to raise_error(ArgumentError)
  end

  it 'compares with other steps, is a hash key and is seconds as JSON' do
    expect(described_class.new(60)).to be < described_class.new(300)
    expect(described_class.new(60)).not_to eq(60), 'a number is not a step'
    expect({ described_class.new(60) => 1 }[described_class.new(60.0)]).to eq(1)
    expect(JSON.generate(step: described_class.new(300))).to eq('{"step":300.0}')
    expect(JSON.generate(step: described_class.new(0.5))).to eq('{"step":0.5}')
    expect(described_class.new(300).inspect).to eq('#<Swmm::TimeStep 00:05:00>')
    expect(described_class.new(300)).to be_frozen
  end

  it 'goes into the input and comes back from it' do
    model = { options: { flow_units: 'LPS', report_step: described_class.new(900), routing_step: described_class.new(0.5) } }
    inp = Swmm::Input.new(model).to_inp
    expect(inp).to include('REPORT_STEP          00:15:00').and include('ROUTING_STEP         0.5')
    expect(Swmm::Input.new(options: { routing_step: described_class.new(30) }).to_inp).to include("ROUTING_STEP         30\n"), 'a whole step is written without .0'
    expect(Swmm::Input.parse(inp)[:options]).to include(report_step: described_class.new(900), routing_step: described_class.new(0.5))
    model[:options][:minimum_step] = described_class.new(0.25)
    model[:raingages] = [{ name: 'RG1', format: 'INTENSITY', interval: described_class.new(900), source: 'TIMESERIES', series: 'RAIN' }]
    model[:timeseries] = [{ name: 'RAIN', points: [[0, 0]] }]
    read = Swmm::Input.parse(Swmm::Input.new(model).to_inp)
    expect(read[:options][:minimum_step]).to eq(described_class.new(0.25))
    expect(read[:raingages].first[:interval]).to eq(described_class.new(900))
    expect(Swmm::Input.validate(options: { minimum_step: '0:00:01' })).not_to be_empty, 'MINIMUM_STEP is decimal seconds only'
    expect { Swmm::Input.new(options: { report_step: described_class.new(0.5) }).to_inp }.to raise_error(Swmm::InvalidInput, /whole seconds/)
  end
end
