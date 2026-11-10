# frozen_string_literal: true

module Swmm
  # The values of one variable of one object, one per reporting period, with the times they are of and their unit:
  # +result.links["C1"][:flow]+. Iterating it goes through +[time, value]+ pairs.
  #
  # @!attribute [r] kind
  #   @return [Symbol] the kind of the object
  # @!attribute [r] id
  #   @return [String] the object
  # @!attribute [r] variable
  #   @return [Symbol] the variable (+:flow+, +:depth+, +:"quality:TSS"+, ...)
  # @!attribute [r] unit
  #   @return [String] its unit (+"LPS"+, +"m"+, ...)
  # @!attribute [r] times
  #   @return [Array<Time>] the time of each period (UTC)
  # @!attribute [r] values
  #   @return [Array<Float, nil>] the value of each period; nil where the engine could not compute one
  #
  # @example
  #   s = result.links["C1"][:flow]
  #   s.values                        # => [0.0, 15.2, 32.0, ...]
  #   s.unit                          # => "LPS"
  #   s.to_h                          # => { 2026-03-24 00:10:00 UTC => 0.0, ... }
  #   s.select { |_time, value| value&.positive? }
  Series = Data.define(:kind, :id, :variable, :unit, :times, :values) do
    include Enumerable

    # @return [Integer] how many periods
    def size = values.size

    # @overload each
    #   @yieldparam time [Time]
    #   @yieldparam value [Float, nil]
    #   @return [self]
    # @overload each
    #   @return [Enumerator<Array(Time, Float)>]
    def each
      return enum_for(:each) { size } unless block_given?

      times.each_with_index { |time, i| yield time, values[i] }
      self
    end

    # @return [Hash{Time => Float, nil}] the value of each time (the members are +deconstruct_keys(nil)+)
    def to_h(&) = times.zip(values).to_h(&)

    # @return [String]
    def inspect = "#<#{self.class.name} #{kind} #{id.inspect} #{variable} (#{unit}): #{size} values>"
  end
end
