# frozen_string_literal: true

module Swmm
  # The objects of one kind a results file saved: {OutputFile#links}, {OutputFile#nodes}, {OutputFile#subcatchments},
  # {OutputFile#system} (also on a {Result}: +result.links+).
  #
  # Kinds and variables are Symbols (Strings are accepted too); ids are Strings. A value the engine could not compute
  # (NaN / Infinity) is nil. Iterating a Collection goes through its objects as {Element}s.
  #
  # @example The objects
  #   links = result.links
  #   links.ids             # => ["C1", "C2", ...]
  #   links.variables       # => [:flow, :depth, :velocity, :volume, :capacity]
  #   links.units           # => { flow: "LPS", depth: "m", velocity: "m/s", volume: "m3", capacity: "fraction" }
  #   links.count_by_type   # => { "CONDUIT" => 607, "PUMP" => 1 }
  #   links.find { it.type == "PUMP" }.id   # => "P1"
  #
  # @example The values
  #   links["C1"][:flow]    # => #<Swmm::Series links "C1" flow (LPS): 12 values>
  #   links.frames(:depth)  # => #<Swmm::Frames links depth (m): 12 periods x 608 objects>
  #   links.records.each_slice(5_000) { |rows| LinkResult.insert_all(rows.map(&:to_h)) }
  #   File.open("links.csv", "w") { links.to_csv(it) }
  class Collection
    include Enumerable

    # @return [Symbol] +:subcatchments+, +:nodes+, +:links+ or +:system+
    attr_reader :kind

    # @api private
    # Built by {OutputFile#[]}.
    def initialize(reader:, kind:)
      @reader = reader
      @kind = kind
    end

    # @return [Array<String>] the ids of the objects, in the order of the file (the system has one: +"system"+)
    def ids = @reader.ids(kind)

    # @return [Array<Symbol>] the variables the file saved for this kind; pollutants are +:"quality:<name>"+
    def variables = @reader.variables(kind)

    # @return [Hash{Symbol => String}] the unit of each variable (+"m"+, +"LPS"+, +"MG/L"+, ...)
    def units = @reader.units(kind)

    # @param variable [Symbol, String] one of {#variables}
    # @return [String] its unit
    # @raise [UnknownObject] for another variable
    def unit(variable) = units.fetch(variables.fetch(@reader.variable_index!(kind:, variable:)))

    # @return [Integer] how many objects
    def size = ids.size

    # @overload each
    #   @yieldparam element [Element] each object, in the order of {#ids}
    #   @return [self]
    # @overload each
    #   @return [Enumerator<Element>]
    def each
      return enum_for(:each) { size } unless block_given?

      ids.each_index { yield Element.new(reader: @reader, kind:, index: it) }
      self
    end

    # @param id [String] one of {#ids}
    # @return [Element] that object
    # @raise [UnknownObject] when the file did not save it
    def [](id) = Element.new(reader: @reader, kind:, index: @reader.index!(kind:, id:))

    # @return [Hash{String => String}] the type of each node (+JUNCTION+, +OUTFALL+, +STORAGE+, +DIVIDER+) or link
    #   (+CONDUIT+, +PUMP+, +ORIFICE+, +WEIR+, +OUTLET+), as the file saves them
    # @raise [UnknownObject] for subcatchments and the system, which have no type
    def types = @reader.types(kind)

    # @return [Hash{String => Integer}] how many objects of each type, in the order of {OutputFile::TYPES}, without the
    #   types there are none of
    # @raise [UnknownObject] for subcatchments and the system, which have no type
    def count_by_type = @reader.count_by_type(kind)

    # One variable of every object, as a map plays it frame by frame.
    #
    # @param variable [Symbol, String] one of {#variables}
    # @return [Frames] a row per period, each with the value of every object (in memory)
    # @raise [UnknownObject] for another variable
    def frames(variable)
      index = @reader.variable_index!(kind:, variable:)
      name = variables[index]
      Frames.new(kind:, variable: name, unit: units.fetch(name), times: @reader.times, ids:,
                 rows: @reader.frames(kind:, variable_index: index))
    end

    # Every value as a table: a {Record} per period and object, time-major and then in the order of {#ids}. Read a
    # period at a time, never all in memory.
    #
    # @overload records
    #   @yieldparam record [Record] the time, the id and one member per variable
    #   @return [self]
    # @overload records
    #   @return [Enumerator<Record>] lazy: +records.each_slice(1000) { ... }+ reads as it goes
    def records(&)
      return enum_for(:records) { size * @reader.periods } unless block_given?

      @reader.each_record(kind, &)
      self
    end

    # Every value, by object and variable, read in one pass (in Ractors for a big kind; see {OutputFile.ractors}).
    #
    # @return [Hash{String => Hash{Symbol => Array<Float, nil>}}] +{ "C1" => { flow: [...], depth: [...] } }+, one
    #   value per period (in memory: for a big file, prefer {#records} or {#frames})
    def to_h = @reader.all_series(kind)

    # The values as CSV: a header +time,id,<variables>+, then a row per period and object (as {#records}). Times in ISO
    # 8601 (UTC, no zone), a nil value as an empty field, ids quoted when they need it.
    #
    # @param io [#write, nil] where to write it, a span of periods at a time (never whole in memory)
    # @return [String, #write] the CSV; or +io+, when given
    def to_csv(io = nil) = @reader.csv(kind:, io:)

    # @return [String]
    def inspect = "#<#{self.class.name} #{kind}: #{size} (#{variables.join(', ')})>"
  end
end
