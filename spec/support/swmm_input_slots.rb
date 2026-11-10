# Front A of docs/test-plan.md (risk R1): hostile input against the input contract.
#
# The engine reads the .inp with fgets(line, 1024) and tokenises each piece twice (tmp/swmm-src/src/solver/input.c):
# pass 1 (input_countObjects) with strtok on " \t\n\r", pass 2 (input_readData) with getTokens (quotes, ";").
# A piece whose first token starts with "[" is a section header in both passes. SwmmEngineView replays that, so the specs
# can check, without the engine, that an accepted model means to the engine what the generator wrote.
module SwmmEngineView
  module_function

  # fgets(line, MAXLINE = 1024): a line longer than 1023 bytes comes back in several pieces, each read as a new line
  def pieces(inp) = inp.b.each_line.flat_map { it.scan(/.{1,1023}/mn) }

  # first token of a piece in pass 1 and in pass 2 (nil when the piece is blank)
  def first_tokens(piece)
    s = piece[/\A[^\0]*/n] # C strings stop at NUL
    pass1 = s.split(/[ \t\n\r]+/).find { !it.empty? }
    t = s.split(';', 2).first.to_s.sub(/\A[ \t\n\r]+/, '')
    pass2 = t.start_with?('"') ? t[1..][/\A[^"\n]*/n] : t[/\A[^ \t\n\r]*/n]
    [pass1, (pass2 unless t.empty?)]
  end

  # what can go wrong between the generator and the engine, as readable strings ([] = the engine sees the same file)
  def violations(model, inp = Swmm::Input.new(model).to_inp)
    present = model.reject { |_, v| v.respond_to?(:empty?) && v.empty? }.keys.map { it.to_s.downcase.delete('[]').to_sym }
    expected = Swmm::Schema::SECTIONS.keys.select { present.include?(it) }.map { "[#{it.upcase}]" }
    out = []
    long = inp.b.each_line.map { it.chomp.bytesize }.select { it > Swmm::Input::Renderer::MAX_LINE }
    out << "line of #{long.max} bytes is split by the engine" if long.any?
    out << 'CR or NUL inside a line' if inp.b.match?(/[\r\0]/n)
    pieces(inp).map { first_tokens(it) }.transpose.each_with_index do |tokens, pass|
      seen = tokens.compact.select { it.start_with?('[') }
      out << "engine pass #{pass + 1} sees sections #{seen.inspect}, generator wrote #{expected.inspect}" unless seen == expected
    end
    out
  end
end

# One slot per place a String can reach the .inp, enumerated from Swmm::Schema (not hand-picked).
module SwmmSlots
  SAMPLE = { id: 'X', opt_id: 'X', any: 1, text: '1', num: 1, int: 1, yn: true, date: '2026-01-01', time: '00:00',
             step: '00:15', seconds: 1, decimal_seconds: 0.5, monthday: '01/01' }.freeze
  STRINGY = %i[id opt_id any text].freeze

  module_function

  def sample(col) = col.type.is_a?(Array) ? col.type.first : SAMPLE.fetch(col.type)

  def active?(col, row) = col.only.nil? || col.only[1].any? { it.casecmp?(row[col.only[0]].to_s) }

  def min_count(spec) = spec.is_a?(Integer) ? spec : spec.min

  # required columns only, with valid sample values
  def minimal_row(cols)
    cols.each_with_object({}) do |c, row|
      next unless c.required && active?(c, row)

      row[c.name] = c.list ? Array.new(min_count(c.list)) { sample(c) } : sample(c)
    end
  end

  # [[label, type, ->(value) { model }], ...]
  def all
    out = []
    Swmm::Schema::SECTIONS.each do |name, sec|
      case sec.kind
      when :rows
        base = minimal_row(sec.columns)
        columns(sec.columns, base) { |c, row| out << ["#{name}[0].#{c.name}", c.type, ->(v) { { name => [row.call(v)] } }] }
        out << ["#{name}[0] (raw Array row)", :any, ->(v) { { name => [[v, 1, 2]] } }]
      when :keywords
        sec.spec.each do |key, (_, cols)|
          base = minimal_row(cols)
          columns(cols, base) { |c, row| out << ["#{name}.#{key}.#{c.name}", c.type, ->(v) { { name => { key => row.call(v) } } }] }
        end
      when :block
        head, parts = sec.spec.values_at(:head, :parts)
        base = { name: 'X', **minimal_row(head || []), **parts.transform_values { minimal_row(it[1]) } }
        out << ["#{name}[0].name", :id, ->(v) { { name => [base.merge(name: v)] } }]
        parts.each do |key, (_, cols)|
          columns(cols, base[key]) { |c, row| out << ["#{name}[0].#{key}.#{c.name}", c.type, ->(v) { { name => [base.merge(key => row.call(v))] } }] }
        end
      when :options
        out << ['options.tempdir', :id, ->(v) { { options: { tempdir: v } } }]
      when :report
        out << ['report.nodes[0]', :id, ->(v) { { report: { nodes: [v] } } }]
      when :timeseries
        out << ['timeseries[0].name', :id, ->(v) { { timeseries: [{ name: v, points: [[0, 1]] }] } }]
        out << ['timeseries[0].file', :id, ->(v) { { timeseries: [{ name: 'X', file: v }] } }]
      when :curves
        out << ['curves[0].name', :id, ->(v) { { curves: [{ name: v, type: 'STORAGE', points: [[0, 1]] }] } }]
      when :patterns
        out << ['patterns[0].name', :id, ->(v) { { patterns: [{ name: v, type: 'DAILY', factors: [1] * 7 }] } }]
      when :transects
        out << ['transects[0].name', :id, ->(v) { { transects: [{ name: v, n_left: 1, n_right: 1, n_channel: 1, x_left: 0, x_right: 1, stations: [[0, 0], [1, 1]] }] } }]
      when :controls
        rule = { name: 'R', if: ['NODE J DEPTH > 1'], then: ['PUMP P STATUS = ON'] }
        out << ['controls[0].name', :id, ->(v) { { controls: [rule.merge(name: v)] } }]
        %i[if then else].each { |k| out << ["controls[0].#{k}[0]", :clause, ->(v) { { controls: [rule.merge(k => [v])] } }] }
        out << ['controls[0] (raw String line)', :clause, ->(v) { { controls: [v] } }]
      when :text
        out << ['title[0]', :clause, ->(v) { { title: [v] } }]
      end
    end
    out
  end

  # yields each String-capable column and a ->(value) { row } that puts the value there
  # (earlier optional columns without a default get a sample, since nothing may be written after a gap)
  def columns(cols, base)
    cols.each_with_index do |c, i|
      next unless STRINGY.include?(c.type) && active?(c, base)

      gaps = cols.first(i).select { !it.required && it.default.nil? && active?(it, base) }.to_h { [it.name, sample(it)] }
      row = base.merge(gaps)
      yield c, ->(v) { row.merge(c.name => c.list ? [v, *Array.new([min_count(c.list) - 1, 0].max) { sample(c) }] : v) }
    end
  end
end

# Values JSON (plus Symbols) can carry, valid UTF-8 only and nesting <= 5: the encoding and Symbol-date cases have their own
# examples, and Array#inspect deeper than ~10_000 levels kills Ruby 4.0.7 itself (SIGILL).
module SwmmGarbage
  STRINGS = ['', ' ', 'J1', '[OUTFALLS]', "a\nb", 'é', ' ', ';', '"', "\0", 'x' * 1100, '2026-03-24', '03/24/2026',
             '00:10', 'yes', 'FREE', 'ALL', '*', '-1', '1e400', 'NaN', "\t", 'RULE', '[', ']'].freeze
  NUMBERS = [0, 1, -1, 2**70, 10**400, 0.5, -0.0, Float::NAN, Float::INFINITY, 1e308, Rational(1, 2)].freeze

  module_function

  def garbage(rng, depth = 0)
    case rng.rand(depth > 3 ? 5 : 8)
    when 0 then [nil, true, false].sample(random: rng)
    when 1 then NUMBERS.sample(random: rng)
    when 2, 3 then STRINGS.sample(random: rng)
    when 4 then [:free, :J1, :ALL, :name, :'[X]'].sample(random: rng)
    when 5 then Array.new(rng.rand(4)) { garbage(rng, depth + 1) }
    else
      keys = Swmm::Schema::SECTIONS.keys + %i[name type points elevation if then bogus]
      Array.new(rng.rand(4)) { [keys.sample(random: rng).then { rng.rand(2).zero? ? it.to_s.upcase : it }, garbage(rng, depth + 1)] }.to_h
    end
  end

  def leaf_paths(obj, path = [], out = [])
    out << path unless path.empty?
    case obj
    when Hash then obj.each { |k, v| leaf_paths(v, path + [k], out) }
    when Array then obj.each_with_index { |v, i| leaf_paths(v, path + [i], out) }
    end
    out
  end
end
