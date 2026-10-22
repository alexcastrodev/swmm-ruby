# frozen_string_literal: true

require "test_helper"
require "ffi"
require "fileutils"
require "tmpdir"

# FRONT C: fidelity of the numbers against oracles that live OUTSIDE this gem's reader (docs/test-plan.md, R3 and R6).
#
#   1. EPA's own test file tests/outfile/Example1.out and the numbers hard-coded in EPA's tests/outfile/test_output.cpp
#      (SWMM 5.1.0 output format, version code 51000), plus numbers computed once with EPA's libswmm-output
#      (src/outfile of the same SWMM 5.2.4 tag, compiled by hand) over the same file.
#   2. The engine's own report: swmm_report() writes "<<< Node X >>>" tables read straight from the .out by C code.
#   3. The engine C API: swmm_getSavedValue / swmm_getValue on the same run.
#
# Oracles 2 and 3 use a PRIVATE copy of libswmm5 (like Engine.pool), so they never touch the state of Swmm.run.
module Oracle
  KINDS = %i[subcatchments nodes links].freeze
  OBJECT = { subcatchments: 1, nodes: 2, links: 3 }.freeze # swmm_Object
  RPTFLAG = { subcatchments: 206, nodes: 309, links: 414 }.freeze # swmm_*_RPTFLAG
  # variable of the .out => swmm_getSavedValue property code (swmm5.h); swmm_LINK_SETTING returns the capacity column
  PROPS = {
    subcatchments: { "rainfall" => 202, "evaporation" => 203, "infiltration" => 204, "runoff" => 205 },
    nodes: { "depth" => 303, "head" => 304, "volume" => 305, "lateral_inflow" => 306, "total_inflow" => 307, "overflow" => 308 },
    links: { "flow" => 410, "depth" => 411, "velocity" => 412, "capacity" => 407 }
  }.freeze
  Run = Struct.new(:flow_units_code, :periods, :dates, :saved, :flagged, :report, :out_path)

  class << self
    def lib
      @lib ||= begin
        paths = Swmm::Engine.library_candidates
        if (source = paths.find { File.file?(_1) })
          dir = Dir.mktmpdir("swmm-oracle")
          Minitest.after_run { FileUtils.rm_rf(dir) }
          paths = [File.join(dir, File.basename(source))]
          FileUtils.cp(source, paths.first)
        end
        Module.new do
          extend FFI::Library
          ffi_lib paths
          attach_function :swmm_open, %i[string string string], :int
          attach_function :swmm_start, [:int], :int
          attach_function :swmm_step, [:pointer], :int
          attach_function :swmm_end, [], :int
          attach_function :swmm_report, [], :int
          attach_function :swmm_close, [], :int
          attach_function :swmm_getCount, [:int], :int
          attach_function :swmm_getName, %i[int int pointer int], :void
          attach_function :swmm_getValue, %i[int int], :double
          attach_function :swmm_getSavedValue, %i[int int int], :double
        end
      end
    end

    # open, start, step..., end, then read the saved values through the C API, then write the report, then close.
    def run(inp, dir)
      rpt = File.join(dir, "oracle.rpt")
      out = File.join(dir, "oracle.out")
      engine = lib
      check engine.swmm_open(inp, rpt, out), "swmm_open"
      begin
        run = Run.new(engine.swmm_getValue(8, 0).to_i) # swmm_FLOWUNITS
        check engine.swmm_start(1), "swmm_start"
        elapsed = FFI::MemoryPointer.new(:double)
        loop do
          check engine.swmm_step(elapsed), "swmm_step"
          break if elapsed.read_double <= 0
        end
        check engine.swmm_end, "swmm_end"
        run.periods = engine.swmm_getValue(6, 0).to_i # swmm_TOTALSTEPS: number of reporting periods saved
        run.dates = (1..run.periods).map { engine.swmm_getSavedValue(1, 0, _1) } # swmm_CURRENTDATE, days since 1899-12-30
        run.saved = {}
        run.flagged = {}
        KINDS.each do |kind|
          run.saved[kind] = {}
          run.flagged[kind] = []
          engine.swmm_getCount(OBJECT[kind]).times do |i|
            name = FFI::MemoryPointer.new(:char, 256)
            engine.swmm_getName(OBJECT[kind], i, name, 256)
            next if engine.swmm_getValue(RPTFLAG[kind], i).zero?

            id = name.read_string.force_encoding(Encoding::UTF_8)
            run.flagged[kind] << id
            run.saved[kind][id] =
              PROPS[kind].to_h { |var, prop| [var, (1..run.periods).map { engine.swmm_getSavedValue(prop, i, _1) }] }
          end
        end
        check engine.swmm_report, "swmm_report"
      ensure
        engine.swmm_close
      end
      run.report = File.binread(rpt).force_encoding(Encoding::UTF_8).scrub
      run.out_path = out
      run
    end

    def check(code, what) = (raise "#{what} failed with code #{code}" unless code.zero?)

    def time_of(days) = Swmm::OutputFile::EPOCH + (days * 86_400).round

    # "<<< Node J1 >>>" tables of the report => { "J1" => [[Time, [Float, ...]], ...] }
    def tables(report, word)
      report.scan(/<<< #{word} (\S+) >>>(.*?)(?=<<<|\z)/m).to_h do |id, body|
        rows = body.scan(%r{^\s+(\d\d)/(\d\d)/(\d{4}) (\d\d):(\d\d):(\d\d)\s+(.*)$}).map do |mo, d, y, h, mi, s, rest|
          [Time.utc(y.to_i, mo.to_i, d.to_i, h.to_i, mi.to_i, s.to_i), rest.split.map(&:to_f)]
        end
        [id, rows]
      end
    end

    # the unit words of the 2nd header line of a table ("Date Time  lps  meters ...") as printed by the engine
    def header_units(report, word, id)
      block = report[/<<< #{word} #{Regexp.escape(id)} >>>(.*?)(?=<<<|\z)/m, 1]
      block.lines.grep(/^\s+Date\s+Time/).last.split.drop(2)
    end
  end
end

# Shared by the engine-backed tests.
module OracleHelpers
  # delta of a value that went through "%.7g" (relative 5e-7 at worst) or was printed with +decimals+ digits
  def near(expected, actual, rel: 1e-6, decimals: nil, msg: nil)
    delta = decimals ? (0.5 * (10.0**-decimals)) + (rel * (expected.abs + actual.abs)) : [rel * expected.abs, 1e-12].max
    assert_in_delta expected, actual, delta, msg
  end

  # model => [Result (via Swmm.run, public API), Oracle::Run on the same .inp]
  def both(model, dir)
    result = Swmm.run(model, dir: File.join(dir, "gem"))
    assert result.ok?, result.error&.fetch(:details, nil)&.join("; ")
    [result, Oracle.run(result.files[:inp], dir)]
  end
end

# ---------------------------------------------------------------------------------------------------------------------
# Oracle 1: EPA's Example1.out. Does not need the engine, so it must never skip.
# ---------------------------------------------------------------------------------------------------------------------
class EpaExample1Test < Minitest::Test
  # test/fixtures/Example1.out: copied unchanged from tmp/swmm-src/tests/outfile/data/Example1.out of the EPA SWMM
  # repository (tag v5.2.4), a US-government (EPA) test file written by SWMM 5.1.0 (output format code 51000).
  # Expected numbers: tests/outfile/test_output.cpp of the same tree (indexes there are 0-based; EPA compares to 3 decimals).
  FILE = File.expand_path("fixtures/Example1.out", __dir__)

  def setup
    @bytes = File.binread(FILE)
    @out = Swmm::OutputFile.new(@bytes)
  end

  def close(expected, actual, msg = nil)
    assert_equal expected.size, actual.size, msg
    expected.zip(actual).each_with_index do |(e, a), i|
      assert_in_delta e, a, 1e-5 * [1, e.abs].max, "#{msg} [#{i}]" # tighter than EPA's own 1e-3
    end
  end

  def test_the_fixture_is_the_epa_file
    assert_equal 44_018, @bytes.bytesize
    assert_equal 51_000, @bytes.unpack1("l<", offset: 4), "SWMM 5.1.0 output format code (test_getVersion)"
  end

  def test_project_size_as_in_test_getProjectSize
    assert_equal [8, 14, 13, 2], [@out.ids[:subcatchments].size, @out.ids[:nodes].size, @out.ids[:links].size, @out.pollutants.size]
  end

  def test_names_pollutants_and_units_as_in_the_cpp_test
    assert_equal "CFS", @out.flow_units # test_getFlowUnits: 0
    assert_equal %w[TSS Lead], @out.pollutants
    assert_equal "10", @out.ids[:nodes][1], "test_getElementName: node index 1"
    assert_equal({ "TSS" => "MG/L", "Lead" => "UG/L" }, @out.units[:nodes].select { _1.start_with?("quality:") }.transform_keys { _1.delete_prefix("quality:") }) # {SMO_MG, SMO_UG}
    assert_equal "ft", @out.units[:nodes]["depth"], "unit system SMO_US"
    assert_equal "in/h", @out.units[:subcatchments]["rainfall"]
    assert_equal 36, @out.periods # test_getTimes SMO_numPeriods
    assert_equal 3600, @out.report_step # test_getTimes SMO_reportStep
    assert_equal Time.utc(1998, 1, 1), @out.start # test_getStartDate: 35796.0 days since 1899-12-30
    assert_equal (Time.utc(1998, 1, 1) + 3600), @out.times.first
    assert_equal Time.utc(1998, 1, 2, 12), @out.times.last, "36 periods of 1 h after the start"
    assert_equal(@out.times.each_cons(2).map { _2 - _1 }.uniq, [3600.0])
  end

  def test_series_as_in_test_getSubcatchSeries_and_test_getSystemSeries
    close [0.0, 1.2438242, 2.5639679, 4.524055, 2.5115132, 0.69808137, 0.040894926, 0.011605669, 0.00509294, 0.0027438672],
          @out.series(:subcatchments, "2", :runoff).first(10), "subcatchment index 1, runoff_rate, periods 0-9"
    close [0.0, 6.216825, 13.030855, 24.252975, 14.172027, 4.1949716, 0.322329, 0.056010, 0.024938, 0.012474],
          @out.series(:system, "system", :runoff).first(10), "system runoff_flow, periods 0-9"
  end

  def test_one_period_of_every_kind_as_in_the_cpp_result_tests
    sub = @out.all_series(:subcatchments)["2"] # test_getSubcatchResult(period 1, subcatchment 1)
    close [0.5, 0.0, 0.0, 0.125, 1.2438242, 0.0, 0.0, 0.0, 33.481991, 6.6963983], @out.variables[:subcatchments].map { sub[_1][1] }, "subcatchment"
    node = @out.all_series(:nodes)["13"] # test_getNodeResult(period 2, node 2)
    close [0.296234, 995.296204, 0.0, 1.302650, 1.302650, 0.0, 15.361463, 3.072293], @out.variables[:nodes].map { node[_1][2] }, "node"
    link = @out.all_series(:links)["6"] # test_getLinkResult(period 3, link 3): 4th link of the file
    close [4.631762, 1.0, 5.8973422, 314.15927, 1.0, 19.070757, 3.8141515], @out.variables[:links].map { link[_1][3] }, "link"
    sys = @out.all_series(:system)["system"] # test_getSystemResult(period 4)
    close [70.0, 0.1, 0.0, 0.19042271, 14.172027, 0.0, 0.0, 0.0, 0.0, 14.172027, 0.55517411, 13.622702, 2913.0793, 0.0],
          @out.variables[:system].map { sys[_1][4] }, "system"
  end

  def test_the_same_numbers_through_series_and_all_series
    assert_equal @out.series(:nodes, "13", :total_inflow), @out.all_series(:nodes)["13"]["total_inflow"]
    assert_equal 14, @out.variables[:system].size, "a 5.1 file has 14 system variables (5.2 adds potential_et)"
    refute_includes @out.variables[:system], "potential_et"
  end

  # Weighted sums sum(value * (object index + 1) * (period + 1)) over the WHOLE file, per variable, computed once with EPA's
  # libswmm-output (SMO_get{Subcatch,Node,Link,System}Result, SWMM 5.2.4 src/outfile compiled from the same tag) over Example1.out.
  # The weights make a swapped object or period change the sum, not only a wrong variable.
  GOLDEN_SUMS = {
    subcatchments: [819.000012, 0, 0, 606.997588, 2515.04905, 0, 0, 0, 198_334.897, 39_666.9794],
    nodes: [19_040.8799, 69_179_145, 0, 3437.11439, 36_045.5913, 44.962549, 524_483.653, 104_896.731],
    links: [29_408.2135, 4418.14009, 67_986.6882, 1_421_569.67, 1918.51409, 389_519.254, 77_903.8507],
    system: [46_620, 22.7500003, 0, 14.8531609, 704.942831, 0, 0, 0, 0, 704.942831, 22.4812745, 686.429877, 176_337.893, 0]
  }.freeze

  def test_every_value_of_the_file_agrees_with_epas_libswmm_output
    GOLDEN_SUMS.each do |kind, sums|
      all = @out.all_series(kind)
      names = @out.variables[kind]
      assert_equal sums.size, names.size, kind
      names.each_with_index do |name, v|
        got = all.each_with_index.sum { |(_id, vars), i| vars[name].each_with_index.sum { |x, p| x * (i + 1) * (p + 1) } }
        assert_in_delta sums[v], got, [sums[v].abs * 1e-6, 1e-9].max, "#{kind} #{name}"
      end
    end
  end
end

# ---------------------------------------------------------------------------------------------------------------------
# Oracles 2 and 3 on live runs
# ---------------------------------------------------------------------------------------------------------------------
class EngineOracleTest < Minitest::Test
  include NeedsEngine
  include OracleHelpers

  # series read by the gem == swmm_getSavedValue of the engine, value by value, to the 7 digits that "%.7g" keeps
  def compare_with_saved(result, oracle)
    compared = Hash.new(0)
    Oracle::KINDS.each do |kind|
      assert_equal oracle.flagged[kind], result.ids(kind), "#{kind}: objects saved (the engine's report flag) vs ids"
      oracle.saved[kind].each do |id, vars|
        vars.each do |var, expected|
          actual = result.series(kind, id, var)
          assert_equal expected.size, actual.size, "#{kind} #{id} #{var}: periods"
          expected.zip(actual).each_with_index do |(e, a), p|
            near e, a, msg: "#{kind} #{id} #{var} period #{p}"
            compared[kind] += 1
          end
        end
      end
    end
    compared
  end

  def test_base_model_series_dates_and_header_match_the_c_api
    Dir.mktmpdir do |dir|
      result, oracle = both(Fixtures.base, dir)
      assert_equal oracle.flow_units_code, Swmm::OutputFile::FLOW_UNITS.index(result.output.flow_units), "swmm_getValue(FLOWUNITS)"
      assert_equal oracle.periods, result.output.periods, "swmm_getValue(TOTALSTEPS)"
      assert_equal oracle.dates.map { Oracle.time_of(_1) }, result.times, "swmm_getSavedValue(CURRENTDATE)"
      compared = compare_with_saved(result, oracle)
      assert_equal({ nodes: 3 * 6 * 12, links: 2 * 4 * 12 }, compared.slice(:nodes, :links), "no vacuous pass")
      assert_equal 0, compared[:subcatchments]
    end
  end

  def test_full_model_with_subcatchments_pollutants_and_groundwater_matches_the_c_api
    Dir.mktmpdir do |dir|
      result, oracle = both(Fixtures.full(dir), dir)
      compared = compare_with_saved(result, oracle)
      assert_equal({ subcatchments: 3 * 4 * 24, nodes: 9 * 6 * 24, links: 10 * 4 * 24 }, compared.slice(:subcatchments, :nodes, :links))
      assert_equal oracle.dates.map { Oracle.time_of(_1) }, result.times
    end
  end

  def test_series_match_the_engine_report_tables
    Dir.mktmpdir do |dir|
      result, oracle = both(Fixtures.base, dir)
      nodes = Oracle.tables(oracle.report, "Node")
      links = Oracle.tables(oracle.report, "Link")
      assert_equal %w[J1 J2 O1], nodes.keys
      assert_equal %w[C1 C2], links.keys
      check_tables(result, :nodes, nodes, %w[total_inflow overflow depth head])
      check_tables(result, :links, links, %w[flow velocity depth capacity])
    end
  end

  def test_full_model_series_match_the_engine_report_tables_including_quality_columns
    Dir.mktmpdir do |dir|
      result, oracle = both(Fixtures.full(dir), dir)
      check_tables(result, :nodes, Oracle.tables(oracle.report, "Node"), %w[total_inflow overflow depth head quality:TSS quality:COD])
      check_tables(result, :links, Oracle.tables(oracle.report, "Link"), %w[flow velocity depth capacity quality:TSS quality:COD])
      subs = Oracle.tables(oracle.report, "Subcatchment")
      assert_equal %w[S1 S2 S3], subs.keys
      # report columns: precip, losses (= evap/24 + infil), runoff, snow depth, gw elevation, gw flow, washoff per pollutant
      names = ["rainfall", :losses, "runoff", "snow_depth", "gw_elevation", "gw_flow", "quality:TSS", "quality:COD"]
      decimals = [3, 3, 4, 3, 3, 4, 3, 3]
      subs.each do |id, rows|
        assert_equal result.times, rows.map(&:first), "subcatchment #{id}: dates"
        refute_empty rows
        rows.each_with_index do |(_t, cols), p|
          assert_equal names.size, cols.size, "subcatchment #{id} row #{p}"
          names.each_with_index do |name, c|
            mine = name == :losses ? (result.series(:subcatchments, id, :evaporation)[p] / 24.0) + result.series(:subcatchments, id, :infiltration)[p] : result.series(:subcatchments, id, name)[p]
            near mine, cols[c], decimals: decimals[c], msg: "subcatchment #{id} #{name} period #{p}"
          end
        end
      end
    end
  end

  def check_tables(result, kind, tables, names)
    decimals = Array.new(names.size, 3)
    tables.each do |id, rows|
      assert_equal result.times.size, rows.size, "#{kind} #{id}: one row per period"
      assert_equal result.times, rows.map(&:first), "#{kind} #{id}: report dates vs times"
      rows.each_with_index do |(_t, cols), p|
        assert_equal names.size, cols.size, "#{kind} #{id} row #{p}"
        names.each_with_index do |name, c|
          near result.series(kind, id, name)[p], cols[c], decimals: decimals[c], msg: "#{kind} #{id} #{name} period #{p}"
        end
      end
    end
  end

  # current behaviour, not a defect: Engine#run stops at swmm_end and never calls swmm_report, so the .rpt of Swmm.run has the
  # summaries but not the "... Time Series Results" tables that `swmm5 model.inp model.rpt` would write for [REPORT] NODES/LINKS.
  def test_gem_report_has_no_time_series_tables_unlike_swmm_run
    Dir.mktmpdir do |dir|
      result, oracle = both(Fixtures.base, dir)
      refute_includes result.report, "Time Series Results"
      refute_includes result.report, "<<< Node"
      assert_includes oracle.report, "Node Time Series Results"
      assert_includes result.report, "Node Depth Summary"
    end
  end

  def test_continuity_matches_the_report_to_its_rounding
    Dir.mktmpdir do |dir|
      result = Swmm.run(Fixtures.full(dir))
      pct = lambda do |title|
        section = result.report[/#{title}[^\n]*\n.*?Continuity Error \(%\) \.+\s+([^\n]*)\n/m, 1]
        section.split.map(&:to_f)
      end
      near pct.call("Runoff Quantity Continuity").first, result.continuity[:runoff], decimals: 3
      near pct.call("Flow Routing Continuity").first, result.continuity[:flow_routing], decimals: 3
      worst = pct.call("Quality Routing Continuity").max_by(&:abs) # swmm_getMassBalErr gives the largest of the pollutants
      near worst, result.continuity[:quality], decimals: 3
      refute_equal 0, result.continuity[:quality], "no vacuous pass"
    end
  end

  # --- times with report_start / report_step ------------------------------------------------------------------------

  def run_with_report_start(start_time, step)
    model = Fixtures.base
    model[:options] = model[:options].merge(report_start_date: "2026-03-24", report_start_time: start_time, report_step: step)
    Dir.mktmpdir do |dir|
      result, oracle = both(model, dir)
      yield result, oracle
    end
  end

  def test_times_follow_report_start_and_report_step
    { ["00:30", "00:10:00"] => ["00:30", 10, 10], ["00:35", "00:10:00"] => ["00:40", 10, 9],
      ["01:00", "00:15:00"] => ["01:00", 15, 5], ["00:00", "00:30:00"] => ["00:30", 30, 4] }.each do |(rs, step), (first, minutes, count)|
      run_with_report_start(rs, step) do |result, oracle|
        label = "report_start #{rs} step #{step}"
        assert_equal oracle.dates.map { Oracle.time_of(_1) }, result.times, label
        assert_equal count, result.output.periods, label
        assert_equal first, result.times.first.strftime("%H:%M"), "#{label}: first period is the first step at or after report_start"
        assert_equal Time.utc(2026, 3, 24, 2), result.times.last, label
        assert_equal [minutes * 60.0], result.times.each_cons(2).map { _2 - _1 }.uniq, label
        assert_equal minutes * 60, result.output.report_step, label
        stamps = Oracle.tables(oracle.report, "Node")["J1"].map(&:first)
        assert_equal result.times, stamps, "#{label}: dates of the report table"
        # the series of the periods that exist are still the engine's values
        near oracle.saved[:nodes]["J1"]["depth"].last, result.series(:nodes, "J1", :depth).last, msg: label
      end
    end
  end

  # SURPRISING BUT ACCEPTABLE (engine semantics, kept in the file header): OutputFile#start is not the simulation start nor the
  # report start when report_start is later; the engine stores "one reporting period before the first reported result" computed
  # from a multiple of the step counted from the start. start + report_step is the first time only when report_start is a multiple.
  def test_start_is_one_period_before_the_first_reported_time_only_when_report_start_is_aligned
    run_with_report_start("00:30", "00:10:00") do |result, _|
      assert_equal Time.utc(2026, 3, 24, 0, 20), result.output.start
      assert_equal result.output.start + 600, result.times.first
    end
    run_with_report_start("00:35", "00:10:00") do |result, _|
      assert_equal Time.utc(2026, 3, 24, 0, 20), result.output.start
      assert_equal Time.utc(2026, 3, 24, 0, 40), result.times.first
      refute_equal result.output.start + 600, result.times.first, "start + report_step is NOT the first time here"
    end
    Dir.mktmpdir do |dir|
      assert_equal Time.utc(2026, 3, 24), Swmm.run(Fixtures.base, dir: dir).output.start, "no report_start: the simulation start"
    end
  end

  def with_options(**options)
    model = Fixtures.base
    model.merge(options: model[:options].merge(options))
  end

  def test_dates_across_midnight_year_end_leap_day_and_second_steps_match_the_engine
    {
      "year end" => with_options(start_date: "2026-12-31", start_time: "23:30", end_date: "2027-01-01", end_time: "00:30"),
      "leap day" => with_options(start_date: "2028-02-28", start_time: "23:00", end_date: "2028-03-01", end_time: "01:00", report_step: "00:30:00"),
      "30 s step" => with_options(end_time: "00:10", report_step: "00:00:30", routing_step: 5),
      "step longer than the run" => with_options(report_step: "03:00:00") # the engine shortens it to the run (7200 s)
    }.each do |label, model|
      Dir.mktmpdir do |dir|
        result, oracle = both(model, dir)
        assert_equal oracle.dates.map { Oracle.time_of(_1) }, result.times, label
        assert_equal oracle.periods, result.output.periods, label
        assert_equal result.times, Oracle.tables(oracle.report, "Node")["J1"].map(&:first), "#{label}: report dates"
        assert_equal [result.output.report_step.to_f], result.times.each_cons(2).map { _2 - _1 }.uniq, label if result.times.size > 1
        compare_with_saved(result, oracle)
      end
    end
  end

  # Engine behaviour, reproduced with the stock swmm_run of the same libswmm5 (not a wrapper defect): for about 1 start time in 3
  # the period that falls exactly on the end date is not saved (floating-point date arithmetic in SWMM 5.2.4), so the last time is
  # 10 minutes before the end. Nothing in Result tells the caller. Known engine bug (docs/known-issues.md, #1); the test pins the
  # facts so a change (an engine fix) is noticed.
  def test_the_period_on_the_end_date_can_be_missing_because_of_the_engine
    short = with_options(start_date: "2022-11-27", start_time: "11:00", end_date: "2022-11-27", end_time: "13:00")
    Dir.mktmpdir do |dir|
      result, oracle = both(short, dir)
      assert_equal 11, result.output.periods, "12 expected from 11:00 to 13:00 every 10 min"
      assert_equal oracle.periods, result.output.periods
      assert_equal Time.utc(2022, 11, 27, 12, 50), result.times.last
      assert_match(/Ending Date \.+ 11\/27\/2022 13:00:00/, result.report)
    end
    Dir.mktmpdir { |dir| assert_equal Time.utc(2026, 3, 24, 2), both(Fixtures.base, dir).first.times.last, "midnight start: the last period is there" }
  end

  def test_averages_option_saves_averaged_values_and_still_matches_the_c_api
    Dir.mktmpdir do |dir|
      model = Fixtures.base.merge(report: Fixtures.base[:report].merge(averages: true))
      result, oracle = both(model, dir)
      compare_with_saved(result, oracle)
      check_tables(result, :nodes, Oracle.tables(oracle.report, "Node"), %w[total_inflow overflow depth head])
    end
  end

  def test_unicode_and_punctuated_ids_survive_the_out_file
    base = Fixtures.base
    [%w[Nó-é Ç2], %w[J.1 J/2], ["a" * 79, "b" * 80], %w[日本1 ü2]].each do |a, b|
      model = base.merge(junctions: [{ name: a, elevation: 10, max_depth: 3 }, { name: b, elevation: 9.5, max_depth: 3 }],
                         conduits: base[:conduits].map { _1[:name] == "C1" ? _1.merge(from_node: a, to_node: b) : _1.merge(from_node: b) },
                         inflows: [{ node: a, series: "Q" }])
      Dir.mktmpdir do |dir|
        result, oracle = both(model, dir)
        assert_equal [a, b, "O1"], result.ids(:nodes)
        assert_equal Oracle.tables(oracle.report, "Node").keys, result.ids(:nodes)
        compare_with_saved(result, oracle)
        assert_equal 12, result.to_csv(:nodes).lines.count { _1.include?(",#{a},") }
      end
    end
  end

  def test_continuity_is_cleaned_like_every_other_float
    continuity = assert_runs(Fixtures.base).continuity
    continuity.each_value { |v| assert_equal Swmm::OutputFile.clean(v), v }
  end

  # --- [REPORT] selection rules ---------------------------------------------------------------------------------------

  def test_only_listed_objects_are_saved_and_the_system_always_is
    Dir.mktmpdir do |dir|
      model = Fixtures.base.merge(report: { nodes: %w[J2], links: %w[C2] })
      result, oracle = both(model, dir)
      assert_equal %w[J2], result.ids(:nodes)
      assert_equal %w[C2], result.ids(:links)
      assert_empty result.ids(:subcatchments)
      assert_equal ["system"], result.ids(:system)
      assert_equal 12, result.series(:system, "system", :outflow).size
      assert_equal %w[J2], oracle.flagged[:nodes], "the engine's own report flags"
      assert_equal %w[J2], Oracle.tables(oracle.report, "Node").keys
      assert_equal %w[C2], Oracle.tables(oracle.report, "Link").keys
      assert_raises(Swmm::UnknownObject) { result.series(:nodes, "J1", :depth) }
      compare_with_saved(result, oracle)
    end
  end

  def test_saved_objects_come_in_definition_order_not_in_the_order_of_the_list
    model = Fixtures.base.merge(report: { nodes: %w[O1 J2 J1], links: %w[C2 C1] })
    result = assert_runs(model)
    assert_equal %w[J1 J2 O1], result.ids(:nodes)
    assert_equal %w[C1 C2], result.ids(:links)
  end

  def test_none_and_a_missing_report_section_save_no_objects_but_keep_the_system
    no_section = Fixtures.base
    no_section.delete(:report)
    [no_section, Fixtures.base.merge(report: { nodes: "NONE", links: "NONE", subcatchments: "NONE" })].each do |model|
      result = assert_runs(model)
      %i[subcatchments nodes links].each { assert_empty result.ids(_1) }
      assert_equal 12, result.series(:system, "system", :total_inflow).size
      assert_equal "time,id,air_temperature", result.to_csv(:system).lines.first[0, 23]
      assert_equal 1, result.to_csv(:nodes).lines.size
      assert_equal 12, result.output.periods
    end
  end

  def test_listed_subcatchments_only
    Dir.mktmpdir do |dir|
      model = Fixtures.full(dir)
      model[:report] = model[:report].merge(subcatchments: %w[S3 S1], nodes: %w[J3], links: %w[C5])
      result, oracle = both(model, dir)
      assert_equal %w[S1 S3], result.ids(:subcatchments)
      assert_equal %w[J3], result.ids(:nodes)
      assert_equal %w[C5], result.ids(:links)
      assert_equal %w[S1 S3], Oracle.tables(oracle.report, "Subcatchment").keys
      compare_with_saved(result, oracle)
    end
  end

  # --- units ---------------------------------------------------------------------------------------------------------

  def expected_units(flow, si)
    {
      subcatchments: si ? [*%w[mm/h mm mm/day mm/h], flow, flow, "m", "fraction"] : [*%w[in/h in in/day in/h], flow, flow, "ft", "fraction"],
      nodes: si ? ["m", "m", "m3", flow, flow, flow] : ["ft", "ft", "ft3", flow, flow, flow],
      links: si ? [flow, "m", "m/s", "m3", "fraction"] : [flow, "ft", "ft/s", "ft3", "fraction"],
      system: [si ? "degC" : "degF", si ? "mm/h" : "in/h", si ? "mm" : "in", si ? "mm/h" : "in/h", *[flow] * 8, si ? "m3" : "ft3",
               si ? "mm/day" : "in/day", si ? "mm/day" : "in/day"]
    }
  end

  # peak of the hydrograph in each unit: 0.1 cfs expressed in the unit (US geometry in ft), 80 L/s in the SI ones (geometry in m)
  PEAK = { "CFS" => 0.1, "GPM" => 44.8831, "MGD" => 0.0646317, "LPS" => 80.0, "CMS" => 0.08, "MLD" => 6.912 }.freeze

  def model_in(unit)
    m = Fixtures.base
    m[:options] = m[:options].merge(flow_units: unit)
    peak = PEAK.fetch(unit)
    m[:timeseries] = [{ name: "Q", points: [[0, 0], [0.5, peak * 0.625], [1, peak], [2, 0]] }]
    m
  end

  def test_every_flow_unit_is_reported_consistently_by_the_gem_the_engine_and_the_report
    results = {}
    PEAK.each_key do |unit|
      Dir.mktmpdir do |dir|
        result, oracle = both(model_in(unit), dir)
        results[unit] = result
        si = %w[LPS CMS MLD].include?(unit)
        assert_equal unit, result.output.flow_units
        assert_equal unit, Swmm::OutputFile::FLOW_UNITS.fetch(oracle.flow_units_code), "engine's own flow unit code"
        assert_match(/Flow Units \.+ #{unit}$/, result.report)
        assert_match(/Flow Units \.+ #{unit}$/, oracle.report)
        words = Oracle.header_units(oracle.report, "Node", "J1")
        assert_equal [unit.downcase, unit.downcase, si ? "meters" : "feet", si ? "meters" : "feet"], words.map(&:downcase), "node table header"
        words = Oracle.header_units(oracle.report, "Link", "C1")
        assert_equal [unit.downcase, si ? "m/sec" : "ft/sec", si ? "meters" : "feet"], words.first(3).map(&:downcase), "link table header"
        expected = expected_units(unit, si)
        expected.each do |kind, list|
          assert_equal list, result.output.units[kind].values, "#{unit} #{kind} units"
          assert_equal list, result.to_h[:output][:units][kind].values
        end
        near PEAK[unit], result.series(:nodes, "J1", :lateral_inflow).max, rel: 5e-3, msg: "#{unit}: peak of the hydrograph in the unit"
        compare_with_saved(result, oracle)
      end
    end
    # same network, flows scaled by the unit conversion: depths agree, flows scale (factors: cfs->unit, 1 cfs = 448.831 gpm ...)
    { "GPM" => 448.831, "MGD" => 0.646317 }.each do |unit, k|
      assert_series_scaled results["CFS"], results[unit], k
    end
    { "CMS" => 0.001, "MLD" => 0.0864 }.each do |unit, k|
      assert_series_scaled results["LPS"], results[unit], k
    end
  end

  def assert_series_scaled(base, other, k)
    assert_equal base.series(:links, "C2", :depth).size, other.series(:links, "C2", :depth).size
    base.series(:links, "C2", :depth).zip(other.series(:links, "C2", :depth)).each do |a, b|
      assert_in_delta a, b, (0.002 * a.abs) + 1e-4, "depth does not depend on the flow unit"
    end
    peak = base.series(:links, "C2", :flow).max
    assert_in_delta peak * k, other.series(:links, "C2", :flow).max, peak * k * 0.01, "flow scales with the unit"
  end

  def with_pollutant_units(model, units)
    model.merge(pollutants: model[:pollutants].each_with_index.map { |p, i| p.merge(units: units[i]) })
  end

  def test_pollutant_units_mg_ug_and_count_per_litre
    Dir.mktmpdir do |dir|
      { %w[MG/L UG/L] => %w[mg/l ug/l], %w[UG/L #/L] => %w[ug/l #/l], %w[#/L MG/L] => %w[#/l mg/l] }.each do |codes, words|
        model = with_pollutant_units(Fixtures.full(dir), codes)
        result, oracle = both(model, dir)
        %i[subcatchments nodes links].each do |kind|
          shown = result.output.units[kind].select { |name, _| name.start_with?("quality:") }
          assert_equal({ "quality:TSS" => codes[0], "quality:COD" => codes[1] }, shown, "#{kind} #{codes}")
        end
        assert_equal words, Oracle.header_units(oracle.report, "Node", "J3").last(2).map(&:downcase), "engine's header #{codes}"
        assert_equal words, Oracle.header_units(oracle.report, "Link", "C1").last(2).map(&:downcase)
        compare_with_saved(result, oracle)
      end
    end
  end

  def test_values_are_in_the_labelled_units_in_the_full_model
    Dir.mktmpdir do |dir|
      result = Swmm.run(Fixtures.full(dir))
      assert_equal "degC", result.output.units[:system]["air_temperature"]
      assert_equal "mm/h", result.output.units[:system]["rainfall"]
      temperature = result.series(:system, "system", :air_temperature)
      # TEMP goes 5 -> 8 degC over 6 h, [ADJUSTMENTS] adds 1 degC per month: 6 .. 9 (a value in degF would be 40+)
      assert_in_delta 6.0, temperature.first, 1e-4
      assert(temperature.all? { _1.between?(6.0, 9.0) })
      assert_equal temperature.sort, temperature, "rising series"
      # RAIN gage in mm/h (INTENSITY): 10, 20, 5, 0 at 00:15, 00:30, 00:45, 01:00 as given, no conversion
      assert_equal [10.0, 20.0, 5.0, 0.0], result.series(:system, "system", :rainfall).first(4)
    end
  end

  # --- magnitudes ----------------------------------------------------------------------------------------------------

  def scaled_model(factor)
    m = Fixtures.base
    m[:timeseries] = [{ name: "Q", points: [[0, 0], [0.5, 50 * factor], [1, 80 * factor], [2, 0]] }]
    m
  end

  def test_very_large_and_very_small_magnitudes_keep_seven_digits
    Dir.mktmpdir do |dir|
      { "x1e4 (flooding)" => 1e4, "x1e-2" => 1e-2 }.each do |label, factor|
        result, oracle = both(scaled_model(factor), FileUtils.mkdir_p(File.join(dir, label.delete(" ()"))).first)
        compare_with_saved(result, oracle)
        peak = result.series(:nodes, "J1", :total_inflow).max
        assert_in_delta 80 * factor, peak, 80 * factor * 5e-3, label
        result.series(:links, "C1", :flow).each { assert_kind_of Float, _1 }
        assert_equal [], result.series(:links, "C1", :flow).grep_v(Float), label
        # the JSON of any of these numbers is plain JSON that parses back to the same Float
        json = JSON.parse(result.to_json)
        assert_equal result.series(:links, "C1", :flow), json["output"]["links"]["C1"]["flow"], label
      end
    end
  end

  def test_high_elevations_lose_nothing_beyond_seven_digits_of_the_float32
    Dir.mktmpdir do |dir|
      model = Fixtures.base
      model[:junctions] = [{ name: "J1", elevation: 4000.25, max_depth: 3 }, { name: "J2", elevation: 3999.75, max_depth: 3 }]
      model[:outfalls] = [{ name: "O1", elevation: 3999.5, type: "FREE" }]
      result, oracle = both(model, dir)
      compare_with_saved(result, oracle)
      heads = result.series(:nodes, "J1", :head)
      assert(heads.all? { _1 > 4000.25 })
      assert_in_delta oracle.saved[:nodes]["J1"]["head"].last, heads.last, 4000 * 5e-7, "head at 4000 m is kept to 5e-7 relative (about 2 mm)"
    end
  end
end

# ---------------------------------------------------------------------------------------------------------------------
# clean: pure, no engine
# ---------------------------------------------------------------------------------------------------------------------
class CleanTest < Minitest::Test
  def float32(x) = [x].pack("e").unpack1("e")

  def test_non_finite_floats_become_nil_and_zero_stays_zero
    assert_nil Swmm::OutputFile.clean(Float::NAN)
    assert_nil Swmm::OutputFile.clean(Float::INFINITY)
    assert_nil Swmm::OutputFile.clean(-Float::INFINITY)
    assert_equal 0.0, Swmm::OutputFile.clean(0.0)
    assert_equal 0.0, Swmm::OutputFile.clean(-0.0).abs
  end

  def test_float32_noise_is_removed
    assert_equal 0.1, Swmm::OutputFile.clean(float32(0.1))
    assert_equal 1.243824, Swmm::OutputFile.clean(float32(1.2438242))
    assert_equal 995.2962, Swmm::OutputFile.clean(float32(995.296204))
  end

  # Surprising but acceptable (the header comment says "the 7 digits that mean something"): a float32 holds ~7.2 digits and needs
  # 9 to round-trip, so clean(x) is within 5e-7 relative of x but is not always the same float32 again.
  def test_relative_error_is_at_most_five_e_minus_seven_over_the_float32_range
    rng = Random.new(20_260_416)
    worst = 0.0
    changed = 0
    2000.times do
      exponent = rng.rand(-37..37)
      x = float32(rng.rand(1.0..9.999999) * (10.0**exponent) * (rng.rand < 0.5 ? 1 : -1))
      c = Swmm::OutputFile.clean(x)
      worst = [worst, ((c - x) / x).abs].max
      changed += 1 unless float32(c) == x
    end
    assert_operator worst, :<=, 5.0001e-7
    assert_operator changed, :>, 0, "documented: not every float32 survives the 7-digit round trip"
  end

  def test_extremes_of_the_float32_range
    big = float32(3.4028234e38)
    assert_in_delta big, Swmm::OutputFile.clean(big), big * 5e-7
    tiny = float32(1.17549435e-38) # smallest normal float32
    assert_in_delta tiny, Swmm::OutputFile.clean(tiny), tiny * 5e-7
    denormal = float32(1e-45) # smallest subnormal float32 (about 1.4e-45)
    assert_operator Swmm::OutputFile.clean(denormal), :>, 0.0
    assert_in_delta denormal, Swmm::OutputFile.clean(denormal), denormal * 0.5
  end
end

# ---------------------------------------------------------------------------------------------------------------------
# R6: golden contract of Result#to_h / #to_json
# ---------------------------------------------------------------------------------------------------------------------
class ResultContractTest < Minitest::Test
  include NeedsEngine

  Near = Struct.new(:value, :delta)

  # Differences between a golden structure and actual data, as readable lines. A Class in the golden means "any instance of it",
  # a Near means "a Float within delta" (engine numerics), everything else must be equal. Key ORDER matters (it is the contract's order).
  def diff(golden, actual, path = "result", out = [])
    case golden
    when Hash
      return out << "#{path}: was a Hash, now #{actual.class}" unless actual.is_a?(Hash)

      (golden.keys - actual.keys).each { out << "#{path}: key #{_1.inspect} REMOVED" }
      (actual.keys - golden.keys).each { out << "#{path}: key #{_1.inspect} ADDED (value #{actual[_1].inspect[0, 60]})" }
      out << "#{path}: key order changed from #{golden.keys} to #{actual.keys}" if (golden.keys - actual.keys).empty? && (actual.keys - golden.keys).empty? && golden.keys != actual.keys
      golden.each { |k, v| diff(v, actual[k], "#{path}.#{k}", out) if actual.key?(k) }
    when Array
      return out << "#{path}: was an Array, now #{actual.class}" unless actual.is_a?(Array)

      out << "#{path}: size changed from #{golden.size} to #{actual.size}" unless golden.size == actual.size
      golden.zip(actual).each_with_index { |(g, a), i| diff(g, a, "#{path}[#{i}]", out) if i < actual.size }
    when Class
      out << "#{path}: expected #{golden}, got #{actual.class} (#{actual.inspect[0, 60]})" unless golden === actual
    when Near
      out << "#{path}: expected #{golden.value} +- #{golden.delta}, got #{actual.inspect}" unless actual.is_a?(Float) && (actual - golden.value).abs <= golden.delta
    else
      out << "#{path}: expected #{golden.inspect}, got #{actual.inspect}" unless golden == actual
    end
    out
  end

  def assert_golden(golden, actual, what)
    problems = diff(golden, actual)
    assert_empty problems, "#{what}: the output contract changed (update the golden only on purpose):\n  #{problems.first(25).join("\n  ")}"
  end

  NODE_VARS = %w[depth head volume lateral_inflow total_inflow overflow].freeze
  LINK_VARS = %w[flow depth velocity volume capacity].freeze
  SYSTEM_VARS = %w[air_temperature rainfall snow_depth infiltration runoff dry_weather_inflow groundwater_inflow rdii_inflow
                   direct_inflow total_inflow flooding outflow storage evaporation potential_et].freeze

  def vars(names, value) = names.to_h { [_1, value] }

  def golden(series:)
    value = series ? Array.new(12, Float) : nil
    {
      status: "ok", swmm_version: "5.2.4", error: nil, warnings: [],
      continuity: { runoff: 0.0, flow_routing: Near.new(-0.144, 0.005), quality: 0.0 },
      flow_instability: {}, files: nil,
      output: {
        flow_units: "LPS", start: "2026-03-24T00:00:00", report_step: 600, periods: 12,
        times: %w[00:10 00:20 00:30 00:40 00:50 01:00 01:10 01:20 01:30 01:40 01:50 02:00].map { "2026-03-24T#{_1}:00" },
        units: {
          subcatchments: { "rainfall" => "mm/h", "snow_depth" => "mm", "evaporation" => "mm/day", "infiltration" => "mm/h",
                           "runoff" => "LPS", "gw_flow" => "LPS", "gw_elevation" => "m", "soil_moisture" => "fraction" },
          nodes: { "depth" => "m", "head" => "m", "volume" => "m3", "lateral_inflow" => "LPS", "total_inflow" => "LPS", "overflow" => "LPS" },
          links: { "flow" => "LPS", "depth" => "m", "velocity" => "m/s", "volume" => "m3", "capacity" => "fraction" },
          system: { "air_temperature" => "degC", "rainfall" => "mm/h", "snow_depth" => "mm", "infiltration" => "mm/h",
                    "runoff" => "LPS", "dry_weather_inflow" => "LPS", "groundwater_inflow" => "LPS", "rdii_inflow" => "LPS",
                    "direct_inflow" => "LPS", "total_inflow" => "LPS", "flooding" => "LPS", "outflow" => "LPS",
                    "storage" => "m3", "evaporation" => "mm/day", "potential_et" => "mm/day" }
        },
        subcatchments: {},
        nodes: %w[J1 J2 O1].to_h { [_1, vars(NODE_VARS, value)] },
        links: %w[C1 C2].to_h { [_1, vars(LINK_VARS, value)] },
        system: { "system" => vars(SYSTEM_VARS, value) }
      }
    }
  end

  def test_to_h_without_series_is_the_golden_contract
    result = assert_runs(Fixtures.base)
    assert_golden golden(series: false), result.to_h(series: false), "to_h(series: false)"
  end

  def test_to_h_with_series_has_the_same_structure_and_float_arrays
    result = assert_runs(Fixtures.base)
    assert_golden golden(series: true), result.to_h, "to_h"
    assert_golden golden(series: true), result.to_h(series: true), "to_h(series: true)"
  end

  def test_to_json_is_the_golden_contract_as_plain_json
    result = assert_runs(Fixtures.base)
    json = JSON.parse(result.to_json)
    stringify = lambda do |g|
      case g
      when Hash then g.to_h { |k, v| [k.to_s, stringify.call(v)] }
      when Array then g.map { stringify.call(_1) }
      else g
      end
    end
    assert_golden stringify.call(golden(series: true)), json, "to_json"
    assert_equal JSON.parse(JSON.generate(result.to_h)), json, "to_json is the JSON of to_h"
    assert_equal json, JSON.parse(JSON.generate(result)), "JSON.generate(result) uses to_json"
    assert_equal json, JSON.parse(JSON.pretty_generate(result)), "pretty_generate too"
    json["output"]["nodes"].each_value { |vars| vars.each_value { |a| assert_equal 12, a.size } }
    assert_equal result.series(:nodes, "J1", :depth), json["output"]["nodes"]["J1"]["depth"], "floats survive the JSON round trip"
  end

  def test_types_of_the_leaf_values
    h = assert_runs(Fixtures.base).to_h
    assert_instance_of String, h[:status]
    assert_instance_of String, h[:swmm_version]
    assert_instance_of Array, h[:warnings]
    assert_instance_of Integer, h[:output][:report_step]
    assert_instance_of Integer, h[:output][:periods]
    assert(h[:output][:times].all?(String))
    assert(h[:output][:times].all? { _1.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\z/) }, "ISO 8601 without zone: SWMM dates carry none")
    assert_equal h[:output][:times].sort, h[:output][:times]
    assert_equal h[:output][:periods], h[:output][:times].size
  end

  def test_failure_shape
    model = Fixtures.base.merge(conduits: [{ name: "C1", from_node: "J1", to_node: "NOPE", length: 100, roughness: 0.013, in_offset: 0, out_offset: 0 }])
    h = Swmm.run(model).to_h
    assert_golden({ status: "error", swmm_version: "5.2.4", error: { code: 200, message: "ERROR 200: one or more errors in input file.", details: Array },
                    warnings: [], continuity: nil, flow_instability: {}, files: nil, output: nil }, h, "failed run")
    assert(h[:error][:details].all?(String))
    assert_equal JSON.parse(JSON.generate(h)), JSON.parse(Swmm.run(model).to_json), "to_json of a failed run"
  end

  def test_files_and_flow_instability_shapes_on_the_full_model
    Dir.mktmpdir do |dir|
      result = Swmm.run(Fixtures.full(dir), dir: File.join(dir, "kept"))
      h = result.to_h(series: false)
      assert_golden({ inp: String, rpt: String, out: String }, h[:files], "files")
      assert_equal %w[model.inp model.rpt model.out], h[:files].values.map { File.basename(_1) }
      assert(h[:files].values.all? { File.file?(_1) })
      refute_empty h[:flow_instability], "the full model is unstable (links W1, W2, OR1, C3, C4 at the time of writing)"
      assert(h[:flow_instability].all? { |k, v| k.is_a?(String) && v.is_a?(Integer) })
      assert_equal %i[runoff flow_routing quality], h[:continuity].keys
      assert(h[:continuity].values.all?(Float))
      assert_equal %w[S1 S2 S3], h[:output][:subcatchments].keys
      assert_includes h[:output][:subcatchments]["S1"].keys, "quality:TSS"
      assert_nil h[:output][:subcatchments]["S1"]["quality:TSS"]
    end
  end
end
