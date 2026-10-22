# frozen_string_literal: true

require "date"
require_relative "types"
require_relative "schema"
require_relative "input"

module Swmm
  class Input
    # .inp text -> the contract Hash Swmm::Input takes (Schema), so that a model written by the SWMM GUI, the swmm5 CLI or
    # Swmm::Input can be read, changed and run again: Swmm::Input.new(Swmm::Input.parse(text)) writes it back.
    #
    #   Swmm::Input.read("model.inp")                                        # every section
    #   Swmm::Input.parse(text, only: %i[junctions conduits coordinates])    # some; the others are not read at all
    #
    # Sections present in the file come back with their lowercase names; empty ones are left out. Values are typed:
    # numbers as Integer / Float, YES/NO as true / false, keywords in the case Schema lists them, MM/DD/YYYY dates as
    # Date, clock times as "H:MM[:SS]" text, names and labels as String. A row that does not fit its section's columns is
    # kept as the Array of its tokens (Input writes such a row as given). What the contract cannot hold (an unknown
    # section, option, keyword or report line, a malformed table line) raises InvalidInput, with every problem and its line.
    def self.parse(text, only: nil) = Parser.new(text, only).parse

    def self.read(path, only: nil) = parse(File.binread(path), only: only)

    # Reads a .inp the way the engine does (input.c getTokens, table.c, inflow.c, transect.c): blanks separate tokens,
    # double quotes group them, ";" starts a comment; [SECTION] headers are case-insensitive.
    class Parser
      # body: the line without its comment; tokens: [[text, offset in body], ...]
      Line = Struct.new(:number, :body, :tokens)

      INTEGER = /\A[-+]?\d+\z/
      NUMBER = /\A[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/
      MONTHDAY = %r{\A\d{1,2}/\d{1,2}\z}
      MAX_TITLE_LINES = 3 # the engine keeps the first 3

      def initialize(text, only)
        @text = utf8(text)
        @only = only && Array(only).map { |name| Schema::SECTIONS.key?(name.to_sym) ? name.to_sym : raise(ArgumentError, "unknown section #{name.inspect}") }
        @errors = []
      end

      def parse
        data = sections.filter_map do |name, lines|
          value = send("read_#{Schema::SECTIONS.fetch(name).kind}", name, Schema::SECTIONS.fetch(name), lines)
          [name, value] unless value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
        raise InvalidInput, @errors.sort_by { _1[:path][/line (\d+)\)\z/, 1].to_i } unless @errors.empty?

        data.to_h
      end

      private

      # UTF-8 text; a file in another single-byte encoding (Windows-1252, as older GUIs write) is converted
      def utf8(text)
        s = text.to_s.dup.force_encoding(Encoding::UTF_8)
        s = s.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless s.valid_encoding?
        s.delete_prefix("﻿")
      end

      # { section => [Line] } in file order, for the sections asked for; lines before the first header are ignored
      def sections
        current = nil
        @text.each_line.with_index(1).each_with_object({}) do |(raw, number), found|
          line = raw.chomp.delete_suffix("\r")
          if (header = line.strip[/\A\[([^\]]*)\]/, 1])
            current = header.strip.downcase.to_sym
            unless Schema::SECTIONS.key?(current)
              error(number, "[#{header.strip}]", "unknown section (valid: #{Schema::SECTIONS.keys.join(", ")})") unless @only
              current = nil
            end
            current = nil if @only && !@only.include?(current)
            found[current] ||= [] if current
          elsif current
            found[current] << line_of(number, line)
          end
        end
      end

      def line_of(number, line)
        body = line[/\A(?:[^";]|"[^"]*"?)*/] # up to the first ; outside quotes
        tokens = body.to_enum(:scan, /"([^"]*)"?|[^\s"]+/).map { [$~[1] || $~[0], $~.begin(0)] }
        Line.new(number, body, tokens)
      end

      def error(number, path, message) = @errors << { path: "#{path} (line #{number})", message: message }

      def lines_with_tokens(lines) = lines.reject { _1.tokens.empty? }

      # ---- values ----------------------------------------------------------------------------------

      # +text+ as a value of the column type, nil when it is not one
      def value_of(type, text)
        case type
        when Array then type.find { _1.casecmp?(text) }
        when :num then number(text)
        when :int then text.to_i if text.match?(INTEGER)
        when :yn then { "YES" => true, "NO" => false }[text.upcase]
        when :any then number(text) || text
        when :date then date(text)
        when :time then clock(text)
        when :seconds then number(text) || (text if text.match?(Types::CLOCK))
        when :monthday then text if text.match?(MONTHDAY)
        else text # names, labels, paths
        end
      end

      def number(text)
        if text.match?(INTEGER) then text.to_i
        elsif text.match?(NUMBER) then text.to_f
        end
      end

      def date(text)
        Date.strptime(text, "%m/%d/%Y") if text.match?(Types::US_DATE)
      rescue Date::Error
        nil
      end

      # "H:MM[:SS]" as written, or decimal hours (the engine takes both) as "H:MM:SS"
      def clock(text)
        return text if text.match?(Types::CLOCK)

        hours = number(text)
        return unless hours && !hours.negative?

        seconds = (hours * 3600).round
        format("%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
      end

      # ---- columns: Input#row_tokens read backwards --------------------------------------------------

      # { column => value } of +tokens+, nil when they do not fit +cols+: a column without its token or with a token
      # of another type, or tokens left over. Inactive columns take no token; a list takes as many tokens of its type as
      # it may; optional columns may be missing at the end; a :text column takes the rest of the line as written.
      def bind(cols, tokens, body)
        row = {}
        i = 0
        cols.each do |col|
          next unless active?(col, row)

          if i >= tokens.size
            return nil if col.required && !(col.list && count_ok?(col.list, 0))

            next
          end
          if col.type == :text
            row[col.name] = body[tokens[i][1]..].strip
            i = tokens.size
          elsif col.list
            values = []
            while i < tokens.size && values.size < max_count(col.list) && !(value = value_of(col.type, tokens[i][0])).nil?
              values << value
              i += 1
            end
            return nil unless count_ok?(col.list, values.size)

            row[col.name] = values unless values.empty?
          else
            value = value_of(col.type, tokens[i][0])
            return nil if value.nil?

            row[col.name] = value
            i += 1
          end
        end
        row if i == tokens.size
      end

      def active?(col, row) = col.only.nil? || col.only[1].any? { _1.casecmp?(row[col.only[0]].to_s) }

      def count_ok?(spec, n)
        case spec
        when Range then spec.cover?(n)
        when Array then spec.include?(n)
        else spec == n
        end
      end

      def max_count(spec) = spec.is_a?(Integer) ? spec : spec.max

      # one more entry for +key+: a Hash, then an Array of them
      def add(item, key, entry)
        item[key] = if !item.key?(key) then entry
                    elsif item[key].is_a?(Array) then [*item[key], entry]
                    else [item[key], entry]
                    end
      end

      # ---- generic kinds -------------------------------------------------------------------------------

      def read_rows(_name, section, lines)
        lines_with_tokens(lines).map { |line| bind(section.columns, line.tokens, line.body) || line.tokens.map(&:first) }
      end

      def read_text(_name, _section, lines)
        lines.map { _1.body.strip }.reject { _1.empty? || _1.start_with?(";") }.first(MAX_TITLE_LINES)
      end

      def read_options(name, section, lines)
        lines_with_tokens(lines).each_with_object({}) do |line, options|
          word, *rest = line.tokens.map(&:first)
          key = word.downcase.to_sym
          type = section.spec[key]
          next error(line.number, "#{name}.#{word}", "unknown option (valid: #{section.spec.keys.join(", ")})") unless type

          value = value_of(type, rest.first.to_s) if rest.size == 1
          next error(line.number, "#{name}.#{key}", "#{rest.join(" ").inspect} is not a valid value (#{Schema.type_label(type)})") if value.nil?

          options[key] = value
        end
      end

      # { key => Hash of columns (true for a bare keyword), or an Array of them when the keyword repeats }
      def read_keywords(name, section, lines)
        keywords = section.spec.sort_by { |_, (text, _)| -text.split.size } # "WINDSPEED MONTHLY" before a one-word one
        lines_with_tokens(lines).each_with_object({}) do |line, values|
          key, (text, cols) = keywords.find { |_, (text, _)| keyword?(line.tokens, text) }
          next error(line.number, "#{name}.#{line.tokens.first[0]}", "unknown keyword (valid: #{section.spec.keys.join(", ")})") unless key

          rest = line.tokens.drop(text.split.size)
          entry = cols.empty? && rest.empty? ? true : bind(cols, rest, line.body)
          next error(line.number, "#{name}.#{key}", "does not fit #{text} #{cols.map(&:name).join(" ")}".strip) unless entry

          add(values, key, entry)
        end
      end

      def keyword?(tokens, text)
        words = text.split
        tokens.size >= words.size && words.each_with_index.all? { |w, i| w.casecmp?(tokens[i][0]) }
      end

      # one Hash per object name, with its head columns and its parts (keyword-led lines, or the part without a keyword)
      def read_block(name, section, lines)
        head, parts = section.spec.values_at(:head, :parts)
        lines_with_tokens(lines).each_with_object({}) do |line, items|
          id, *rest = line.tokens
          item = items[id[0]] ||= { name: id[0] }
          key, entry = part_of(parts, rest, line.body)
          if key
            add(item, key, entry)
          elsif head && (entry = bind(head, rest, line.body))
            item.merge!(entry)
          else
            error(line.number, "#{name}.#{id[0]}", "is not a line of the section (parts: #{parts.keys.join(", ")})")
          end
        end.values
      end

      def part_of(parts, tokens, body)
        parts.each do |key, (keyword, cols)|
          if keyword
            next unless tokens.first&.first&.casecmp?(keyword)

            entry = bind(cols, tokens.drop(1), body)
          else
            entry = bind(cols, tokens, body)
          end
          return [key, entry] if entry
        end
        nil
      end

      # ---- sections with their own line layout --------------------------------------------------------

      # name [date] time value [[date] time value ...]: a date holds for the next times of the series until another
      # one (Tseries.lastDate); without any, times are elapsed hours or H:MM. Or: name FILE path.
      def read_timeseries(name, _section, lines)
        dates = {}
        lines_with_tokens(lines).each_with_object({}) do |line, series|
          id, *rest = line.tokens.map(&:first)
          item = series[id] ||= { name: id }
          path = "#{name}.#{id}"
          if rest.first&.casecmp?("FILE")
            next item[:file] = rest[1] if rest.size == 2

            next error(line.number, path, "needs FILE and a path")
          end
          until rest.empty?
            dates[id] = rest.shift if rest.first.match?(Types::US_DATE)
            time = rest.shift
            value = number(rest.shift.to_s)
            hours = number(time.to_s)
            stamp = dates[id] ? (clock_of_day(time) && "#{dates[id]} #{clock_of_day(time)}") : (hours || (time if time.to_s.match?(Types::CLOCK)))
            break error(line.number, path, "needs [date] time value entries, got #{line.body.strip.inspect}") if stamp.nil? || value.nil?

            (item[:points] ||= []) << [stamp, value]
          end
        end.values
      end

      # a time after a date, as "H:MM[:SS]" (decimal hours become a clock)
      def clock_of_day(text) = text && clock(text)

      # name TYPE x y [x y ...] on its first line, name x y [x y ...] after
      def read_curves(name, _section, lines)
        lines_with_tokens(lines).each_with_object({}) do |line, curves|
          id, *rest = line.tokens.map(&:first)
          path = "#{name}.#{id}"
          unless curves.key?(id)
            type = value_of(Schema::CURVE_TYPES, rest.shift.to_s)
            next error(line.number, path, "needs a curve type (#{Schema::CURVE_TYPES.join(", ")})") unless type

            curves[id] = { name: id, type: type, points: [] }
          end
          numbers = rest.map { number(_1) }
          next error(line.number, path, "needs x y pairs") if numbers.size.odd? || numbers.any?(&:nil?)

          curves[id][:points].concat(numbers.each_slice(2).to_a)
        end.values.reject { _1[:points].empty? }
      end

      # name TYPE factors... on its first line, name factors... after
      def read_patterns(name, _section, lines)
        lines_with_tokens(lines).each_with_object({}) do |line, patterns|
          id, *rest = line.tokens.map(&:first)
          path = "#{name}.#{id}"
          unless patterns.key?(id)
            type = value_of(Schema::PATTERN_SIZES.keys, rest.shift.to_s)
            next error(line.number, path, "needs a pattern type (#{Schema::PATTERN_SIZES.keys.join(", ")})") unless type

            patterns[id] = { name: id, type: type, factors: [] }
          end
          factors = rest.map { number(_1) }
          next error(line.number, path, "factors must be numbers") if factors.any?(&:nil?)

          patterns[id][:factors].concat(factors)
        end.values
      end

      # NC n_left n_right n_channel (for the transects after it), X1 name nsta x_left x_right 0 0 0 x_factor y_factor,
      # GR elevation station [elevation station ...]
      def read_transects(name, _section, lines)
        manning = nil
        lines_with_tokens(lines).each_with_object([]) do |line, transects|
          word, *rest = line.tokens.map(&:first)
          numbers = rest.map { number(_1) }
          case word.upcase
          when "NC"
            next error(line.number, "#{name}.NC", "needs n_left n_right n_channel") unless numbers.size >= 3 && numbers.first(3).none?(&:nil?)

            manning = %i[n_left n_right n_channel].zip(numbers).to_h
          when "X1"
            values = numbers.drop(1)
            unless manning && rest.size >= 9 && values.first(8).none?(&:nil?)
              next error(line.number, "#{name}.X1", "needs an NC line before it and name nsta x_left x_right 0 0 0 x_factor y_factor")
            end

            transects << { name: rest[0], **manning, x_left: values[1], x_right: values[2], x_factor: values[6], y_factor: values[7], stations: [] }
          when "GR"
            next error(line.number, "#{name}.GR", "needs an X1 line before it and elevation station pairs") if transects.empty? || numbers.size.odd? || numbers.any?(&:nil?)

            transects.last[:stations].concat(numbers.each_slice(2).to_a)
          else
            error(line.number, "#{name}.#{word}", "unknown line (NC, X1 or GR)")
          end
        end
      end

      # the rule lines as written (Input writes text lines as given)
      def read_controls(_name, _section, lines) = lines_with_tokens(lines).map { _1.body.rstrip }

      # flags => true / false; SUBCATCHMENTS / NODES / LINKS => "ALL", "NONE" or the ids of every line
      def read_report(name, _section, lines)
        lines_with_tokens(lines).each_with_object({}) do |line, report|
          word, *rest = line.tokens.map(&:first)
          key = word.downcase.to_sym
          if Schema::REPORT_FLAGS.include?(key)
            flag = value_of(:yn, rest.first.to_s) if rest.size == 1
            next error(line.number, "#{name}.#{word}", "needs YES or NO") if flag.nil?

            report[key] = flag
          elsif Schema::REPORT_OBJECTS.include?(key)
            next error(line.number, "#{name}.#{word}", "needs ALL, NONE or ids") if rest.empty?

            report[key] = if rest.size == 1 && rest.first.match?(/\A(ALL|NONE)\z/i) then rest.first.upcase
                          else [*(report[key] if report[key].is_a?(Array)), *rest]
                          end
          else
            error(line.number, "#{name}.#{word}", "unknown report line (valid: #{[*Schema::REPORT_FLAGS, *Schema::REPORT_OBJECTS].join(", ")})")
          end
        end
      end
    end
  end
end
