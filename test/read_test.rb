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
