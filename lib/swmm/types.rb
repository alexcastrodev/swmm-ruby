# frozen_string_literal: true

require 'date'

module Swmm
  # Scalar converters: Ruby value -> the text token SWMM's .inp tokenizer expects.
  # Each raises ArgumentError ("must be ...") when the value is not acceptable.
  module Types
    BAD_CHARS = /["\r\n;]/ # quote, line end and comment start cannot travel inside a token
    US_DATE = %r{\A\d{1,2}/\d{1,2}/\d{4}\z}
    ISO_DATE = /\A(\d{4})-(\d{2})-(\d{2})\z/
    INTEGER_OVERFLOW = (2**1024) - (2**970) # the first Integer that rounds to Infinity as a double (Float::MAX plus half an ulp)
    CLOCK = /\A\d{1,3}:\d{2}(:\d{2})?\z/
    # "2026-03-24 10:00", "2026-03-24T10:00:00.000Z", "03/24/2026 10:00 UTC": fraction and zone are dropped (SWMM has no time zone)
    STAMP = %r{\A(\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{4})[T ](\d{1,2}:\d{2}(?::\d{2})?)(?:\.\d+)?\s?(?:Z|UTC|[+-]\d{2}:?\d{2})?\z}

    module_function

    def convert(type, value)
      value = utf8(value) if value.is_a?(String)
      type.is_a?(Array) ? one_of(type, value) : public_send(type, value)
    end

    # Contract text is UTF-8: a String in another encoding is converted when it can be (UTF-16, Latin-1,
    # BINARY holding UTF-8), anything else is rejected. Every converter below sees UTF-8 only.
    def utf8(value)
      s = case value.encoding
          when Encoding::UTF_8 then value
          when Encoding::BINARY then value.dup.force_encoding(Encoding::UTF_8)
          else value.encode(Encoding::UTF_8)
          end
      s.valid_encoding? ? s : raise(ArgumentError, 'must be valid UTF-8')
    rescue EncodingError
      raise ArgumentError, 'must be valid UTF-8'
    end

    # text token: quoted when it holds blanks; checked for NUL before the strip would swallow it
    def word(value)
      raise ArgumentError, "must be a String, Symbol or Integer, got #{value.class}" unless [String, Symbol, Integer].any? { value.is_a?(it) }

      s = utf8(value.to_s)
      raise ArgumentError, 'must not contain NUL' if s.include?("\0")

      s = s.strip
      raise ArgumentError, %(must not contain ", ; or line breaks) if s.match?(BAD_CHARS)
      raise ArgumentError, %(must not start with "[") if s.start_with?('[') # the engine reads it as a section header, quoted or not

      s.empty? || s.match?(/\s/) ? %("#{s}") : s
    end

    # label, path or tag: blanks are quoted, the engine's second pass honours the quotes
    def label(value) = word(value).then { |s| s == '""' ? raise(ArgumentError, 'must not be blank') : s }

    # object names and the references to them: the engine counts objects in a first pass that ignores quotes,
    # so a name with blanks is counted as its first word and can never be defined (ERROR 209 on every use)
    def bare(token) = token != '""' && token.start_with?('"') ? raise(ArgumentError, 'must not contain blanks') : token

    def id(value) = bare(label(value))

    # blank allowed (written as "")
    def opt_id(value) = bare(word(value))

    # number or name (e.g. FIXED stage or tidal curve)
    def any(value) = value.is_a?(Numeric) ? num(value) : bare(word(value))

    # tokens of a raw Array row: written as given, so a blank is quoted
    # ponytail: a raw row cannot tell names from labels, so a name with blanks passes here and the engine rejects it (ERROR 209); typed rows are checked
    def raw(value)
      if [true, false].include?(value)
        yn(value)
      else
        value.is_a?(Numeric) ? num(value) : word(value)
      end
    end

    # free text kept verbatim (expressions)
    def text(value)
      raise ArgumentError, 'must be a non-empty String' unless value.is_a?(String) && !value.strip.empty?
      raise ArgumentError, 'must not contain NUL' if value.include?("\0")
      raise ArgumentError, 'must not contain ; or line breaks' if value.match?(/[;\r\n]/)

      value.strip
    end

    def num(value)
      raise ArgumentError, "must be a number, got #{value.inspect}" unless value.is_a?(Numeric) && !value.is_a?(Complex)

      if value.is_a?(Integer)
        raise ArgumentError, 'must be finite' if value.abs >= INTEGER_OVERFLOW # the engine's strtod reads it as infinity

        return value.to_s
      end

      f = Float(value)
      raise ArgumentError, 'must be finite' unless f.finite?

      f.to_s
    rescue TypeError # a Numeric subclass that cannot become a Float
      raise ArgumentError, "must be a number, got #{value.inspect}"
    end

    def int(value) = value.is_a?(Integer) ? value.to_s : raise(ArgumentError, "must be an Integer, got #{value.inspect}")

    def yn(value)
      case value
      when true then 'YES'
      when false then 'NO'
      when /\A(yes|no)\z/i then value.to_s.upcase
      else raise ArgumentError, 'must be true, false, YES or NO'
      end
    end

    # MM/DD/YYYY; accepts Date/Time or "YYYY-MM-DD"
    def date(value)
      value = value.to_s if value.is_a?(Symbol) # a Symbol matches the patterns but Date.strptime / iso8601 raise TypeError on it
      case value
      when Date, Time then value
      when US_DATE then Date.strptime(value, '%m/%d/%Y')
      when ISO_DATE then Date.iso8601(value)
      else raise ArgumentError, 'must be a Date, MM/DD/YYYY or YYYY-MM-DD'
      end.strftime('%m/%d/%Y')
    rescue Date::Error
      raise ArgumentError, 'is not a valid calendar date'
    end

    # HH:MM[:SS]; an Integer is a number of seconds
    def time(value)
      case value
      when Integer then value.negative? ? raise(ArgumentError, 'must not be negative') : format('%d:%02d:%02d', value / 3600, value % 3600 / 60, value % 60)
      when CLOCK then value
      when Time then value.strftime('%H:%M:%S')
      else raise ArgumentError, 'must be HH:MM[:SS] or a number of seconds (Integer)'
      end
    end

    # report-step style: HH:MM[:SS], a number of seconds (Integer) or a TimeStep of whole seconds
    def step(value)
      return time(value) unless value.is_a?(TimeStep)
      raise ArgumentError, 'must not be negative' if value.in_seconds.negative?
      raise ArgumentError, "must be whole seconds, got #{value.in_seconds}" unless value.whole?

      value.formatted
    end

    # routing-step style: decimal seconds (0 allowed, e.g. lengthening_step), HH:MM:SS or a TimeStep
    def seconds(value)
      value = decimal(value) if value.is_a?(TimeStep) # written as decimal seconds, as SWMM reads them
      return value if value.is_a?(String) && value.match?(CLOCK)
      return num(value) if value.is_a?(Numeric) && !value.negative?

      raise ArgumentError, 'must be a non-negative number of seconds or HH:MM:SS'
    end

    # MINIMUM_STEP style: decimal seconds only (the engine reads no clock there), or a TimeStep
    def decimal_seconds(value)
      value = decimal(value) if value.is_a?(TimeStep)
      return num(value) if value.is_a?(Numeric) && !value.negative?

      raise ArgumentError, 'must be a non-negative number of seconds'
    end

    # a TimeStep's seconds as written to the input: 30, not 30.0
    def decimal(step) = step.whole? ? step.to_i : step.in_seconds

    def monthday(value)
      case value
      when Date, Time then value.strftime('%m/%d')
      when %r{\A\d{1,2}/\d{1,2}\z} then value
      else raise ArgumentError, 'must be MM/DD'
      end
    end

    # TIMESERIES time: [date, time] tokens for a calendar stamp (a Time keeps its own wall-clock fields),
    # or a single elapsed-time token
    def stamp(value)
      case value
      when Time then [value.strftime('%m/%d/%Y'), value.strftime('%H:%M:%S')]
      when Numeric then [num(value)] # elapsed hours
      when CLOCK then [value] # elapsed H:MM
      when STAMP then [date(::Regexp.last_match(1)), ::Regexp.last_match(2)]
      else raise ArgumentError, "must be a Time, 'YYYY-MM-DD HH:MM', 'MM/DD/YYYY HH:MM', elapsed hours or H:MM"
      end
    end

    def one_of(list, value)
      list.find { it.casecmp?(value.to_s) } || raise(ArgumentError, "must be one of #{list.join(', ')}")
    end
  end
end
