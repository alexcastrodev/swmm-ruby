# frozen_string_literal: true

module Swmm
  # A step of time (report_step, routing_step, ...): what every reader of the pack returns for one, and what the input
  # takes besides seconds and "H:MM[:SS]".
  #
  #   step = Swmm::TimeStep.new(300)
  #   step.in_seconds   # => 300.0 (always a Float: a routing step can be 0.5 s)
  #   step.to_i         # => 300 (whole seconds, truncated: 0.5 s is 0)
  #   step.formatted    # => "00:05:00" (hh:mm:ss; a fraction of a second stays: "00:00:00.5")
  #   Swmm::TimeStep.parse("0:05:00") == step
  #   step.to_json      # => "300" (plain data stays seconds)
  class TimeStep
    include Comparable

    CLOCK = /\A(\d+):(\d{2})(?::(\d{2}))?\z/

    attr_reader :in_seconds

    # A TimeStep as it is, a Numeric as seconds, a String as "H:MM[:SS]" or decimal seconds.
    def self.from(value)
      case value
      when TimeStep then value
      when Numeric then new(value)
      when String then parse(value)
      else raise ArgumentError, "a time step is a TimeStep, a number of seconds or H:MM[:SS], got #{value.inspect}"
      end
    end

    # "H:MM[:SS]", or a decimal number in +decimal+ units (:seconds, or :hours as SWMM reads REPORT_STEP and the like).
    def self.parse(text, decimal: :seconds)
      text = text.to_s.strip
      if (m = text.match(CLOCK))
        new((m[1].to_i * 3600) + (m[2].to_i * 60) + m[3].to_i)
      elsif text.match?(/\A-?\d+(\.\d+)?\z/)
        new(decimal == :hours ? (text.to_f * 3600).round : Float(text))
      else
        raise ArgumentError, "not a time step (H:MM[:SS] or a number): #{text.inspect}"
      end
    end

    def initialize(seconds)
      raise ArgumentError, "a time step is a finite number of seconds, got #{seconds.inspect}" unless seconds.is_a?(Numeric) && seconds.finite?

      @in_seconds = seconds.to_f
      freeze
    end

    def whole? = (in_seconds % 1).zero?

    # hh:mm:ss (hours past 99 keep their digits; a negative step, as a broken .out may hold, gets a "-")
    def formatted
      total = in_seconds.abs
      whole = total.floor
      text = format('%<h>02d:%<m>02d:%<s>02d', h: whole / 3600, m: whole % 3600 / 60, s: whole % 60)
      text += (total - whole).round(6).to_s.delete_prefix('0') unless whole?
      in_seconds.negative? ? "-#{text}" : text
    end

    def to_s = formatted
    def to_i = in_seconds.to_i
    def to_f = in_seconds.to_f
    def positive? = in_seconds.positive?
    def inspect = "#<#{self.class.name} #{formatted}>"
    def as_json(*) = in_seconds
    def to_json(*) = in_seconds.to_json(*)

    def <=>(other) = other.is_a?(TimeStep) ? in_seconds <=> other.in_seconds : nil
    def eql?(other) = other.is_a?(TimeStep) && in_seconds == other.in_seconds
    def hash = [self.class, in_seconds.to_r].hash
  end
end
