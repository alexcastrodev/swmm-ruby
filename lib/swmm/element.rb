# frozen_string_literal: true

module Swmm
  # One object of a {Collection}: +result.links["C1"]+, or each one of +result.links.each+.
  #
  # @example
  #   link = result.links["C1"]
  #   link.id        # => "C1"
  #   link.type      # => "CONDUIT"
  #   link[:flow]    # => #<Swmm::Series links "C1" flow (LPS): 12 values>
  #   link.series    # => { flow: #<Swmm::Series ...>, depth: #<Swmm::Series ...>, ... }
  class Element
    # @return [Symbol] the kind of the object (+:subcatchments+, +:nodes+, +:links+ or +:system+)
    attr_reader :kind

    # @return [String] its id
    attr_reader :id

    # @api private
    # Built by {Collection#[]} and {Collection#each}.
    def initialize(reader:, kind:, index:)
      @reader = reader
      @kind = kind
      @index = index
      @id = reader.ids(kind).fetch(index)
    end

    # @return [String, nil] the node or link type (+"JUNCTION"+, +"CONDUIT"+, ...); nil for subcatchments and the system
    def type = (@reader.types(kind).fetch(id) if OutputFile::TYPES.key?(kind))

    # @param variable [Symbol, String] one of the kind's variables ({Collection#variables})
    # @return [Series] its values, one per period
    # @raise [UnknownObject] for another variable
    def [](variable)
      index = @reader.variable_index!(kind:, variable:)
      name = @reader.variables(kind)[index]
      Series.new(kind:, id:, variable: name, unit: @reader.units(kind).fetch(name), times: @reader.times,
                 values: @reader.series(kind:, index: @index, variable_index: index))
    end

    # @return [Hash{Symbol => Series}] every variable of the object
    def series = @reader.variables(kind).to_h { [it, self[it]] }

    # @return [String]
    def inspect = "#<#{self.class.name} #{kind} #{id.inspect}>"
  end
end
