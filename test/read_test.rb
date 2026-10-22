# frozen_string_literal: true

require "open3"
require "test_helper"

# Swmm.read: the Result built from the files SWMM wrote (rpt, out), without running the engine.
class ReadTest < Minitest::Test
  include NeedsEngine

  def read(ran) = Swmm.read(**ran.files.slice(:rpt, :out))

  def test_read_gives_the_same_result_as_run
    Dir.mktmpdir do |dir|
      ran = Swmm.run(Fixtures.base, dir: dir)
      read = read(ran)
      assert_equal ran.version, read.version
      assert_equal ran.report, read.report
      assert_equal ran.to_h.except(:continuity, :files), read.to_h.except(:continuity, :files), "everything but the continuity and the files is identical"
      assert_equal ran.files.merge(inp: nil), read.files, "the .inp is not needed"
      ran.continuity.each { |kind, value| assert_in_delta value, read.continuity.fetch(kind), 0.0006, "#{kind}: the report prints 3 decimals" }
    end
  end

  def test_continuity_of_a_model_with_runoff_and_quality
    Dir.mktmpdir do |dir|
      ran = Swmm.run(Fixtures.full(dir), dir: dir)
      assert ran.ok?, ran.error.inspect
      read = read(ran)
      refute_equal 0.0, read.continuity[:runoff]
      assert_operator read.continuity[:quality].abs, :>, 1, "the quality error is the pollutant with the largest absolute value, signed"
      ran.continuity.each { |kind, value| assert_in_delta value, read.continuity.fetch(kind), 0.0006, kind }
    end
  end

  def test_a_failed_run_is_read_from_the_report_alone
    bad = Fixtures.base.merge(conduits: [{ name: "C1", from_node: "J1", to_node: "NOPE", length: 1, roughness: 0.01, in_offset: 0, out_offset: 0 }])
    Dir.mktmpdir do |dir|
      ran = Swmm.run(bad, dir: dir)
      refute File.exist?(ran.files[:out]), "the engine wrote no .out"
      read = read(ran)
      refute read.ok?
      assert_equal ran.error, read.error, "code 200 (the report only prints the specific 2xx errors), message and details"
      assert_nil read.continuity
      assert_nil read.output
      assert_raises(Swmm::Error) { read.times }
    end
  end

  def test_the_error_code_in_the_out_epilogue_wins
    Dir.mktmpdir do |dir|
      ran = Swmm.run(Fixtures.base, dir: dir)
      bytes = File.binread(ran.files[:out])
      bytes[-8, 4] = [307].pack("l<") # epilogue: id pos, input pos, output pos, periods, error code, magic
      File.binwrite(ran.files[:out], bytes)
      read = read(ran)
      refute read.ok?
      assert_equal({ code: 307, message: "ERROR 307", details: [] }, read.error)
      assert_nil read.output, "a run that failed has no trusted results"
    end
  end

  def test_the_report_alone_is_enough_for_status_and_continuity
    Dir.mktmpdir do |dir|
      ran = Swmm.run(Fixtures.base, dir: dir)
      read = Swmm.read(rpt: ran.files[:rpt])
      assert read.ok?
      assert_equal ran.version, read.version, "from the banner of the report"
      assert_nil read.output
      assert_in_delta ran.continuity[:flow_routing], read.continuity[:flow_routing], 0.0006
      assert_equal({ inp: nil, rpt: ran.files[:rpt], out: nil }, read.files)
    end
  end

  def test_bad_files_fail_clearly
    Dir.mktmpdir do |dir|
      ran = Swmm.run(Fixtures.base, dir: dir)
      assert_raises(Errno::ENOENT) { Swmm.read(rpt: File.join(dir, "nope.rpt")) }
      assert_raises(ArgumentError) { Swmm.read(rpt: ran.files[:rpt], out: File.join(dir, "nope.out")) }
      File.binwrite(ran.files[:out], "not a swmm file" * 10)
      assert_raises(Swmm::OutputFormatError) { read(ran) }
    end
  end

  def test_node_flooding_places_the_worst_moment_in_time
    Dir.mktmpdir do |dir|
      ran = Swmm.run(Fixtures.flooded, dir: dir)
      assert_equal Time.utc(2026, 3, 24), ran.report_start, "the simulation start"
      assert_equal 1, ran.node_flooding.size
      j1 = ran.node_flooding.first
      assert_equal "J1", j1[:node]
      assert_in_delta 103.07, j1[:max_rate], 0.5
      assert_equal 3600, j1[:max_elapsed]
      overflow = ran.series(:nodes, "J1", :overflow)
      assert_equal ran.times[overflow.index(overflow.compact.max)], j1[:max_time], "the saved period of the largest overflow"
      assert_operator j1[:volume], :>, 300, "m3"
      assert_equal ran.node_flooding, read(ran).node_flooding
    end
  end

  def test_a_later_report_start_moves_the_report_times_and_report_start_follows
    Dir.mktmpdir do |dir|
      ran = Swmm.run(Fixtures.flooded(report_start_date: "2026-03-24", report_start_time: "00:30"), dir: dir)
      assert_equal Time.utc(2026, 3, 24, 0, 20), ran.output.start, "the engine saves the period before the first reported one"
      assert_equal Time.utc(2026, 3, 24, 0, 30), ran.report_start
      j1 = ran.node_flooding.first
      assert_equal 1800, j1[:max_elapsed], "the report counts from REPORT_START"
      assert_equal Time.utc(2026, 3, 24, 1), j1[:max_time]
      assert_equal ran.node_flooding, read(ran).node_flooding, "a later report start is not a mismatch"
    end
  end

  # The limit Result#report_start documents: these report starts save the .out of an earlier one.
  def test_a_report_start_the_files_cannot_place_is_taken_up_to_one_step_early
    { "00:10" => Time.utc(2026, 3, 24, 0, 0), "00:25" => Time.utc(2026, 3, 24, 0, 20) }.each do |time, taken|
      Dir.mktmpdir do |dir|
        ran = Swmm.run(Fixtures.flooded(report_start_date: "2026-03-24", report_start_time: time), dir: dir)
        assert_equal taken, ran.report_start, time
        early = Time.utc(2026, 3, 24, 1) - ran.node_flooding.first[:max_time]
        assert_operator early, :>, 0, time
        assert_operator early, :<=, 600, "#{time}: at most one report step"
      end
    end
  end

  def test_an_out_of_another_run_is_rejected
    Dir.mktmpdir do |dir|
      ran = Swmm.run(Fixtures.base, dir: File.join(dir, "base"))
      with = ->(options) { Fixtures.base.then { _1.merge(options: _1[:options].merge(options)) } }
      {
        "report step" => with.(report_step: "00:05:00"),
        "flow units" => with.(flow_units: "CMS"),
        "start" => with.(start_date: "2026-03-23", end_date: "2026-03-23")
      }.each do |difference, model|
        other = Swmm.run(model, dir: File.join(dir, difference.tr(" ", "_")))
        assert other.ok?, difference
        error = assert_raises(Swmm::MismatchedFiles, difference) { Swmm.read(rpt: ran.files[:rpt], out: other.files[:out]) }
        assert_match(/not from the same run: .*#{difference}/, error.message)
      end
      again = Swmm.run(Fixtures.base, dir: File.join(dir, "again"))
      assert Swmm.read(rpt: ran.files[:rpt], out: again.files[:out]).ok?, "another run of the same model cannot be told apart"
    end
  end

  def test_read_needs_neither_the_engine_nor_the_library
    Dir.mktmpdir do |dir|
      ran = Swmm.run(Fixtures.base, dir: dir)
      script = <<~RUBY
        require "swmm"
        Swmm::Engine.define_singleton_method(:default) { raise "the engine was used" }
        result = Swmm.read(rpt: ARGV[0], out: ARGV[1])
        puts [result.ok?, result.version, result.series(:links, "C2", :flow).size, result.to_json.bytesize.positive?].inspect
      RUBY
      lib = File.expand_path("../lib", __dir__)
      out, err, status = Open3.capture3({ "SWMM_LIB" => "/nonexistent" }, RbConfig.ruby, "-I#{lib}", "-e", script, *ran.files.values_at(:rpt, :out))
      assert status.success?, err
      assert_equal "[true, \"#{ran.version}\", 12, true]\n", out
    end
  end
end
