require 'open3'
require_relative '../swmm_helper'

# Swmm.read: the Result built from the files SWMM wrote (rpt, out), without running the engine.
RSpec.describe Swmm, '.read', :libswmm5 do
  def read(ran) = described_class.read(**ran.files.slice(:rpt, :out))

  it 'gives the same result as run' do
    Dir.mktmpdir do |dir|
      ran = described_class.run(SwmmFixtures.base, dir: dir)
      read = read(ran)
      expect(read.version).to eq(ran.version)
      expect(read.report).to eq(ran.report)
      expect(read.to_h.except(:continuity, :files)).to eq(ran.to_h.except(:continuity, :files)), 'everything but the continuity and the files is identical'
      expect(read.files).to eq(ran.files.merge(inp: nil)), 'the .inp is not needed'
      ran.continuity.each { |kind, value| expect(read.continuity.fetch(kind)).to be_within(0.0006).of(value), "#{kind}: the report prints 3 decimals" }
    end
  end

  it 'reads the continuity of a model with runoff and quality' do
    Dir.mktmpdir do |dir|
      ran = described_class.run(SwmmFixtures.full(dir), dir: dir)
      expect(ran).to be_ok, ran.error.inspect
      read = read(ran)
      expect(read.continuity[:runoff]).not_to eq(0.0)
      expect(read.continuity[:quality].abs).to be > 1, 'the quality error is the pollutant with the largest absolute value, signed'
      ran.continuity.each { |kind, value| expect(read.continuity.fetch(kind)).to be_within(0.0006).of(value), kind.to_s }
    end
  end

  it 'reads a failed run from the report alone' do
    bad = SwmmFixtures.base.merge(conduits: [{ name: 'C1', from_node: 'J1', to_node: 'NOPE', length: 1, roughness: 0.01, in_offset: 0, out_offset: 0 }])
    Dir.mktmpdir do |dir|
      ran = described_class.run(bad, dir: dir)
      expect(File).not_to exist(ran.files[:out]), 'the engine wrote no .out'
      read = read(ran)
      expect(read).not_to be_ok
      expect(read.error).to eq(ran.error), 'code 200 (the report only prints the specific 2xx errors), message and details'
      expect(read.continuity).to be_nil
      expect(read.output).to be_nil
      expect { read.times }.to raise_error(Swmm::Error)
    end
  end

  it 'lets the error code in the .out epilogue win' do
    Dir.mktmpdir do |dir|
      ran = described_class.run(SwmmFixtures.base, dir: dir)
      bytes = File.binread(ran.files[:out])
      bytes[-8, 4] = [307].pack('l<') # epilogue: id pos, input pos, output pos, periods, error code, magic
      File.binwrite(ran.files[:out], bytes)
      read = read(ran)
      expect(read).not_to be_ok
      expect(read.error).to eq(code: 307, message: 'ERROR 307', details: [])
      expect(read.output).to be_nil, 'a run that failed has no trusted results'
    end
  end

  it 'needs only the report for the status and the continuity' do
    Dir.mktmpdir do |dir|
      ran = described_class.run(SwmmFixtures.base, dir: dir)
      read = described_class.read(rpt: ran.files[:rpt])
      expect(read).to be_ok
      expect(read.version).to eq(ran.version), 'from the banner of the report'
      expect(read.output).to be_nil
      expect(read.continuity[:flow_routing]).to be_within(0.0006).of(ran.continuity[:flow_routing])
      expect(read.files).to eq(inp: nil, rpt: ran.files[:rpt], out: nil)
    end
  end

  it 'fails clearly on bad files' do
    Dir.mktmpdir do |dir|
      ran = described_class.run(SwmmFixtures.base, dir: dir)
      expect { described_class.read(rpt: File.join(dir, 'nope.rpt')) }.to raise_error(Errno::ENOENT)
      expect { described_class.read(rpt: ran.files[:rpt], out: File.join(dir, 'nope.out')) }.to raise_error(ArgumentError)
      File.binwrite(ran.files[:out], 'not a swmm file' * 10)
      expect { read(ran) }.to raise_error(Swmm::OutputFormatError)
    end
  end

  it 'places the worst moment of node flooding in time' do
    Dir.mktmpdir do |dir|
      ran = described_class.run(SwmmFixtures.flooded, dir: dir)
      expect(ran.report_start).to eq(Time.utc(2026, 3, 24)), 'the simulation start'
      expect(ran.node_flooding.size).to eq(1)
      j1 = ran.node_flooding.first
      expect(j1[:node]).to eq('J1')
      expect(j1[:max_rate]).to be_within(0.5).of(103.07)
      expect(j1[:max_elapsed]).to eq(3600)
      overflow = ran.nodes['J1'][:overflow].values
      expect(j1[:max_time]).to eq(ran.times[overflow.index(overflow.compact.max)]), 'the saved period of the largest overflow'
      expect(j1[:volume]).to be > 300, 'm3'
      expect(read(ran).node_flooding).to eq(ran.node_flooding)
    end
  end

  it 'moves the report times with a later report start, and report_start follows' do
    Dir.mktmpdir do |dir|
      ran = described_class.run(SwmmFixtures.flooded(report_start_date: '2026-03-24', report_start_time: '00:30'), dir: dir)
      expect(ran.output.start_time).to eq(Time.utc(2026, 3, 24, 0, 20)), 'the engine saves the period before the first reported one'
      expect(ran.report_start).to eq(Time.utc(2026, 3, 24, 0, 30))
      j1 = ran.node_flooding.first
      expect(j1[:max_elapsed]).to eq(1800), 'the report counts from REPORT_START'
      expect(j1[:max_time]).to eq(Time.utc(2026, 3, 24, 1))
      expect(read(ran).node_flooding).to eq(ran.node_flooding), 'a later report start is not a mismatch'
    end
  end

  # The limit Result#report_start documents: these report starts save the .out of an earlier one.
  it 'takes a report start the files cannot place up to one step early' do
    { '00:10' => Time.utc(2026, 3, 24, 0, 0), '00:25' => Time.utc(2026, 3, 24, 0, 20) }.each do |time, taken|
      Dir.mktmpdir do |dir|
        ran = described_class.run(SwmmFixtures.flooded(report_start_date: '2026-03-24', report_start_time: time), dir: dir)
        expect(ran.report_start).to eq(taken), time
        early = Time.utc(2026, 3, 24, 1) - ran.node_flooding.first[:max_time]
        expect(early).to be > 0, time
        expect(early).to be <= 600, "#{time}: at most one report step"
      end
    end
  end

  it 'rejects an .out of another run' do
    Dir.mktmpdir do |dir|
      ran = described_class.run(SwmmFixtures.base, dir: File.join(dir, 'base'))
      with = ->(options) { SwmmFixtures.base.then { it.merge(options: it[:options].merge(options)) } }
      {
        'report step' => with.call(report_step: '00:05:00'),
        'flow units' => with.call(flow_units: 'CMS'),
        'start' => with.call(start_date: '2026-03-23', end_date: '2026-03-23')
      }.each do |difference, model|
        other = described_class.run(model, dir: File.join(dir, difference.tr(' ', '_')))
        expect(other).to be_ok, difference
        expect { described_class.read(rpt: ran.files[:rpt], out: other.files[:out]) }
          .to raise_error(Swmm::MismatchedFiles, /not from the same run: .*#{difference}/)
      end
      again = described_class.run(SwmmFixtures.base, dir: File.join(dir, 'again'))
      expect(described_class.read(rpt: ran.files[:rpt], out: again.files[:out])).to be_ok, 'another run of the same model cannot be told apart'
    end
  end

  it 'needs neither the engine nor the library' do
    Dir.mktmpdir do |dir|
      ran = described_class.run(SwmmFixtures.base, dir: dir)
      script = <<~RUBY
        require "swmm_standalone"
        Swmm::Engine.define_singleton_method(:default) { raise "the engine was used" }
        result = Swmm.read(rpt: ARGV[0], out: ARGV[1])
        puts [result.ok?, result.version, result.links["C2"][:flow].values.size, result.to_json.bytesize.positive?].inspect
      RUBY
      support = File.expand_path('../support', __dir__)
      out, err, status = Open3.capture3({ 'SWMM_LIB' => '/nonexistent' }, RbConfig.ruby, "-I#{support}", '-e', script, *ran.files.values_at(:rpt, :out))
      expect(status).to be_success, err
      expect(out).to eq("[true, \"#{ran.version}\", 12, true]\n")
    end
  end
end
