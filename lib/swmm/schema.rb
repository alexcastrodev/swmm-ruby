# frozen_string_literal: true

module Swmm
  # The input contract: every [SECTION] of a SWMM 5.2 .inp described as data (column order and
  # arity taken from the EPA parser sources, v5.2.4). Swmm::Input validates against it and renders it.
  #
  # Column definition (one Array per column):
  #   [:name, type]                 required
  #   [:name, type, default]        optional; the default is written when the key is absent
  #                                 (a Proc receives the row)
  #   [:name, type, nil]            optional; written only when given, and only if every earlier
  #                                 optional column was given too
  #   trailing Hash                 count: n | range | [n, m] -> list column (an Array of that many values)
  #                                 only:  [:other, %w[A B]] -> column exists only for those values of :other
  # type: :id :opt_id :any :text :num :int :yn :date :time :seconds :monthday (see Swmm::Types),
  #       or an Array of allowed words.
  module Schema
    Column = Struct.new(:name, :type, :default, :required, :list, :only)
    # kind: :text :options :rows :keywords :block :timeseries :curves :patterns :transects :controls :report
    Section = Struct.new(:kind, :columns, :spec)

    def self.cols(defs)
      defs.map do |name, type, *rest|
        opts = rest.last.is_a?(Hash) ? rest.pop : {}
        Column.new(name, type, rest.first, rest.empty?, opts[:count], opts[:only])
      end
    end

    def self.rows(*defs) = Section.new(:rows, cols(defs))

    # keyword-led lines: { key => [cols] | ["TEXT", cols] }; the written keyword defaults to KEY.upcase
    def self.keywords(table)
      Section.new(:keywords, nil, table.to_h { |k, v| [k, v.first.is_a?(String) ? [v[0], cols(v[1])] : [k.to_s.upcase, cols(v)]] })
    end

    # named object spread over several lines: an optional head line plus keyword-led parts
    def self.block(head: nil, parts:)
      Section.new(:block, nil, head: head && cols(head), parts: parts.transform_values { |kw, defs| [kw, cols(defs)] })
    end

    FLOW_UNITS = %w[CFS GPM MGD CMS LPS MLD].freeze
    INFILTRATION = %w[HORTON MODIFIED_HORTON GREEN_AMPT MODIFIED_GREEN_AMPT CURVE_NUMBER].freeze
    CURVE_TYPES = %w[STORAGE DIVERSION TIDAL RATING CONTROL SHAPE WEIR PUMP1 PUMP2 PUMP3 PUMP4 PUMP5].freeze
    PATTERN_SIZES = { "MONTHLY" => 12, "DAILY" => 7, "HOURLY" => 24, "WEEKEND" => 24 }.freeze
    SHAPES = %w[DUMMY CIRCULAR FILLED_CIRCULAR RECT_CLOSED RECT_OPEN TRAPEZOIDAL TRIANGULAR PARABOLIC POWER
                RECT_TRIANGULAR RECT_ROUND MODBASKETHANDLE HORIZ_ELLIPSE VERT_ELLIPSE ARCH EGG HORSESHOE GOTHIC
                CATENARY SEMIELLIPTICAL BASKETHANDLE SEMICIRCULAR IRREGULAR CUSTOM FORCE_MAIN STREET].freeze
    REPORT_FLAGS = %i[disabled input continuity flowstats controls averages].freeze
    REPORT_OBJECTS = %i[subcatchments nodes links].freeze

    # [OPTIONS]: key => type
    OPTIONS = {
      flow_units: FLOW_UNITS, infiltration: INFILTRATION, flow_routing: %w[NONE STEADY KINWAVE DYNWAVE],
      link_offsets: %w[DEPTH ELEVATION], force_main_equation: %w[H-W D-W], surcharge_method: %w[EXTRAN SLOT],
      inertial_damping: %w[NONE PARTIAL FULL], normal_flow_limited: %w[SLOPE FROUDE BOTH NONE],
      allow_ponding: :yn, skip_steady_state: :yn, slope_weighting: :yn, ignore_rainfall: :yn,
      ignore_snowmelt: :yn, ignore_groundwater: :yn, ignore_rdii: :yn, ignore_routing: :yn, ignore_quality: :yn,
      start_date: :date, end_date: :date, report_start_date: :date,
      start_time: :time, end_time: :time, report_start_time: :time,
      sweep_start: :monthday, sweep_end: :monthday, dry_days: :num,
      report_step: :time, wet_step: :time, dry_step: :time, rule_step: :time,
      routing_step: :seconds, lengthening_step: :seconds, variable_step: :num, min_surfarea: :num,
      min_slope: :num, head_tolerance: :num, sys_flow_tol: :num, lat_flow_tol: :num, minimum_step: :num,
      max_trials: :int, threads: :int, tempdir: :id, compatibility: %w[3 4 5]
    }.freeze

    NODE_ONLY = ->(*types) { { only: [:type, types] } }
    LAYER_NUMBERS = ->(*names) { names.map { [_1, :num] } }

    # Canonical order = order sections are written to the .inp.
    SECTIONS = {
      title: Section.new(:text),
      options: Section.new(:options, nil, OPTIONS),
      files: rows([:mode, %w[USE SAVE]], [:type, %w[RAINFALL RUNOFF HOTSTART RDII INFLOWS OUTFLOWS]], [:path, :id]),

      # --- climate & hydrology
      raingages: rows(
        [:name, :id], [:format, %w[INTENSITY VOLUME CUMULATIVE]], [:interval, :time], [:snow_catch_factor, :num, 1],
        [:source, %w[TIMESERIES FILE]], [:series, :id, { only: [:source, %w[TIMESERIES]] }],
        [:path, :id, { only: [:source, %w[FILE]] }], [:station, :id, { only: [:source, %w[FILE]] }],
        [:units, %w[IN MM], { only: [:source, %w[FILE]] }], [:start_date, :date, nil, { only: [:source, %w[FILE]] }]
      ),
      temperature: keywords(
        timeseries: [[:series, :id]],
        file: [[:path, :id], [:start_date, :date, nil], [:units, %w[C10 C F], nil]],
        windspeed_monthly: ["WINDSPEED MONTHLY", [[:values, :num, { count: 12 }]]],
        windspeed_file: ["WINDSPEED FILE", []],
        snowmelt: [[:values, :num, { count: 6 }]],
        adc_impervious: ["ADC IMPERVIOUS", [[:values, :num, { count: 10 }]]],
        adc_pervious: ["ADC PERVIOUS", [[:values, :num, { count: 10 }]]]
      ),
      evaporation: keywords(
        constant: [[:value, :num]], monthly: [[:values, :num, { count: 12 }]], timeseries: [[:series, :id]],
        temperature: [], file: [[:pan_coefficients, :num, { count: [0, 12] }]],
        recovery: [[:pattern, :id]], dry_only: [[:value, :yn]]
      ),
      adjustments: keywords(
        temperature: [[:values, :num, { count: 12 }]], evaporation: [[:values, :num, { count: 12 }]],
        rainfall: [[:values, :num, { count: 12 }]], conductivity: [[:values, :num, { count: 12 }]],
        n_perv: ["N-PERV", [[:subcatchment, :id], [:pattern, :id]]],
        dstore: [[:subcatchment, :id], [:pattern, :id]],
        infil: [[:subcatchment, :id], [:pattern, :id]]
      ),
      subcatchments: rows(
        [:name, :id], [:raingage, :id], [:outlet, :id], [:area, :num], [:pct_imperv, :num], [:width, :num],
        [:slope, :num], [:curb_length, :num, 0], [:snowpack, :id, nil]
      ),
      subareas: rows(
        [:subcatchment, :id], [:n_imperv, :num], [:n_perv, :num], [:storage_imperv, :num], [:storage_perv, :num],
        [:pct_zero_storage, :num], [:route_to, %w[OUTLET IMPERVIOUS PERVIOUS], "OUTLET"], [:pct_routed, :num, 100]
      ),
      # params: HORTON/MODIFIED_HORTON max_rate min_rate decay dry_time [max_volume];
      #         GREEN_AMPT/MODIFIED_GREEN_AMPT suction conductivity initial_deficit;
      #         CURVE_NUMBER curve_number conductivity(unused) dry_time. method overrides [OPTIONS] INFILTRATION.
      infiltration: rows([:subcatchment, :id], [:params, :num, { count: 3..5 }], [:method, INFILTRATION, nil]),
      aquifers: rows(
        [:name, :id], [:porosity, :num], [:wilting_point, :num], [:field_capacity, :num], [:conductivity, :num],
        [:conductivity_slope, :num], [:tension_slope, :num], [:upper_evap_fraction, :num], [:lower_evap_depth, :num],
        [:lower_loss_rate, :num], [:bottom_elevation, :num], [:water_table_elevation, :num], [:upper_moisture, :num],
        [:evap_pattern, :id, nil]
      ),
      groundwater: rows(
        [:subcatchment, :id], [:aquifer, :id], [:node, :id], [:surface_elevation, :num], [:a1, :num], [:b1, :num],
        [:a2, :num], [:b2, :num], [:a3, :num], [:fixed_depth, :num], [:node_elevation, :any, "*"], # the engine requires this 11th token ("*" = node invert)
        [:bottom_elevation, :any, nil], [:water_table_elevation, :any, nil], [:upper_moisture, :any, nil]
      ),
      gwf: rows([:subcatchment, :id], [:flow, %w[LATERAL DEEP]], [:expression, :text]),
      snowpacks: block(parts: {
        plowable: ["PLOWABLE", LAYER_NUMBERS.(:min_melt_coeff, :max_melt_coeff, :base_temp, :free_water_fraction,
                                              :initial_depth, :initial_free_water, :depth_at_full_cover)],
        impervious: ["IMPERVIOUS", LAYER_NUMBERS.(:min_melt_coeff, :max_melt_coeff, :base_temp, :free_water_fraction,
                                                  :initial_depth, :initial_free_water, :depth_at_full_cover)],
        pervious: ["PERVIOUS", LAYER_NUMBERS.(:min_melt_coeff, :max_melt_coeff, :base_temp, :free_water_fraction,
                                              :initial_depth, :initial_free_water, :depth_at_full_cover)],
        removal: ["REMOVAL", LAYER_NUMBERS.(:plow_depth, :fraction_out, :fraction_impervious, :fraction_pervious,
                                            :fraction_melt, :fraction_to_subcatchment) + [[:subcatchment, :id, nil]]]
      }),

      # --- nodes
      junctions: rows(
        [:name, :id], [:elevation, :num], [:max_depth, :num, 0], [:init_depth, :num, 0],
        [:surcharge_depth, :num, 0], [:ponded_area, :num, 0]
      ),
      outfalls: rows(
        [:name, :id], [:elevation, :num], [:type, %w[FREE NORMAL FIXED TIDAL TIMESERIES]],
        [:stage_data, :any, NODE_ONLY.("FIXED", "TIDAL", "TIMESERIES")], # stage | tidal curve | time series
        [:gated, :yn, "NO"], [:route_to, :id, nil]
      ),
      storage: rows(
        [:name, :id], [:elevation, :num], [:max_depth, :num], [:init_depth, :num],
        [:shape, %w[TABULAR FUNCTIONAL CYLINDRICAL CONICAL PARABOLIC PYRAMIDAL]],
        [:curve, :id, { only: [:shape, %w[TABULAR]] }],
        [:coefficient, :num, { only: [:shape, %w[FUNCTIONAL]] }], [:exponent, :num, { only: [:shape, %w[FUNCTIONAL]] }],
        [:constant, :num, { only: [:shape, %w[FUNCTIONAL]] }],
        # cylindrical/conical/parabolic: A=major axis B=minor axis Z=height; pyramidal: A=length B=width Z=height
        [:a, :num, { only: [:shape, %w[CYLINDRICAL CONICAL PARABOLIC PYRAMIDAL]] }],
        [:b, :num, { only: [:shape, %w[CYLINDRICAL CONICAL PARABOLIC PYRAMIDAL]] }],
        [:z, :num, { only: [:shape, %w[CYLINDRICAL CONICAL PARABOLIC PYRAMIDAL]] }],
        [:surcharge_depth, :num, 0], [:evap_fraction, :num, 0], [:seepage, :num, { count: 0..3 }] # [suction] ksat [imd]
      ),
      dividers: rows(
        [:name, :id], [:elevation, :num], [:diverted_link, :id, "*"], [:type, %w[CUTOFF TABULAR WEIR OVERFLOW]],
        [:cutoff_flow, :num, { only: [:type, %w[CUTOFF]] }], [:curve, :id, { only: [:type, %w[TABULAR]] }],
        [:weir_min_flow, :num, { only: [:type, %w[WEIR]] }], [:weir_max_depth, :num, { only: [:type, %w[WEIR]] }],
        [:weir_coefficient, :num, { only: [:type, %w[WEIR]] }],
        [:max_depth, :num, 0], [:init_depth, :num, 0], [:surcharge_depth, :num, 0], [:ponded_area, :num, 0]
      ),

      # --- links
      conduits: rows(
        [:name, :id], [:from_node, :id], [:to_node, :id], [:length, :num], [:roughness, :num],
        [:in_offset, :any], [:out_offset, :any], [:init_flow, :num, 0], [:max_flow, :num, 0] # offsets accept "*" with LINK_OFFSETS ELEVATION
      ),
      pumps: rows(
        [:name, :id], [:from_node, :id], [:to_node, :id], [:curve, :id, "*"], [:status, %w[ON OFF], "ON"],
        [:startup_depth, :num, 0], [:shutoff_depth, :num, 0]
      ),
      orifices: rows(
        [:name, :id], [:from_node, :id], [:to_node, :id], [:type, %w[SIDE BOTTOM]], [:offset, :any],
        [:discharge_coeff, :num], [:gated, :yn, "NO"], [:close_time, :num, 0]
      ),
      weirs: rows(
        [:name, :id], [:from_node, :id], [:to_node, :id], [:type, %w[TRANSVERSE SIDEFLOW V-NOTCH TRAPEZOIDAL ROADWAY]],
        [:crest_height, :any], [:discharge_coeff, :num], [:gated, :yn, "NO"], [:end_contractions, :num, 0],
        [:end_coeff, :num, 0], [:can_surcharge, :yn, "YES"], [:road_width, :any, "*"], [:road_surface, :any, "*"],
        [:coeff_curve, :id, nil]
      ),
      outlets: rows(
        [:name, :id], [:from_node, :id], [:to_node, :id], [:offset, :any],
        [:type, %w[TABULAR/DEPTH TABULAR/HEAD FUNCTIONAL/DEPTH FUNCTIONAL/HEAD TABULAR FUNCTIONAL]],
        [:curve, :id, { only: [:type, %w[TABULAR/DEPTH TABULAR/HEAD TABULAR]] }],
        [:coefficient, :num, { only: [:type, %w[FUNCTIONAL/DEPTH FUNCTIONAL/HEAD FUNCTIONAL]] }],
        [:exponent, :num, { only: [:type, %w[FUNCTIONAL/DEPTH FUNCTIONAL/HEAD FUNCTIONAL]] }],
        [:gated, :yn, "NO"]
      ),
      # geom1..4 depend on the shape (see the SWMM manual, Cross-section geometry); CUSTOM: geom1 = height, curve = shape curve
      xsections: rows(
        [:link, :id], [:shape, SHAPES],
        [:transect, :id, { only: [:shape, %w[IRREGULAR]] }], [:street, :id, { only: [:shape, %w[STREET]] }],
        [:geom1, :num, { only: [:shape, SHAPES - %w[IRREGULAR STREET]] }],
        [:curve, :id, { only: [:shape, %w[CUSTOM]] }],
        [:geom2, :num, 0, { only: [:shape, SHAPES - %w[IRREGULAR STREET CUSTOM]] }],
        [:geom3, :num, 0, { only: [:shape, SHAPES - %w[IRREGULAR STREET]] }],
        [:geom4, :num, 0, { only: [:shape, SHAPES - %w[IRREGULAR STREET]] }],
        [:barrels, :int, 1, { only: [:shape, SHAPES - %w[IRREGULAR STREET]] }],
        [:culvert_code, :int, nil, { only: [:shape, SHAPES - %w[IRREGULAR STREET]] }]
      ),
      transects: Section.new(:transects),
      losses: rows(
        [:link, :id], [:inlet, :num, 0], [:outlet, :num, 0], [:average, :num, 0], [:flap_gate, :yn, "NO"],
        [:seepage_rate, :num, 0]
      ),
      controls: Section.new(:controls),

      # --- water quality
      pollutants: rows(
        [:name, :id], [:units, %w[MG/L UG/L #/L]], [:rain_conc, :num], [:groundwater_conc, :num], [:rdii_conc, :num],
        [:decay_coeff, :num], [:snow_only, :yn, "NO"], [:co_pollutant, :id, "*"], [:co_fraction, :num, 0],
        [:dwf_conc, :num, 0], [:init_conc, :num, 0]
      ),
      landuses: rows([:name, :id], [:sweep_interval, :num, 0], [:sweep_removal, :num, 0], [:last_swept, :num, 0]),
      buildup: rows(
        [:landuse, :id], [:pollutant, :id], [:function, %w[NONE POW EXP SAT EXT]],
        [:c1, :num, { only: [:function, %w[POW EXP SAT EXT]] }], [:c2, :num, { only: [:function, %w[POW EXP SAT EXT]] }],
        [:c3, :any, { only: [:function, %w[POW EXP SAT EXT]] }], # EXT: time series name
        [:normalizer, %w[AREA CURB], { only: [:function, %w[POW EXP SAT EXT]] }]
      ),
      washoff: rows(
        [:landuse, :id], [:pollutant, :id], [:function, %w[NONE EXP RC EMC]],
        [:coefficient, :num, { only: [:function, %w[EXP RC EMC]] }], [:exponent, :num, { only: [:function, %w[EXP RC EMC]] }],
        [:cleaning_efficiency, :num, 0, { only: [:function, %w[EXP RC EMC]] }],
        [:bmp_efficiency, :num, 0, { only: [:function, %w[EXP RC EMC]] }]
      ),
      coverages: rows([:subcatchment, :id], [:landuses, :any, { count: 2..38 }]), # landuse, percent, landuse, percent ...
      loadings: rows([:subcatchment, :id], [:pollutants, :any, { count: 2..38 }]), # pollutant, initial load, ...
      treatment: rows([:node, :id], [:pollutant, :id], [:expression, :text]), # e.g. "R = 0.5" or "C = C * (1 - 0.3)"

      # --- inflows
      inflows: rows(
        [:node, :id], [:constituent, :id, "FLOW"], [:series, :opt_id, ""],
        [:type, %w[FLOW CONCEN MASS], ->(r) { (r[:constituent] || "FLOW").to_s.casecmp?("FLOW") ? "FLOW" : "CONCEN" }],
        [:units_factor, :num, 1.0], [:scale_factor, :num, 1.0], [:baseline, :num, 0], [:baseline_pattern, :id, nil]
      ),
      dwf: rows([:node, :id], [:constituent, :id, "FLOW"], [:average, :num], [:patterns, :opt_id, { count: 0..4 }]),
      patterns: Section.new(:patterns),
      rdii: rows([:node, :id], [:hydrograph, :id], [:sewer_area, :num]),
      hydrographs: block(head: [[:raingage, :id]], parts: {
        responses: [nil, [[:month, %w[ALL JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC]],
                          [:response, %w[SHORT MEDIUM LONG]], [:r, :num], [:t, :num], [:k, :num],
                          [:initial_abstraction_max, :num, 0], [:recovery, :num, 0], [:initial_abstraction, :num, 0]]]
      }),
      curves: Section.new(:curves),
      timeseries: Section.new(:timeseries),

      # --- output / reporting
      report: Section.new(:report),
      events: rows([:start_date, :date], [:start_time, :time], [:end_date, :date], [:end_time, :time]),

      # --- LID, streets and inlets (5.2)
      lid_controls: block(head: [[:type, %w[BC RG GR IT PP RB RD VS]]], parts: {
        surface: ["SURFACE", LAYER_NUMBERS.(:storage_depth, :vegetation_fraction, :roughness, :surface_slope, :swale_side_slope)],
        soil: ["SOIL", LAYER_NUMBERS.(:thickness, :porosity, :field_capacity, :wilting_point, :conductivity,
                                      :conductivity_slope, :suction_head)],
        storage: ["STORAGE", LAYER_NUMBERS.(:height, :void_ratio, :conductivity, :clog_factor) + [[:covered, :yn, "NO"]]],
        pavement: ["PAVEMENT", LAYER_NUMBERS.(:thickness, :void_ratio, :impervious_fraction, :permeability, :clog_factor) +
                               [[:regen_days, :num, 0], [:regen_degree, :num, 0]]],
        drainmat: ["DRAINMAT", LAYER_NUMBERS.(:thickness, :void_ratio, :roughness)],
        drain: ["DRAIN", LAYER_NUMBERS.(:coefficient, :exponent, :offset, :delay) +
                         [[:open_level, :num, 0], [:close_level, :num, 0], [:control_curve, :id, nil]]],
        removals: ["REMOVALS", [[:pollutant, :id], [:percent, :num]]]
      }),
      lid_usage: rows(
        [:subcatchment, :id], [:lid, :id], [:number, :int], [:area, :num], [:width, :num], [:init_saturation, :num],
        [:from_impervious, :num], [:to_pervious, :int], [:report_file, :any, "*"], [:drain_to, :any, "*"],
        [:from_pervious, :num, 0]
      ),
      streets: rows(
        [:name, :id], [:crown_width, :num], [:curb_height, :num], [:cross_slope, :num], [:roughness, :num],
        [:gutter_depression, :num, 0], [:gutter_width, :num, 0], [:sides, :int, 1], [:back_width, :num, 0],
        [:back_slope, :num, 0], [:back_roughness, :num, 0]
      ),
      inlet_usage: rows(
        [:link, :id], [:inlet, :id], [:node, :id], [:count, :int, 1], [:pct_clogged, :num, 0], [:max_flow, :num, 0],
        [:local_depression, :num, 0], [:local_width, :num, 0],
        [:placement, %w[AUTOMATIC ON_GRADE ON_SAG], "AUTOMATIC"]
      ),
      inlets: rows(
        [:name, :id], [:type, %w[GRATE CURB SLOTTED DROP_GRATE DROP_CURB CUSTOM]],
        [:length, :num, { only: [:type, %w[GRATE CURB SLOTTED DROP_GRATE DROP_CURB]] }],
        [:width, :num, { only: [:type, %w[GRATE SLOTTED DROP_GRATE]] }],
        [:height, :num, { only: [:type, %w[CURB DROP_CURB]] }],
        [:grate_type, %w[P_BAR-50 P_BAR-50x100 P_BAR-30 CURVED_VANE TILT_BAR-45 TILT_BAR-30 RETICULINE GENERIC],
         { only: [:type, %w[GRATE DROP_GRATE]] }],
        [:open_area, :num, { only: [:grate_type, %w[GENERIC]] }],
        [:splash_velocity, :num, nil, { only: [:grate_type, %w[GENERIC]] }],
        [:throat_type, %w[HORIZONTAL INCLINED VERTICAL], nil, { only: [:type, %w[CURB]] }],
        [:curve, :id, { only: [:type, %w[CUSTOM]] }]
      ),

      # --- drawing data (ignored by the engine; kept so a GUI model round-trips)
      coordinates: rows([:node, :id], [:x, :num], [:y, :num]),
      vertices: rows([:link, :id], [:x, :num], [:y, :num]),
      polygons: rows([:subcatchment, :id], [:x, :num], [:y, :num]),
      labels: rows([:x, :num], [:y, :num], [:text, :id]),
      symbols: rows([:gage, :id], [:x, :num], [:y, :num]),
      tags: rows([:type, %w[Node Link Subcatch Gage]], [:name, :id], [:tag, :id]),
      profiles: rows([:name, :id], [:links, :id, { count: 1..38 }]),
      map: keywords(dimensions: [[:values, :num, { count: 4 }]], units: [[:value, %w[FEET METERS DEGREES NONE]]]),
      backdrop: keywords(file: [[:path, :id]], dimensions: [[:values, :num, { count: 4 }]])
    }.freeze

    # Markdown reference of the contract, generated from SECTIONS (rake contract).
    def self.describe
      out = ["# SWMM input contract", "", "Generated from `Swmm::Schema` — do not edit by hand.", "",
             "Every section takes an Array of rows (Hash with the columns below, or a raw Array of tokens) " \
             "unless noted. Column legend: **required**, `default`, *optional*, `list[n]`.", "",
             "- Units follow `options.flow_units`: LPS/CMS/MLD are SI (m, mm, mm/h, ha); CFS/GPM/MGD are US (ft, in, in/h, acre).",
             "- Percentages are 0-100 unless the column says fraction. `\"*\"` is SWMM's placeholder for a skipped value where it accepts one.",
             "- Relative file paths are resolved by the engine against the .inp directory; use absolute paths with `Swmm.run(hash)`.",
             "- Rows may also be raw Arrays of tokens, written as given.", ""]
      SECTIONS.each do |name, s|
        out << "## `#{name}` — `[#{name.to_s.upcase}]`" << ""
        out.concat(describe_section(s))
        out << ""
      end
      out.join("\n")
    end

    def self.describe_section(s)
      case s.kind
      when :rows then describe_columns(s.columns)
      when :options then ["Hash of option => value.", "", s.spec.map { |k, t| "- `#{k}`: #{type_label(t)}" }]
      when :keywords then ["Hash keyword => value (`true` for a bare keyword, an Array, or a Hash of the columns).", "",
                           s.spec.map { |k, (text, c)| "- `#{k}` (`#{text}`): #{c.map(&:name).join(", ").then { _1.empty? ? "—" : _1 }}" }]
      when :block then describe_block(s.spec)
      else [DOCS.fetch(s.kind)]
      end.flatten
    end

    def self.describe_block(spec)
      lines = ["Rows are Hashes with `name`" + (spec[:head] ? " plus #{spec[:head].map { "`#{_1.name}`" }.join(", ")}" : "") +
               " and these parts (a Hash, or an Array of Hashes for repeated lines):", ""]
      spec[:parts].each { |k, (kw, c)| lines << "- `#{k}`#{" (`#{kw}`)" if kw}: #{c.map(&:name).join(", ")}" }
      lines
    end

    def self.describe_columns(columns)
      lines = ["| column | type | |", "|---|---|---|"]
      columns.each do |c|
        flag = c.list ? "list[#{c.list}]" : (c.required ? "**required**" : (c.default.nil? ? "*optional*" : "`#{c.default.is_a?(Proc) ? "derived" : c.default}`"))
        only = c.only ? " (when `#{c.only[0]}` is #{only_label(columns, c.only)})" : ""
        lines << "| `#{c.name}` | #{type_label(c.type)} | #{flag}#{only} |"
      end
      lines
    end

    # "FIXED/TIDAL", or "not IRREGULAR/STREET" when that is the shorter way to say it
    def self.only_label(columns, only)
      all = columns.find { _1.name == only[0] }&.type
      rest = all.is_a?(Array) ? all - only[1] : []
      only[1].size > rest.size && rest.any? ? "not #{rest.join(", ")}" : only[1].join(", ")
    end

    def self.type_label(t) = t.is_a?(Array) ? t.join(" \\| ") : t.to_s

    DOCS = {
      text: "String or Array of up to 3 lines.",
      transects: "Rows: `name`, `n_left`, `n_right`, `n_channel`, `x_left`, `x_right`, `x_factor` (1), `y_factor` (1), " \
                 "`stations` = [[elevation, station], ...].",
      controls: "Array of rule Hashes `{name:, if: [...], then: [...], else: [...], priority:}` or raw lines (also `VARIABLE`/`EXPRESSION`).",
      patterns: "Rows: `name`, `type` (MONTHLY 12 | DAILY 7 | HOURLY 24 | WEEKEND 24 factors), `factors`.",
      curves: "Rows: `name`, `type` (#{CURVE_TYPES.join(" | ")}), `points` = [[x, y], ...].",
      timeseries: "Rows: `name` + `points` = [[time, value], ...] (time: Time, 'YYYY-MM-DD HH:MM[:SS]' (zone ignored), elapsed hours or H:MM) or `file`.",
      report: "Hash: #{REPORT_FLAGS.join(", ")} (true/false) and #{REPORT_OBJECTS.join(", ")} (\"ALL\", \"NONE\" or an Array of ids). " \
              "**Only objects listed here are saved to the binary output.**"
    }.freeze
  end
end
