# frozen_string_literal: true

module Swmm
  # Reader for SWMM's binary results file (.out). Layout (engine src/solver/output.c):
  #   header: magic, version, flow units, #subcatchments, #nodes, #links, #pollutants
  #   ids (length-prefixed) of subcatchments, nodes, links, pollutants; pollutant unit codes
  #   input block (areas / node & link properties), variable codes per object kind, start date, report step
  #   one record per period: float64 date + float32 values (subcatchments, nodes, links, then 15 system values)
  #   epilogue: 6 int32 (id pos, input pos, output pos, #periods, error code, magic)
  # Only objects listed in [REPORT] (SUBCATCHMENTS / NODES / LINKS) are saved by the engine.
  #
  # Two ways to read one: OutputFile.read(path) keeps only the header in memory (ids, types, units: a few KB) and reads
  # the values from the file when asked, chunk_bytes at a time, so a 116 MB .out costs a few MB; the file must stay
  # where it is while the reader is used. OutputFile.new(bytes) reads a .out already in memory (a String).
  # What a call returns is in memory either way: all_series of a big kind is big; each_period and to_csv(io) stream.
  class OutputFile
    MAGIC = 516_114_522
    EPOCH = Time.utc(1899, 12, 30) # SWMM dates are days since 1899-12-30
    FLOW_UNITS = %w[CFS GPM MGD CMS LPS MLD].freeze
    POLLUTANT_UNITS = %w[MG/L UG/L #/L].freeze
    KINDS = %i[subcatchments nodes links system].freeze
    # type of a node / link by the code the input block saves for it (engine enums NodeType / LinkType)
    TYPES = {
      nodes: %w[JUNCTION OUTFALL STORAGE DIVIDER],
      links: %w[CONDUIT PUMP ORIFICE WEIR OUTLET]
    }.freeze

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
      # bytes of period records read from a file at a time (OutputFile.read): the memory a streaming read needs
      attr_accessor :chunk_bytes

      # Yields (bytes, first, n) for the period records first...first + n of +periods+ (a Range) in a file, each span
      # starting +offset+ bytes into the first record and ending +length+ bytes into the last, about +chunk+ bytes at a
      # time. Pure and constant-free, like read_columns: it also runs inside Ractors.
      def each_span(path, offset, stride, periods, length, chunk)
        per = [chunk / stride, 1].max
        File.open(path, "rb") do |file|
          periods.step(per) do |first|
            n = [per, periods.end - first].min
            size = ((n - 1) * stride) + length
            bytes = begin
              file.pread(size, offset + (first * stride))
            rescue EOFError # pread at or past the end
              nil
            end
            raise OutputFormatError, "output file changed or was truncated while reading it" unless bytes&.bytesize == size

            yield bytes, first, n
          end
        end
      end

      # read_columns of a file, a span at a time
      def read_columns_from(path, offset, stride, periods, width, chunk)
        columns = Array.new(width) { [] }
        each_span(path, offset, stride, 0...periods, 4 * width, chunk) do |bytes, _first, n|
          read_columns(bytes, 0, stride, n, width).each_with_index { |column, i| columns[i].concat(column) }
        end
        columns
      end

      # csv_rows of a file, a span at a time: yields each span's rows when given a block, else returns them joined
      def csv_rows_from(path, offset, stride, periods, nvars, ids, stamps, chunk)
        return enum_for(:csv_rows_from, path, offset, stride, periods, nvars, ids, stamps, chunk).to_a.join unless block_given?

        each_span(path, offset, stride, periods, 4 * ids.size * nvars, chunk) do |bytes, first, n|
          yield csv_rows(bytes, 0, stride, 0...n, nvars, ids, stamps[first, n])
        end
      end

      # +width+ consecutive float32 of every period record (+stride+ bytes apart, the first at +offset+), as one cleaned
      # column per float. Pure and free of constants on purpose: it also runs inside Ractors.
      def read_columns(bytes, offset, stride, periods, width)
        Array.new(periods) { |p| bytes.unpack("e#{width}", offset: offset + (p * stride)) }.transpose.each { |col| col.map! { clean(_1) } }
      end

      # CSV rows "stamp,id,v1,..,vn\n" of the +periods+ range (time-major, then object). A period record already holds a kind
      # object-major, variable-minor, which is row order: no transpose. Pure and constant-free, like read_columns.
      def csv_rows(bytes, offset, stride, periods, nvars, ids, stamps)
        periods.map do |p|
          rows = bytes.unpack("e#{ids.size * nvars}", offset: offset + (p * stride)).map! { clean(_1) }.each_slice(nvars)
          ids.zip(rows).map { |id, vals| "#{stamps[p]},#{id},#{vals.join(",")}\n" }.join
        end.join
      end

      # float32 -> readable Float (0.1f0 reads back as 0.10000000149; keep the 7 digits that mean something)
      def clean(x) = x.finite? ? format("%.7g", x).to_f : nil

      # +kind+ (Symbol or String) as one of KINDS; anything else (nil included) is an UnknownObject
      def kind!(kind)
        sym = kind.to_sym if kind.is_a?(Symbol) || kind.is_a?(String)
        KINDS.include?(sym) ? sym : raise(UnknownObject, "unknown kind #{kind.inspect} (#{KINDS.join(", ")})")
      end

      # Ruby 4.0 still prints "Ractor API is experimental" on the first Ractor; a library should not write that to the user's
      # stderr. The flag is process-wide, so overlapping calls (threads) share one save/restore: the first in saves it, the
      # last out puts it back.
      def without_experimental_warning
        @quiet.synchronize do
          @quiet_depth += 1
          @quiet_was = Warning[:experimental] if @quiet_depth == 1
          Warning[:experimental] = false
        end
        begin
          yield
        ensure
          @quiet.synchronize do
            @quiet_depth -= 1
            Warning[:experimental] = @quiet_was if @quiet_depth.zero?
          end
        end
      end
    end
    @quiet = Mutex.new
    @quiet_depth = 0
    self.ractors = [Etc.nprocessors, 6].min
    self.parallel_from = 250_000
    self.chunk_bytes = 8 * 1024 * 1024

    attr_reader :flow_units, :periods, :report_step, :start, :ids, :variables, :pollutants

    # error code the engine stored in the file's epilogue (0 = the run finished)
    attr_reader :engine_error

    # "5.2.4": the engine version that wrote the file
    def engine_version = Swmm.format_version(@version)

    # The .out at +path+, read from the file as it is used (only the header stays in memory); the file must stay there
    # while the reader is used. Raises OutputFormatError for a file SWMM did not write (or a truncated one).
    def self.read(path) = new(path: path)

    # +bytes+: a whole .out in memory (a String); or path: to read the file as it is used (OutputFile.read).
    # Values are read little-endian, as the engine writes them on x86/arm64.
    def initialize(bytes = nil, path: nil)
      if path
        @path = File.expand_path(path).freeze
        @size = File.size(@path)
        @bytes = head_of_file
      else
        @bytes = (String.try_convert(bytes) or raise TypeError, "the .out contents must be a String, got #{bytes.class}").b
        @size = @bytes.bytesize
      end
      parse
    end

    # the file it reads, nil for one in memory
    attr_reader :path

    # { id => "JUNCTION" | "OUTFALL" | "STORAGE" | "DIVIDER" } (nodes) or { id => "CONDUIT" | "PUMP" | "ORIFICE" | "WEIR" |
    # "OUTLET" } (links), as the input block of the file saves them; UnknownObject for another kind. Totals per type:
    # out.types(:nodes).values.tally
    def types(kind)
      kind = self.class.kind!(kind)
      names = TYPES[kind] or raise UnknownObject, "#{kind} have no type"
      @types[kind] ||= begin
        first, stride = @type_at.fetch(kind)
        @ids.fetch(kind).each_with_index.to_h do |id, i|
          code = @bytes.unpack1("l<", offset: first + (i * stride))
          [id, (code >= 0 && names[code]) || raise(OutputFormatError, "output file is corrupted: unknown #{kind} type code #{code}")]
        end.freeze
      end
    end

    # How many objects the file saved, per kind: { subcatchments: 0, nodes: 609, links: 608, pollutants: 0 }
    def counts = { **@ids.transform_values(&:size), pollutants: @pollutants.size }

    # How many nodes of each type: { "JUNCTION" => 605, "OUTFALL" => 1, "STORAGE" => 3 } (in the order of TYPES, without
    # the types the file has none of)
    def count_nodes = count_by_type(:nodes)

    # How many links of each type: { "CONDUIT" => 607, "PUMP" => 1 }
    def count_links = count_by_type(:links)

    # How many nodes / links of one type (0 when the file has none)
    def count_nodes_junction = count_nodes.fetch("JUNCTION", 0)
    def count_nodes_outfall = count_nodes.fetch("OUTFALL", 0)
    def count_nodes_storage = count_nodes.fetch("STORAGE", 0)
    def count_nodes_divider = count_nodes.fetch("DIVIDER", 0)
    def count_links_conduit = count_links.fetch("CONDUIT", 0)
    def count_links_pump = count_links.fetch("PUMP", 0)
    def count_links_orifice = count_links.fetch("ORIFICE", 0)
    def count_links_weir = count_links.fetch("WEIR", 0)
    def count_links_outlet = count_links.fetch("OUTLET", 0)

    # How many objects the file saved, as a number (as Swmm::Model#total_*)
    def total_nodes = @ids[:nodes].size
    def total_links = @ids[:links].size
    def total_subcatchments = @ids[:subcatchments].size
    def total_pollutants = @pollutants.size

    # the time of each period (read once, when the reader is built: a date that is not one is an OutputFormatError there)
    attr_reader :times

    # Values of one variable for one object, one per period (aligned with #times). UnknownObject for a kind, id or
    # variable the file does not have.
    def series(kind, id, variable)
      kind = self.class.kind!(kind)
      index = kind == :system ? 0 : @ids.fetch(kind).index(id.to_s) || raise(UnknownObject, "#{kind} has no #{id.inspect}")
      var = @variables.fetch(kind).index(variable.to_s) || raise(UnknownObject, "#{kind} has no variable #{variable.inspect}")
      base = @base.fetch(kind) + (index * @variables.fetch(kind).size) + var
      at = ->(p) { period_offset(p) + 8 + (4 * base) }
      file_there!
      return Array.new(@periods) { |p| self.class.clean(@bytes.unpack1("e", offset: at.call(p))) } unless @path

      File.open(@path, "rb") { |file| Array.new(@periods) { |p| self.class.clean(pread!(file, 4, at.call(p)).unpack1("e")) } }
    end

    # Each period of a kind, one at a time and without holding the others: yields (time, { id => { variable => value } });
    # an Enumerator without a block. The memory-light way through every value of a big file.
    def each_period(kind)
      kind = self.class.kind!(kind)
      return enum_for(:each_period, kind) unless block_given?

      file_there!

      names = @variables.fetch(kind)
      ids = kind == :system ? ["system"] : @ids.fetch(kind)
      width = ids.size * names.size
      each_record_span(@output_pos + 8 + (4 * @base.fetch(kind)), 4 * width) do |bytes, first, n|
        n.times do |i|
          values = bytes.unpack("e#{width}", offset: i * @period_bytes).map! { self.class.clean(it) }
          yield @times[first + i], ids.each_with_index.to_h { |id, o| [id, names.each_with_index.to_h { |name, v| [name, values[(o * names.size) + v]] }] }
        end
      end
    end

    # { id => { variable => [values per period] } } for every object of a kind, read in one pass: one unpack per
    # period instead of one per value, which is what makes dumping a whole week (to_h, to_csv) affordable.
    def all_series(kind)
      kind = self.class.kind!(kind)
      names = @variables.fetch(kind)
      ids = kind == :system ? ["system"] : @ids.fetch(kind)
      file_there!
      columns = columns_of(kind, ids.size, names.size)
      ids.each_with_index.to_h do |id, i|
        [id, names.each_with_index.to_h { |name, v| [name, columns[(i * names.size) + v] || []] }]
      end
    end

    # Rows of Result#to_csv: +ids+ are the (already quoted) id fields of the kind, +stamps+ one String per period.
    # Given an +io+, the rows are written to it a span of periods at a time (never all in memory) and the io comes back.
    # Else big outputs are split by period across Ractors, all reading the same frozen bytes (or the same file).
    def csv_rows(kind, ids, stamps, io = nil)
      file_there!
      nvars = @variables.fetch(kind).size
      offset = @output_pos + 8 + (4 * @base.fetch(kind))
      if io
        each_record_span(offset, 4 * ids.size * nvars) do |bytes, first, n|
          io.write(self.class.csv_rows(bytes, 0, @period_bytes, 0...n, nvars, ids, stamps[first, n]))
        end
        return io
      end

      source = @path || @bytes
      read = ->(range) { @path ? self.class.csv_rows_from(@path, offset, @period_bytes, range, nvars, ids, stamps, self.class.chunk_bytes) : self.class.csv_rows(@bytes, offset, @period_bytes, range, nvars, ids, stamps) }
      workers = self.class.ractors
      return read.call(0...@periods) if workers <= 1 || ids.size * nvars * @periods < self.class.parallel_from

      Ractor.make_shareable(source)
      per = (@periods / workers.to_f).ceil
      chunk = self.class.chunk_bytes
      ractors = without_experimental_warning do
        (0...@periods).step(per).map do |first|
          range = first...[first + per, @periods].min
          if @path
            Ractor.new(source, offset, @period_bytes, range, nvars, ids, stamps, chunk) { |*args| OutputFile.csv_rows_from(*args) }
          else
            Ractor.new(source, offset, @period_bytes, range, nvars, ids, stamps) { |*args| OutputFile.csv_rows(*args) }
          end
        end
      end
      ractors.map(&:value).join
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

    def count_by_type(kind)
      tally = types(kind).values.tally
      TYPES.fetch(kind).filter_map { [it, tally[it]] if tally[it] }.to_h
    end

    # The bytes before the period records (header, ids, input block), where the epilogue says they end: all parse reads.
    # When the epilogue is not one, the first bytes, for parse to say what is wrong.
    def head_of_file
      return File.binread(@path) if @size < 28 + 24

      File.open(@path, "rb") do |file|
        @epilogue = pread!(file, 24, @size - 24)
        output_pos = @epilogue.unpack("l<6")[2]
        file.pread(output_pos.between?(28, @size - 24) ? output_pos : [@size - 24, 4096].min, 0) || "".b
      end
    end

    # a reader of a file needs it where it was (a temp dir may be gone): a clear error instead of Errno::ENOENT
    def file_there!
      return if @path.nil? || File.exist?(@path)

      raise Error, "the .out is gone (#{@path}): OutputFile.read reads it as it is used; keep the file, or read it with OutputFile.new(File.binread(path))"
    end

    def pread!(file, length, offset)
      bytes = begin
        file.pread(length, offset)
      rescue EOFError # pread at or past the end
        nil
      end
      bytes&.bytesize == length ? bytes : raise(OutputFormatError, "output file changed or was truncated while reading it")
    end

    # Yields (bytes, first period, n) for every period record, each span from +offset+ into the first record to +length+
    # bytes into the last: from the file chunk_bytes at a time, or slices of the bytes in memory.
    def each_record_span(offset, length, &)
      return if @periods.zero?
      return self.class.each_span(@path, offset, @period_bytes, 0...@periods, length, self.class.chunk_bytes, &) if @path

      per = [self.class.chunk_bytes / @period_bytes, 1].max
      (0...@periods).step(per) do |first|
        n = [per, @periods - first].min
        yield @bytes.byteslice(offset + (first * @period_bytes), ((n - 1) * @period_bytes) + length), first, n
      end
    end

    def parse
      b = @bytes
      raise OutputFormatError, "output file is truncated" if @size < 28 + 24

      magic, @version, units, *counts = b.unpack("l<7")
      id_pos, input_pos, @output_pos, @periods, @engine_error, magic_end = (@epilogue || b.byteslice(-24, 24)).unpack("l<6")
      raise OutputFormatError, "not a SWMM output file (bad magic number)" unless magic == MAGIC && magic_end == MAGIC

      @flow_units = unit_name(FLOW_UNITS, units, "flow")
      n_sub, n_node, n_link, n_pol = counts
      @cursor = 28
      raise OutputFormatError, "unexpected id block position" unless @cursor == id_pos

      @ids = { subcatchments: read_ids(n_sub), nodes: read_ids(n_node), links: read_ids(n_link) }
      @pollutants = read_ids(n_pol)
      @pollutant_units = @pollutants.zip(ints(n_pol).map { unit_name(POLLUTANT_UNITS, _1, "pollutant") }).to_h
      raise OutputFormatError, "unexpected input block position" unless @cursor == input_pos

      # input block: #properties, their codes, then per-object values (4 bytes each); a node saves its type code, invert
      # and max depth (12 bytes), a link its type code, offsets, max depth and length (20 bytes): read by #types
      @cursor += 8 + (4 * n_sub)
      @type_at = { nodes: [@cursor + 4 + (4 * 3), 12] }
      @cursor += 4 + (4 * 3) + (12 * n_node)
      @type_at[:links] = [@cursor + 4 + (4 * 5), 20]
      @cursor += 4 + (4 * 5) + (20 * n_link)
      @types = {}
      @variables = KINDS.to_h { |kind| [kind, variable_names(kind, ints(ints(1).first))] }
      raise OutputFormatError, "output file is truncated" if @cursor + 12 > b.bytesize

      @start = date_at(@cursor)
      @report_step = TimeStep.new(b.unpack1("l<", offset: @cursor + 8))
      @cursor += 12
      layout_check(n_sub, n_node, n_link)
      # every date at construction (one 8-byte read each from a file), so #times never meets a NaN
      @times = read_times.freeze
    end

    def read_times
      return Array.new(@periods) { |p| date_at(period_offset(p)) } unless @path

      File.open(@path, "rb") { |file| Array.new(@periods) { |p| date_at(0, pread!(file, 8, period_offset(p))) } }
    end

    # a negative code would index the table from its end, a too-large one would give nil: both are a corrupted file
    def unit_name(table, code, what) = (code >= 0 && table[code]) || raise(OutputFormatError, "output file is corrupted: unknown #{what} units code #{code}")

    # a SWMM date (float64 days) as a Time; NaN / Infinity cannot be one
    def date_at(offset, bytes = @bytes)
      seconds = bytes.unpack1("E", offset: offset) * 86_400
      raise OutputFormatError, "output file is corrupted: date #{seconds / 86_400} is not finite" unless seconds.finite?

      EPOCH + seconds.round
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
      return if @cursor == @output_pos && @output_pos + (@periods * @period_bytes) + 24 == @size

      raise OutputFormatError, "unsupported output layout (engine version #{@version}): size does not match the header"
    end

    def variable_names(kind, codes)
      fixed = VARIABLES[kind]
      raise OutputFormatError, "output file is corrupted: invalid #{kind} variable codes #{codes.first(5)}" unless codes.uniq == codes && codes.all? { _1.between?(0, fixed.size + @pollutants.size - 1) }

      codes.map { |c| c < fixed.size ? fixed[c] : "quality:#{@pollutants[c - fixed.size]}" }
    end

    # Counts and lengths come from the file: check them against the bytes left BEFORE allocating (a 2**31-1 count
    # would make unpack build billions of nils). Every int32 read goes through here.
    def ints(n)
      fits!(n)
      read_ints(n)
    end

    def fits!(n) = n.between?(0, (@bytes.bytesize - @cursor) / 4) || raise(OutputFormatError, "output file is corrupted: #{n} values do not fit in the file")

    def read_ints(n)
      values = @bytes.unpack("l<#{n}", offset: @cursor)
      @cursor += 4 * n
      values
    end

    def read_ids(n)
      fits!(n) # each id takes at least its 4-byte length
      Array.new(n) do
        len = ints(1).first
        raise OutputFormatError, "output file is corrupted: id of #{len} bytes does not fit in the file" unless len.between?(0, @bytes.bytesize - @cursor)

        name = @bytes.byteslice(@cursor, len).force_encoding(Encoding::UTF_8).scrub
        @cursor += len
        name
      end
    end

    def period_offset(period) = @output_pos + (period * @period_bytes)

    # One cleaned column per (object, variable), object-major. Big outputs are split by object across Ractors, all
    # reading the same frozen bytes (or the same file, each its own spans); the columns come back frozen (no copy) and
    # are dup'ed so callers get plain arrays.
    def columns_of(kind, count, nvars)
      offset = @output_pos + 8 + (4 * @base.fetch(kind)) # the period's date, then the kinds stored before this one
      chunk = self.class.chunk_bytes
      read = ->(width) { @path ? self.class.read_columns_from(@path, offset, @period_bytes, @periods, width, chunk) : self.class.read_columns(@bytes, offset, @period_bytes, @periods, width) }
      workers = [self.class.ractors, count].min
      return read.call(count * nvars) if workers <= 1 || count * nvars * @periods < self.class.parallel_from

      source = Ractor.make_shareable(@path || @bytes) # frozen: never modified anyway
      per = (count / workers.to_f).ceil
      ractors = without_experimental_warning do
        (0...count).step(per).map do |first|
          args = [source, offset + (4 * first * nvars), @period_bytes, @periods, [per, count - first].min * nvars]
          if @path
            Ractor.new(*args, chunk) { |*a| Ractor.make_shareable(OutputFile.read_columns_from(*a)) }
          else
            Ractor.new(*args) { |*a| Ractor.make_shareable(OutputFile.read_columns(*a)) }
          end
        end
      end
      ractors.flat_map(&:value).map(&:dup)
    end

    def without_experimental_warning(&) = self.class.without_experimental_warning(&)
  end
end
