# frozen_string_literal: true

require "date"

module Swmm
  # Scalar converters: Ruby value -> the text token SWMM's .inp tokenizer expects.
  # Each raises ArgumentError ("must be ...") when the value is not acceptable.
  module Types
    BAD_CHARS = /["\r\n;]/ # quote, line end and comment start cannot travel inside a token
    US_DATE = %r{\A\d{1,2}/\d{1,2}/\d{4}\z}
    ISO_DATE = /\A(\d{4})-(\d{2})-(\d{2})\z/
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
    def utf8(v)
      s = case v.encoding
          when Encoding::UTF_8 then v
          when Encoding::BINARY then v.dup.force_encoding(Encoding::UTF_8)
          else v.encode(Encoding::UTF_8)
          end
      s.valid_encoding? ? s : raise(ArgumentError, "must be valid UTF-8")
    rescue EncodingError
      raise ArgumentError, "must be valid UTF-8"
    end

    # text token: quoted when it holds blanks; checked for NUL before the strip would swallow it
    def word(v)
      raise ArgumentError, "must be a String, Symbol or Integer, got #{v.class}" unless [String, Symbol, Integer].any? { v.is_a?(_1) }

      s = utf8(v.to_s)
      raise ArgumentError, "must not contain NUL" if s.include?("\0")

      s = s.strip
      raise ArgumentError, %(must not contain ", ; or line breaks) if s.match?(BAD_CHARS)
      raise ArgumentError, %(must not start with "[") if s.start_with?("[") # the engine reads it as a section header, quoted or not

      s.empty? || s.match?(/\s/) ? %("#{s}") : s
    end

    # label, path or tag: blanks are quoted, the engine's second pass honours the quotes
    def label(v) = word(v).then { |s| s == '""' ? raise(ArgumentError, "must not be blank") : s }

    # object names and the references to them: the engine counts objects in a first pass that ignores quotes,
    # so a name with blanks is counted as its first word and can never be defined (ERROR 209 on every use)
    def bare(s) = s != '""' && s.start_with?('"') ? raise(ArgumentError, "must not contain blanks") : s

    def id(v) = bare(label(v))

    def opt_id(v) = bare(word(v)) # blank allowed (written as "")

    def any(v) = v.is_a?(Numeric) ? num(v) : bare(word(v)) # number or name (e.g. FIXED stage or tidal curve)

    # tokens of a raw Array row: written as given, so a blank is quoted
    # ponytail: a raw row cannot tell names from labels, so a name with blanks passes here and the engine rejects it (ERROR 209); typed rows are checked
    def raw(v) = [true, false].include?(v) ? yn(v) : v.is_a?(Numeric) ? num(v) : word(v)

    def text(v) # free text kept verbatim (expressions)
      raise ArgumentError, "must be a non-empty String" unless v.is_a?(String) && !v.strip.empty?
      raise ArgumentError, "must not contain NUL" if v.include?("\0")
      raise ArgumentError, "must not contain ; or line breaks" if v.match?(/[;\r\n]/)

      v.strip
    end

    def num(v)
      raise ArgumentError, "must be a number, got #{v.inspect}" unless v.is_a?(Numeric) && !v.is_a?(Complex)
      return v.to_s if v.is_a?(Integer)

      f = Float(v)
      raise ArgumentError, "must be finite" unless f.finite?

      f.to_s
    end

    def int(v) = v.is_a?(Integer) ? v.to_s : raise(ArgumentError, "must be an Integer, got #{v.inspect}")

    def yn(v)
      case v
      when true then "YES"
      when false then "NO"
      when /\A(yes|no)\z/i then v.to_s.upcase
      else raise ArgumentError, "must be true, false, YES or NO"
      end
    end

    def date(v) # MM/DD/YYYY; accepts Date/Time or "YYYY-MM-DD"
      case v
      when Date, Time then v
      when US_DATE then Date.strptime(v, "%m/%d/%Y")
      when ISO_DATE then Date.iso8601(v)
      else raise ArgumentError, "must be a Date, MM/DD/YYYY or YYYY-MM-DD"
      end.strftime("%m/%d/%Y")
    rescue Date::Error
      raise ArgumentError, "is not a valid calendar date"
    end

    def time(v) # HH:MM[:SS]; an Integer is a number of seconds
      case v
      when Integer then v.negative? ? raise(ArgumentError, "must not be negative") : format("%d:%02d:%02d", v / 3600, v % 3600 / 60, v % 60)
      when CLOCK then v
      when Time then v.strftime("%H:%M:%S")
      else raise ArgumentError, "must be HH:MM[:SS] or a number of seconds (Integer)"
      end
    end

    def seconds(v) # routing-step style: decimal seconds (0 allowed, e.g. lengthening_step) or HH:MM:SS
      return v if v.is_a?(String) && v.match?(CLOCK)
      return num(v) if v.is_a?(Numeric) && !v.negative?

      raise ArgumentError, "must be a non-negative number of seconds or HH:MM:SS"
    end

    def monthday(v)
      case v
      when Date, Time then v.strftime("%m/%d")
      when %r{\A\d{1,2}/\d{1,2}\z} then v
      else raise ArgumentError, "must be MM/DD"
      end
    end

    # TIMESERIES time: [date, time] tokens for a calendar stamp (a Time keeps its own wall-clock fields),
    # or a single elapsed-time token
    def stamp(v)
      case v
      when Time then [v.strftime("%m/%d/%Y"), v.strftime("%H:%M:%S")]
      when Numeric then [num(v)] # elapsed hours
      when CLOCK then [v] # elapsed H:MM
      when STAMP then [date($1), $2]
      else raise ArgumentError, "must be a Time, 'YYYY-MM-DD HH:MM', 'MM/DD/YYYY HH:MM', elapsed hours or H:MM"
      end
    end

    def one_of(list, v)
      list.find { _1.casecmp?(v.to_s) } || raise(ArgumentError, "must be one of #{list.join(", ")}")
    end
  end
end
