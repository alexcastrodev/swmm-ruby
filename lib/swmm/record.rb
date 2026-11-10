# frozen_string_literal: true

module Swmm
  # One row of {Collection#records}: the values of one object in one period. Besides +time+ and +id+, it has a member
  # per variable of the kind (+row.flow+, +row.depth+, ...). Each kind of each file has its own Data class with those
  # members; all of them are a Record (+row.is_a?(Swmm::Record)+).
  #
  # @example
  #   row = result.links.records.first
  #   row.time                # => 2026-03-24 00:10:00 UTC
  #   row.id                  # => "C1"
  #   row.flow                # => 0.12 (nil where the engine could not compute it)
  #   row[:"quality:TSS"]     # => 3.5 (a pollutant has no method name: by name)
  #   row.values              # => { flow: 0.12, depth: 0.3, ... }
  #   row.to_h                # => { time: ..., id: "C1", flow: 0.12, depth: 0.3, ... }
  module Record
    # @param name [Symbol, String] +:time+, +:id+ or a variable
    # @return [Object] that member
    # @raise [NoMethodError] for another name
    def [](name) = public_send(name.to_sym)

    # @return [Hash{Symbol => Float, nil}] the variables, without +time+ and +id+
    def values = to_h.except(:time, :id)

    # @return [String]
    def inspect = "#<Swmm::Record #{to_h.map { |name, value| "#{name}=#{value.inspect}" }.join(', ')}>"
  end
end
