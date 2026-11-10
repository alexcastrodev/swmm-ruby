require 'ffi'
require 'fileutils'

# FRONT C: fidelity of the numbers against oracles that live OUTSIDE this pack's reader (docs/test-plan.md, R3 and R6).
#
#   1. EPA's own test file tests/outfile/Example1.out and the numbers hard-coded in EPA's tests/outfile/test_output.cpp
#      (SWMM 5.1.0 output format, version code 51000), plus numbers computed once with EPA's libswmm-output
#      (src/outfile of the same SWMM 5.2.4 tag, compiled by hand) over the same file.
#   2. The engine's own report: swmm_report() writes "<<< Node X >>>" tables read straight from the .out by C code.
#   3. The engine C API: swmm_getSavedValue / swmm_getValue on the same run.
#
# Oracles 2 and 3 use a PRIVATE copy of libswmm5 (like Engine.pool), so they never touch the state of Swmm.run.
module SwmmOracle
  KINDS = %i[subcatchments nodes links].freeze
  OBJECT = { subcatchments: 1, nodes: 2, links: 3 }.freeze # swmm_Object
  RPTFLAG = { subcatchments: 206, nodes: 309, links: 414 }.freeze # swmm_*_RPTFLAG
  # variable of the .out => swmm_getSavedValue property code (swmm5.h); swmm_LINK_SETTING returns the capacity column
  PROPS = {
    subcatchments: { 'rainfall' => 202, 'evaporation' => 203, 'infiltration' => 204, 'runoff' => 205 },
    nodes: { 'depth' => 303, 'head' => 304, 'volume' => 305, 'lateral_inflow' => 306, 'total_inflow' => 307, 'overflow' => 308 },
    links: { 'flow' => 410, 'depth' => 411, 'velocity' => 412, 'capacity' => 407 }
  }.freeze
  Run = Struct.new(:flow_units_code, :periods, :dates, :saved, :flagged, :report, :out_path)

  class << self
    def lib
      @lib ||= begin
        paths = Swmm::Engine.library_candidates
        if (source = paths.find { File.file?(it) })
          dir = Dir.mktmpdir('swmm-oracle')
          at_exit { FileUtils.rm_rf(dir) }
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
      rpt = File.join(dir, 'oracle.rpt')
      out = File.join(dir, 'oracle.out')
      engine = lib
      check engine.swmm_open(inp, rpt, out), 'swmm_open'
      begin
        run = Run.new(engine.swmm_getValue(8, 0).to_i) # swmm_FLOWUNITS
        check engine.swmm_start(1), 'swmm_start'
        elapsed = FFI::MemoryPointer.new(:double)
        loop do
          check engine.swmm_step(elapsed), 'swmm_step'
          break if elapsed.read_double <= 0
        end
        check engine.swmm_end, 'swmm_end'
        run.periods = engine.swmm_getValue(6, 0).to_i # swmm_TOTALSTEPS: number of reporting periods saved
        run.dates = (1..run.periods).map { engine.swmm_getSavedValue(1, 0, it) } # swmm_CURRENTDATE, days since 1899-12-30
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
              PROPS[kind].to_h { |var, prop| [var, (1..run.periods).map { engine.swmm_getSavedValue(prop, i, it) }] }
          end
        end
        check engine.swmm_report, 'swmm_report'
      ensure
        engine.swmm_close
      end
      run.report = File.binread(rpt).force_encoding(Encoding::UTF_8).scrub
      run.out_path = out
      run
    end

    def check(code, what) = (raise "#{what} failed with code #{code}" unless code.zero?)

    def time_of(days) = Swmm::OutputReader::EPOCH + (days * 86_400).round

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

# R6: golden contract of Result#to_h / #to_json.
module SwmmGolden
  Near = Struct.new(:value, :delta)

  NODE_VARS = %i[depth head volume lateral_inflow total_inflow overflow].freeze
  LINK_VARS = %i[flow depth velocity volume capacity].freeze
  SYSTEM_VARS = %i[air_temperature rainfall snow_depth infiltration runoff dry_weather_inflow groundwater_inflow rdii_inflow
                   direct_inflow total_inflow flooding outflow storage evaporation potential_et].freeze

  module_function

  # Differences between a golden structure and actual data, as readable lines. A Class in the golden means "any instance of it",
  # a Near means "a Float within delta" (engine numerics), everything else must be equal. Key ORDER matters (it is the contract's order).
  def diff(golden, actual, path = 'result', out = [])
    case golden
    when Hash
      return out << "#{path}: was a Hash, now #{actual.class}" unless actual.is_a?(Hash)

      (golden.keys - actual.keys).each { out << "#{path}: key #{it.inspect} REMOVED" }
      (actual.keys - golden.keys).each { out << "#{path}: key #{it.inspect} ADDED (value #{actual[it].inspect[0, 60]})" }
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

  def vars(names, value) = names.to_h { [it, value] }

  # Result#to_h of SwmmFixtures.base
  def golden(series:)
    value = series ? Array.new(12, Float) : nil
    {
      status: 'ok', swmm_version: '5.2.4', error: nil, warnings: [],
      continuity: { runoff: 0.0, flow_routing: Near.new(-0.144, 0.005), quality: 0.0 },
      flow_instability: {}, files: nil,
      output: {
        flow_units: 'LPS', start: '2026-03-24T00:00:00', report_step: 600, periods: 12,
        times: %w[00:10 00:20 00:30 00:40 00:50 01:00 01:10 01:20 01:30 01:40 01:50 02:00].map { "2026-03-24T#{it}:00" },
        units: {
          subcatchments: { rainfall: 'mm/h', snow_depth: 'mm', evaporation: 'mm/day', infiltration: 'mm/h',
                           runoff: 'LPS', gw_flow: 'LPS', gw_elevation: 'm', soil_moisture: 'fraction' },
          nodes: { depth: 'm', head: 'm', volume: 'm3', lateral_inflow: 'LPS', total_inflow: 'LPS', overflow: 'LPS' },
          links: { flow: 'LPS', depth: 'm', velocity: 'm/s', volume: 'm3', capacity: 'fraction' },
          system: { air_temperature: 'degC', rainfall: 'mm/h', snow_depth: 'mm', infiltration: 'mm/h',
                    runoff: 'LPS', dry_weather_inflow: 'LPS', groundwater_inflow: 'LPS', rdii_inflow: 'LPS',
                    direct_inflow: 'LPS', total_inflow: 'LPS', flooding: 'LPS', outflow: 'LPS',
                    storage: 'm3', evaporation: 'mm/day', potential_et: 'mm/day' }
        },
        subcatchments: {},
        nodes: %w[J1 J2 O1].to_h { [it, vars(NODE_VARS, value)] },
        links: %w[C1 C2].to_h { [it, vars(LINK_VARS, value)] },
        system: { 'system' => vars(SYSTEM_VARS, value) }
      }
    }
  end
end
