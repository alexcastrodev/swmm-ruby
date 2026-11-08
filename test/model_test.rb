# frozen_string_literal: true

require "test_helper"

class ModelTest < Minitest::Test
  PER_TYPE = %i[nodes_junction nodes_outfall nodes_storage nodes_divider links_conduit links_pump links_orifice links_weir links_outlet]
             .map { :"count_#{_1}" }
  TOTALS = %i[total_nodes total_links total_subcatchments total_pollutants].freeze

  def test_is_what_input_read_gives_and_still_the_hash_input_takes
    model = Swmm::Input.parse(Swmm::Input.new(Fixtures.base).to_inp)
    assert_kind_of Swmm::Model, model
    assert_kind_of Hash, model
    model[:options][:end_time] = "01:00"
    assert_includes Swmm::Input.new(model).to_inp, "END_TIME             01:00"
    assert_equal model.to_h, model, "equal to the plain Hash"
  end

  def test_counts_its_objects_per_type_and_in_total_as_the_out_does
    skip "libswmm5 not found: run `rake swmm:build`" unless Swmm::Engine.available?
    Dir.mktmpdir do |dir|
      hash = Fixtures.full(dir)
      model = Swmm::Input.parse(Swmm::Input.new(hash).to_inp)
      output = Swmm.run(hash, dir: dir).output
      by_type = %i[junctions outfalls storage dividers].zip(%w[JUNCTION OUTFALL STORAGE DIVIDER]).to_h { |section, type| [type, hash[section].size] }
      assert_equal by_type, model.count_nodes
      assert_equal %w[CONDUIT PUMP ORIFICE WEIR OUTLET], model.count_links.keys
      assert_equal model.count_nodes.values.sum, model.total_nodes
      (%i[count_nodes count_links] + PER_TYPE + TOTALS).each do |name|
        assert_equal output.public_send(name), model.public_send(name), name.to_s
      end
      assert PER_TYPE.all? { model.public_send(_1).positive? }, "the full model has every type"
    end
  end

  def test_counts_a_hash_of_its_own_string_keys_raw_rows_and_types_it_has_none_of
    model = Swmm::Model["junctions" => [{ name: "J1", elevation: 1 }, %w[J2 1]], outfalls: [{ name: "O1", elevation: 0, type: "FREE" }], conduits: []]
    assert_equal({ "JUNCTION" => 2, "OUTFALL" => 1 }, model.count_nodes)
    assert_equal({}, model.count_links)
    assert_equal [3, 0, 0, 0], [model.total_nodes, model.total_links, model.total_subcatchments, model.total_pollutants]
    assert_equal [2, 0, 0], [model.count_nodes_junction, model.count_nodes_divider, model.count_links_conduit]
    assert_equal({}, Swmm::Model[{}].count_nodes)
  end
end
