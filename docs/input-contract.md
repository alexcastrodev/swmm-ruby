# SWMM input contract

Generated from `Swmm::Schema` — do not edit by hand.

Every section takes an Array of rows (Hash with the columns below, or a raw Array of tokens) unless noted. Column legend: **required**, `default`, *optional*, `list[n]`.

- Units follow `options.flow_units`: LPS/CMS/MLD are SI (m, mm, mm/h, ha); CFS/GPM/MGD are US (ft, in, in/h, acre).
- Percentages are 0-100 unless the column says fraction. `"*"` is SWMM's placeholder for a skipped value where it accepts one.
- Relative file paths are resolved by the engine against the .inp directory; use absolute paths with `Swmm.run(hash)`.
- Rows may also be raw Arrays of tokens, written as given.

## `title` — `[TITLE]`

String or Array of up to 3 lines.

## `options` — `[OPTIONS]`

Hash of option => value.

- `flow_units`: CFS \| GPM \| MGD \| CMS \| LPS \| MLD
- `infiltration`: HORTON \| MODIFIED_HORTON \| GREEN_AMPT \| MODIFIED_GREEN_AMPT \| CURVE_NUMBER
- `flow_routing`: NONE \| STEADY \| KINWAVE \| DYNWAVE
- `link_offsets`: DEPTH \| ELEVATION
- `force_main_equation`: H-W \| D-W
- `surcharge_method`: EXTRAN \| SLOT
- `inertial_damping`: NONE \| PARTIAL \| FULL
- `normal_flow_limited`: SLOPE \| FROUDE \| BOTH \| NONE
- `allow_ponding`: yn
- `skip_steady_state`: yn
- `slope_weighting`: yn
- `ignore_rainfall`: yn
- `ignore_snowmelt`: yn
- `ignore_groundwater`: yn
- `ignore_rdii`: yn
- `ignore_routing`: yn
- `ignore_quality`: yn
- `start_date`: date
- `end_date`: date
- `report_start_date`: date
- `start_time`: time
- `end_time`: time
- `report_start_time`: time
- `sweep_start`: monthday
- `sweep_end`: monthday
- `dry_days`: num
- `report_step`: time
- `wet_step`: time
- `dry_step`: time
- `rule_step`: time
- `routing_step`: seconds
- `lengthening_step`: seconds
- `variable_step`: num
- `min_surfarea`: num
- `min_slope`: num
- `head_tolerance`: num
- `sys_flow_tol`: num
- `lat_flow_tol`: num
- `minimum_step`: num
- `max_trials`: int
- `threads`: int
- `tempdir`: id
- `compatibility`: 3 \| 4 \| 5

## `files` — `[FILES]`

| column | type | |
|---|---|---|
| `mode` | USE \| SAVE | **required** |
| `type` | RAINFALL \| RUNOFF \| HOTSTART \| RDII \| INFLOWS \| OUTFLOWS | **required** |
| `path` | id | **required** |

## `raingages` — `[RAINGAGES]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `format` | INTENSITY \| VOLUME \| CUMULATIVE | **required** |
| `interval` | time | **required** |
| `snow_catch_factor` | num | `1` |
| `source` | TIMESERIES \| FILE | **required** |
| `series` | id | **required** (when `source` is TIMESERIES) |
| `path` | id | **required** (when `source` is FILE) |
| `station` | id | **required** (when `source` is FILE) |
| `units` | IN \| MM | **required** (when `source` is FILE) |
| `start_date` | date | *optional* (when `source` is FILE) |

## `temperature` — `[TEMPERATURE]`

Hash keyword => value (`true` for a bare keyword, an Array, or a Hash of the columns).

- `timeseries` (`TIMESERIES`): series
- `file` (`FILE`): path, start_date, units
- `windspeed_monthly` (`WINDSPEED MONTHLY`): values
- `windspeed_file` (`WINDSPEED FILE`): —
- `snowmelt` (`SNOWMELT`): values
- `adc_impervious` (`ADC IMPERVIOUS`): values
- `adc_pervious` (`ADC PERVIOUS`): values

## `evaporation` — `[EVAPORATION]`

Hash keyword => value (`true` for a bare keyword, an Array, or a Hash of the columns).

- `constant` (`CONSTANT`): value
- `monthly` (`MONTHLY`): values
- `timeseries` (`TIMESERIES`): series
- `temperature` (`TEMPERATURE`): —
- `file` (`FILE`): pan_coefficients
- `recovery` (`RECOVERY`): pattern
- `dry_only` (`DRY_ONLY`): value

## `adjustments` — `[ADJUSTMENTS]`

Hash keyword => value (`true` for a bare keyword, an Array, or a Hash of the columns).

- `temperature` (`TEMPERATURE`): values
- `evaporation` (`EVAPORATION`): values
- `rainfall` (`RAINFALL`): values
- `conductivity` (`CONDUCTIVITY`): values
- `n_perv` (`N-PERV`): subcatchment, pattern
- `dstore` (`DSTORE`): subcatchment, pattern
- `infil` (`INFIL`): subcatchment, pattern

## `subcatchments` — `[SUBCATCHMENTS]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `raingage` | id | **required** |
| `outlet` | id | **required** |
| `area` | num | **required** |
| `pct_imperv` | num | **required** |
| `width` | num | **required** |
| `slope` | num | **required** |
| `curb_length` | num | `0` |
| `snowpack` | id | *optional* |

## `subareas` — `[SUBAREAS]`

| column | type | |
|---|---|---|
| `subcatchment` | id | **required** |
| `n_imperv` | num | **required** |
| `n_perv` | num | **required** |
| `storage_imperv` | num | **required** |
| `storage_perv` | num | **required** |
| `pct_zero_storage` | num | **required** |
| `route_to` | OUTLET \| IMPERVIOUS \| PERVIOUS | `OUTLET` |
| `pct_routed` | num | `100` |

## `infiltration` — `[INFILTRATION]`

| column | type | |
|---|---|---|
| `subcatchment` | id | **required** |
| `params` | num | list[3..5] |
| `method` | HORTON \| MODIFIED_HORTON \| GREEN_AMPT \| MODIFIED_GREEN_AMPT \| CURVE_NUMBER | *optional* |

## `aquifers` — `[AQUIFERS]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `porosity` | num | **required** |
| `wilting_point` | num | **required** |
| `field_capacity` | num | **required** |
| `conductivity` | num | **required** |
| `conductivity_slope` | num | **required** |
| `tension_slope` | num | **required** |
| `upper_evap_fraction` | num | **required** |
| `lower_evap_depth` | num | **required** |
| `lower_loss_rate` | num | **required** |
| `bottom_elevation` | num | **required** |
| `water_table_elevation` | num | **required** |
| `upper_moisture` | num | **required** |
| `evap_pattern` | id | *optional* |

## `groundwater` — `[GROUNDWATER]`

| column | type | |
|---|---|---|
| `subcatchment` | id | **required** |
| `aquifer` | id | **required** |
| `node` | id | **required** |
| `surface_elevation` | num | **required** |
| `a1` | num | **required** |
| `b1` | num | **required** |
| `a2` | num | **required** |
| `b2` | num | **required** |
| `a3` | num | **required** |
| `fixed_depth` | num | **required** |
| `node_elevation` | any | `*` |
| `bottom_elevation` | any | *optional* |
| `water_table_elevation` | any | *optional* |
| `upper_moisture` | any | *optional* |

## `gwf` — `[GWF]`

| column | type | |
|---|---|---|
| `subcatchment` | id | **required** |
| `flow` | LATERAL \| DEEP | **required** |
| `expression` | text | **required** |

## `snowpacks` — `[SNOWPACKS]`

Rows are Hashes with `name` and these parts (a Hash, or an Array of Hashes for repeated lines):

- `plowable` (`PLOWABLE`): min_melt_coeff, max_melt_coeff, base_temp, free_water_fraction, initial_depth, initial_free_water, depth_at_full_cover
- `impervious` (`IMPERVIOUS`): min_melt_coeff, max_melt_coeff, base_temp, free_water_fraction, initial_depth, initial_free_water, depth_at_full_cover
- `pervious` (`PERVIOUS`): min_melt_coeff, max_melt_coeff, base_temp, free_water_fraction, initial_depth, initial_free_water, depth_at_full_cover
- `removal` (`REMOVAL`): plow_depth, fraction_out, fraction_impervious, fraction_pervious, fraction_melt, fraction_to_subcatchment, subcatchment

## `junctions` — `[JUNCTIONS]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `elevation` | num | **required** |
| `max_depth` | num | `0` |
| `init_depth` | num | `0` |
| `surcharge_depth` | num | `0` |
| `ponded_area` | num | `0` |

## `outfalls` — `[OUTFALLS]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `elevation` | num | **required** |
| `type` | FREE \| NORMAL \| FIXED \| TIDAL \| TIMESERIES | **required** |
| `stage_data` | any | **required** (when `type` is not FREE, NORMAL) |
| `gated` | yn | `NO` |
| `route_to` | id | *optional* |

## `storage` — `[STORAGE]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `elevation` | num | **required** |
| `max_depth` | num | **required** |
| `init_depth` | num | **required** |
| `shape` | TABULAR \| FUNCTIONAL \| CYLINDRICAL \| CONICAL \| PARABOLIC \| PYRAMIDAL | **required** |
| `curve` | id | **required** (when `shape` is TABULAR) |
| `coefficient` | num | **required** (when `shape` is FUNCTIONAL) |
| `exponent` | num | **required** (when `shape` is FUNCTIONAL) |
| `constant` | num | **required** (when `shape` is FUNCTIONAL) |
| `a` | num | **required** (when `shape` is not TABULAR, FUNCTIONAL) |
| `b` | num | **required** (when `shape` is not TABULAR, FUNCTIONAL) |
| `z` | num | **required** (when `shape` is not TABULAR, FUNCTIONAL) |
| `surcharge_depth` | num | `0` |
| `evap_fraction` | num | `0` |
| `seepage` | num | list[0..3] |

## `dividers` — `[DIVIDERS]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `elevation` | num | **required** |
| `diverted_link` | id | `*` |
| `type` | CUTOFF \| TABULAR \| WEIR \| OVERFLOW | **required** |
| `cutoff_flow` | num | **required** (when `type` is CUTOFF) |
| `curve` | id | **required** (when `type` is TABULAR) |
| `weir_min_flow` | num | **required** (when `type` is WEIR) |
| `weir_max_depth` | num | **required** (when `type` is WEIR) |
| `weir_coefficient` | num | **required** (when `type` is WEIR) |
| `max_depth` | num | `0` |
| `init_depth` | num | `0` |
| `surcharge_depth` | num | `0` |
| `ponded_area` | num | `0` |

## `conduits` — `[CONDUITS]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `from_node` | id | **required** |
| `to_node` | id | **required** |
| `length` | num | **required** |
| `roughness` | num | **required** |
| `in_offset` | any | **required** |
| `out_offset` | any | **required** |
| `init_flow` | num | `0` |
| `max_flow` | num | `0` |

## `pumps` — `[PUMPS]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `from_node` | id | **required** |
| `to_node` | id | **required** |
| `curve` | id | `*` |
| `status` | ON \| OFF | `ON` |
| `startup_depth` | num | `0` |
| `shutoff_depth` | num | `0` |

## `orifices` — `[ORIFICES]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `from_node` | id | **required** |
| `to_node` | id | **required** |
| `type` | SIDE \| BOTTOM | **required** |
| `offset` | any | **required** |
| `discharge_coeff` | num | **required** |
| `gated` | yn | `NO` |
| `close_time` | num | `0` |

## `weirs` — `[WEIRS]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `from_node` | id | **required** |
| `to_node` | id | **required** |
| `type` | TRANSVERSE \| SIDEFLOW \| V-NOTCH \| TRAPEZOIDAL \| ROADWAY | **required** |
| `crest_height` | any | **required** |
| `discharge_coeff` | num | **required** |
| `gated` | yn | `NO` |
| `end_contractions` | num | `0` |
| `end_coeff` | num | `0` |
| `can_surcharge` | yn | `YES` |
| `road_width` | any | `*` |
| `road_surface` | any | `*` |
| `coeff_curve` | id | *optional* |

## `outlets` — `[OUTLETS]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `from_node` | id | **required** |
| `to_node` | id | **required** |
| `offset` | any | **required** |
| `type` | TABULAR/DEPTH \| TABULAR/HEAD \| FUNCTIONAL/DEPTH \| FUNCTIONAL/HEAD \| TABULAR \| FUNCTIONAL | **required** |
| `curve` | id | **required** (when `type` is TABULAR/DEPTH, TABULAR/HEAD, TABULAR) |
| `coefficient` | num | **required** (when `type` is FUNCTIONAL/DEPTH, FUNCTIONAL/HEAD, FUNCTIONAL) |
| `exponent` | num | **required** (when `type` is FUNCTIONAL/DEPTH, FUNCTIONAL/HEAD, FUNCTIONAL) |
| `gated` | yn | `NO` |

## `xsections` — `[XSECTIONS]`

| column | type | |
|---|---|---|
| `link` | id | **required** |
| `shape` | DUMMY \| CIRCULAR \| FILLED_CIRCULAR \| RECT_CLOSED \| RECT_OPEN \| TRAPEZOIDAL \| TRIANGULAR \| PARABOLIC \| POWER \| RECT_TRIANGULAR \| RECT_ROUND \| MODBASKETHANDLE \| HORIZ_ELLIPSE \| VERT_ELLIPSE \| ARCH \| EGG \| HORSESHOE \| GOTHIC \| CATENARY \| SEMIELLIPTICAL \| BASKETHANDLE \| SEMICIRCULAR \| IRREGULAR \| CUSTOM \| FORCE_MAIN \| STREET | **required** |
| `transect` | id | **required** (when `shape` is IRREGULAR) |
| `street` | id | **required** (when `shape` is STREET) |
| `geom1` | num | **required** (when `shape` is not IRREGULAR, STREET) |
| `curve` | id | **required** (when `shape` is CUSTOM) |
| `geom2` | num | `0` (when `shape` is not IRREGULAR, CUSTOM, STREET) |
| `geom3` | num | `0` (when `shape` is not IRREGULAR, STREET) |
| `geom4` | num | `0` (when `shape` is not IRREGULAR, STREET) |
| `barrels` | int | `1` (when `shape` is not IRREGULAR, STREET) |
| `culvert_code` | int | *optional* (when `shape` is not IRREGULAR, STREET) |

## `transects` — `[TRANSECTS]`

Rows: `name`, `n_left`, `n_right`, `n_channel`, `x_left`, `x_right`, `x_factor` (1), `y_factor` (1), `stations` = [[elevation, station], ...].

## `losses` — `[LOSSES]`

| column | type | |
|---|---|---|
| `link` | id | **required** |
| `inlet` | num | `0` |
| `outlet` | num | `0` |
| `average` | num | `0` |
| `flap_gate` | yn | `NO` |
| `seepage_rate` | num | `0` |

## `controls` — `[CONTROLS]`

Array of rule Hashes `{name:, if: [...], then: [...], else: [...], priority:}` or raw lines (also `VARIABLE`/`EXPRESSION`).

## `pollutants` — `[POLLUTANTS]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `units` | MG/L \| UG/L \| #/L | **required** |
| `rain_conc` | num | **required** |
| `groundwater_conc` | num | **required** |
| `rdii_conc` | num | **required** |
| `decay_coeff` | num | **required** |
| `snow_only` | yn | `NO` |
| `co_pollutant` | id | `*` |
| `co_fraction` | num | `0` |
| `dwf_conc` | num | `0` |
| `init_conc` | num | `0` |

## `landuses` — `[LANDUSES]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `sweep_interval` | num | `0` |
| `sweep_removal` | num | `0` |
| `last_swept` | num | `0` |

## `buildup` — `[BUILDUP]`

| column | type | |
|---|---|---|
| `landuse` | id | **required** |
| `pollutant` | id | **required** |
| `function` | NONE \| POW \| EXP \| SAT \| EXT | **required** |
| `c1` | num | **required** (when `function` is not NONE) |
| `c2` | num | **required** (when `function` is not NONE) |
| `c3` | any | **required** (when `function` is not NONE) |
| `normalizer` | AREA \| CURB | **required** (when `function` is not NONE) |

## `washoff` — `[WASHOFF]`

| column | type | |
|---|---|---|
| `landuse` | id | **required** |
| `pollutant` | id | **required** |
| `function` | NONE \| EXP \| RC \| EMC | **required** |
| `coefficient` | num | **required** (when `function` is not NONE) |
| `exponent` | num | **required** (when `function` is not NONE) |
| `cleaning_efficiency` | num | `0` (when `function` is not NONE) |
| `bmp_efficiency` | num | `0` (when `function` is not NONE) |

## `coverages` — `[COVERAGES]`

| column | type | |
|---|---|---|
| `subcatchment` | id | **required** |
| `landuses` | any | list[2..38] |

## `loadings` — `[LOADINGS]`

| column | type | |
|---|---|---|
| `subcatchment` | id | **required** |
| `pollutants` | any | list[2..38] |

## `treatment` — `[TREATMENT]`

| column | type | |
|---|---|---|
| `node` | id | **required** |
| `pollutant` | id | **required** |
| `expression` | text | **required** |

## `inflows` — `[INFLOWS]`

| column | type | |
|---|---|---|
| `node` | id | **required** |
| `constituent` | id | `FLOW` |
| `series` | opt_id | `` |
| `type` | FLOW \| CONCEN \| MASS | `derived` |
| `units_factor` | num | `1.0` |
| `scale_factor` | num | `1.0` |
| `baseline` | num | `0` |
| `baseline_pattern` | id | *optional* |

## `dwf` — `[DWF]`

| column | type | |
|---|---|---|
| `node` | id | **required** |
| `constituent` | id | `FLOW` |
| `average` | num | **required** |
| `patterns` | opt_id | list[0..4] |

## `patterns` — `[PATTERNS]`

Rows: `name`, `type` (MONTHLY 12 | DAILY 7 | HOURLY 24 | WEEKEND 24 factors), `factors`.

## `rdii` — `[RDII]`

| column | type | |
|---|---|---|
| `node` | id | **required** |
| `hydrograph` | id | **required** |
| `sewer_area` | num | **required** |

## `hydrographs` — `[HYDROGRAPHS]`

Rows are Hashes with `name` plus `raingage` and these parts (a Hash, or an Array of Hashes for repeated lines):

- `responses`: month, response, r, t, k, initial_abstraction_max, recovery, initial_abstraction

## `curves` — `[CURVES]`

Rows: `name`, `type` (STORAGE | DIVERSION | TIDAL | RATING | CONTROL | SHAPE | WEIR | PUMP1 | PUMP2 | PUMP3 | PUMP4 | PUMP5), `points` = [[x, y], ...].

## `timeseries` — `[TIMESERIES]`

Rows: `name` + `points` = [[time, value], ...] (time: Time, 'YYYY-MM-DD HH:MM[:SS]' (zone ignored), elapsed hours or H:MM) or `file`.

## `report` — `[REPORT]`

Hash: disabled, input, continuity, flowstats, controls, averages (true/false) and subcatchments, nodes, links ("ALL", "NONE" or an Array of ids). **Only objects listed here are saved to the binary output.**

## `events` — `[EVENTS]`

| column | type | |
|---|---|---|
| `start_date` | date | **required** |
| `start_time` | time | **required** |
| `end_date` | date | **required** |
| `end_time` | time | **required** |

## `lid_controls` — `[LID_CONTROLS]`

Rows are Hashes with `name` plus `type` and these parts (a Hash, or an Array of Hashes for repeated lines):

- `surface` (`SURFACE`): storage_depth, vegetation_fraction, roughness, surface_slope, swale_side_slope
- `soil` (`SOIL`): thickness, porosity, field_capacity, wilting_point, conductivity, conductivity_slope, suction_head
- `storage` (`STORAGE`): height, void_ratio, conductivity, clog_factor, covered
- `pavement` (`PAVEMENT`): thickness, void_ratio, impervious_fraction, permeability, clog_factor, regen_days, regen_degree
- `drainmat` (`DRAINMAT`): thickness, void_ratio, roughness
- `drain` (`DRAIN`): coefficient, exponent, offset, delay, open_level, close_level, control_curve
- `removals` (`REMOVALS`): pollutant, percent

## `lid_usage` — `[LID_USAGE]`

| column | type | |
|---|---|---|
| `subcatchment` | id | **required** |
| `lid` | id | **required** |
| `number` | int | **required** |
| `area` | num | **required** |
| `width` | num | **required** |
| `init_saturation` | num | **required** |
| `from_impervious` | num | **required** |
| `to_pervious` | int | **required** |
| `report_file` | any | `*` |
| `drain_to` | any | `*` |
| `from_pervious` | num | `0` |

## `streets` — `[STREETS]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `crown_width` | num | **required** |
| `curb_height` | num | **required** |
| `cross_slope` | num | **required** |
| `roughness` | num | **required** |
| `gutter_depression` | num | `0` |
| `gutter_width` | num | `0` |
| `sides` | int | `1` |
| `back_width` | num | `0` |
| `back_slope` | num | `0` |
| `back_roughness` | num | `0` |

## `inlet_usage` — `[INLET_USAGE]`

| column | type | |
|---|---|---|
| `link` | id | **required** |
| `inlet` | id | **required** |
| `node` | id | **required** |
| `count` | int | `1` |
| `pct_clogged` | num | `0` |
| `max_flow` | num | `0` |
| `local_depression` | num | `0` |
| `local_width` | num | `0` |
| `placement` | AUTOMATIC \| ON_GRADE \| ON_SAG | `AUTOMATIC` |

## `inlets` — `[INLETS]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `type` | GRATE \| CURB \| SLOTTED \| DROP_GRATE \| DROP_CURB \| CUSTOM | **required** |
| `length` | num | **required** (when `type` is not CUSTOM) |
| `width` | num | **required** (when `type` is GRATE, SLOTTED, DROP_GRATE) |
| `height` | num | **required** (when `type` is CURB, DROP_CURB) |
| `grate_type` | P_BAR-50 \| P_BAR-50x100 \| P_BAR-30 \| CURVED_VANE \| TILT_BAR-45 \| TILT_BAR-30 \| RETICULINE \| GENERIC | **required** (when `type` is GRATE, DROP_GRATE) |
| `open_area` | num | **required** (when `grate_type` is GENERIC) |
| `splash_velocity` | num | *optional* (when `grate_type` is GENERIC) |
| `throat_type` | HORIZONTAL \| INCLINED \| VERTICAL | *optional* (when `type` is CURB) |
| `curve` | id | **required** (when `type` is CUSTOM) |

## `coordinates` — `[COORDINATES]`

| column | type | |
|---|---|---|
| `node` | id | **required** |
| `x` | num | **required** |
| `y` | num | **required** |

## `vertices` — `[VERTICES]`

| column | type | |
|---|---|---|
| `link` | id | **required** |
| `x` | num | **required** |
| `y` | num | **required** |

## `polygons` — `[POLYGONS]`

| column | type | |
|---|---|---|
| `subcatchment` | id | **required** |
| `x` | num | **required** |
| `y` | num | **required** |

## `labels` — `[LABELS]`

| column | type | |
|---|---|---|
| `x` | num | **required** |
| `y` | num | **required** |
| `text` | id | **required** |

## `symbols` — `[SYMBOLS]`

| column | type | |
|---|---|---|
| `gage` | id | **required** |
| `x` | num | **required** |
| `y` | num | **required** |

## `tags` — `[TAGS]`

| column | type | |
|---|---|---|
| `type` | Node \| Link \| Subcatch \| Gage | **required** |
| `name` | id | **required** |
| `tag` | id | **required** |

## `profiles` — `[PROFILES]`

| column | type | |
|---|---|---|
| `name` | id | **required** |
| `links` | id | list[1..38] |

## `map` — `[MAP]`

Hash keyword => value (`true` for a bare keyword, an Array, or a Hash of the columns).

- `dimensions` (`DIMENSIONS`): values
- `units` (`UNITS`): value

## `backdrop` — `[BACKDROP]`

Hash keyword => value (`true` for a bare keyword, an Array, or a Hash of the columns).

- `file` (`FILE`): path
- `dimensions` (`DIMENSIONS`): values
