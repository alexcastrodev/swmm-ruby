# frozen_string_literal: true

require "test_helper"

class InputTest < Minitest::Test
  def inp(**sections) = Swmm::Input.new(sections).to_inp

  def errors(**sections) = Swmm::Input.validate(sections).to_h { [_1[:path], _1[:message]] }

  def test_rows_get_defaults_and_blanks_are_rejected_in_names_and_quoted_in_labels
    assert_equal({ "junctions[0].name" => "must not contain blanks" }, errors(junctions: [{ name: "Poço 1", elevation: 10 }]))
    assert_includes inp(tags: [{ type: "Node", name: "J1", tag: "up stream" }]), %(Node J1 "up stream")
    assert_includes inp(conduits: [{ name: "C", from_node: "A", to_node: "B", length: 5, roughness: 0.01, in_offset: 0, out_offset: 0 }]), "C A B 5 0.01 0 0 0 0"
  end

  def test_values_are_normalised_to_swmm_syntax
    text = inp(options: { flow_units: "lps", start_date: "2026-03-24", end_time: "01:30", report_step: 900, allow_ponding: true },
               outfalls: [{ name: "O", elevation: 1, type: "free", gated: false }])
    assert_includes text, "FLOW_UNITS           LPS"
    assert_includes text, "START_DATE           03/24/2026"
    assert_includes text, "REPORT_STEP          0:15:00"
    assert_includes text, "ALLOW_PONDING        YES"
    assert_includes text, "O 1 FREE NO"
  end

  def test_columns_that_depend_on_another_column
    assert_includes inp(outfalls: [{ name: "O", elevation: 1, type: "FIXED", stage_data: 2.5 }]), "O 1 FIXED 2.5 NO"
    assert_equal({ "outfalls[0].stage_data" => "is required" }, errors(outfalls: [{ name: "O", elevation: 1, type: "FIXED" }]))
    assert_equal ["outfalls[0].stage_data"], errors(outfalls: [{ name: "O", elevation: 1, type: "FREE", stage_data: 1 }]).keys
  end

  def test_every_violation_is_reported_with_its_path
    found = errors(options: { flow_units: "GALLONS", nope: 1 }, junctions: [{ name: "", elevation: "x", extra: 1 }, "not a row"],
                   patterns: [{ name: "P", type: "HOURLY", factors: [1] }], bogus: [])
    assert_equal ["input.bogus", "junctions[0].elevation", "junctions[0].extra", "junctions[0].name", "junctions[1]",
                  "options.flow_units", "options.nope", "patterns[0].factors"], found.keys.sort
    assert_raises(Swmm::InvalidInput) { Swmm::Input.new(junctions: [{ name: "J" }]) }
  end

  def test_optional_columns_cannot_be_skipped_over
    row = { subcatchment: "S", aquifer: "A", node: "N", surface_elevation: 1, a1: 0, b1: 0, a2: 0, b2: 0, a3: 0, fixed_depth: 0 }
    assert_includes inp(groundwater: [row]), "S A N 1 0 0 0 0 0 0 *"
    assert_includes errors(groundwater: [row.merge(water_table_elevation: 3)])["groundwater[0].water_table_elevation"], "bottom_elevation"
  end

  def test_keyword_sections_take_hashes
    text = inp(evaporation: { monthly: (1..12).to_a, dry_only: true }, temperature: { file: ["clima.dat", "2020-01-01", "C"], windspeed_file: true },
               report: { input: false, nodes: %w[A B], links: "ALL" })
    assert_includes text, "MONTHLY 1 2 3 4 5 6 7 8 9 10 11 12"
    assert_includes text, "DRY_ONLY YES"
    assert_includes text, "FILE clima.dat 01/01/2020 C"
    assert_includes text, "WINDSPEED FILE"
    assert_includes text, "INPUT NO\nNODES A B\nLINKS ALL"
    refute_empty errors(evaporation: { monthly: [1, 2] }), "wrong value count"
  end

  def test_multi_line_objects
    text = inp(timeseries: [{ name: "T", points: [["2026-03-24 10:00", 1], [0.5, 2]] }, { name: "F", file: "data.dat" }],
               curves: [{ name: "C", type: "pump1", points: [[0, 0], [1, 5]] }],
               transects: [{ name: "T1", n_left: 0.05, n_right: 0.05, n_channel: 0.03, x_left: 1, x_right: 9,
                             stations: (0..9).map { [_1, _1 * 2] } }])
    assert_includes text, "T 03/24/2026 10:00 1\nT 0.5 2"
    assert_includes text, "F FILE data.dat"
    assert_includes text, "C PUMP1 0 0\nC 1 5"
    assert_includes text, "NC 0.05 0.05 0.03\nX1 T1 10 1 9 0 0 0 1 1\nGR 0 0 1 2"
    assert_equal 2, text.scan(/^GR /).size, "10 stations wrap onto 2 GR lines"
  end

  def test_rule_hashes_become_control_rules
    text = inp(controls: [{ name: "R1", if: ["NODE J DEPTH > 1", "AND LINK C FLOW < 2"], then: ["PUMP P STATUS = ON"], priority: 2 }, "VARIABLE x = NODE J DEPTH"])
    assert_includes text, "RULE R1\n  IF NODE J DEPTH > 1\n  AND LINK C FLOW < 2\n  THEN PUMP P STATUS = ON\n  PRIORITY 2"
    assert_includes text, "VARIABLE x = NODE J DEPTH"
  end

  def test_raw_array_rows_pass_through_and_respect_the_engine_token_limit
    assert_includes inp(junctions: [["J", 1, "*", true]]), "J 1 * YES"
    assert_equal ["junctions[0]"], errors(junctions: [Array.new(41) { "x" }]).keys
  end

  def test_a_json_document_is_a_valid_input
    Dir.mktmpdir do |dir|
      model = Fixtures.full(dir)
      from_json = JSON.parse(JSON.generate(model)) # string keys at every level, times as strings
      assert_empty Swmm::Input.validate(from_json)
      assert_equal Swmm::Input.new(model.merge(timeseries: [])).to_inp.lines.size, Swmm::Input.new(from_json.merge("timeseries" => [])).to_inp.lines.size
    end
  end

  def test_describe_documents_every_section
    doc = Swmm::Schema.describe
    Swmm::Schema::SECTIONS.each_key { assert_includes doc, "## `#{_1}`" }
  end
end
