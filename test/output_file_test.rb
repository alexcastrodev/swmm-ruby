# frozen_string_literal: true

require "test_helper"

class OutputFileTest < Minitest::Test
  include NeedsEngine

  def test_rejects_files_that_are_not_swmm_output
    assert_raises(Swmm::OutputFormatError) { Swmm::OutputFile.new("x" * 100) }
    assert_raises(Swmm::OutputFormatError) { Swmm::OutputFile.new("") }
  end

  def test_rejects_a_truncated_file
    Dir.mktmpdir do |dir|
      bytes = File.binread(Swmm.run(Fixtures.base, dir: dir).files[:out])
      assert_equal 12, Swmm::OutputFile.new(bytes).periods
      assert_raises(Swmm::OutputFormatError) { Swmm::OutputFile.new(bytes[0, bytes.bytesize - 100] + bytes[-24, 24]) }
    end
  end

  def test_series_lookups_fail_loudly
    Dir.mktmpdir do |dir|
      out = Swmm::OutputFile.new(File.binread(Swmm.run(Fixtures.base, dir: dir).files[:out]))
      error = assert_raises(Swmm::UnknownObject) { out.series(:nodes, "nope", :depth) }
      assert_equal 'nodes has no "nope"', error.message
      assert_kind_of Swmm::Error, error, "one rescue Swmm::Error covers every reading error"
      assert_equal "nodes has no variable :nope", assert_raises(Swmm::UnknownObject) { out.series(:nodes, "J1", :nope) }.message
      assert_equal "unknown kind :pipes (subcatchments, nodes, links, system)", assert_raises(Swmm::UnknownObject) { out.series(:pipes, "J1", :depth) }.message
      assert_raises(Swmm::UnknownObject) { out.series(nil, "J1", :depth) }
      assert_raises(Swmm::UnknownObject) { out.all_series(:pipes) }
      assert_equal out.series(:nodes, "J1", :depth), out.series("nodes", "J1", "depth"), "kinds and variables may be Strings"
    end
  end

  def test_all_series_matches_series_for_every_object
    Dir.mktmpdir do |dir|
      out = Swmm::OutputFile.new(File.binread(Swmm.run(Fixtures.base, dir: dir).files[:out]))
      Swmm::OutputFile::KINDS.each do |kind|
        all = out.all_series(kind)
        assert_equal(kind == :system ? ["system"] : out.ids.fetch(kind), all.keys)
        all.each do |id, vars|
          assert_equal out.variables.fetch(kind), vars.keys
          vars.each { |name, values| assert_equal out.series(kind, id, name), values, "#{kind} #{id} #{name}" }
        end
      end
    end
  end

  def test_all_series_read_in_ractors_equals_the_sequential_read
    Dir.mktmpdir do |dir|
      bytes = File.binread(Swmm.run(Fixtures.base, dir: dir).files[:out])
      sequential = Swmm::OutputFile.new(bytes)
      parallel = Swmm::OutputFile.new(bytes)
      was = [Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from]
      Swmm::OutputFile.ractors = 1
      expected = Swmm::OutputFile::KINDS.to_h { [_1, sequential.all_series(_1)] }
      Swmm::OutputFile.ractors = 2 # 3 nodes over 2 Ractors: the last one gets the short chunk
      Swmm::OutputFile.parallel_from = 0
      assert_equal expected, Swmm::OutputFile::KINDS.to_h { [_1, parallel.all_series(_1)] }
      refute parallel.all_series(:nodes).dig("J1", "depth").frozen?, "callers get plain arrays"
    ensure
      Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from = was
    end
  end
end
