# frozen_string_literal: true

# Models used by the tests. SI units (LPS), 2 hours or 6 hours of simulation.
module Fixtures
  module_function

  # Smallest useful network: J1 -> J2 -> O1 with a hydrograph entering J1.
  def base
    {
      options: { flow_units: "LPS", flow_routing: "DYNWAVE", start_date: "2026-03-24", start_time: "00:00",
                 end_date: "2026-03-24", end_time: "02:00", report_step: "00:10:00", routing_step: 10 },
      junctions: [{ name: "J1", elevation: 10, max_depth: 3 }, { name: "J2", elevation: 9.5, max_depth: 3 }],
      outfalls: [{ name: "O1", elevation: 9, type: "FREE" }],
      conduits: [{ name: "C1", from_node: "J1", to_node: "J2", length: 100, roughness: 0.013, in_offset: 0, out_offset: 0 },
                 { name: "C2", from_node: "J2", to_node: "O1", length: 100, roughness: 0.013, in_offset: 0, out_offset: 0 }],
      xsections: [{ link: "C1", shape: "CIRCULAR", geom1: 0.4 }, { link: "C2", shape: "CIRCULAR", geom1: 0.4 }],
      timeseries: [{ name: "Q", points: [[0, 0], [0.5, 50], [1, 80], [2, 0]] }],
      inflows: [{ node: "J1", series: "Q" }],
      report: { subcatchments: "NONE", nodes: "ALL", links: "ALL" }
    }
  end

  MONTHS = [1] * 12

  # Uses every section of the contract. +dir+ receives the hotstart file.
  def full(dir)
    {
      title: ["Contract conformance model", "uses every section"],
      options: {
        flow_units: "LPS", infiltration: "GREEN_AMPT", flow_routing: "DYNWAVE", link_offsets: "DEPTH",
        force_main_equation: "H-W", surcharge_method: "EXTRAN", inertial_damping: "PARTIAL",
        normal_flow_limited: "BOTH", allow_ponding: false, skip_steady_state: false, slope_weighting: true,
        ignore_rainfall: false, ignore_snowmelt: false, ignore_groundwater: false, ignore_rdii: false,
        ignore_routing: false, ignore_quality: false, start_date: "2026-03-24", start_time: "00:00",
        end_date: "2026-03-24", end_time: "06:00", report_start_date: "2026-03-24", report_start_time: "00:00",
        sweep_start: "01/01", sweep_end: "12/31", dry_days: 2, report_step: "00:15:00", wet_step: "00:05:00",
        dry_step: "01:00:00", routing_step: 20, rule_step: "00:00:30", lengthening_step: 0, variable_step: 0.75,
        min_surfarea: 1.14, min_slope: 0, max_trials: 8, head_tolerance: 0.0015, sys_flow_tol: 5,
        lat_flow_tol: 5, minimum_step: 0.5, threads: 1
      },
      files: [{ mode: "SAVE", type: "HOTSTART", path: File.join(dir, "end state.hsf") }],

      raingages: [{ name: "RG1", format: "INTENSITY", interval: "0:15", source: "TIMESERIES", series: "RAIN" }],
      temperature: {
        timeseries: "TEMP", snowmelt: [0, 0.5, 0.6, 50, 40, 0],
        adc_impervious: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1], adc_pervious: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1],
        windspeed_monthly: [2] * 12
      },
      evaporation: { monthly: [0.5] * 12, dry_only: false, recovery: "PM" },
      adjustments: {
        temperature: MONTHS, evaporation: MONTHS, rainfall: MONTHS, conductivity: MONTHS,
        n_perv: [{ subcatchment: "S1", pattern: "PM" }], dstore: [{ subcatchment: "S1", pattern: "PM" }],
        infil: [{ subcatchment: "S1", pattern: "PM" }]
      },
      subcatchments: [
        { name: "S1", raingage: "RG1", outlet: "J1", area: 2, pct_imperv: 60, width: 150, slope: 1, snowpack: "SP1" },
        { name: "S2", raingage: "RG1", outlet: "J2", area: 3, pct_imperv: 30, width: 200, slope: 2, curb_length: 100 },
        { name: "S3", raingage: "RG1", outlet: "S2", area: 1, pct_imperv: 10, width: 80, slope: 2 }
      ],
      subareas: [
        { subcatchment: "S1", n_imperv: 0.012, n_perv: 0.15, storage_imperv: 1.5, storage_perv: 5, pct_zero_storage: 25 },
        { subcatchment: "S2", n_imperv: 0.012, n_perv: 0.15, storage_imperv: 1.5, storage_perv: 5, pct_zero_storage: 25,
          route_to: "PERVIOUS", pct_routed: 50 },
        { subcatchment: "S3", n_imperv: 0.012, n_perv: 0.15, storage_imperv: 1.5, storage_perv: 5, pct_zero_storage: 25 }
      ],
      infiltration: [
        { subcatchment: "S1", params: [100, 5, 0.3] },
        { subcatchment: "S2", params: [50, 5, 4, 7, 0], method: "HORTON" },
        { subcatchment: "S3", params: [75, 4, 0.2], method: "GREEN_AMPT" }
      ],
      aquifers: [{ name: "A1", porosity: 0.5, wilting_point: 0.15, field_capacity: 0.3, conductivity: 10,
                   conductivity_slope: 10, tension_slope: 15, upper_evap_fraction: 0.35, lower_evap_depth: 14,
                   lower_loss_rate: 0.002, bottom_elevation: 0, water_table_elevation: 3, upper_moisture: 0.3 }],
      groundwater: [{ subcatchment: "S2", aquifer: "A1", node: "J2", surface_elevation: 9.5, a1: 0.001, b1: 1,
                      a2: 0, b2: 0, a3: 0, fixed_depth: 0 }],
      gwf: [{ subcatchment: "S2", flow: "LATERAL", expression: "0.001*(Hgw-Hsw)" }],
      snowpacks: [{ name: "SP1",
                    plowable: { min_melt_coeff: 0.002, max_melt_coeff: 0.01, base_temp: 0, free_water_fraction: 0.5,
                                initial_depth: 0, initial_free_water: 0, depth_at_full_cover: 0 },
                    impervious: [0.002, 0.01, 0, 0.5, 0, 0, 0].then { |v| %i[min_melt_coeff max_melt_coeff base_temp free_water_fraction initial_depth initial_free_water depth_at_full_cover].zip(v).to_h },
                    pervious: [0.002, 0.01, 0, 0.5, 0, 0, 0].then { |v| %i[min_melt_coeff max_melt_coeff base_temp free_water_fraction initial_depth initial_free_water depth_at_full_cover].zip(v).to_h },
                    removal: { plow_depth: 0.1, fraction_out: 0.1, fraction_impervious: 0, fraction_pervious: 0,
                               fraction_melt: 0, fraction_to_subcatchment: 0.9, subcatchment: "S2" } }],

      junctions: [{ name: "J1", elevation: 10, max_depth: 3 }, { name: "J2", elevation: 9.5, max_depth: 3 },
                  { name: "J3", elevation: 9, max_depth: 3, init_depth: 0.1 },
                  { name: "J4", elevation: 8.5, max_depth: 3, surcharge_depth: 1, ponded_area: 10 }],
      outfalls: [{ name: "O1", elevation: 7, type: "FREE" },
                 { name: "O2", elevation: 7, type: "FIXED", stage_data: 7.2, gated: true }],
      storage: [{ name: "ST1", elevation: 7.5, max_depth: 3, init_depth: 0, shape: "TABULAR", curve: "STC", evap_fraction: 0.5 },
                { name: "ST2", elevation: 7.5, max_depth: 3, init_depth: 0, shape: "FUNCTIONAL", coefficient: 100,
                  exponent: 0.5, constant: 50, seepage: [10, 5, 0.3] }],
      dividers: [{ name: "D1", elevation: 8, diverted_link: "C4", type: "CUTOFF", cutoff_flow: 20 }],

      conduits: [
        { name: "C1", from_node: "J1", to_node: "J2", length: 100, roughness: 0.013, in_offset: 0, out_offset: 0, init_flow: 1, max_flow: 500 },
        { name: "C2", from_node: "J2", to_node: "J3", length: 100, roughness: 0.013, in_offset: 0, out_offset: 0 },
        { name: "C3", from_node: "D1", to_node: "O1", length: 50, roughness: 0.013, in_offset: 0, out_offset: 0 },
        { name: "C4", from_node: "D1", to_node: "ST1", length: 50, roughness: 0.013, in_offset: 0, out_offset: 0 },
        { name: "C5", from_node: "J1", to_node: "J4", length: 80, roughness: 0.016, in_offset: 0, out_offset: 0 }
      ],
      pumps: [{ name: "P1", from_node: "J3", to_node: "J4", curve: "PC1", startup_depth: 1, shutoff_depth: 0.2 }],
      orifices: [{ name: "OR1", from_node: "J3", to_node: "J4", type: "BOTTOM", offset: 0, discharge_coeff: 0.65 }],
      weirs: [{ name: "W1", from_node: "J4", to_node: "D1", type: "TRANSVERSE", crest_height: 0.5, discharge_coeff: 1.8 },
              { name: "W2", from_node: "J4", to_node: "ST2", type: "ROADWAY", crest_height: 0.5, discharge_coeff: 1.8,
                road_width: 6, road_surface: "PAVED" }],
      outlets: [{ name: "OU1", from_node: "ST1", to_node: "O2", offset: 0, type: "TABULAR/DEPTH", curve: "OUC" }],
      xsections: [
        { link: "C1", shape: "CIRCULAR", geom1: 0.5 }, { link: "C2", shape: "IRREGULAR", transect: "T1" },
        { link: "C3", shape: "CIRCULAR", geom1: 0.6 }, { link: "C4", shape: "CUSTOM", geom1: 0.8, curve: "SHP" },
        { link: "C5", shape: "STREET", street: "STR1" },
        { link: "OR1", shape: "CIRCULAR", geom1: 0.3 }, { link: "W1", shape: "RECT_OPEN", geom1: 1, geom2: 1 },
        { link: "W2", shape: "RECT_OPEN", geom1: 1, geom2: 4 }
      ],
      transects: [{ name: "T1", n_left: 0.05, n_right: 0.05, n_channel: 0.03, x_left: 5, x_right: 15,
                    stations: [[2, 0], [1, 5], [0, 7], [0, 13], [1, 15], [2, 20]] }],
      losses: [{ link: "C1", inlet: 0.5, outlet: 0.5, average: 0.1, flap_gate: false, seepage_rate: 0 }],
      controls: [{ name: "R1", if: ["NODE J3 DEPTH > 1.5"], then: ["PUMP P1 STATUS = ON"], else: ["PUMP P1 STATUS = OFF"], priority: 1 }],

      pollutants: [{ name: "TSS", units: "MG/L", rain_conc: 0, groundwater_conc: 0, rdii_conc: 0, decay_coeff: 0 },
                   { name: "COD", units: "MG/L", rain_conc: 0, groundwater_conc: 0, rdii_conc: 0, decay_coeff: 0.1,
                     co_pollutant: "TSS", co_fraction: 0.5, dwf_conc: 10, init_conc: 1 }],
      landuses: [{ name: "LU1", sweep_interval: 7, sweep_removal: 0.5, last_swept: 3 }, { name: "LU2" }],
      buildup: [{ landuse: "LU1", pollutant: "TSS", function: "POW", c1: 50, c2: 0.5, c3: 1, normalizer: "AREA" },
                { landuse: "LU1", pollutant: "COD", function: "EXT", c1: 50, c2: 1, c3: "XB", normalizer: "AREA" },
                { landuse: "LU2", pollutant: "TSS", function: "SAT", c1: 50, c2: 5, c3: 0, normalizer: "CURB" },
                { landuse: "LU2", pollutant: "COD", function: "NONE" }],
      washoff: [{ landuse: "LU1", pollutant: "TSS", function: "EXP", coefficient: 0.1, exponent: 1, cleaning_efficiency: 50 },
                { landuse: "LU1", pollutant: "COD", function: "RC", coefficient: 0.1, exponent: 1 },
                { landuse: "LU2", pollutant: "TSS", function: "EMC", coefficient: 20, exponent: 0 },
                { landuse: "LU2", pollutant: "COD", function: "NONE" }],
      coverages: [{ subcatchment: "S1", landuses: { "LU1" => 60, "LU2" => 40 } }, { subcatchment: "S2", landuses: %w[LU1 100] }],
      loadings: [{ subcatchment: "S1", pollutants: { "TSS" => 5 } }],
      treatment: [{ node: "J3", pollutant: "TSS", expression: "R = 0.5" }],

      inflows: [{ node: "J1", series: "Q" }, { node: "J1", constituent: "TSS", series: "POLLQ", type: "CONCEN" },
                { node: "J2", series: "", baseline: 3, baseline_pattern: "HP" }],
      dwf: [{ node: "J3", average: 5, patterns: %w[PM PD HP PW] }, { node: "J3", constituent: "TSS", average: 20, patterns: ["", "", "HP"] }],
      patterns: [{ name: "PM", type: "MONTHLY", factors: MONTHS }, { name: "PD", type: "DAILY", factors: [1] * 7 },
                 { name: "HP", type: "HOURLY", factors: [1] * 24 }, { name: "PW", type: "WEEKEND", factors: [1] * 24 }],
      rdii: [{ node: "J2", hydrograph: "UH1", sewer_area: 2 }],
      hydrographs: [{ name: "UH1", raingage: "RG1",
                      responses: [{ month: "ALL", response: "SHORT", r: 0.1, t: 1, k: 2 },
                                  { month: "ALL", response: "MEDIUM", r: 0.1, t: 3, k: 3, initial_abstraction_max: 1 },
                                  { month: "JAN", response: "LONG", r: 0.1, t: 8, k: 4 }] }],
      curves: [{ name: "STC", type: "STORAGE", points: [[0, 100], [3, 300]] },
               { name: "PC1", type: "PUMP1", points: [[0, 0], [1, 10], [3, 30]] },
               { name: "OUC", type: "RATING", points: [[0, 0], [1, 20], [3, 60]] },
               { name: "SHP", type: "SHAPE", points: [[0, 0], [0.5, 1], [1, 0]] }],
      timeseries: [
        { name: "RAIN", points: [[0, 0], [0.25, 10], [0.5, 20], [0.75, 5], [1, 0], [6, 0]] },
        { name: "TEMP", points: [["2026-03-24 00:00", 5], [Time.utc(2026, 3, 24, 6), 8]] },
        { name: "Q", points: [[0, 0], [0.5, 50], [1, 80], [6, 0]] }, { name: "POLLQ", points: [[0, 10], [6, 10]] },
        { name: "XB", points: [[0, 1], [6, 1]] }
      ],

      report: { input: false, continuity: true, flowstats: true, controls: false, averages: false,
                subcatchments: "ALL", nodes: "ALL", links: "ALL" },
      events: [{ start_date: "2026-03-24", start_time: "00:00", end_date: "2026-03-24", end_time: "06:00" }],
      lid_controls: [{ name: "BC1", type: "BC",
                       surface: { storage_depth: 150, vegetation_fraction: 0.1, roughness: 0.1, surface_slope: 1, swale_side_slope: 5 },
                       soil: { thickness: 500, porosity: 0.5, field_capacity: 0.2, wilting_point: 0.1, conductivity: 30,
                               conductivity_slope: 10, suction_head: 3.5 },
                       storage: { height: 300, void_ratio: 0.75, conductivity: 10, clog_factor: 0 },
                       drain: { coefficient: 1, exponent: 0.5, offset: 6, delay: 6 },
                       removals: [{ pollutant: "TSS", percent: 80 }] }],
      lid_usage: [{ subcatchment: "S2", lid: "BC1", number: 2, area: 50, width: 5, init_saturation: 0, from_impervious: 20, to_pervious: 0 }],
      streets: [{ name: "STR1", crown_width: 5, curb_height: 0.15, cross_slope: 2, roughness: 0.016 }],
      inlets: [{ name: "IN1", type: "GRATE", length: 0.6, width: 0.45, grate_type: "P_BAR-50" }],
      inlet_usage: [{ link: "C5", inlet: "IN1", node: "J4" }],

      coordinates: [{ node: "J1", x: 0, y: 0 }, { node: "J2", x: 100, y: 0 }],
      vertices: [{ link: "C1", x: 50, y: 5 }], polygons: [{ subcatchment: "S1", x: 0, y: 10 }],
      labels: [{ x: 10, y: 10, text: "Main trunk" }], symbols: [{ gage: "RG1", x: 5, y: 5 }],
      tags: [{ type: "Node", name: "J1", tag: "upstream" }], profiles: [{ name: "Main", links: %w[C1 C2] }],
      map: { dimensions: [0, 0, 100, 100], units: "METERS" }, backdrop: { file: "plan.bmp", dimensions: [0, 0, 100, 100] }
    }
  end
end
