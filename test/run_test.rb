# frozen_string_literal: true

require "test_helper"

class RunTest < Minitest::Test
  include NeedsEngine

  def test_run_returns_the_output_contract
    result = assert_runs(Fixtures.base)
    assert_match(/\A5\.\d+\.\d+\z/, result.version)
    assert_equal "ok", result.status
    assert_nil result.error
    assert_equal 12, result.times.size, "2 h at a 10 min report step"
    assert_equal Time.utc(2026, 3, 24, 0, 10), result.times.first
    assert_equal %w[J1 J2 O1], result.ids(:nodes)
    assert_in_delta 0, result.continuity[:flow_routing], 1
    assert result.continuity_ok?
    refute result.continuity_ok?(tolerance: 0.01), "the base model has about -0.14 % flow routing error"
    assert_empty result.flow_instability
    flow = result.series(:links, "C2", :flow)
    assert_equal 12, flow.size
    assert_operator flow.max, :>, 60, "the 80 L/s hydrograph reaches the outlet"
    assert_equal({ "flow" => "LPS", "depth" => "m", "velocity" => "m/s" }, result.to_h[:output][:units][:links].slice("flow", "depth", "velocity"))
  end

  def test_to_h_json_and_csv_carry_the_same_data
    result = Swmm.run(Fixtures.base)
    data = JSON.parse(result.to_json, symbolize_names: true)
    assert_equal %i[status swmm_version error warnings continuity flow_instability files output], data.keys
    assert_equal result.series(:nodes, "J1", :depth), data[:output][:nodes][:J1][:depth]
    assert_equal result.times.size, data[:output][:times].size
    assert_nil Swmm.run(Fixtures.base).to_h(series: false)[:output][:nodes]["J1"]["depth"]
    csv = result.to_csv(:links).lines
    assert_equal "time,id,flow,depth,velocity,volume,capacity\n", csv.first
    assert_equal 1 + (12 * 2), csv.size, "one row per link per period"
  end

  def test_engine_errors_come_back_in_the_result
    model = Fixtures.base.merge(conduits: [{ name: "C1", from_node: "J1", to_node: "NOPE", length: 1, roughness: 0.01, in_offset: 0, out_offset: 0 }])
    result = Swmm.run(model)
    refute result.ok?
    assert_equal 200, result.error[:code]
    refute result.continuity_ok?
    assert_empty result.flow_instability
    assert_match(/ERROR 209: undefined object NOPE at line \d+ of \[CONDUIT\] section: C1 J1 NOPE/, result.error[:details].first)
    assert_raises(Swmm::Error) { result.times }
  end

  def test_contract_violations_raise_before_the_engine_runs
    assert_raises(Swmm::InvalidInput) { Swmm.run(junctions: [{ name: "J" }]) }
  end

  def test_dir_keeps_the_files_and_an_existing_inp_can_be_run
    Dir.mktmpdir do |dir|
      first = Swmm.run(Fixtures.base, dir: dir)
      assert_equal %w[model.inp model.out model.rpt], Dir.children(dir).sort
      assert_equal File.join(dir, "model.inp"), first.files[:inp]
      again = Swmm.run(first.files[:inp])
      assert_equal first.series(:nodes, "J2", :depth), again.series(:nodes, "J2", :depth)
      assert_nil again.files, "no dir: => temp files are removed"
    end
  end

  def test_only_reported_objects_are_saved
    result = assert_runs(Fixtures.base.merge(report: { nodes: %w[J2], links: "NONE" }))
    assert_equal %w[J2], result.ids(:nodes)
    assert_empty result.ids(:links)
    assert_equal 12, result.series(:system, "system", :total_inflow).size, "system results are always there"
  end

  def test_run_many_matches_sequential_runs_in_order
    models = [10, 20, 40, 80, 160].map { |q| Fixtures.base.merge(timeseries: [{ name: "Q", points: [[0, 0], [0.5, q / 2.0], [1, q], [2, 0]] }]) }
    bad = Fixtures.base.merge(conduits: [{ name: "C1", from_node: "J1", to_node: "NOPE", length: 1, roughness: 0.01, in_offset: 0, out_offset: 0 }])
    results = Swmm.run_many(models.first(2) + [bad] + models.last(3), workers: 3)
    assert_equal [true, true, false, true, true, true], results.map(&:ok?)
    assert_equal 200, results[2].error[:code]
    (models.first(2) + models.last(3)).zip(results.values_at(0, 1, 3, 4, 5)).each do |model, result|
      assert_equal Swmm.run(model).series(:links, "C2", :flow), result.series(:links, "C2", :flow)
    end
    assert_equal 3, Swmm::Engine.pool(3).uniq.size, "each worker has its own copy of the library"
  end

  def test_run_many_checks_every_contract_before_running_anything
    assert_raises(Swmm::InvalidInput) { Swmm.run_many([Fixtures.base, { junctions: [{ name: "J" }] }]) }
    assert_equal [], Swmm.run_many([])
  end

  def test_an_unstable_model_finishes_ok_but_is_flagged
    short = Fixtures.base.merge(
      options: Fixtures.base[:options].merge(routing_step: 60, end_time: "06:00"),
      conduits: [{ name: "C1", from_node: "J1", to_node: "J2", length: 3, roughness: 0.013, in_offset: 0, out_offset: 0 },
                 { name: "C2", from_node: "J2", to_node: "O1", length: 3, roughness: 0.013, in_offset: 0, out_offset: 0 }],
      timeseries: [{ name: "Q", points: [[0, 0], [0.5, 400], [1, 20], [1.5, 300], [2, 0], [3, 250], [4, 0]] }]
    )
    result = assert_runs(short)
    refute result.continuity_ok?, "flow routing error was #{result.continuity[:flow_routing]} %"
    refute_empty result.flow_instability
    assert(result.flow_instability.all? { |id, turns| id.start_with?("C") && turns.positive? })
  end
end
