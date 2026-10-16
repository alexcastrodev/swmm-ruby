# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "timeout"

# Front A of docs/test-plan.md (risk R1): hostile input against the input contract.
#
# The engine reads the .inp with fgets(line, 1024) and tokenises each piece twice (tmp/swmm-src/src/solver/input.c):
# pass 1 (input_countObjects) with strtok on " \t\n\r", pass 2 (input_readData) with getTokens (quotes, ";").
# A piece whose first token starts with "[" is a section header in both passes. EngineView replays that, so the tests
# can check, without the engine, that an accepted model means to the engine what the generator wrote.
#
# Tests marked `skip "BUG: ..."` reproduce confirmed defects; set SWMM_SHOW_BUGS=1 to run them (they fail today).
module EngineView
  module_function

  # fgets(line, MAXLINE = 1024): a line longer than 1023 bytes comes back in several pieces, each read as a new line
  def pieces(inp) = inp.b.each_line.flat_map { _1.scan(/.{1,1023}/mn) }

  # first token of a piece in pass 1 and in pass 2 (nil when the piece is blank)
  def first_tokens(piece)
    s = piece[/\A[^\0]*/n] # C strings stop at NUL
    pass1 = s.split(/[ \t\n\r]+/).find { !_1.empty? }
    t = s.split(";", 2).first.to_s.sub(/\A[ \t\n\r]+/, "")
    pass2 = t.start_with?('"') ? t[1..][/\A[^"\n]*/n] : t[/\A[^ \t\n\r]*/n]
    [pass1, (pass2 unless t.empty?)]
  end

  # what can go wrong between the generator and the engine, as readable strings ([] = the engine sees the same file)
  def violations(model, inp = Swmm::Input.new(model).to_inp)
    present = model.select { |_, v| !(v.respond_to?(:empty?) && v.empty?) }.keys.map { _1.to_s.downcase.delete("[]").to_sym }
    expected = Swmm::Schema::SECTIONS.keys.select { present.include?(_1) }.map { "[#{_1.upcase}]" }
    out = []
    long = inp.b.each_line.map { _1.chomp("\n").bytesize }.select { _1 > Swmm::Input::MAX_LINE }
    out << "line of #{long.max} bytes is split by the engine" if long.any?
    out << "CR or NUL inside a line" if inp.b.match?(/[\r\0]/n)
    pieces(inp).map { first_tokens(_1) }.transpose.each_with_index do |tokens, pass|
      seen = tokens.compact.select { _1.start_with?("[") }
      out << "engine pass #{pass + 1} sees sections #{seen.inspect}, generator wrote #{expected.inspect}" unless seen == expected
    end
    out
  end
end

# One slot per place a String can reach the .inp, enumerated from Swmm::Schema (not hand-picked).
module Slots
  SAMPLE = { id: "X", opt_id: "X", any: 1, text: "1", num: 1, int: 1, yn: true, date: "2026-01-01", time: "00:00",
             seconds: 1, monthday: "01/01" }.freeze
  STRINGY = %i[id opt_id any text].freeze

  module_function

  def sample(col) = col.type.is_a?(Array) ? col.type.first : SAMPLE.fetch(col.type)

  def active?(col, row) = col.only.nil? || col.only[1].any? { _1.casecmp?(row[col.only[0]].to_s) }

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
        columns(sec.columns, base) { |c, row| out << ["#{name}[0].#{c.name}", c.type, ->(v) { { name => [row.(v)] } }] }
        out << ["#{name}[0] (raw Array row)", :any, ->(v) { { name => [[v, 1, 2]] } }]
      when :keywords
        sec.spec.each do |key, (_, cols)|
          base = minimal_row(cols)
          columns(cols, base) { |c, row| out << ["#{name}.#{key}.#{c.name}", c.type, ->(v) { { name => { key => row.(v) } } }] }
        end
      when :block
        head, parts = sec.spec.values_at(:head, :parts)
        base = { name: "X", **minimal_row(head || []), **parts.transform_values { minimal_row(_1[1]) } }
        out << ["#{name}[0].name", :id, ->(v) { { name => [base.merge(name: v)] } }]
        parts.each do |key, (_, cols)|
          columns(cols, base[key]) { |c, row| out << ["#{name}[0].#{key}.#{c.name}", c.type, ->(v) { { name => [base.merge(key => row.(v))] } }] }
        end
      when :options
        out << ["options.tempdir", :id, ->(v) { { options: { tempdir: v } } }]
      when :report
        out << ["report.nodes[0]", :id, ->(v) { { report: { nodes: [v] } } }]
      when :timeseries
        out << ["timeseries[0].name", :id, ->(v) { { timeseries: [{ name: v, points: [[0, 1]] }] } }]
        out << ["timeseries[0].file", :id, ->(v) { { timeseries: [{ name: "X", file: v }] } }]
      when :curves
        out << ["curves[0].name", :id, ->(v) { { curves: [{ name: v, type: "STORAGE", points: [[0, 1]] }] } }]
      when :patterns
        out << ["patterns[0].name", :id, ->(v) { { patterns: [{ name: v, type: "DAILY", factors: [1] * 7 }] } }]
      when :transects
        out << ["transects[0].name", :id, ->(v) { { transects: [{ name: v, n_left: 1, n_right: 1, n_channel: 1, x_left: 0, x_right: 1, stations: [[0, 0], [1, 1]] }] } }]
      when :controls
        rule = { name: "R", if: ["NODE J DEPTH > 1"], then: ["PUMP P STATUS = ON"] }
        out << ["controls[0].name", :id, ->(v) { { controls: [rule.merge(name: v)] } }]
        %i[if then else].each { |k| out << ["controls[0].#{k}[0]", :clause, ->(v) { { controls: [rule.merge(k => [v])] } }] }
        out << ["controls[0] (raw String line)", :clause, ->(v) { { controls: [v] } }]
      when :text
        out << ["title[0]", :clause, ->(v) { { title: [v] } }]
      end
    end
    out
  end

  # yields each String-capable column and a ->(value) { row } that puts the value there
  # (earlier optional columns without a default get a sample, since nothing may be written after a gap)
  def columns(cols, base)
    cols.each_with_index do |c, i|
      next unless STRINGY.include?(c.type) && active?(c, base)

      gaps = cols.first(i).select { !_1.required && _1.default.nil? && active?(_1, base) }.to_h { [_1.name, sample(_1)] }
      row = base.merge(gaps)
      yield c, ->(v) { row.merge(c.name => c.list ? [v, *Array.new([min_count(c.list) - 1, 0].max) { sample(c) }] : v) }
    end
  end
end

class InputAdversarialTest < Minitest::Test
  def errors(model) = Swmm::Input.validate(model)

  def inp(model) = Swmm::Input.new(model).to_inp

  def show(list) = "#{list.size} offending:\n  #{list.first(40).join("\n  ")}"

  # ---- the engine view itself ------------------------------------------------------------------------------------

  def test_engine_view_agrees_with_the_generator_on_valid_models
    Dir.mktmpdir do |dir|
      assert_empty EngineView.violations(Fixtures.full(dir))
      assert_empty EngineView.violations(Fixtures.base)
    end
    assert_equal [%w[J1 J1]], EngineView.pieces("J1 1\n").map { EngineView.first_tokens(_1) }
    assert_equal ['"J', "J 1"], EngineView.first_tokens(%("J 1" 10\n))
    assert_equal [";x", nil], EngineView.first_tokens(";x [OUTFALLS]\n")
    assert_equal ['"[OUTFALLS]', "[OUTFALLS] x"], EngineView.first_tokens(%("[OUTFALLS] x" 1\n)), "pass 1 ignores quotes"
    assert_equal 2, EngineView.pieces("#{"x" * 1024}\n").size, "fgets splits at 1023 bytes"
  end

  def test_every_slot_accepts_a_plain_value
    slots = Slots.all
    assert_operator slots.size, :>, 100, "the schema exposes many String slots"
    bad = slots.filter_map { |label, type, model| "#{label}: #{errors(model.(type == :clause ? "x" : "Y"))}" unless errors(model.(type == :clause ? "x" : "Y")).empty? }
    assert_empty bad, show(bad)
  end

  # ---- R1: structure injection -----------------------------------------------------------------------------------

  # The core invariant: whatever the contract accepts, the engine must see exactly the sections the generator wrote.
  # A name that starts with "[" (quoted or not) is a section header for the engine: it used to be silently dropped, to
  # re-route the following rows into another section, or to kill the process. Types.word now rejects a leading "["
  # and Input#line rejects line breaks, NUL and "[" in every written line (controls, rule clauses and titles too).
  def test_no_accepted_value_changes_the_sections_the_engine_sees
    payloads = ["[OUTFALLS]", "[JUNCTIONS] x", "x\n[OUTFALLS]", "x\r[OUTFALLS]"]
    bad = Slots.all.flat_map do |label, _type, model|
      payloads.filter_map do |p|
        m = model.(p)
        next unless errors(m).empty?

        v = EngineView.violations(m)
        "#{label} = #{p.inspect}: #{v.join("; ")}" if v.any?
      end
    end
    assert_empty bad, show(bad)
  end

  # Regression guard for what the contract does get right: in every typed slot, a line break, ";" or (outside
  # free-text expressions) a quote is rejected, never written.
  def test_line_breaks_comments_and_quotes_are_rejected_in_every_typed_slot
    accepted = Slots.all.reject { _2 == :clause }.flat_map do |label, type, model|
      ["a\nb", "a\rb", "a;b", "a\r\nb", ("a\"b" unless type == :text)].compact.filter_map { "#{label} = #{_1.inspect}" if errors(model.(_1)).empty? }
    end
    assert_empty accepted, show(accepted)
  end

  def test_rule_clauses_and_raw_control_lines_cannot_carry_structure
    rule = { name: "R", if: ["NODE J1 DEPTH > 1"], then: ["CONDUIT C1 STATUS = OPEN"] }
    { "raw line with a line break" => { controls: ["VARIABLE x = NODE J1 DEPTH\n[JUNCTIONS]\nJ9 3"] },
      "raw line that is a header" => { controls: ["[JUNCTIONS]", "J9 3"] },
      "then with a line break" => { controls: [rule.merge(then: ["CONDUIT C1 STATUS = OPEN\n[JUNCTIONS]\nJ9 3"])] },
      "if with a line break" => { controls: [rule.merge(if: ["NODE J1 DEPTH > 1\r\n[JUNCTIONS]"])] },
      "else with NUL" => { controls: [rule.merge(else: ["CONDUIT C1 STATUS = CLOSED\0x"])] } }.each do |label, m|
      refute_empty errors(m), "#{label} must be rejected"
    end
  end

  def test_title_lines_cannot_carry_structure
    ["T" * 1023 + "[JUNCTIONS]", "a\rb", "a\0b"].each do |line|
      m = { title: [line, "J10 3"] }
      refute_empty errors(m), -> { "title #{line[0, 20].inspect}...: engine view #{EngineView.violations(m)}" }
    end
  end

  # MAX_LINE is a byte limit (fgets). Input#line used to count characters: a 521-character line of 1031 bytes passed,
  # the engine read it as two lines and created a junction nobody wrote (see the engine test).
  def test_the_line_limit_is_counted_in_bytes
    m = { junctions: [{ name: "é" * 510, elevation: 10 }] }
    assert_equal ["junctions[0]"], errors(m).map { _1[:path] }, "engine view: #{EngineView.violations(m) if errors(m).empty?}"
  end

  def test_line_and_item_limits_are_exact_for_ascii
    pad = ->(n) { { junctions: [["J9", 5, 0, 0, 0, 0, "x" * n]] } } # "J9 5 0 0 0 0 " is 13 characters
    assert_empty errors(pad.(1010)), "1023 characters is the longest line"
    assert_equal [{ path: "junctions[0]", message: "line is 1024 characters; SWMM reads at most 1023" }], errors(pad.(1011))
    assert_empty errors(junctions: [{ name: "x" * 1013, elevation: 1 }]), "Hash row: name + ' 1 0 0 0 0' = 1023"
    refute_empty errors(junctions: [{ name: "x" * 1014, elevation: 1 }])
    assert_empty errors(options: { tempdir: "d" * 1002 }), "the padded option keyword counts: 20 + 1 + 1002"
    assert_equal ["options.tempdir"], errors(options: { tempdir: "d" * 1003 }).map { _1[:path] }

    assert_empty errors(junctions: [Array.new(40) { "x" }])
    assert_equal [{ path: "junctions[0]", message: "line has 41 items; SWMM reads at most 40" }], errors(junctions: [Array.new(41) { "x" }])
    assert_empty errors(junctions: [Array.new(39) { "x" } + ["a b"]]), "a quoted token is one item"
    refute_empty errors(profiles: [{ name: "P", links: Array.new(39) { "L" } }]), "list count also guards the items"
  end

  def test_nul_is_rejected_in_ids_and_expressions
    skip "BUG: NUL is accepted inside ids/text; the engine stops reading the line there (drops later values) - types.rb:9" unless ENV["SWMM_SHOW_BUGS"]
    refute_empty errors(inflows: [{ node: "J1", series: "Q\0x", scale_factor: 2 }])
    refute_empty errors(junctions: [{ name: "J\0x", elevation: 1 }])
    refute_empty errors(gwf: [{ subcatchment: "S", flow: "LATERAL", expression: "1\0" }])
  end

  # ---- scalars -----------------------------------------------------------------------------------------------------

  # Current behaviour, acceptable: ASCII whitespace (and NUL) at the ends is stripped; inner ASCII whitespace makes
  # the id quoted; Unicode spaces are ordinary characters for both Ruby's \s and the engine's " \t\n\r", so they stay
  # inside an unquoted token (two ids that look the same may differ).
  def test_whitespace_in_ids
    t = Swmm::Types
    assert_equal "J1", t.id(" \tJ1\n ")
    assert_equal "J1", t.id("\0J1\0")
    assert_equal %("a\tb"), t.id("a\tb")
    assert_equal %("a\vb"), t.id("a\vb")
    ["J 1", " J1", "J1 ", "　", "J x", "J\u0085x"].each { assert_equal _1, t.id(_1) }
    assert_raises(ArgumentError) { t.id(" \t ") }
    assert_equal '""', t.opt_id("")
    assert_equal "J1", t.id(:J1)
    assert_equal "-7", t.id(-7)
    [nil, true, 1.5, [], {}].each { |v| assert_raises(ArgumentError, v.inspect) { t.id(v) } }
    assert_equal "x" * 5000, t.id("x" * 5000), "ids have no length limit of their own; the line limit applies"
  end

  def test_numbers
    t = Swmm::Types
    [Float::NAN, Float::INFINITY, -Float::INFINITY, Float::MAX * 2, JSON.parse("[-1e400]")[0]].each { |v| assert_raises(ArgumentError, v.to_s) { t.num(v) } }
    [Complex(1, 0), "1", "1.5", nil, true, false, :one].each { |v| assert_raises(ArgumentError, v.inspect) { t.num(v) } }
    assert_equal "-0.0", t.num(-0.0)
    assert_equal "0.3333333333333333", t.num(Rational(1, 3))
    assert_equal "18446744073709551616", t.num(2**64)
    assert_equal "5.0e-324", t.num(5e-324)
    assert_equal "1.7976931348623157e+308", t.num(Float::MAX)
    rng = Random.new(1234)
    1000.times do
      f = (rng.rand - 0.5) * (10**rng.rand(-300..300).to_f)
      s = t.num(f)
      assert_match(/\A-?\d+\.\d+(e[+-]\d+)?\z/, s)
      assert_equal f, Float(s), "#{f} must round-trip"
    end
    assert_raises(ArgumentError) { t.int(1.0) }
    assert_equal "0", t.int(0)
  end

  # num rejects Float::INFINITY, but an Integer beyond the Float range is written in full and strtod reads it as
  # infinity: Swmm.run with junction elevation 10**309 finishes "ok" with the node full and no flow.
  def test_integers_beyond_the_float_range_are_rejected_like_infinity
    skip "BUG: Integer >= 2**1024 is accepted by num; the engine reads it as infinity - types.rb:51" unless ENV["SWMM_SHOW_BUGS"]
    assert_raises(ArgumentError) { Swmm::Types.num(10**309) }
  end

  def test_yes_no_words_and_case
    t = Swmm::Types
    assert_equal %w[YES NO YES NO], [true, false, "yes", :No].map { t.yn(_1) }
    ["y", 1, 0, nil, "true"].each { |v| assert_raises(ArgumentError, v.inspect) { t.yn(v) } }
    assert_equal "FREE", t.one_of(%w[FREE FIXED], :free)
    assert_equal "5", t.one_of(%w[3 4 5], 5)
    # Unicode case folding: the ligature folds to "fi". Harmless, the canonical word is what gets written.
    assert_equal "FIXED", t.one_of(%w[FREE FIXED], "ﬁxed")
    assert_raises(ArgumentError) { t.one_of(%w[FREE], " FREE") }

    plain = inp(junctions: [{ name: "J", elevation: 1 }], options: { flow_units: "LPS" })
    assert_equal plain, inp("JUNCTIONS" => [{ "NAME" => "J", "Elevation" => 1 }], "[OPTIONS]" => { "Flow_Units" => :lps })
  end

  def test_dates_and_times
    t = Swmm::Types
    assert_equal %w[03/24/2026 03/24/2026 03/04/2026 03/24/2026],
                 [Date.new(2026, 3, 24), DateTime.new(2026, 3, 24, 23), "3/4/2026", Time.new(2026, 3, 24, 23, 59, 0, "+05:00")].map { t.date(_1) }
    ["2026-02-30", "02/30/2026", "13/01/2026", "2026-3-4", " 2026-03-24", "2026-03-24\n", "24/03/2026", 20_260_324, nil].each do |v|
      assert_raises(ArgumentError, v.inspect) { t.date(v) }
    end
    assert_equal %w[0:15:00 1:00:00 05:06:07], [900, 3600, Time.utc(2026, 1, 1, 5, 6, 7)].map { t.time(_1) }
    [-1, 900.0, "10:00:00.5", "10", "1:2", nil].each { |v| assert_raises(ArgumentError, v.inspect) { t.time(v) } }
    # current behaviour: the clock pattern does not range-check; "1:60" / "24:00" / "999:59:59" are left to the engine
    assert_equal %w[1:60 24:00 999:59:59], %w[1:60 24:00 999:59:59].map { t.time(_1) }
    assert_equal [%w[03/24/2026 10:00:00], %w[03/24/2026 10:00], ["0:30"], ["0.5"]],
                 ["2026-03-24T10:00:00.000Z", "03/24/2026 10:00 UTC", "0:30", 0.5].map { t.stamp(_1) }
    # current behaviour, surprising: a DateTime is a Date, not a Time, so a time series point cannot use one
    assert_raises(ArgumentError) { t.stamp(DateTime.new(2026, 3, 24, 10)) }
    assert_raises(ArgumentError) { t.stamp(Float::NAN) }
  end

  # ---- validate must report, never raise ---------------------------------------------------------------------------

  # Strings from File.binread / an HTTP body are BINARY; Latin-1 and UTF-16 strings exist too. Today several reach
  # code outside convert_one's `rescue ArgumentError` (input.rb:44, 59, 70, 87, 162, 310, 327; types.rb:27).
  def test_strings_in_other_encodings_are_reported_not_raised
    skip "BUG: validate raises Encoding::CompatibilityError/ArgumentError for binary, Latin-1, UTF-16 or invalid UTF-8 strings" unless ENV["SWMM_SHOW_BUGS"]
    latin1 = "Po\xE7o".dup.force_encoding("ISO-8859-1")
    cases = {
      "binary + UTF-8 rows" => { junctions: [{ name: "\xFF".b, elevation: 1 }, { name: "Poço", elevation: 1 }] },
      "binary + UTF-8 in one row" => { conduits: [{ name: "Poço", from_node: "\xFF".b, to_node: "B", length: 1, roughness: 1, in_offset: 0, out_offset: 0 }] },
      "Latin-1 + UTF-8" => { junctions: [{ name: latin1, elevation: 1 }, { name: "Poço", elevation: 1 }] },
      "UTF-16 name" => { junctions: [{ name: "J1".encode("UTF-16LE"), elevation: 1 }] },
      "invalid UTF-8 section key" => { "\xFF" => 1 },
      "invalid UTF-8 column key" => { junctions: [{ "\xFF" => 1 }] },
      "invalid UTF-8 title" => { title: "\xFF" },
      "invalid UTF-8 report" => { report: { nodes: "\xFF" } },
      "invalid UTF-8 rule clause" => { controls: [{ name: "R", if: ["a", "\xFF"], then: ["b"] }] },
      "invalid UTF-8 in a column others depend on" => { outfalls: [{ name: "O", elevation: 1, type: "\xFF" }] }
    }
    raised = cases.filter_map do |label, m|
      Swmm::Input.validate(m)
      nil
    rescue StandardError => e
      "#{label}: #{e.class}: #{e.message}"
    end
    assert_empty raised, show(raised)
  end

  def test_symbol_dates_are_reported_not_raised
    skip "BUG: a date-shaped Symbol passes the regexp and Date.strptime/iso8601 raise TypeError - types.rb:73-74" unless ENV["SWMM_SHOW_BUGS"]
    [:"03/24/2026", :"2026-03-24"].each do |d|
      assert_kind_of Array, Swmm::Input.validate(options: { start_date: d })
    end
  end

  # JSON allows {"junctions": [...], "JUNCTIONS": [...]}; symbolize (input.rb:59) keeps only the last one.
  def test_keys_that_differ_only_in_case_do_not_lose_data
    skip "BUG: keys equal after downcase are merged silently, the earlier section/column is dropped - input.rb:59" unless ENV["SWMM_SHOW_BUGS"]
    m = { junctions: [{ name: "A", elevation: 1 }], "JUNCTIONS" => [{ name: "B", elevation: 2 }] }
    assert(errors(m).any? || (inp(m).include?("A 1") && inp(m).include?("B 2")), inp(m))
    row = { junctions: [{ name: "A", "NAME" => "B", elevation: 1 }] }
    refute_empty errors(row), "two names for one row"
  end

  def test_wrong_containers_are_reported
    assert_equal [{ path: "input", message: "must be a Hash" }], errors(nil)
    assert_equal [{ path: "input", message: "must be a Hash" }], errors([])
    assert_equal "\n", inp({}), "an empty model is valid (the engine then reports error 191)"
    {
      { junctions: { name: "J" } } => ["junctions"], { junctions: "J" } => ["junctions"], { junctions: [nil, 1, "x"] } => %w[junctions[0] junctions[1] junctions[2]],
      { options: [1] } => ["options"], { report: "ALL" } => ["report"], { evaporation: [[1]] } => ["evaporation"],
      { timeseries: [{ name: "T", points: [[0]] }] } => ["timeseries[0].points[0]"], { curves: [{ name: "C", type: "STORAGE", points: {} }] } => ["curves[0].points"],
      { patterns: [{ name: "P", type: "DAILY", factors: "1" }] } => ["patterns[0].factors"], { junctions: [{ name: { a: 1 }, elevation: [1] }] } => %w[junctions[0].elevation junctions[0].name],
      { coverages: [{ subcatchment: "S", landuses: "LU1" }] } => ["coverages[0].landuses"]
    }.each { |m, paths| assert_equal paths, errors(m).map { _1[:path] }.sort, m.inspect }
    # current behaviour: an empty Hash or Array is "nothing given" whatever the section expects
    assert_equal "\n", inp(junctions: {}, options: [], report: [], title: [])
  end

  def test_frozen_and_json_inputs_render_the_same_file
    Dir.mktmpdir do |dir|
      model = Fixtures.full(dir)
      assert_equal inp(model), inp(Ractor.make_shareable(Marshal.load(Marshal.dump(model))))
    end
    assert_equal inp(Fixtures.base), inp(JSON.parse(JSON.generate(Fixtures.base)))
  end

  # Property: on any input, validate returns a list of {path:, message:} and Input.new raises only InvalidInput.
  # Generated values are what JSON (plus Symbols) can carry, valid UTF-8 only and nesting <= 5: the encoding and Symbol-date
  # cases are separate tests above, and Array#inspect deeper than ~10_000 levels kills Ruby 4.0.7 itself (SIGILL).
  STRINGS = ["", " ", "J1", "[OUTFALLS]", "a\nb", "é", " ", ";", '"', "\0", "x" * 1100, "2026-03-24", "03/24/2026",
             "00:10", "yes", "FREE", "ALL", "*", "-1", "1e400", "NaN", "\t", "RULE", "[", "]"].freeze
  NUMBERS = [0, 1, -1, 2**70, 10**400, 0.5, -0.0, Float::NAN, Float::INFINITY, 1e308, Rational(1, 2)].freeze

  def garbage(rng, depth = 0)
    case rng.rand(depth > 3 ? 5 : 8)
    when 0 then [nil, true, false].sample(random: rng)
    when 1 then NUMBERS.sample(random: rng)
    when 2, 3 then STRINGS.sample(random: rng)
    when 4 then [:free, :J1, :ALL, :name, :"[X]"].sample(random: rng)
    when 5 then Array.new(rng.rand(4)) { garbage(rng, depth + 1) }
    else
      keys = Swmm::Schema::SECTIONS.keys + %i[name type points elevation if then bogus]
      Array.new(rng.rand(4)) { [keys.sample(random: rng).then { rng.rand(2).zero? ? _1.to_s.upcase : _1 }, garbage(rng, depth + 1)] }.to_h
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

  def check_contract(model, label)
    found = Swmm::Input.validate(model)
    assert_kind_of Array, found, label
    assert(found.all? { _1.keys == %i[path message] && _1[:path].is_a?(String) && _1[:message].is_a?(String) }, label)
    begin
      assert_kind_of String, Swmm::Input.new(model).to_inp, label
      assert_empty found, label
    rescue Swmm::InvalidInput => e
      assert_equal found, e.errors, label
    end
  rescue Swmm::InvalidInput, Minitest::Assertion
    raise
  rescue StandardError => e
    flunk "#{label}: #{e.class}: #{e.message[0, 200]}"
  end

  def test_validate_never_raises_on_generated_garbage
    rng = Random.new(1234)
    Dir.mktmpdir do |dir|
      full = Fixtures.full(dir)
      paths = leaf_paths(full)
      Timeout.timeout(10) do
        200.times { |i| check_contract(Swmm::Schema::SECTIONS.keys.sample(random: rng).then { { _1 => garbage(rng) } }, "section garbage ##{i}") }
        200.times { |i| check_contract(garbage(rng), "top-level garbage ##{i}") }
        400.times do |i|
          m = Marshal.load(Marshal.dump(full))
          picked = Array.new(1 + rng.rand(3)) { paths.sample(random: rng) }
          picked.each do |p|
            parent = p[0..-2].reduce(m) { |o, k| o.is_a?(Hash) || o.is_a?(Array) ? o[k] : nil }
            parent[p.last] = garbage(rng) if parent.is_a?(Hash) || (parent.is_a?(Array) && p.last.is_a?(Integer))
          end
          check_contract(m, "mutant ##{i} at #{picked.inspect}")
        end
      end
    end
  end
end

# The same defects seen through the real engine. A model that crashes the process runs in a child Ruby.
class InputAdversarialEngineTest < Minitest::Test
  include NeedsEngine

  def run_model(model) = Timeout.timeout(10) { Swmm.run(model) }

  def base_plus(**extra) = Fixtures.base.tap { |m| extra.each { |s, rows| m[s] = (m[s] || []) + rows } }

  def test_section_header_names_change_the_model_silently
    %w[[JUNCTIONS] [OUTFALLS]].each do |name|
      m = base_plus(junctions: [{ name: name, elevation: 1 }])
      next refute_empty(Swmm::Input.validate(m)) if Swmm::Input.validate(m).any?

      result = run_model(m)
      assert(!result.ok? || result.ids(:nodes).include?(name), "#{name}: run is ok but the node is gone: #{result.ids(:nodes)}")
    end
  end

  # The reproduction from the test plan: in the middle of [JUNCTIONS] the same name re-routed the next rows into
  # [OUTFALLS] and the run failed with the generic 200 (ERROR 205 on J2), far from the cause. Now the contract names it.
  def test_section_header_name_before_other_rows_is_rejected_at_the_cause
    m = Fixtures.base.merge(junctions: [Fixtures.base[:junctions][0], { name: "[OUTFALLS]", elevation: 1 }, Fixtures.base[:junctions][1]])
    assert_equal [{ path: "junctions[1].name", message: %(must not start with "[") }], Swmm::Input.validate(m)
    assert_raises(Swmm::InvalidInput) { Swmm.run(m) }
  end

  # Any leading "[" is refused, not only the known section names: the engine reads the line as a header anyway.
  def test_a_name_that_starts_with_a_bracket_is_rejected_even_when_it_is_not_a_known_section
    m = base_plus(junctions: [{ name: "[FOO]", elevation: 1 }])
    assert_equal [{ path: "junctions[2].name", message: %(must not start with "[") }], Swmm::Input.validate(m)
  end

  # Pass 1 (strtok) reads the quoted name as the object '"[JUNCTIONS]', pass 2 (getTokens) as a header: the object
  # counts disagree and libswmm5 dereferences NULL in swmm_open/output_open. SIGSEGV takes the whole Ruby process.
  def test_quoted_section_header_name_does_not_kill_the_process
    {
      "junction [JUNCTIONS] x" => base_plus(junctions: [{ name: "[JUNCTIONS] x", elevation: 1 }]),
      "junction [OUTFALLS]<tab>x" => base_plus(junctions: [{ name: "[OUTFALLS]\tx", elevation: 1 }]),
      "time series [REPORT] x" => base_plus(timeseries: [{ name: "[REPORT] x", points: [[0, 1]] }])
    }.each do |label, m|
      next if Swmm::Input.validate(m).any?

      script = 'require "swmm"; r = Swmm.run(Marshal.load($stdin.read)); print r.ok? || r.error[:code].is_a?(Integer)'
      out, status = Timeout.timeout(20) do
        Open3.capture2(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script, stdin_data: Marshal.dump(m), err: File::NULL)
      end
      assert status.success? && out == "true", "#{label}: child Ruby #{status.inspect}"
    end
  end

  # getTokens understands quotes, the counting pass (strtok) does not: an object whose name holds a blank is
  # counted as '"J' and then looked up as 'J 1'. The contract quotes such names (types.rb:29, input_test) but the
  # engine can never define them; it fails with ERROR 209 on every line that uses the name.
  def test_names_with_blanks_can_be_used
    skip "BUG: names with blanks are quoted and accepted, but the engine cannot define them (ERROR 209) - types.rb:29" unless ENV["SWMM_SHOW_BUGS"]
    b = Fixtures.base
    m = b.merge(junctions: [b[:junctions][0].merge(name: "J 1"), b[:junctions][1]],
                conduits: [b[:conduits][0].merge(from_node: "J 1"), b[:conduits][1]], inflows: [{ node: "J 1", series: "Q" }])
    assert(Swmm::Input.validate(m).any? || run_model(m).ok?, run_model(m).error.inspect)
  end

  # Typed Hash rows only: a 521-character (1032-byte) junction line passes the contract; fgets splits it after
  # 1023 bytes and the tail " 0 0 0 0" becomes a junction named "0". Run is "ok".
  def test_a_multibyte_line_is_not_split_into_two_objects
    name = "é" * 510
    m = base_plus(junctions: [{ name: name, elevation: 10 }])
    return refute_empty(Swmm::Input.validate(m)) if Swmm::Input.validate(m).any? # the contract counts bytes now

    nodes = run_model(m).ids(:nodes)
    assert_equal ["J1", "J2", "O1", name].sort, nodes.sort, "nodes: #{nodes.map { _1.size > 10 ? "#{_1[0, 3]}…" : _1 }}"
  end

  # The same split with a raw Array row places any row the caller wants: J10 appears from one J9 row.
  def test_a_raw_row_cannot_smuggle_a_second_row
    m = base_plus(junctions: [["J9", 5, 0, 0, 0, 0, "é" * 505, "J10", 3]])
    assert(Swmm::Input.validate(m).any? || !run_model(m).ids(:nodes).include?("J10"), "J10 was created")
  end

  def test_a_title_cannot_smuggle_a_section
    m = Fixtures.base.merge(title: ["T" * 1023 + "[JUNCTIONS]", "J10 3"])
    assert(Swmm::Input.validate(m).any? || !run_model(m).ids(:nodes).include?("J10"), "J10 was created")
  end

  def test_a_control_action_cannot_smuggle_a_section
    m = Fixtures.base.merge(controls: [{ name: "R", if: ["NODE J1 DEPTH > 100"], then: ["CONDUIT C1 STATUS = OPEN\n[JUNCTIONS]\nJ12 3"] }])
    assert(Swmm::Input.validate(m).any? || !run_model(m).ids(:nodes).include?("J12"), "J12 was created")
  end

  # NUL ends the C string: "J1 FLOW Q\0x FLOW 1.0 2.0 0" is read as "J1 FLOW Q", so scale_factor 2 is ignored.
  def test_nul_does_not_drop_the_rest_of_the_line
    skip "BUG: NUL inside an id makes the engine ignore the rest of the line (scale_factor 2 silently becomes 1) - types.rb:9" unless ENV["SWMM_SHOW_BUGS"]
    scaled = Fixtures.base.merge(inflows: [{ node: "J1", series: "Q", scale_factor: 2 }])
    with_nul = Fixtures.base.merge(inflows: [{ node: "J1", series: "Q\0x", scale_factor: 2 }])
    return refute_empty(Swmm::Input.validate(with_nul)) if Swmm::Input.validate(with_nul).any?

    assert_equal run_model(scaled).series(:links, "C2", :flow).max, run_model(with_nul).series(:links, "C2", :flow).max
  end

  def test_the_longest_accepted_lines_run_as_written
    full_line = base_plus(junctions: [["J9", 5, 0, 0, 0, 0, "x" * 1010]]) # 1023 characters
    forty = base_plus(junctions: [["J9", 5, 0, 0, 0, 0, *Array.new(34) { "x" }]]) # 40 items
    [full_line, forty].each do |m|
      assert_empty EngineView.violations(m)
      result = run_model(m)
      assert result.ok?, result.error.inspect
      assert_equal %w[J1 J2 J9 O1], result.ids(:nodes).sort
    end
  end

  # Accepted-but-odd models: the outcome is a normal Result (ok, or an engine error with an Integer code).
  def test_odd_accepted_models_come_back_as_results
    b = Fixtures.base
    nbsp = "J 1"
    models = {
      "empty model" => [{}, 191],
      "title only" => [{ title: "only a title" }, 191],
      "unicode-space id" => [b.merge(junctions: [b[:junctions][0].merge(name: nbsp), b[:junctions][1]],
                                     conduits: [b[:conduits][0].merge(from_node: nbsp), b[:conduits][1]], inflows: [{ node: nbsp, series: "Q" }]), 0],
      "Latin-1 id alone" => [base_plus(junctions: [{ name: "Po\xE7o".dup.force_encoding("ISO-8859-1"), elevation: 1 }]), 0],
      "binary id alone" => [base_plus(junctions: [{ name: "\xFF".b, elevation: 1 }]), 0],
      "elevation 1e308" => [base_plus(junctions: [{ name: "J9", elevation: 1e308 }]), nil],
      "barrels 2**40" => [b.merge(xsections: [b[:xsections][0].merge(barrels: 2**40), b[:xsections][1]]), 200],
      "start_time 99:99" => [b.merge(options: b[:options].merge(start_time: "99:99")), nil],
      "empty raw row" => [base_plus(junctions: [[]]), 0]
    }
    models.each do |label, (m, code)|
      assert_empty Swmm::Input.validate(m), label
      result = run_model(m)
      assert_kind_of Swmm::Result, result
      assert(result.ok? || result.error[:code].is_a?(Integer), label)
      assert_equal code, result.ok? ? 0 : result.error[:code], label if code
    end
    assert_includes run_model(models["unicode-space id"][0]).ids(:nodes), nbsp, "a Unicode space is part of the id end to end"
  end
end
