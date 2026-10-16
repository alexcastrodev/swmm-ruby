# frozen_string_literal: true

require "test_helper"

# Known bugs of the EPA engine (libswmm5 5.2.4), see docs/known-issues.md. The tests that state the CORRECT behaviour are skipped
# unless SWMM_SHOW_BUGS is set, because they fail with the engine as released; the one for the workaround always runs.
class KnownEngineBugsTest < Minitest::Test
  include NeedsEngine

  # Bug 1: 2-hour windows (start date, start hour) where (end - start) * 86400 comes out below 7200 in doubles, so the engine saves
  # 11 periods and loses the one at the end. The first is the case from the bug report.
  LOST_LAST_PERIOD = [["2022-11-27", 11], ["2020-11-29", 20], ["2022-10-20", 5], ["2025-06-19", 2], ["2021-09-15", 20], ["2025-01-26", 17]].freeze

  def window(date, hour, end_time: format("%02d:00", hour + 2))
    options = Fixtures.base[:options].merge(start_date: date, start_time: format("%02d:00", hour), end_date: date, end_time: end_time,
                                            report_step: "00:10:00")
    assert_runs(Fixtures.base.merge(options: options), "#{date} #{hour}:00")
  end

  def utc(date, hour, minute = 0) = Time.utc(*date.split("-").map(&:to_i), hour, minute)

  def test_the_last_reporting_period_is_saved
    skip "KNOWN BUG 1: the engine loses the last reporting period in about 1 window in 3 (TotalDuration, project.c:165)" unless ENV["SWMM_SHOW_BUGS"]
    LOST_LAST_PERIOD.each do |date, hour|
      result = window(date, hour)
      assert_equal 12, result.output.periods, "#{date} #{hour}:00"
      assert_equal utc(date, hour + 2), result.times.last
    end
  end

  # The workaround: end the simulation one second later. The extra second adds no period and changes none of the others.
  def test_ending_one_second_later_saves_the_last_period
    LOST_LAST_PERIOD.each do |date, hour|
      plain = window(date, hour)
      later = window(date, hour, end_time: format("%02d:00:01", hour + 2))
      assert_equal 12, later.output.periods, "#{date} #{hour}:00 ending at :00:01"
      assert_equal [utc(date, hour, 10), utc(date, hour + 2)], [later.times.first, later.times.last]
      %i[nodes links].each do |kind|
        later.ids(kind).each { |id| later.variables(kind).each { |v| assert_equal plain.series(kind, id, v), later.series(kind, id, v).first(plain.times.size), "#{kind} #{id} #{v}" } }
      end
    end
  end

  # Bug 2: the snowpack's imelt[] is never initialised (snow.c). On glibc a freed block is handed out again with its old contents,
  # so filling freed blocks with 0xFF bytes (a NaN as a double) makes the engine read NaN in about half of the runs; on macOS malloc
  # does not recycle them and the test has nothing to catch.
  def poison_heap
    (32..2048).step(16) do |size|
      Array.new(24) { FFI::MemoryPointer.new(:uint8, size).tap { |ptr| ptr.put_bytes(0, "\xFF".b * size) } }.each(&:free)
    end
  end

  def test_a_snowpack_with_a_zero_area_surface_does_not_read_recycled_heap
    skip "KNOWN BUG 2: the engine reads an uninitialised snowpack variable (imelt, snow.c:171-187); fails on Linux" unless ENV["SWMM_SHOW_BUGS"]
    Dir.mktmpdir do |dir|
      24.times do |i|
        poison_heap
        result = assert_runs(Fixtures.full(dir, snow: true), "run #{i}")
        assert_predicate result.continuity[:runoff], :finite?, "run #{i}: runoff continuity is #{result.continuity[:runoff]}"
        assert_operator result.series(:subcatchments, "S1", :runoff).max, :>, 0, "run #{i}: S1 produced no runoff"
      end
    end
  end

  # How a caller notices bug 2 (and what the exported data looks like): the continuity is NaN, never within a tolerance.
  def test_a_nan_continuity_is_never_ok_and_exports_as_null
    raw = { code: 0, message: "", continuity: { runoff: Float::NAN, flow_routing: 6.4177, quality: -51.1273 } }
    result = Swmm::Result.new(version: "5.2.4", raw: raw, report: "", output: nil, files: nil)
    refute result.continuity_ok?(tolerance: 100)
    assert_nil JSON.parse(result.to_json).dig("continuity", "runoff")
  end
end
