# frozen_string_literal: true

require "test_helper"

# The CONTENT of Result#to_csv, checked against an oracle that only uses the per-object reader (series), never all_series.
class CsvTest < Minitest::Test
  include NeedsEngine

  def expected_csv(result, kind)
    ids = result.ids(kind)
    vars = result.variables(kind)
    stamps = result.times.map { _1.strftime("%Y-%m-%dT%H:%M:%S") }
    table = ids.to_h { |id| [id, vars.map { |v| result.series(kind, id, v) }] }
    rows = stamps.each_index.flat_map do |i|
      ids.map { |id| [stamps[i], quote(id), *table[id].map { |col| col[i].to_s }].join(",") } # nil.to_s is ""
    end
    (["time,id,#{vars.map { quote(_1) }.join(",")}"] + rows).join("\n") << "\n"
  end

  def quote(field) = field.match?(/[",\n]/) ? %("#{field.gsub('"', '""')}") : field

  def test_nodes_links_and_system_rows_match_the_per_object_reader
    result = assert_runs(Fixtures.base)
    %i[nodes links system].each do |kind|
      assert_equal expected_csv(result, kind), result.to_csv(kind), kind
    end
    assert_equal "time,id,#{result.variables(:system).join(",")}\n", result.to_csv(:system).lines.first
    assert_match(/\A2026-03-24T00:10:00,system,/, result.to_csv(:system).lines[1])
  end

  def test_subcatchments_with_quality_columns
    Dir.mktmpdir do |dir|
      result = assert_runs(Fixtures.full(dir), "full model")
      assert_includes result.variables(:subcatchments), "quality:TSS"
      assert_equal expected_csv(result, :subcatchments), result.to_csv(:subcatchments)
      assert_equal expected_csv(result, :nodes), result.to_csv(:nodes)
    end
  end

  def test_ids_with_a_comma_are_quoted
    model = Fixtures.base.merge(
      junctions: [{ name: "J,1", elevation: 10, max_depth: 3 }, { name: "J2", elevation: 9.5, max_depth: 3 }],
      conduits: Fixtures.base[:conduits].map { _1[:name] == "C1" ? _1.merge(from_node: "J,1") : _1 },
      inflows: [{ node: "J,1", series: "Q" }]
    )
    result = assert_runs(model)
    assert_includes result.ids(:nodes), "J,1"
    csv = result.to_csv(:nodes)
    assert_equal expected_csv(result, :nodes), csv
    assert_equal 12, csv.lines.count { _1.include?(%(,"J,1",)) }, "one quoted row per period"
    assert_equal 12, csv.lines.count { _1.include?(",J2,") }
  end

  def test_splitting_the_periods_across_ractors_gives_the_same_csv
    Dir.mktmpdir do |dir|
      result = assert_runs(Fixtures.full(dir), "full model")
      kinds = %i[subcatchments nodes links system]
      was = [Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from]
      Swmm::OutputFile.ractors = 1
      expected = kinds.to_h { [_1, result.to_csv(_1)] }
      Swmm::OutputFile.ractors = 5 # 24 periods in chunks of 5: the last Ractor gets the short one
      Swmm::OutputFile.parallel_from = 0
      assert_equal expected, kinds.to_h { [_1, result.to_csv(_1)] }
    ensure
      Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from = was
    end
  end

  def test_a_kind_without_objects_gives_only_the_header
    csv = assert_runs(Fixtures.base).to_csv(:subcatchments)
    assert_equal 1, csv.lines.size
    assert_match(/\Atime,id,rainfall,/, csv)
  end
end
