require 'fileutils'
require_relative '../swmm_helper'
require_relative '../support/swmm_oracle'

# Oracles 2 and 3 of spec/support/swmm_oracle.rb on live runs: the engine's own report tables and its C API.
RSpec.describe Swmm, 'fidelity to the engine', :libswmm5 do
  # peak of the hydrograph in each unit: 0.1 cfs expressed in the unit (US geometry in ft), 80 L/s in the SI ones (geometry in m)
  let(:peaks) { { 'CFS' => 0.1, 'GPM' => 44.8831, 'MGD' => 0.0646317, 'LPS' => 80.0, 'CMS' => 0.08, 'MLD' => 6.912 } }

  # delta of a value that went through "%.7g" (relative 5e-7 at worst) or was printed with +decimals+ digits
  def near(expected, actual, rel: 1e-6, decimals: nil, msg: nil)
    delta = decimals ? (0.5 * (10.0**-decimals)) + (rel * (expected.abs + actual.abs)) : [rel * expected.abs, 1e-12].max
    expect(actual).to be_within(delta).of(expected), msg
  end

  # model => [Result (via Swmm.run, public API), SwmmOracle::Run on the same .inp]
  def both(model, dir)
    result = described_class.run(model, dir: File.join(dir, 'gem'))
    expect(result).to be_ok, result.error&.fetch(:details, nil)&.join('; ')
    [result, SwmmOracle.run(result.files[:inp], dir)]
  end

  # series read by the pack == swmm_getSavedValue of the engine, value by value, to the 7 digits that "%.7g" keeps
  def compare_with_saved(result, oracle)
    compared = Hash.new(0)
    SwmmOracle::KINDS.each do |kind|
      expect(result[kind].ids).to eq(oracle.flagged[kind]), "#{kind}: objects saved (the engine's report flag) vs ids"
      oracle.saved[kind].each do |id, vars|
        vars.each do |var, expected|
          actual = result[kind][id][var].values
          expect(actual.size).to eq(expected.size), "#{kind} #{id} #{var}: periods"
          expected.zip(actual).each_with_index do |(e, a), p|
            near e, a, msg: "#{kind} #{id} #{var} period #{p}"
            compared[kind] += 1
          end
        end
      end
    end
    compared
  end

  def check_tables(result, kind, tables, names)
    decimals = Array.new(names.size, 3)
    tables.each do |id, rows|
      expect(rows.size).to eq(result.times.size), "#{kind} #{id}: one row per period"
      expect(rows.map(&:first)).to eq(result.times), "#{kind} #{id}: report dates vs times"
      rows.each_with_index do |(_t, cols), p|
        expect(cols.size).to eq(names.size), "#{kind} #{id} row #{p}"
        names.each_with_index do |name, c|
          near result[kind][id][name].values[p], cols[c], decimals: decimals[c], msg: "#{kind} #{id} #{name} period #{p}"
        end
      end
    end
  end

  it 'matches the C API on the series, dates and header of the base model' do
    Dir.mktmpdir do |dir|
      result, oracle = both(SwmmFixtures.base, dir)
      expect(Swmm::OutputReader::FLOW_UNITS.index(result.output.flow_units)).to eq(oracle.flow_units_code), 'swmm_getValue(FLOWUNITS)'
      expect(result.output.periods).to eq(oracle.periods), 'swmm_getValue(TOTALSTEPS)'
      expect(result.times).to eq(oracle.dates.map { SwmmOracle.time_of(it) }), 'swmm_getSavedValue(CURRENTDATE)'
      compared = compare_with_saved(result, oracle)
      expect(compared.slice(:nodes, :links)).to eq({ nodes: 3 * 6 * 12, links: 2 * 4 * 12 }), 'no vacuous pass'
      expect(compared[:subcatchments]).to eq(0)
    end
  end

  it 'matches the C API on the full model with subcatchments, pollutants and groundwater' do
    Dir.mktmpdir do |dir|
      result, oracle = both(SwmmFixtures.full(dir), dir)
      compared = compare_with_saved(result, oracle)
      expect(compared.slice(:subcatchments, :nodes, :links)).to eq(subcatchments: 3 * 4 * 24, nodes: 9 * 6 * 24, links: 10 * 4 * 24)
      expect(result.times).to eq(oracle.dates.map { SwmmOracle.time_of(it) })
    end
  end

  it 'matches the engine report tables on the series' do
    Dir.mktmpdir do |dir|
      result, oracle = both(SwmmFixtures.base, dir)
      nodes = SwmmOracle.tables(oracle.report, 'Node')
      links = SwmmOracle.tables(oracle.report, 'Link')
      expect(nodes.keys).to eq(%w[J1 J2 O1])
      expect(links.keys).to eq(%w[C1 C2])
      check_tables(result, :nodes, nodes, %w[total_inflow overflow depth head])
      check_tables(result, :links, links, %w[flow velocity depth capacity])
    end
  end

  it 'matches the engine report tables on the full model series, quality columns included' do
    Dir.mktmpdir do |dir|
      result, oracle = both(SwmmFixtures.full(dir), dir)
      check_tables(result, :nodes, SwmmOracle.tables(oracle.report, 'Node'), %w[total_inflow overflow depth head quality:TSS quality:COD])
      check_tables(result, :links, SwmmOracle.tables(oracle.report, 'Link'), %w[flow velocity depth capacity quality:TSS quality:COD])
      subs = SwmmOracle.tables(oracle.report, 'Subcatchment')
      expect(subs.keys).to eq(%w[S1 S2 S3])
      # report columns: precip, losses (= evap/24 + infil), runoff, snow depth, gw elevation, gw flow, washoff per pollutant
      names = ['rainfall', :losses, 'runoff', 'snow_depth', 'gw_elevation', 'gw_flow', 'quality:TSS', 'quality:COD']
      decimals = [3, 3, 4, 3, 3, 4, 3, 3]
      subs.each do |id, rows|
        expect(rows.map(&:first)).to eq(result.times), "subcatchment #{id}: dates"
        expect(rows).not_to be_empty
        rows.each_with_index do |(_t, cols), p|
          expect(cols.size).to eq(names.size), "subcatchment #{id} row #{p}"
          names.each_with_index do |name, c|
            mine = name == :losses ? (result.subcatchments[id][:evaporation].values[p] / 24.0) + result.subcatchments[id][:infiltration].values[p] : result.subcatchments[id][name].values[p]
            near mine, cols[c], decimals: decimals[c], msg: "subcatchment #{id} #{name} period #{p}"
          end
        end
      end
    end
  end

  # current behaviour, not a defect: Engine#run stops at swmm_end and never calls swmm_report, so the .rpt of Swmm.run has the
  # summaries but not the "... Time Series Results" tables that `swmm5 model.inp model.rpt` would write for [REPORT] NODES/LINKS.
  it 'writes no time series tables in its report, unlike swmm_run' do
    Dir.mktmpdir do |dir|
      result, oracle = both(SwmmFixtures.base, dir)
      expect(result.report).not_to include('Time Series Results')
      expect(result.report).not_to include('<<< Node')
      expect(oracle.report).to include('Node Time Series Results')
      expect(result.report).to include('Node Depth Summary')
    end
  end

  it 'matches the report continuity to its rounding' do
    Dir.mktmpdir do |dir|
      result = described_class.run(SwmmFixtures.full(dir))
      pct = lambda do |title|
        section = result.report[/#{title}[^\n]*\n.*?Continuity Error \(%\) \.+\s+([^\n]*)\n/m, 1]
        section.split.map(&:to_f)
      end
      near pct.call('Runoff Quantity Continuity').first, result.continuity[:runoff], decimals: 3
      near pct.call('Flow Routing Continuity').first, result.continuity[:flow_routing], decimals: 3
      worst = pct.call('Quality Routing Continuity').max_by(&:abs) # swmm_getMassBalErr gives the largest of the pollutants
      near worst, result.continuity[:quality], decimals: 3
      expect(result.continuity[:quality]).not_to eq(0), 'no vacuous pass'
    end
  end

  # --- times with report_start / report_step ------------------------------------------------------------------------

  def run_with_report_start(start_time, step)
    model = SwmmFixtures.base
    model[:options] = model[:options].merge(report_start_date: '2026-03-24', report_start_time: start_time, report_step: step)
    Dir.mktmpdir do |dir|
      result, oracle = both(model, dir)
      yield result, oracle
    end
  end

  it 'follows report_start and report_step in the times' do
    { ['00:30', '00:10:00'] => ['00:30', 10, 10], ['00:35', '00:10:00'] => ['00:40', 10, 9],
      ['01:00', '00:15:00'] => ['01:00', 15, 5], ['00:00', '00:30:00'] => ['00:30', 30, 4] }.each do |(rs, step), (first, minutes, count)|
      run_with_report_start(rs, step) do |result, oracle|
        label = "report_start #{rs} step #{step}"
        expect(result.times).to eq(oracle.dates.map { SwmmOracle.time_of(it) }), label
        expect(result.output.periods).to eq(count), label
        expect(result.times.first.strftime('%H:%M')).to eq(first), "#{label}: first period is the first step at or after report_start"
        expect(result.times.last).to eq(Time.utc(2026, 3, 24, 2)), label
        expect(result.times.each_cons(2).map { |a, b| b - a }.uniq).to eq([minutes * 60.0]), label
        expect(result.output.report_step.in_seconds).to eq(minutes * 60), label
        stamps = SwmmOracle.tables(oracle.report, 'Node')['J1'].map(&:first)
        expect(stamps).to eq(result.times), "#{label}: dates of the report table"
        # the series of the periods that exist are still the engine's values
        near oracle.saved[:nodes]['J1']['depth'].last, result.nodes['J1'][:depth].values.last, msg: label
      end
    end
  end

  # SURPRISING BUT ACCEPTABLE (engine semantics, kept in the file header): OutputFile#start is not the simulation start nor the
  # report start when report_start is later; the engine stores "one reporting period before the first reported result" computed
  # from a multiple of the step counted from the start. start + report_step is the first time only when report_start is a multiple.
  it 'has a start one period before the first reported time only when report_start is aligned' do
    run_with_report_start('00:30', '00:10:00') do |result, _|
      expect(result.output.start_time).to eq(Time.utc(2026, 3, 24, 0, 20))
      expect(result.times.first).to eq(result.output.start_time + 600)
    end
    run_with_report_start('00:35', '00:10:00') do |result, _|
      expect(result.output.start_time).to eq(Time.utc(2026, 3, 24, 0, 20))
      expect(result.times.first).to eq(Time.utc(2026, 3, 24, 0, 40))
      expect(result.times.first).not_to eq(result.output.start_time + 600), 'start + report_step is NOT the first time here'
    end
    Dir.mktmpdir do |dir|
      expect(described_class.run(SwmmFixtures.base, dir: dir).output.start_time).to eq(Time.utc(2026, 3, 24)), 'no report_start: the simulation start'
    end
  end

  def with_options(**options)
    model = SwmmFixtures.base
    model.merge(options: model[:options].merge(options))
  end

  it 'matches the engine on dates across midnight, year end, leap day and second steps' do
    {
      'year end' => with_options(start_date: '2026-12-31', start_time: '23:30', end_date: '2027-01-01', end_time: '00:30'),
      'leap day' => with_options(start_date: '2028-02-28', start_time: '23:00', end_date: '2028-03-01', end_time: '01:00', report_step: '00:30:00'),
      '30 s step' => with_options(end_time: '00:10', report_step: '00:00:30', routing_step: 5),
      'step longer than the run' => with_options(report_step: '03:00:00') # the engine shortens it to the run (7200 s)
    }.each do |label, model|
      Dir.mktmpdir do |dir|
        result, oracle = both(model, dir)
        expect(result.times).to eq(oracle.dates.map { SwmmOracle.time_of(it) }), label
        expect(result.output.periods).to eq(oracle.periods), label
        expect(SwmmOracle.tables(oracle.report, 'Node')['J1'].map(&:first)).to eq(result.times), "#{label}: report dates"
        expect(result.times.each_cons(2).map { |a, b| b - a }.uniq).to eq([result.output.report_step.to_f]), label if result.times.size > 1
        compare_with_saved(result, oracle)
      end
    end
  end

  # Engine behaviour, reproduced with the stock swmm_run of the same libswmm5 (not a wrapper defect): for about 1 start time in 3
  # the period that falls exactly on the end date is not saved (floating-point date arithmetic in SWMM 5.2.4), so the last time is
  # 10 minutes before the end. Nothing in Result tells the caller. Known engine bug (docs/known-issues.md, #1); the example pins the
  # facts so a change (an engine fix) is noticed.
  it 'can miss the period on the end date because of the engine' do
    short = with_options(start_date: '2022-11-27', start_time: '11:00', end_date: '2022-11-27', end_time: '13:00')
    Dir.mktmpdir do |dir|
      result, oracle = both(short, dir)
      expect(result.output.periods).to eq(11), '12 expected from 11:00 to 13:00 every 10 min'
      expect(result.output.periods).to eq(oracle.periods)
      expect(result.times.last).to eq(Time.utc(2022, 11, 27, 12, 50))
      expect(result.report).to match(%r{Ending Date \.+ 11/27/2022 13:00:00})
    end
    Dir.mktmpdir { |dir| expect(both(SwmmFixtures.base, dir).first.times.last).to eq(Time.utc(2026, 3, 24, 2)), 'midnight start: the last period is there' }
  end

  it 'saves averaged values with the averages option and still matches the C API' do
    Dir.mktmpdir do |dir|
      model = SwmmFixtures.base.merge(report: SwmmFixtures.base[:report].merge(averages: true))
      result, oracle = both(model, dir)
      compare_with_saved(result, oracle)
      check_tables(result, :nodes, SwmmOracle.tables(oracle.report, 'Node'), %w[total_inflow overflow depth head])
    end
  end

  it 'keeps Unicode and punctuated ids through the .out' do
    base = SwmmFixtures.base
    [%w[Nó-é Ç2], %w[J.1 J/2], ['a' * 79, 'b' * 80], %w[日本1 ü2]].each do |a, b|
      model = base.merge(junctions: [{ name: a, elevation: 10, max_depth: 3 }, { name: b, elevation: 9.5, max_depth: 3 }],
                         conduits: base[:conduits].map { it[:name] == 'C1' ? it.merge(from_node: a, to_node: b) : it.merge(from_node: b) },
                         inflows: [{ node: a, series: 'Q' }])
      Dir.mktmpdir do |dir|
        result, oracle = both(model, dir)
        expect(result.nodes.ids).to eq([a, b, 'O1'])
        expect(result.nodes.ids).to eq(SwmmOracle.tables(oracle.report, 'Node').keys)
        compare_with_saved(result, oracle)
        expect(result.nodes.to_csv.lines.count { it.include?(",#{a},") }).to eq(12)
      end
    end
  end

  it 'cleans the continuity like every other float' do
    continuity = run_ok(SwmmFixtures.base).continuity
    continuity.each_value { |v| expect(v).to eq(Swmm::OutputReader.clean(v)) }
  end

  # --- [REPORT] selection rules ---------------------------------------------------------------------------------------

  it 'saves only the listed objects, and the system always' do
    Dir.mktmpdir do |dir|
      model = SwmmFixtures.base.merge(report: { nodes: %w[J2], links: %w[C2] })
      result, oracle = both(model, dir)
      expect(result.nodes.ids).to eq(%w[J2])
      expect(result.links.ids).to eq(%w[C2])
      expect(result.subcatchments.ids).to be_empty
      expect(result.system.ids).to eq(['system'])
      expect(result.system['system'][:outflow].values.size).to eq(12)
      expect(oracle.flagged[:nodes]).to eq(%w[J2]), "the engine's own report flags"
      expect(SwmmOracle.tables(oracle.report, 'Node').keys).to eq(%w[J2])
      expect(SwmmOracle.tables(oracle.report, 'Link').keys).to eq(%w[C2])
      expect { result.nodes['J1'][:depth].values }.to raise_error(Swmm::UnknownObject)
      compare_with_saved(result, oracle)
    end
  end

  it 'gives the saved objects in definition order, not in the order of the list' do
    model = SwmmFixtures.base.merge(report: { nodes: %w[O1 J2 J1], links: %w[C2 C1] })
    result = run_ok(model)
    expect(result.nodes.ids).to eq(%w[J1 J2 O1])
    expect(result.links.ids).to eq(%w[C1 C2])
  end

  it 'saves no objects but keeps the system with NONE and with a missing [REPORT] section' do
    no_section = SwmmFixtures.base
    no_section.delete(:report)
    [no_section, SwmmFixtures.base.merge(report: { nodes: 'NONE', links: 'NONE', subcatchments: 'NONE' })].each do |model|
      result = run_ok(model)
      %i[subcatchments nodes links].each { expect(result[it].ids).to be_empty }
      expect(result.system['system'][:total_inflow].values.size).to eq(12)
      expect(result.system.to_csv.lines.first[0, 23]).to eq('time,id,air_temperature')
      expect(result.nodes.to_csv.lines.size).to eq(1)
      expect(result.output.periods).to eq(12)
    end
  end

  it 'saves only the listed subcatchments' do
    Dir.mktmpdir do |dir|
      model = SwmmFixtures.full(dir)
      model[:report] = model[:report].merge(subcatchments: %w[S3 S1], nodes: %w[J3], links: %w[C5])
      result, oracle = both(model, dir)
      expect(result.subcatchments.ids).to eq(%w[S1 S3])
      expect(result.nodes.ids).to eq(%w[J3])
      expect(result.links.ids).to eq(%w[C5])
      expect(SwmmOracle.tables(oracle.report, 'Subcatchment').keys).to eq(%w[S1 S3])
      compare_with_saved(result, oracle)
    end
  end

  # --- units ---------------------------------------------------------------------------------------------------------

  def expected_units(flow, si)
    {
      subcatchments: si ? ['mm/h', 'mm', 'mm/day', 'mm/h', flow, flow, 'm', 'fraction'] : ['in/h', 'in', 'in/day', 'in/h', flow, flow, 'ft', 'fraction'],
      nodes: si ? ['m', 'm', 'm3', flow, flow, flow] : ['ft', 'ft', 'ft3', flow, flow, flow],
      links: si ? [flow, 'm', 'm/s', 'm3', 'fraction'] : [flow, 'ft', 'ft/s', 'ft3', 'fraction'],
      system: [si ? 'degC' : 'degF', si ? 'mm/h' : 'in/h', si ? 'mm' : 'in', si ? 'mm/h' : 'in/h', *[flow] * 8, si ? 'm3' : 'ft3',
               si ? 'mm/day' : 'in/day', si ? 'mm/day' : 'in/day']
    }
  end

  def model_in(unit)
    m = SwmmFixtures.base
    m[:options] = m[:options].merge(flow_units: unit)
    peak = peaks.fetch(unit)
    m[:timeseries] = [{ name: 'Q', points: [[0, 0], [0.5, peak * 0.625], [1, peak], [2, 0]] }]
    m
  end

  def expect_series_scaled(base, other, k)
    expect(other.links['C2'][:depth].values.size).to eq(base.links['C2'][:depth].values.size)
    base.links['C2'][:depth].values.zip(other.links['C2'][:depth].values).each do |a, b|
      expect(b).to be_within((0.002 * a.abs) + 1e-4).of(a), 'depth does not depend on the flow unit'
    end
    peak = base.links['C2'][:flow].values.max
    expect(other.links['C2'][:flow].values.max).to be_within(peak * k * 0.01).of(peak * k), 'flow scales with the unit'
  end

  it 'reports every flow unit consistently in the pack, the engine and the report' do
    results = {}
    Dir.mktmpdir do |root| # the results read their .out as they are used: the files stay until the end
      peaks.each_key do |unit|
        FileUtils.mkdir_p(File.join(root, unit)).first.then do |dir|
          result, oracle = both(model_in(unit), dir)
          results[unit] = result
          si = %w[LPS CMS MLD].include?(unit)
          expect(result.output.flow_units).to eq(unit)
          expect(Swmm::OutputReader::FLOW_UNITS.fetch(oracle.flow_units_code)).to eq(unit), "engine's own flow unit code"
          expect(result.report).to match(/Flow Units \.+ #{unit}$/)
          expect(oracle.report).to match(/Flow Units \.+ #{unit}$/)
          words = SwmmOracle.header_units(oracle.report, 'Node', 'J1')
          expect(words.map(&:downcase)).to eq([unit.downcase, unit.downcase, si ? 'meters' : 'feet', si ? 'meters' : 'feet']), 'node table header'
          words = SwmmOracle.header_units(oracle.report, 'Link', 'C1')
          expect(words.first(3).map(&:downcase)).to eq([unit.downcase, si ? 'm/sec' : 'ft/sec', si ? 'meters' : 'feet']), 'link table header'
          expected = expected_units(unit, si)
          expected.each do |kind, list|
            expect(result.output[kind].units.values).to eq(list), "#{unit} #{kind} units"
            expect(result.to_h[:output][:units][kind].values).to eq(list)
          end
          near peaks[unit], result.nodes['J1'][:lateral_inflow].values.max, rel: 5e-3, msg: "#{unit}: peak of the hydrograph in the unit"
          compare_with_saved(result, oracle)
        end
      end
      # same network, flows scaled by the unit conversion: depths agree, flows scale (factors: cfs->unit, 1 cfs = 448.831 gpm ...)
      { 'GPM' => 448.831, 'MGD' => 0.646317 }.each do |unit, k|
        expect_series_scaled results['CFS'], results[unit], k
      end
      { 'CMS' => 0.001, 'MLD' => 0.0864 }.each do |unit, k|
        expect_series_scaled results['LPS'], results[unit], k
      end
    end
  end

  def with_pollutant_units(model, units)
    model.merge(pollutants: model[:pollutants].each_with_index.map { |p, i| p.merge(units: units[i]) })
  end

  it 'handles pollutant units in mg, ug and count per litre' do
    Dir.mktmpdir do |dir|
      { %w[MG/L UG/L] => %w[mg/l ug/l], %w[UG/L #/L] => %w[ug/l #/l], %w[#/L MG/L] => %w[#/l mg/l] }.each do |codes, words|
        model = with_pollutant_units(SwmmFixtures.full(dir), codes)
        result, oracle = both(model, dir)
        %i[subcatchments nodes links].each do |kind|
          shown = result.output[kind].units.select { |name, _| name.start_with?('quality:') }
          expect(shown).to eq({ 'quality:TSS': codes[0], 'quality:COD': codes[1] }), "#{kind} #{codes}"
        end
        expect(SwmmOracle.header_units(oracle.report, 'Node', 'J3').last(2).map(&:downcase)).to eq(words), "engine's header #{codes}"
        expect(SwmmOracle.header_units(oracle.report, 'Link', 'C1').last(2).map(&:downcase)).to eq(words)
        compare_with_saved(result, oracle)
      end
    end
  end

  it 'gives the values in the labelled units in the full model' do
    Dir.mktmpdir do |dir|
      result = described_class.run(SwmmFixtures.full(dir))
      expect(result.output.system.unit(:air_temperature)).to eq('degC')
      expect(result.output.system.units[:rainfall]).to eq('mm/h')
      temperature = result.system['system'][:air_temperature].values
      # TEMP goes 5 -> 8 degC over 6 h, [ADJUSTMENTS] adds 1 degC per month: 6 .. 9 (a value in degF would be 40+)
      expect(temperature.first).to be_within(1e-4).of(6.0)
      expect(temperature).to all(be_between(6.0, 9.0))
      expect(temperature).to eq(temperature.sort), 'rising series'
      # RAIN gage in mm/h (INTENSITY): 10, 20, 5, 0 at 00:15, 00:30, 00:45, 01:00 as given, no conversion
      expect(result.system['system'][:rainfall].values.first(4)).to eq([10.0, 20.0, 5.0, 0.0])
    end
  end

  # --- magnitudes ----------------------------------------------------------------------------------------------------

  def scaled_model(factor)
    m = SwmmFixtures.base
    m[:timeseries] = [{ name: 'Q', points: [[0, 0], [0.5, 50 * factor], [1, 80 * factor], [2, 0]] }]
    m
  end

  it 'keeps seven digits of very large and very small magnitudes' do
    Dir.mktmpdir do |dir|
      { 'x1e4 (flooding)' => 1e4, 'x1e-2' => 1e-2 }.each do |label, factor|
        result, oracle = both(scaled_model(factor), FileUtils.mkdir_p(File.join(dir, label.delete(' ()'))).first)
        compare_with_saved(result, oracle)
        peak = result.nodes['J1'][:total_inflow].values.max
        expect(peak).to be_within(80 * factor * 5e-3).of(80 * factor), label
        expect(result.links['C1'][:flow].values).to all(be_a(Float))
        expect(result.links['C1'][:flow].values.grep_v(Float)).to eq([]), label
        # the JSON of any of these numbers is plain JSON that parses back to the same Float
        json = JSON.parse(result.to_json)
        expect(json['output']['links']['C1']['flow']).to eq(result.links['C1'][:flow].values), label
      end
    end
  end

  it 'loses nothing of high elevations beyond seven digits of the float32' do
    Dir.mktmpdir do |dir|
      model = SwmmFixtures.base
      model[:junctions] = [{ name: 'J1', elevation: 4000.25, max_depth: 3 }, { name: 'J2', elevation: 3999.75, max_depth: 3 }]
      model[:outfalls] = [{ name: 'O1', elevation: 3999.5, type: 'FREE' }]
      result, oracle = both(model, dir)
      compare_with_saved(result, oracle)
      heads = result.nodes['J1'][:head].values
      expect(heads).to all(be > 4000.25)
      expect(heads.last).to be_within(4000 * 5e-7).of(oracle.saved[:nodes]['J1']['head'].last), 'head at 4000 m is kept to 5e-7 relative (about 2 mm)'
    end
  end
end
