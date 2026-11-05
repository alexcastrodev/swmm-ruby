# frozen_string_literal: true

require "stringio"
require "test_helper"

# OutputFile.read(path) reads the file as it is used (only the header in memory); OutputFile.new(bytes) the same file
# in memory. Both must give the same answers, whatever the span size and with or without Ractors.
class OutputFileStreamTest < Minitest::Test
  include NeedsEngine

  def setup
    super
    @saved = [Swmm::OutputFile.chunk_bytes, Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from]
  end

  def teardown
    Swmm::OutputFile.chunk_bytes, Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from = @saved if @saved
  end

  def run_full(dir) = Swmm.run(Fixtures.full(dir), dir: dir)

  def answers(out)
    Swmm::OutputFile::KINDS.to_h do |kind|
      ids = kind == :system ? ["system"] : out.ids[kind]
      first = ids.first
      [kind, { all: out.all_series(kind), series: out.variables[kind].to_h { [_1, out.series(kind, first, _1)] }, periods: out.each_period(kind).to_a }]
    end
  end

  def test_keeps_only_the_header_in_memory_and_answers_what_the_bytes_in_memory_answer
    Dir.mktmpdir do |dir|
      path = run_full(dir).files[:out]
      memory = Swmm::OutputFile.new(File.binread(path))
      file = Swmm::OutputFile.read(path)
      assert_equal path, file.path
      assert_nil memory.path
      assert_operator file.instance_variable_get(:@bytes).bytesize, :<, File.size(path) / 2, "the period records stay in the file"
      assert_equal [memory.ids, memory.times, memory.types(:nodes), memory.counts, memory.units], [file.ids, file.times, file.types(:nodes), file.counts, file.units]
      expected = answers(memory)
      [1, 100, 8 * 1024 * 1024].each do |chunk| # a period per span, a few, all at once
        Swmm::OutputFile.chunk_bytes = chunk
        [[1, 250_000], [3, -1]].each do |ractors, from| # sequential, then always in Ractors
          Swmm::OutputFile.ractors = ractors
          Swmm::OutputFile.parallel_from = from
          assert_equal expected, answers(file), "chunk #{chunk}, ractors #{ractors}"
        end
      end
    end
  end

  def test_streams_the_csv_to_an_io_the_same_as_the_string
    Dir.mktmpdir do |dir|
      result = run_full(dir)
      Swmm::OutputFile.chunk_bytes = 64
      Swmm::OutputFile::KINDS.each do |kind|
        assert_equal result.to_csv(kind), result.to_csv(kind, StringIO.new).string, kind.to_s
      end
      memory = Swmm::Result.new(version: 1, raw: { code: 0 }, report: "", output: Swmm::OutputFile.new(File.binread(result.files[:out])), files: nil)
      assert_equal result.to_csv(:nodes), memory.to_csv(:nodes, StringIO.new).string, "from the bytes in memory too"
    end
  end

  def test_gives_each_period_with_its_time_and_every_object_one_at_a_time
    Dir.mktmpdir do |dir|
      out = Swmm::OutputFile.read(run_full(dir).files[:out])
      enum = out.each_period(:nodes)
      assert_kind_of Enumerator, enum
      time, values = enum.first
      assert_equal out.times.first, time
      assert_equal out.ids[:nodes], values.keys
      assert_equal out.series(:nodes, "J1", :depth).first, values["J1"]["depth"]
      assert_equal out.periods, out.each_period(:system).count
    end
  end

  def test_says_the_file_is_gone_and_a_file_cut_while_reading_it_is_an_output_format_error
    out = nil
    Dir.mktmpdir do |dir|
      path = run_full(dir).files[:out]
      out = Swmm::OutputFile.read(path)
      cut = File.join(dir, "cut.out")
      File.binwrite(cut, File.binread(path))
      reader = Swmm::OutputFile.read(cut)
      File.truncate(cut, File.size(cut) / 2)
      error = assert_raises(Swmm::OutputFormatError) { reader.all_series(:nodes) }
      assert_match(/changed or was truncated/, error.message)
      assert_raises(Swmm::OutputFormatError) { reader.series(:system, nil, :rainfall) }
    end
    assert_match(/the .out is gone/, assert_raises(Swmm::Error) { out.series(:nodes, "J1", :depth) }.message)
    assert_match(/the .out is gone/, assert_raises(Swmm::Error) { out.all_series(:nodes) }.message)
    refute_empty out.ids[:nodes], "the header is still there"
  end

  def test_loads_the_whole_out_of_a_run_without_dir_because_its_temp_dir_goes_away
    result = Swmm.run(Fixtures.base)
    assert_nil result.output.path
    assert_equal result.output.periods, result.series(:nodes, "J1", :depth).size
  end
end
