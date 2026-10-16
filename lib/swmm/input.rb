# frozen_string_literal: true

require_relative "types"
require_relative "schema"

module Swmm
  # Input contract: a Hash (keys = lowercase [SECTION] names, see Swmm::Schema) validated and rendered to .inp text.
  #
  #   input = Swmm::Input.new(options: { flow_units: "LPS" }, junctions: [{ name: "J1", elevation: 10 }], ...)
  #   input.to_inp  # => "[OPTIONS]\nFLOW_UNITS LPS\n\n[JUNCTIONS]\n..."
  #
  # Every violation is collected and raised together as Swmm::InvalidInput (never a partial file).
  # Any row may also be a raw Array of tokens, which is written as given (escape hatch for exotic lines).
  class Input
    MAX_TOKENS = 40 # SWMM's MAXTOKS: tokens past this are silently dropped by the engine
    MAX_LINE = 1023 # MAXLINE - 1
    # Columns that hold a label or a path, not an object name: blanks are quoted (the engine's second pass honours quotes)
    LABELS = %i[path station text tag tempdir file report_file].freeze

    attr_reader :to_inp

    # Returns the list of {path:, message:} violations ([] when the data is valid).
    def self.validate(data)
      new(data)
      []
    rescue InvalidInput => e
      e.errors
    end

    def initialize(data)
      @errors = []
      data = symbolize(data, "input", top: true)
      body = []
      if data
        (data.keys - Schema::SECTIONS.keys).each { error("input.#{_1}", "unknown section (valid: #{Schema::SECTIONS.keys.join(", ")})") }
        Schema::SECTIONS.each do |name, section|
          value = data[name]
          next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

          lines = send("render_#{section.kind}", name, section, value)
          body.push("[#{name.to_s.upcase}]", *lines, "") unless lines.empty?
        end
      end
      raise InvalidInput, @errors unless @errors.empty?

      @to_inp = "#{body.join("\n")}\n"
    end

    def write(path) = File.write(path, to_inp)

    alias to_s to_inp

    private

    def error(path, message) = @errors << { path: path, message: message }

    # Hash (any key case/type) -> Hash with lowercase Symbol keys; reports non-Hashes, keys that are not UTF-8
    # and keys that differ only in case (one would silently replace the other).
    def symbolize(value, path, top: false)
      return error(path, "must be a Hash") && nil unless value.is_a?(Hash)

      seen = {}
      value.each_with_object({}) do |(k, v), h|
        name = Types.utf8(k.to_s)
        key = name.downcase.then { top ? _1.delete("[]") : _1 }.to_sym
        error(path, %(keys "#{seen[key]}" and "#{name}" are the same: names are case-insensitive)) if seen.key?(key)
        seen[key] = name
        h[key] = v
      rescue ArgumentError => e
        error("#{path}.#{k.to_s.inspect}", e.message)
      end
    end

    # a Types converter, or a label/path where the column holds one (see LABELS)
    def kind(type, name, labels = LABELS) = type.is_a?(Symbol) && labels.include?(name) ? :label : type

    def convert_one(type, value, path)
      Types.convert(type, value)
    rescue ArgumentError => e
      error(path, e.message)
      nil
    end

    # Every line written to the file goes through here (free text too): the engine reads it with fgets, so the limit is in bytes.
    def line(path, tokens, tokenized: true)
      s = tokens.join(" ")
      error(path, "must not contain line breaks or NUL") if s.match?(/[\0\r\n]/)
      error(path, %(must not start with "[")) if s.lstrip.start_with?("[")
      error(path, "line is #{s.bytesize} #{s.ascii_only? ? "characters" : "bytes"}; SWMM reads at most #{MAX_LINE}") if s.bytesize > MAX_LINE
      n = s.scan(/"[^"]*"|\S+/).size
      error(path, "line has #{n} items; SWMM reads at most #{MAX_TOKENS}") if tokenized && n > MAX_TOKENS
      s
    end

    # Yields [item, "section[i]"] for an Array value.
    def each_item(name, value)
      return error(name.to_s, "must be an Array") && [] unless value.is_a?(Array)

      value.each_with_index.map { |item, i| [item, "#{name}[#{i}]"] }
    end

    # ---- columns -------------------------------------------------------------------------------

    def active?(col, row)
      col.only.nil? || col.only[1].any? { _1.casecmp?(Types.utf8(row[col.only[0]].to_s)) }
    rescue ArgumentError
      false # not valid text: the column itself reports it
    end

    def count_ok?(spec, n)
      case spec
      when Range then spec.cover?(n)
      when Array then spec.include?(n)
      else spec == n
      end
    end

    def convert_column(col, value, path, labels = LABELS)
      type = kind(col.type, col.name, labels)
      return [convert_one(type, value, path)].compact unless col.list

      value = value.to_a.flatten(1) if value.is_a?(Hash) # { "RES" => 50 } -> ["RES", 50]
      return error(path, "must be an Array") && nil unless value.is_a?(Array)
      return error(path, "needs #{col.list} items, got #{value.size}") && nil unless count_ok?(col.list, value.size)

      tokens = value.each_with_index.map { |v, i| convert_one(type, v, "#{path}[#{i}]") }
      tokens.compact if tokens.none?(&:nil?)
    end

    # Hash row -> tokens following the section's columns.
    def row_tokens(cols, row, path, labels = LABELS)
      row = symbolize(row, path) or return
      (row.keys - cols.map(&:name)).each { error("#{path}.#{_1}", "unknown column (valid: #{cols.map(&:name).join(", ")})") }
      tokens = []
      gap = nil # first optional column without value: nothing after it may be written
      cols.each do |col|
        given = !row[col.name].nil?
        unless active?(col, row)
          error("#{path}.#{col.name}", "does not apply when #{col.only[0]} is #{row[col.only[0]].inspect}") if given
          next
        end
        value = given ? row[col.name] : (col.default.respond_to?(:call) ? col.default.call(row) : col.default)
        value = [] if value.nil? && col.list
        if value.nil?
          error("#{path}.#{col.name}", "is required") if col.required
          gap ||= col.name
          next
        end
        found = convert_column(col, value, "#{path}.#{col.name}", labels) or next
        error("#{path}.#{col.name}", "needs #{gap} to be set first (use \"*\" to skip it where SWMM allows)") if gap && given && found.any?
        tokens.concat(found)
      end
      tokens
    end

    def raw_tokens(row, path)
      tokens = row.each_with_index.map { |v, i| convert_one(:raw, v, "#{path}[#{i}]") }
      tokens unless tokens.any?(&:nil?)
    end

    # ---- generic kinds -----------------------------------------------------------------------------

    def render_rows(name, section, rows)
      each_item(name, rows).flat_map do |row, path|
        tokens = row.is_a?(Array) ? raw_tokens(row, path) : row_tokens(section.columns, row, path, name == :profiles ? [:name, *LABELS] : LABELS) # a profile name is a label
        tokens ? [line(path, tokens)] : []
      end
    end

    def render_options(name, section, value)
      symbolize(value, name.to_s)&.filter_map do |key, v|
        type = section.spec[key]
        if type.nil?
          error("options.#{key}", "unknown option (valid: #{section.spec.keys.join(", ")})")
          next
        end
        token = convert_one(kind(type, key), v, "options.#{key}")
        token && line("options.#{key}", [key.to_s.upcase.ljust(20), token])
      end || []
    end

    def render_text(name, _section, value)
      lines = Array(value).each_with_index.flat_map { |l, i| (convert_one(:utf8, l.to_s, "title[#{i}]") || "").split("\n") }
      error(name.to_s, "SWMM keeps at most 3 title lines") if lines.size > 3
      lines.each_with_index { |l, i| error("title[#{i}]", "must not start with ;") if l.lstrip.start_with?(";") }
      lines.each_with_index.map { |l, i| line("title[#{i}]", [l], tokenized: false) }
    end

    # { key => value }: each key is a keyword line. value: true (bare), scalar/Array (positional) or Hash (named)
    def render_keywords(name, section, value)
      symbolize(value, name.to_s)&.flat_map do |key, val|
        text, cols = section.spec[key]
        next error("#{name}.#{key}", "unknown keyword (valid: #{section.spec.keys.join(", ")})") && [] unless text
        entries = val.is_a?(Array) && val.any? && val.all?(Hash) ? val : [val]
        entries.each_with_index.flat_map do |entry, i|
          path = entries.size > 1 ? "#{name}.#{key}[#{i}]" : "#{name}.#{key}"
          row = bind(cols, entry)
          if row.nil?
            error(path, "has more values than the keyword takes (#{cols.map(&:name).join(", ")})")
            next []
          end
          tokens = row_tokens(cols, row, path)
          tokens ? [line(path, [text, *tokens])] : []
        end
      end || []
    end

    # positional value(s) -> Hash of columns; nil when there are leftovers.
    # `true` is a bare keyword (TEMPERATURE, WINDSPEED FILE) unless the keyword takes a scalar, where it is a YES.
    def bind(cols, entry)
      return {} if entry == true && cols.none? { _1.required && !_1.list }
      return entry if entry.is_a?(Hash)

      vals = entry.is_a?(Array) ? entry.dup : [entry]
      row = cols.each_with_object({}) { |c, h| h[c.name] = c.list ? vals.slice!(0..) : vals.shift }
      vals.empty? ? row : nil
    end

    # named object over several lines: optional head line + keyword-led parts
    def render_block(name, section, items)
      head, parts = section.spec.values_at(:head, :parts)
      each_item(name, items).flat_map do |item, path|
        item = symbolize(item, path) or next []
        id = name_of(item, path)
        head_keys = head ? head.map(&:name) : []
        (item.keys - [:name, *head_keys, *parts.keys]).each { error("#{path}.#{_1}", "unknown key (valid: name, #{[*head_keys, *parts.keys].join(", ")})") }
        lines = []
        if head
          tokens = row_tokens(head, item.slice(*head_keys), path)
          lines << line(path, [id, *tokens]) if id && tokens
        end
        parts.each do |key, (keyword, cols)|
          next if item[key].nil?

          entries = item[key].is_a?(Array) ? item[key] : [item[key]]
          entries.each_with_index do |entry, i|
            epath = entries.size > 1 ? "#{path}.#{key}[#{i}]" : "#{path}.#{key}"
            tokens = row_tokens(cols, entry, epath)
            lines << line(epath, [id, keyword, *tokens].compact) if id && tokens
          end
        end
        lines
      end
    end

    # ---- sections with their own line layout ----------------------------------------------------

    def render_timeseries(name, _section, items)
      each_item(name, items).flat_map do |item, path|
        item = symbolize(item, path) or next []
        keys_check(item, %i[name points file], path)
        id = name_of(item, path) or next []
        if item[:file]
          file = convert_one(:label, item[:file], "#{path}.file")
          next file ? [line(path, [id, "FILE", file])] : []
        end
        points(item[:points], path).filter_map do |t, v, p|
          stamp = convert_one(:stamp, t, "#{p}[0]")
          val = convert_one(:num, v, "#{p}[1]")
          line(p, [id, *stamp, val]) if stamp && val
        end
      end
    end

    def render_curves(name, _section, items)
      each_item(name, items).flat_map do |item, path|
        item = symbolize(item, path) or next []
        keys_check(item, %i[name type points], path)
        id = name_of(item, path)
        type = convert_one(Schema::CURVE_TYPES, item[:type], "#{path}.type")
        next [] unless id && type

        points(item[:points], path).each_with_index.filter_map do |(x, y, p), i|
          xs, ys = convert_one(:num, x, "#{p}[0]"), convert_one(:num, y, "#{p}[1]")
          line(p, [id, (type if i.zero?), xs, ys].compact) if xs && ys
        end
      end
    end

    def render_patterns(name, _section, items)
      each_item(name, items).flat_map do |item, path|
        item = symbolize(item, path) or next []
        keys_check(item, %i[name type factors], path)
        id = name_of(item, path)
        type = convert_one(Schema::PATTERN_SIZES.keys, item[:type], "#{path}.type")
        next [] unless id && type

        factors = item[:factors]
        unless factors.is_a?(Array) && factors.size == Schema::PATTERN_SIZES[type]
          next error("#{path}.factors", "#{type} patterns need #{Schema::PATTERN_SIZES[type]} factors") && []
        end

        nums = factors.each_with_index.map { |f, i| convert_one(:num, f, "#{path}.factors[#{i}]") }
        nums.none?(&:nil?) ? [line(path, [id, type, *nums])] : []
      end
    end

    # NC line, X1 line, then GR lines (elevation/station pairs, wrapped to stay under SWMM's token limit)
    def render_transects(name, _section, items)
      each_item(name, items).flat_map do |item, path|
        item = symbolize(item, path) or next []
        keys_check(item, %i[name n_left n_right n_channel x_left x_right x_factor y_factor stations], path)
        id = name_of(item, path)
        n = %i[n_left n_right n_channel].map { convert_one(:num, item[_1], "#{path}.#{_1}") }
        x = %i[x_left x_right].map { convert_one(:num, item[_1], "#{path}.#{_1}") }
        f = { x_factor: 1, y_factor: 1 }.map { |k, d| convert_one(:num, item.fetch(k, d), "#{path}.#{k}") }
        stations = points(item[:stations], path, key: :stations)
        pairs = stations.map { |e, s, p| [convert_one(:num, e, "#{p}[0]"), convert_one(:num, s, "#{p}[1]")] }
        next [] if (n + x + f + pairs.flatten + [id]).any?(&:nil?)

        [line(path, ["NC", *n]),
         line(path, ["X1", id, pairs.size, *x, 0, 0, 0, *f]),
         *pairs.each_slice(8).map { |slice| line(path, ["GR", *slice.flatten]) }]
      end
    end

    # rule Hashes or raw lines
    def render_controls(name, _section, items)
      each_item(name, items).flat_map do |item, path|
        next [line(path, [convert_one(:utf8, item, path)])] if item.is_a?(String)

        item = symbolize(item, path) or next []
        keys_check(item, %i[name if then else priority], path)
        id = name_of(item, path, :name, :label) # a rule name is a label
        conds, thens = Array(item[:if]), Array(item[:then])
        error("#{path}.if", "needs at least one condition") if conds.empty?
        error("#{path}.then", "needs at least one action") if thens.empty?
        next [] unless id

        clause = lambda do |kw, key, list|
          list.each_with_index.filter_map do |c, i|
            p = "#{path}.#{key}[#{i}]"
            c = convert_one(:utf8, c.to_s, p) or next
            line(p, ["  #{i.zero? ? "#{kw} #{c}" : (c.match?(/\A\s*(AND|OR)\b/i) ? c : "AND #{c}")}"])
          end
        end
        [line("#{path}.name", ["RULE #{id}"]), *clause.("IF", :if, conds), *clause.("THEN", :then, thens),
         *(item[:else] ? clause.("ELSE", :else, Array(item[:else])) : []),
         *(item[:priority] ? ["  PRIORITY #{convert_one(:num, item[:priority], "#{path}.priority")}"] : []), ""]
      end
    end

    def render_report(name, _section, value)
      symbolize(value, name.to_s)&.flat_map do |key, v|
        path = "report.#{key}"
        if Schema::REPORT_FLAGS.include?(key)
          t = convert_one(:yn, v, path)
          next t ? [line(path, [key.to_s.upcase, t])] : []
        end
        next error(path, "unknown key (valid: #{[*Schema::REPORT_FLAGS, *Schema::REPORT_OBJECTS].join(", ")})") && [] unless Schema::REPORT_OBJECTS.include?(key)

        v = convert_one(:utf8, v, path) or next [] if v.is_a?(String)
        if v.to_s.match?(/\A(ALL|NONE)\z/i)
          [line(path, [key.to_s.upcase, v.to_s.upcase])]
        elsif v.is_a?(Array) && v.any?
          ids = v.each_with_index.map { |id, i| convert_one(:id, id, "#{path}[#{i}]") }
          ids.none?(&:nil?) ? ids.each_slice(20).map { line(path, [key.to_s.upcase, *_1]) } : []
        else
          error(path, "must be \"ALL\", \"NONE\" or a non-empty Array of ids") && []
        end
      end || []
    end

    # ---- helpers ------------------------------------------------------------------------------------

    def name_of(item, path, key = :name, type = :id)
      return error("#{path}.#{key}", "is required") && nil if item[key].nil?

      convert_one(type, item[key], "#{path}.#{key}")
    end

    def keys_check(item, valid, path)
      (item.keys - valid).each { error("#{path}.#{_1}", "unknown key (valid: #{valid.join(", ")})") }
    end

    # Array of [a, b] pairs -> [[a, b, "path[i]"], ...]
    def points(list, path, key: :points)
      unless list.is_a?(Array) && list.any?
        error("#{path}.#{key}", "must be a non-empty Array of [x, y] pairs")
        return []
      end
      list.each_with_index.filter_map do |pt, i|
        p = "#{path}.#{key}[#{i}]"
        pt.is_a?(Array) && pt.size == 2 ? [*pt, p] : error(p, "must be a [x, y] pair") && nil
      end
    end
  end
end
