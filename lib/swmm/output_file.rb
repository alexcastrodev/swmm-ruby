# frozen_string_literal: true

module Swmm
  # Reader for SWMM's binary results file (.out). Layout (engine src/solver/output.c):
  #   header: magic, version, flow units, #subcatchments, #nodes, #links, #pollutants
  #   ids (length-prefixed) of subcatchments, nodes, links, pollutants; pollutant unit codes
  #   input block (areas / node & link properties), variable codes per object kind, start date, report step
  #   one record per period: float64 date + float32 values (subcatchments, nodes, links, then 15 system values)
  #   epilogue: 6 int32 (id pos, input pos, output pos, #periods, error code, magic)
  # Only objects listed in [REPORT] (SUBCATCHMENTS / NODES / LINKS) are saved by the engine.
  class OutputFile
    MAGIC = 516_114_522
    EPOCH = Time.utc(1899, 12, 30) # SWMM dates are days since 1899-12-30
    FLOW_UNITS = %w[CFS GPM MGD CMS LPS MLD].freeze
    POLLUTANT_UNITS = %w[MG/L UG/L #/L].freeze
    KINDS = %i[subcatchments nodes links system].freeze

    # variable name by engine code; codes past the list are pollutants (code - list.size)
    VARIABLES = {
      subcatchments: %w[rainfall snow_depth evaporation infiltration runoff gw_flow gw_elevation soil_moisture],
      nodes: %w[depth head volume lateral_inflow total_inflow overflow],
      links: %w[flow depth velocity volume capacity],
      system: %w[air_temperature rainfall snow_depth infiltration runoff dry_weather_inflow groundwater_inflow
                 rdii_inflow direct_inflow total_inflow flooding outflow storage evaporation potential_et]
    }.freeze

    # unit key per variable; resolved by #units
    UNIT_KEYS = {
      subcatchments: %w[rain depth evap rain flow flow length fraction],
      nodes: %w[length length volume flow flow flow],
      links: %w[flow length velocity volume fraction],
      system: %w[temp rain depth rain flow flow flow flow flow flow flow flow volume evap evap]
    }.freeze

    class << self
      # all_series reads in Ractors when a kind has at least parallel_from values (below it the whole read takes
      # milliseconds) and ractors > 1. 12M values: 4.8 s -> 1.7 s with 4 Ractors, 1.4 s with 6; flat past that (Mac and Linux).
      attr_accessor :ractors, :parallel_from

      # +width+ consecutive float32 of every period record (+stride+ bytes apart, the first at +offset+), as one cleaned
      # column per float. Pure and free of constants on purpose: it also runs inside Ractors.
      def read_columns(bytes, offset, stride, periods, width)
        Array.new(periods) { |p| bytes.unpack("e#{width}", offset: offset + (p * stride)) }.transpose.each { |col| col.map! { clean(_1) } }
      end

      # float32 -> readable Float (0.1f0 reads back as 0.10000000149; keep the 7 digits that mean something)
      def clean(x) = x.finite? ? format("%.7g", x).to_f : nil
    end
    self.ractors = [Etc.nprocessors, 6].min
    self.parallel_from = 250_000

    attr_reader :flow_units, :periods, :report_step, :start, :ids, :variables, :pollutants

    # ponytail: the whole .out stays in memory (fine up to a few hundred MB); switch to IO seeks beyond that.
    # Values are read little-endian, as the engine writes them on x86/arm64.
    def initialize(bytes)
      @bytes = bytes.b
      parse
    end

    def times
      @times ||= Array.new(@periods) { |p| EPOCH + (@bytes.unpack1("E", offset: period_offset(p)) * 86_400).round }
    end

    # Values of one variable for one object, one per period (aligned with #times).
    def series(kind, id, variable)
      kind = kind.to_sym
      index = kind == :system ? 0 : @ids.fetch(kind).index(id.to_s) || raise(KeyError, "#{kind} has no #{id.inspect}")
      var = @variables.fetch(kind).index(variable.to_s) || raise(KeyError, "#{kind} has no variable #{variable.inspect}")
      base = @base.fetch(kind) + (index * @variables.fetch(kind).size) + var
      Array.new(@periods) { |p| self.class.clean(@bytes.unpack1("e", offset: period_offset(p) + 8 + (4 * base))) }
    end

    # { id => { variable => [values per period] } } for every object of a kind, read in one pass: one unpack per
    # period instead of one per value, which is what makes dumping a whole week (to_h, to_csv) affordable.
    def all_series(kind)
      kind = kind.to_sym
      names = @variables.fetch(kind)
      ids = kind == :system ? ["system"] : @ids.fetch(kind)
      columns = columns_of(kind, ids.size, names.size)
      ids.each_with_index.to_h do |id, i|
        [id, names.each_with_index.to_h { |name, v| [name, columns[(i * names.size) + v] || []] }]
      end
    end

    # { "depth" => "m", ... } per kind
    def units
      si = %w[CMS LPS MLD].include?(@flow_units)
      table = { "flow" => @flow_units, "length" => si ? "m" : "ft", "depth" => si ? "mm" : "in",
                "rain" => si ? "mm/h" : "in/h", "evap" => si ? "mm/day" : "in/day", "volume" => si ? "m3" : "ft3",
                "velocity" => si ? "m/s" : "ft/s", "temp" => si ? "degC" : "degF", "fraction" => "fraction" }
      KINDS.to_h do |kind|
        names = @variables[kind]
        [kind, names.each_with_index.to_h { |n, i| [n, table[UNIT_KEYS[kind][i]] || @pollutant_units[n.split(":", 2).last] || ""] }]
      end
    end

    private

    def parse
      b = @bytes
      raise OutputFormatError, "output file is truncated" if b.bytesize < 28 + 24

      magic, @version, units, *counts = b.unpack("l<7")
      id_pos, input_pos, @output_pos, @periods, @engine_error, magic_end = b.byteslice(-24, 24).unpack("l<6")
      raise OutputFormatError, "not a SWMM output file (bad magic number)" unless magic == MAGIC && magic_end == MAGIC

      @flow_units = FLOW_UNITS.fetch(units) { raise OutputFormatError, "unknown flow units code #{units}" }
      n_sub, n_node, n_link, n_pol = counts
      @cursor = 28
      raise OutputFormatError, "unexpected id block position" unless @cursor == id_pos

      @ids = { subcatchments: read_ids(n_sub), nodes: read_ids(n_node), links: read_ids(n_link) }
      @pollutants = read_ids(n_pol)
      @pollutant_units = @pollutants.zip(read_ints(n_pol).map { POLLUTANT_UNITS[_1] }).to_h
      raise OutputFormatError, "unexpected input block position" unless @cursor == input_pos

      # input block: #properties, their codes, then per-object values (4 bytes each, +4 for nodes/links type code)
      @cursor += 8 + (4 * n_sub)
      @cursor += 4 + (4 * 3) + (12 * n_node)
      @cursor += 4 + (4 * 5) + (20 * n_link)
      @variables = KINDS.to_h { |kind| [kind, variable_names(kind, read_ints(read_ints(1).first))] }
      @start = EPOCH + (b.unpack1("E", offset: @cursor) * 86_400).round
      @report_step = b.unpack1("l<", offset: @cursor + 8)
      @cursor += 12
      layout_check(n_sub, n_node, n_link)
    end

    def layout_check(n_sub, n_node, n_link)
      counts = { subcatchments: n_sub, nodes: n_node, links: n_link, system: 1 }
      floats = 0
      @base = KINDS.to_h do |kind|
        base = floats
        floats += counts[kind] * @variables[kind].size
        [kind, base]
      end
      @period_bytes = 8 + (4 * floats)
      return if @cursor == @output_pos && @output_pos + (@periods * @period_bytes) + 24 == @bytes.bytesize

      raise OutputFormatError, "unsupported output layout (engine version #{@version}): size does not match the header"
    end

    def variable_names(kind, codes)
      fixed = VARIABLES[kind]
      codes.map { |c| c < fixed.size ? fixed[c] : "quality:#{@pollutants.fetch(c - fixed.size)}" }
    end

    def read_ints(n)
      values = @bytes.unpack("l<#{n}", offset: @cursor)
      @cursor += 4 * n
      values
    end

    def read_ids(n)
      Array.new(n) do
        len = read_ints(1).first
        name = @bytes.byteslice(@cursor, len).force_encoding(Encoding::UTF_8).scrub
        @cursor += len
        name
      end
    end

    def period_offset(period) = @output_pos + (period * @period_bytes)

    # One cleaned column per (object, variable), object-major. Big outputs are split by object across Ractors, all
    # reading the same frozen bytes; the columns come back frozen (no copy) and are dup'ed so callers get plain arrays.
    def columns_of(kind, count, nvars)
      offset = @output_pos + 8 + (4 * @base.fetch(kind)) # the period's date, then the kinds stored before this one
      workers = [self.class.ractors, count].min
      return self.class.read_columns(@bytes, offset, @period_bytes, @periods, count * nvars) if workers <= 1 || count * nvars * @periods < self.class.parallel_from

      Ractor.make_shareable(@bytes) # frozen: never modified anyway
      per = (count / workers.to_f).ceil
      ractors = without_experimental_warning do
        (0...count).step(per).map do |first|
          Ractor.new(@bytes, offset + (4 * first * nvars), @period_bytes, @periods, [per, count - first].min * nvars) do |*args|
            Ractor.make_shareable(OutputFile.read_columns(*args))
          end
        end
      end
      ractors.flat_map(&:value).map(&:dup)
    end

    # Ruby 4.0 still prints "Ractor API is experimental" on the first Ractor; a library should not write that to the user's stderr.
    def without_experimental_warning
      was = Warning[:experimental]
      Warning[:experimental] = false
      yield
    ensure
      Warning[:experimental] = was
    end
  end
end
