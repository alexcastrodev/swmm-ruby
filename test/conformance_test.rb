# frozen_string_literal: true

require "test_helper"

# The input contract against the real engine: if a column is misplaced, the engine rejects the .inp.
class ConformanceTest < Minitest::Test
  include NeedsEngine

  # base network plus extra rows appended to sections
  def model(**extra)
    Fixtures.base.tap { |m| extra.each { |section, rows| m[section] = (m[section] || []) + rows } }
  end

  def test_a_model_using_every_section_runs
    Dir.mktmpdir do |dir|
      full = Fixtures.full(dir)
      assert_empty Swmm::Schema::SECTIONS.keys - full.keys, "fixture must cover every section"
      result = assert_runs(full, "full model")
      assert_equal %w[S1 S2 S3], result.ids(:subcatchments)
      assert_includes result.variables(:nodes), "quality:COD"
      assert_operator result.series(:subcatchments, "S1", :runoff).max, :>, 0, "rain produced runoff"
      assert_path_exists File.join(dir, "end state.hsf")
    end
  end

  def test_outfall_types
    {
      "FREE" => {}, "NORMAL" => {}, "FIXED" => { stage_data: 9.1 }, "TIDAL" => { stage_data: "TIDE" }, "TIMESERIES" => { stage_data: "STG" }
    }.each do |type, extra|
      m = model(curves: [{ name: "TIDE", type: "TIDAL", points: [[0, 9], [12, 9.5], [24, 9]] }],
                timeseries: [{ name: "STG", points: [[0, 9], [2, 9.5]] }])
      m[:outfalls] = [{ name: "O1", elevation: 9, type: type, gated: true, route_to: nil }.merge(extra).compact]
      assert_runs(m, "outfall #{type}")
    end
  end

  def test_storage_shapes
    shapes = {
      "TABULAR" => { curve: "STC" }, "FUNCTIONAL" => { coefficient: 100, exponent: 0.5, constant: 50 },
      "CYLINDRICAL" => { a: 10, b: 5, z: 3 }, "CONICAL" => { a: 10, b: 5, z: 3 }, "PARABOLIC" => { a: 10, b: 5, z: 3 },
      "PYRAMIDAL" => { a: 10, b: 5, z: 3 }
    }
    shapes.each do |shape, extra|
      m = model(curves: [{ name: "STC", type: "STORAGE", points: [[0, 50], [3, 150]] }],
                storage: [{ name: "ST", elevation: 8, max_depth: 3, init_depth: 0, shape: shape, surcharge_depth: 0.5, evap_fraction: 0.1, seepage: [1] }.merge(extra)],
                conduits: [{ name: "C3", from_node: "J2", to_node: "ST", length: 50, roughness: 0.013, in_offset: 0, out_offset: 0 }],
                xsections: [{ link: "C3", shape: "CIRCULAR", geom1: 0.3 }])
      assert_runs(m, "storage #{shape}")
    end
  end

  def test_divider_types
    { "CUTOFF" => { cutoff_flow: 10 }, "OVERFLOW" => {}, "TABULAR" => { curve: "DIV" },
      "WEIR" => { weir_min_flow: 1, weir_max_depth: 1, weir_coefficient: 10 } }.each do |type, extra|
      m = model(curves: [{ name: "DIV", type: "DIVERSION", points: [[0, 0], [100, 50]] }],
                outfalls: [{ name: "O2", elevation: 8, type: "FREE" }, { name: "O3", elevation: 8, type: "FREE" }],
                dividers: [{ name: "D", elevation: 8.5, diverted_link: "CD", type: type, max_depth: 2 }.merge(extra)],
                conduits: [{ name: "C3", from_node: "J2", to_node: "D", length: 50, roughness: 0.013, in_offset: 0, out_offset: 0 },
                           { name: "CD", from_node: "D", to_node: "O2", length: 50, roughness: 0.013, in_offset: 0, out_offset: 0 },
                           { name: "CM", from_node: "D", to_node: "O3", length: 50, roughness: 0.013, in_offset: 0, out_offset: 0 }],
                xsections: %w[C3 CD CM].map { { link: _1, shape: "CIRCULAR", geom1: 0.3 } })
      assert_runs(m, "divider #{type}")
    end
  end

  def test_regulator_links
    link = ->(name, extra) { { name: name, from_node: "J1", to_node: "J2" }.merge(extra) }
    cases = {
      weirs: %w[TRANSVERSE SIDEFLOW V-NOTCH TRAPEZOIDAL ROADWAY].to_h do |t|
        [t, [link.("L", type: t, crest_height: 0.2, discharge_coeff: 1.8, end_contractions: 1, can_surcharge: false,
                   **(t == "ROADWAY" ? { road_width: 5, road_surface: "GRAVEL" } : {})),
             { link: "L", shape: { "V-NOTCH" => "TRIANGULAR", "TRAPEZOIDAL" => "TRAPEZOIDAL" }.fetch(t, "RECT_OPEN"), geom1: 0.5, geom2: 0.5, geom3: 1, geom4: 1 }]]
      end,
      orifices: { "SIDE" => [link.("L", type: "SIDE", offset: 0.1, discharge_coeff: 0.6, gated: true, close_time: 10), { link: "L", shape: "RECT_CLOSED", geom1: 0.3, geom2: 0.3 }],
                  "BOTTOM" => [link.("L", type: "BOTTOM", offset: 0.1, discharge_coeff: 0.6), { link: "L", shape: "CIRCULAR", geom1: 0.3 }] },
      pumps: { "curve" => [link.("L", curve: "PC", status: "OFF", startup_depth: 1, shutoff_depth: 0.1), nil] },
      outlets: {
        "TABULAR/DEPTH" => [link.("L", offset: 0, type: "TABULAR/DEPTH", curve: "RC"), nil], "TABULAR/HEAD" => [link.("L", offset: 0, type: "TABULAR/HEAD", curve: "RC"), nil],
        "FUNCTIONAL/DEPTH" => [link.("L", offset: 0, type: "FUNCTIONAL/DEPTH", coefficient: 5, exponent: 1.2, gated: true), nil],
        "FUNCTIONAL/HEAD" => [link.("L", offset: 0, type: "FUNCTIONAL/HEAD", coefficient: 5, exponent: 1.2), nil]
      }
    }
    cases.each do |section, variants|
      variants.each do |name, (row, xsection)|
        m = model(section => [row], curves: [{ name: "RC", type: "RATING", points: [[0, 0], [1, 10]] }, { name: "PC", type: "PUMP1", points: [[0, 0], [1, 10]] }])
        m[:xsections] += [xsection] if xsection
        assert_runs(m, "#{section} #{name}")
      end
    end
  end

  def test_ideal_pump_must_be_the_only_link_leaving_its_node
    m = model(junctions: [{ name: "JP", elevation: 9.8, max_depth: 3 }], pumps: [{ name: "PI", from_node: "JP", to_node: "J2" }],
              inflows: [{ node: "JP", series: "Q" }])
    assert_runs(m, "ideal pump")
  end

  GEOMETRY = {
    "FILLED_CIRCULAR" => { geom1: 0.5, geom2: 0.1 }, "RECT_CLOSED" => { geom1: 0.5, geom2: 0.5 }, "RECT_OPEN" => { geom1: 0.5, geom2: 0.5 },
    "TRAPEZOIDAL" => { geom1: 0.5, geom2: 0.5, geom3: 1, geom4: 1 }, "TRIANGULAR" => { geom1: 0.5, geom2: 0.5 },
    "PARABOLIC" => { geom1: 0.5, geom2: 0.5 }, "POWER" => { geom1: 0.5, geom2: 0.5, geom3: 2 },
    "RECT_TRIANGULAR" => { geom1: 0.5, geom2: 0.5, geom3: 0.2 }, "RECT_ROUND" => { geom1: 0.5, geom2: 0.5, geom3: 0.2 },
    "MODBASKETHANDLE" => { geom1: 0.5, geom2: 0.5, geom3: 0.1 }, "FORCE_MAIN" => { geom1: 0.5, geom2: 130 },
    "HORIZ_ELLIPSE" => { geom1: 0.5, geom2: 0.5 }, "VERT_ELLIPSE" => { geom1: 0.5, geom2: 0.5 }, "ARCH" => { geom1: 0.5, geom2: 0.5 }
  }.freeze

  def test_every_conduit_cross_section_shape
    (Swmm::Schema::SHAPES - %w[IRREGULAR STREET CUSTOM]).each do |shape|
      m = Fixtures.base
      m[:xsections] = [{ link: "C1", shape: shape, geom1: 0.5, barrels: 2 }.merge(GEOMETRY.fetch(shape, {})), { link: "C2", shape: "CIRCULAR", geom1: 0.4 }]
      assert_runs(m, "xsection #{shape}")
    end
  end

  def test_raingage_sources_and_pollutant_functions
    gage = { name: "G", format: "VOLUME", interval: "1:00", snow_catch_factor: 1.1 }
    assert_runs(model(raingages: [gage.merge(source: "TIMESERIES", series: "R")], timeseries: [{ name: "R", points: [[0, 0], [1, 5]] }]), "gage timeseries")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rain.dat")
      File.write(path, "STA1 2026 3 24 0 0 5\nSTA1 2026 3 24 1 0 3\n")
      assert_runs(model(raingages: [gage.merge(source: "FILE", path: path, station: "STA1", units: "MM", start_date: "2026-03-24")]), "gage file")
    end
  end

  def test_curve_types_and_pattern_types_are_accepted
    curves = Swmm::Schema::CURVE_TYPES.map { { name: "K_#{_1}", type: _1, points: [[0, 0], [1, 1]] } }
    patterns = Swmm::Schema::PATTERN_SIZES.map { |t, n| { name: "P_#{t}", type: t, factors: [1] * n } }
    assert_runs(model(curves: curves, patterns: patterns), "curves and patterns")
  end
end
