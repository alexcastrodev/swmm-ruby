# frozen_string_literal: true

module Swmm
  # One variable of every object of a kind, as a map plays it frame by frame: +result.links.frames(:flow)+.
  # +rows[p][i]+ is the value of +ids[i]+ at +times[p]+. Iterating it goes through +[time, row]+ pairs.
  #
  # @!attribute [r] kind
  #   @return [Symbol] the kind of the objects
  # @!attribute [r] variable
  #   @return [Symbol] the variable
  # @!attribute [r] unit
  #   @return [String] its unit
  # @!attribute [r] times
  #   @return [Array<Time>] the time of each period (UTC)
  # @!attribute [r] ids
  #   @return [Array<String>] the objects, in the order of each row
  # @!attribute [r] rows
  #   @return [Array<Array<Float, nil>>] a row per period, a value per object; nil where the engine could not compute one
  #
  # @example
  #   f = result.links.frames(:depth)
  #   f.rows.first          # => [0.0, 0.01, ...] every link at the first period
  #   f.each { |time, row| paint(time, f.ids.zip(row)) }
  Frames = Data.define(:kind, :variable, :unit, :times, :ids, :rows) do
    include Enumerable

    # @return [Integer] how many periods
    def size = rows.size

    # @overload each
    #   @yieldparam time [Time]
    #   @yieldparam row [Array<Float, nil>]
    #   @return [self]
    # @overload each
    #   @return [Enumerator<Array(Time, Array<Float, nil>)>]
    def each
      return enum_for(:each) { size } unless block_given?

      times.each_with_index { |time, i| yield time, rows[i] }
      self
    end

    # @return [Hash{Symbol => Object}] the members (+kind:+, +variable:+, ..., +rows:+), as Data#to_h
    def to_h(&) = deconstruct_keys(nil).to_h(&)

    # @return [String]
    def inspect = "#<#{self.class.name} #{kind} #{variable} (#{unit}): #{size} periods x #{ids.size} objects>"
  end
end
