require_relative '../../swmm_helper'

# Known bugs of the EPA engine (libswmm5 5.2.4), see docs/known-issues.md. The examples that state the CORRECT behaviour are
# skipped unless SWMM_SHOW_BUGS is set, because they fail with the engine as released; the one for the workaround always runs.
RSpec.describe Swmm::Engine, 'known bugs of libswmm5', :libswmm5 do
  # Bug 1: 2-hour windows (start date, start hour) where (end - start) * 86400 comes out below 7200 in doubles, so the engine saves
  # 11 periods and loses the one at the end. The first is the case from the bug report.
  let(:lost_last_period) { [['2022-11-27', 11], ['2020-11-29', 20], ['2022-10-20', 5], ['2025-06-19', 2], ['2021-09-15', 20], ['2025-01-26', 17]] }

  def window(date, hour, end_time: format('%02d:00', hour + 2))
    options = SwmmFixtures.base[:options].merge(start_date: date, start_time: format('%02d:00', hour), end_date: date, end_time: end_time,
                                                report_step: '00:10:00')
    run_ok(SwmmFixtures.base.merge(options: options), "#{date} #{hour}:00")
  end

  def utc(date, hour, minute = 0) = Time.utc(*date.split('-').map(&:to_i), hour, minute)

  it 'saves the last reporting period' do
    skip 'KNOWN BUG 1: the engine loses the last reporting period in about 1 window in 3 (TotalDuration, project.c:165)' unless ENV['SWMM_SHOW_BUGS']
    lost_last_period.each do |date, hour|
      result = window(date, hour)
      expect(result.output.periods).to eq(12), "#{date} #{hour}:00"
      expect(result.times.last).to eq(utc(date, hour + 2))
    end
  end

  # The workaround: end the simulation one second later. The extra second adds no period and changes none of the others.
  it 'saves the last period when the simulation ends one second later' do
    lost_last_period.each do |date, hour|
      plain = window(date, hour)
      later = window(date, hour, end_time: format('%02d:00:01', hour + 2))
      expect(later.output.periods).to eq(12), "#{date} #{hour}:00 ending at :00:01"
      expect([later.times.first, later.times.last]).to eq([utc(date, hour, 10), utc(date, hour + 2)])
      %i[nodes links].each do |kind|
        later[kind].ids.each { |id| later[kind].variables.each { |v| expect(later[kind][id][v].values.first(plain.times.size)).to eq(plain[kind][id][v].values), "#{kind} #{id} #{v}" } }
      end
    end
  end

  # Bug 2: the snowpack's imelt[] is never initialised (snow.c). On glibc a freed block is handed out again with its old contents,
  # so filling freed blocks with 0xFF bytes (a NaN as a double) makes the engine read NaN in about half of the runs; on macOS malloc
  # does not recycle them and the example has nothing to catch.
  def poison_heap
    (32..2048).step(16) do |size|
      Array.new(24) { FFI::MemoryPointer.new(:uint8, size).tap { |ptr| ptr.put_bytes(0, "\xFF".b * size) } }.each(&:free)
    end
  end

  it 'does not read recycled heap for a snowpack with a zero-area surface' do
    skip 'KNOWN BUG 2: the engine reads an uninitialised snowpack variable (imelt, snow.c:171-187); fails on Linux' unless ENV['SWMM_SHOW_BUGS']
    Dir.mktmpdir do |dir|
      24.times do |i|
        poison_heap
        result = run_ok(SwmmFixtures.full(dir, snow: true), "run #{i}")
        expect(result.continuity[:runoff]).to be_finite, "run #{i}: runoff continuity is #{result.continuity[:runoff]}"
        expect(result.subcatchments['S1'][:runoff].values.max).to be > 0, "run #{i}: S1 produced no runoff"
      end
    end
  end

  # How a caller notices bug 2 (and what the exported data looks like): the continuity is NaN, never within a tolerance.
  it 'never takes a NaN continuity as ok and exports it as null' do
    raw = { code: 0, message: '', continuity: { runoff: Float::NAN, flow_routing: 6.4177, quality: -51.1273 } }
    result = Swmm::Result.new(version: '5.2.4', raw: raw, report: '', output: nil, files: nil)
    expect(result).not_to be_continuity_ok(tolerance: 100)
    expect(JSON.parse(result.to_json).dig('continuity', 'runoff')).to be_nil
  end
end
