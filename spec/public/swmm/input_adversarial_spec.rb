require 'open3'
require 'timeout'
require_relative '../../swmm_helper'
require_relative '../../support/swmm_input_slots'

# Hostile input against the input contract: see spec/support/swmm_input_slots.rb for how the engine reads the .inp.
RSpec.describe Swmm::Input, 'with hostile input' do
  def errors(model) = described_class.validate(model)

  def inp(model) = described_class.new(model).to_inp

  def show(list) = "#{list.size} offending:\n  #{list.first(40).join("\n  ")}"

  # ---- the engine view itself ------------------------------------------------------------------------------------

  it 'has an engine view that agrees with the generator on valid models' do
    Dir.mktmpdir do |dir|
      expect(SwmmEngineView.violations(SwmmFixtures.full(dir))).to be_empty
      expect(SwmmEngineView.violations(SwmmFixtures.base)).to be_empty
    end
    expect(SwmmEngineView.pieces("J1 1\n").map { SwmmEngineView.first_tokens(it) }).to eq([%w[J1 J1]])
    expect(SwmmEngineView.first_tokens(%("J 1" 10\n))).to eq(['"J', 'J 1'])
    expect(SwmmEngineView.first_tokens(";x [OUTFALLS]\n")).to eq([';x', nil])
    expect(SwmmEngineView.first_tokens(%("[OUTFALLS] x" 1\n))).to eq(['"[OUTFALLS]', '[OUTFALLS] x']), 'pass 1 ignores quotes'
    expect(SwmmEngineView.pieces("#{'x' * 1024}\n").size).to eq(2), 'fgets splits at 1023 bytes'
  end

  it 'accepts a plain value in every slot' do
    slots = SwmmSlots.all
    expect(slots.size).to be > 100, 'the schema exposes many String slots'
    bad = slots.filter_map { |label, type, model| "#{label}: #{errors(model.call(type == :clause ? 'x' : 'Y'))}" unless errors(model.call(type == :clause ? 'x' : 'Y')).empty? }
    expect(bad).to be_empty, show(bad)
  end

  # ---- R1: structure injection -----------------------------------------------------------------------------------

  # The core invariant: whatever the contract accepts, the engine must see exactly the sections the generator wrote.
  # A name that starts with "[" (quoted or not) is a section header for the engine: it used to be silently dropped, to
  # re-route the following rows into another section, or to kill the process. Types.word now rejects a leading "["
  # and Input::Renderer#line rejects line breaks, NUL and "[" in every written line (controls, rule clauses and titles too).
  it 'accepts no value that changes the sections the engine sees' do
    payloads = ['[OUTFALLS]', '[JUNCTIONS] x', "x\n[OUTFALLS]", "x\r[OUTFALLS]"]
    bad = SwmmSlots.all.flat_map do |label, _type, model|
      payloads.filter_map do |p|
        m = model.call(p)
        next unless errors(m).empty?

        v = SwmmEngineView.violations(m)
        "#{label} = #{p.inspect}: #{v.join('; ')}" if v.any?
      end
    end
    expect(bad).to be_empty, show(bad)
  end

  # Regression guard for what the contract does get right: in every typed slot, a line break, ";" or (outside
  # free-text expressions) a quote is rejected, never written.
  it 'rejects line breaks, comments and quotes in every typed slot' do
    accepted = SwmmSlots.all.reject { _2 == :clause }.flat_map do |label, type, model|
      ["a\nb", "a\rb", 'a;b', "a\r\nb", ('a"b' unless type == :text)].compact.filter_map { "#{label} = #{it.inspect}" if errors(model.call(it)).empty? }
    end
    expect(accepted).to be_empty, show(accepted)
  end

  it 'does not let rule clauses and raw control lines carry structure' do
    rule = { name: 'R', if: ['NODE J1 DEPTH > 1'], then: ['CONDUIT C1 STATUS = OPEN'] }
    { 'raw line with a line break' => { controls: ["VARIABLE x = NODE J1 DEPTH\n[JUNCTIONS]\nJ9 3"] },
      'raw line that is a header' => { controls: ['[JUNCTIONS]', 'J9 3'] },
      'then with a line break' => { controls: [rule.merge(then: ["CONDUIT C1 STATUS = OPEN\n[JUNCTIONS]\nJ9 3"])] },
      'if with a line break' => { controls: [rule.merge(if: ["NODE J1 DEPTH > 1\r\n[JUNCTIONS]"])] },
      'else with NUL' => { controls: [rule.merge(else: ["CONDUIT C1 STATUS = CLOSED\0x"])] } }.each do |label, m|
      expect(errors(m)).not_to be_empty, "#{label} must be rejected"
    end
  end

  it 'does not let title lines carry structure' do
    ["#{'T' * 1023}[JUNCTIONS]", "a\rb", "a\0b"].each do |line|
      m = { title: [line, 'J10 3'] }
      expect(errors(m)).not_to be_empty, -> { "title #{line[0, 20].inspect}...: engine view #{SwmmEngineView.violations(m)}" }
    end
  end

  # MAX_LINE is a byte limit (fgets). Input::Renderer#line used to count characters: a 521-character line of 1031 bytes passed,
  # the engine read it as two lines and created a junction nobody wrote (see the engine examples).
  it 'counts the line limit in bytes' do
    m = { junctions: [{ name: 'é' * 510, elevation: 10 }] }
    expect(errors(m).map { it[:path] }).to eq(['junctions[0]']), "engine view: #{SwmmEngineView.violations(m) if errors(m).empty?}"
  end

  it 'has exact line and item limits for ASCII' do
    pad = ->(n) { { junctions: [['J9', 5, 0, 0, 0, 0, 'x' * n]] } } # "J9 5 0 0 0 0 " is 13 characters
    expect(errors(pad.call(1010))).to be_empty, '1023 characters is the longest line'
    expect(errors(pad.call(1011))).to eq([{ path: 'junctions[0]', message: 'line is 1024 characters; SWMM reads at most 1023' }])
    expect(errors(junctions: [{ name: 'x' * 1013, elevation: 1 }])).to be_empty, "Hash row: name + ' 1 0 0 0 0' = 1023"
    expect(errors(junctions: [{ name: 'x' * 1014, elevation: 1 }])).not_to be_empty
    expect(errors(options: { tempdir: 'd' * 1002 })).to be_empty, 'the padded option keyword counts: 20 + 1 + 1002'
    expect(errors(options: { tempdir: 'd' * 1003 }).map { it[:path] }).to eq(['options.tempdir'])

    expect(errors(junctions: [Array.new(40) { 'x' }])).to be_empty
    expect(errors(junctions: [Array.new(41) { 'x' }])).to eq([{ path: 'junctions[0]', message: 'line has 41 items; SWMM reads at most 40' }])
    expect(errors(junctions: [Array.new(39) { 'x' } + ['a b']])).to be_empty, 'a quoted token is one item'
    expect(errors(profiles: [{ name: 'P', links: Array.new(39) { 'L' } }])).not_to be_empty, 'list count also guards the items'
  end

  it 'rejects NUL in ids and expressions' do
    expect(errors(inflows: [{ node: 'J1', series: "Q\0x", scale_factor: 2 }])).not_to be_empty
    expect(errors(junctions: [{ name: "J\0x", elevation: 1 }])).not_to be_empty
    expect(errors(gwf: [{ subcatchment: 'S', flow: 'LATERAL', expression: "1\0" }])).not_to be_empty
  end

  # ---- scalars -----------------------------------------------------------------------------------------------------

  # Current behaviour, acceptable: ASCII whitespace at the ends is stripped; inner ASCII whitespace is rejected in
  # identifiers (the engine's counting pass ignores quotes) and quoted in labels and paths; Unicode spaces are ordinary
  # characters for both Ruby's \s and the engine's " \t\n\r", so they stay inside an unquoted token (two ids that look the
  # same may differ).
  it 'handles whitespace in ids' do
    t = Swmm::Types
    expect(t.id(" \tJ1\n ")).to eq('J1')
    expect { t.id("\0J1\0") }.to raise_error(ArgumentError), 'NUL is rejected before the strip can swallow it'
    expect(t.label("a\tb")).to eq(%("a\tb")), 'labels, paths and tags are quoted'
    ["a\tb", "a\vb", 'a b'].each { |v| expect { t.id(v) }.to raise_error(ArgumentError), v.inspect }
    ['J 1', ' J1', 'J1 ', '　', "J\u2028x", "J\u0085x"].each { expect(t.id(it)).to eq(it) }
    expect { t.id(" \t ") }.to raise_error(ArgumentError)
    expect(t.opt_id('')).to eq('""')
    expect(t.id(:J1)).to eq('J1')
    expect(t.id(-7)).to eq('-7')
    [nil, true, 1.5, [], {}].each { |v| expect { t.id(v) }.to raise_error(ArgumentError), v.inspect }
    expect(t.id('x' * 5000)).to eq('x' * 5000), 'ids have no length limit of their own; the line limit applies'
  end

  it 'handles numbers' do
    t = Swmm::Types
    [Float::NAN, Float::INFINITY, -Float::INFINITY, Float::MAX * 2, JSON.parse('[-1e400]')[0]].each { |v| expect { t.num(v) }.to raise_error(ArgumentError), v.to_s }
    [Complex(1, 0), '1', '1.5', nil, true, false, :one].each { |v| expect { t.num(v) }.to raise_error(ArgumentError), v.inspect }
    expect(t.num(-0.0)).to eq('-0.0')
    expect(t.num(Rational(1, 3))).to eq('0.3333333333333333')
    expect(t.num(2**64)).to eq('18446744073709551616')
    expect(t.num(5e-324)).to eq('5.0e-324')
    expect(t.num(Float::MAX)).to eq('1.7976931348623157e+308')
    rng = Random.new(1234)
    1000.times do
      f = (rng.rand - 0.5) * (10**rng.rand(-300..300).to_f)
      s = t.num(f)
      expect(s).to match(/\A-?\d+\.\d+(e[+-]\d+)?\z/)
      expect(Float(s)).to eq(f), "#{f} must round-trip"
    end
    expect { t.int(1.0) }.to raise_error(ArgumentError)
    expect(t.int(0)).to eq('0')
  end

  # num rejects Float::INFINITY, but an Integer beyond the Float range is written in full and strtod reads it as
  # infinity: Swmm.run with junction elevation 10**309 finishes "ok" with the node full and no flow.
  it 'rejects Integers beyond the Float range like infinity' do
    expect { Swmm::Types.num(10**309) }.to raise_error(ArgumentError)
  end

  # A Numeric subclass without #to_f used to make validate raise TypeError instead of listing the error.
  it 'takes a Numeric that cannot become a Float as a contract error' do
    unfloatable = Class.new(Numeric)
    expect(errors(junctions: [{ name: 'J', elevation: unfloatable.new }]).map { it[:path] }).to eq(['junctions[0].elevation'])
    expect { Swmm::Types.num(unfloatable.new) }.to raise_error(ArgumentError)
  end

  it 'handles yes/no, words and case' do
    t = Swmm::Types
    expect([true, false, 'yes', :No].map { t.yn(it) }).to eq(%w[YES NO YES NO])
    ['y', 1, 0, nil, 'true'].each { |v| expect { t.yn(v) }.to raise_error(ArgumentError), v.inspect }
    expect(t.one_of(%w[FREE FIXED], :free)).to eq('FREE')
    expect(t.one_of(%w[3 4 5], 5)).to eq('5')
    # Unicode case folding: the ligature folds to "fi". Harmless, the canonical word is what gets written.
    expect(t.one_of(%w[FREE FIXED], 'ﬁxed')).to eq('FIXED')
    expect { t.one_of(%w[FREE], ' FREE') }.to raise_error(ArgumentError)

    plain = inp(junctions: [{ name: 'J', elevation: 1 }], options: { flow_units: 'LPS' })
    expect(inp('JUNCTIONS' => [{ 'NAME' => 'J', 'Elevation' => 1 }], '[OPTIONS]' => { 'Flow_Units' => :lps })).to eq(plain)
  end

  it 'handles dates and times' do
    t = Swmm::Types
    expect([Date.new(2026, 3, 24), DateTime.new(2026, 3, 24, 23), '3/4/2026', Time.new(2026, 3, 24, 23, 59, 0, '+05:00')].map { t.date(it) })
      .to eq(%w[03/24/2026 03/24/2026 03/04/2026 03/24/2026])
    ['2026-02-30', '02/30/2026', '13/01/2026', '2026-3-4', ' 2026-03-24', "2026-03-24\n", '24/03/2026', 20_260_324, nil].each do |v|
      expect { t.date(v) }.to raise_error(ArgumentError), v.inspect
    end
    expect([900, 3600, Time.utc(2026, 1, 1, 5, 6, 7)].map { t.time(it) }).to eq(%w[0:15:00 1:00:00 05:06:07])
    [-1, 900.0, '10:00:00.5', '10', '1:2', nil].each { |v| expect { t.time(v) }.to raise_error(ArgumentError), v.inspect }
    # current behaviour: the clock pattern does not range-check; "1:60" / "24:00" / "999:59:59" are left to the engine
    expect(%w[1:60 24:00 999:59:59].map { t.time(it) }).to eq(%w[1:60 24:00 999:59:59])
    expect(['2026-03-24T10:00:00.000Z', '03/24/2026 10:00 UTC', '0:30', 0.5].map { t.stamp(it) })
      .to eq([%w[03/24/2026 10:00:00], %w[03/24/2026 10:00], ['0:30'], ['0.5']])
    # current behaviour, surprising: a DateTime is a Date, not a Time, so a time series point cannot use one
    expect { t.stamp(DateTime.new(2026, 3, 24, 10)) }.to raise_error(ArgumentError)
    expect { t.stamp(Float::NAN) }.to raise_error(ArgumentError)
  end

  # ---- validate must report, never raise ---------------------------------------------------------------------------

  # Strings from File.binread / an HTTP body are BINARY; Latin-1 and UTF-16 strings exist too. Several used to reach
  # code outside convert_one's `rescue ArgumentError`.
  it 'reports strings in other encodings instead of raising' do
    latin1 = (+"Po\xE7o").force_encoding('ISO-8859-1')
    cases = {
      'binary + UTF-8 rows' => { junctions: [{ name: "\xFF".b, elevation: 1 }, { name: 'Poço', elevation: 1 }] },
      'binary + UTF-8 in one row' => { conduits: [{ name: 'Poço', from_node: "\xFF".b, to_node: 'B', length: 1, roughness: 1, in_offset: 0, out_offset: 0 }] },
      'Latin-1 + UTF-8' => { junctions: [{ name: latin1, elevation: 1 }, { name: 'Poço', elevation: 1 }] },
      'UTF-16 name' => { junctions: [{ name: 'J1'.encode('UTF-16LE'), elevation: 1 }] },
      'invalid UTF-8 section key' => { "\xFF" => 1 },
      'invalid UTF-8 column key' => { junctions: [{ "\xFF" => 1 }] },
      'invalid UTF-8 title' => { title: "\xFF" },
      'invalid UTF-8 report' => { report: { nodes: "\xFF" } },
      'invalid UTF-8 rule clause' => { controls: [{ name: 'R', if: ['a', "\xFF"], then: ['b'] }] },
      'invalid UTF-8 in a column others depend on' => { outfalls: [{ name: 'O', elevation: 1, type: "\xFF" }] }
    }
    raised = cases.filter_map do |label, m|
      described_class.validate(m)
      nil
    rescue StandardError => e
      "#{label}: #{e.class}: #{e.message}"
    end
    expect(raised).to be_empty, show(raised)
  end

  it 'reports Symbol dates instead of raising' do
    [:'03/24/2026', :'2026-03-24'].each do |d|
      expect(described_class.validate(options: { start_date: d })).to be_a(Array)
    end
  end

  # JSON allows {"junctions": [...], "JUNCTIONS": [...]}; symbolize used to keep only the last one.
  it 'does not lose data to keys that differ only in case' do
    m = { junctions: [{ name: 'A', elevation: 1 }], 'JUNCTIONS' => [{ name: 'B', elevation: 2 }] }
    expect(errors(m)).not_to be_empty, 'two sections for one name'
    row = { junctions: [{ name: 'A', 'NAME' => 'B', elevation: 1 }] }
    expect(errors(row)).not_to be_empty, 'two names for one row'
  end

  it 'reports wrong containers' do
    expect(errors(nil)).to eq([{ path: 'input', message: 'must be a Hash' }])
    expect(errors([])).to eq([{ path: 'input', message: 'must be a Hash' }])
    expect(inp({})).to eq("\n"), 'an empty model is valid (the engine then reports error 191)'
    {
      { junctions: { name: 'J' } } => ['junctions'], { junctions: 'J' } => ['junctions'], { junctions: [nil, 1, 'x'] } => %w[junctions[0] junctions[1] junctions[2]],
      { options: [1] } => ['options'], { report: 'ALL' } => ['report'], { evaporation: [[1]] } => ['evaporation'],
      { timeseries: [{ name: 'T', points: [[0]] }] } => ['timeseries[0].points[0]'], { curves: [{ name: 'C', type: 'STORAGE', points: {} }] } => ['curves[0].points'],
      { patterns: [{ name: 'P', type: 'DAILY', factors: '1' }] } => ['patterns[0].factors'], { junctions: [{ name: { a: 1 }, elevation: [1] }] } => %w[junctions[0].elevation junctions[0].name],
      { coverages: [{ subcatchment: 'S', landuses: 'LU1' }] } => ['coverages[0].landuses']
    }.each { |m, paths| expect(errors(m).map { it[:path] }.sort).to eq(paths), m.inspect }
    # current behaviour: an empty Hash or Array is "nothing given" whatever the section expects
    expect(inp(junctions: {}, options: [], report: [], title: [])).to eq("\n")
  end

  it 'renders the same file for frozen and JSON inputs' do
    Dir.mktmpdir do |dir|
      model = SwmmFixtures.full(dir)
      expect(inp(Ractor.make_shareable(Marshal.load(Marshal.dump(model))))).to eq(inp(model))
    end
    expect(inp(JSON.parse(JSON.generate(SwmmFixtures.base)))).to eq(inp(SwmmFixtures.base))
  end

  # Property: on any input, validate returns a list of {path:, message:} and Input.new raises only InvalidInput.
  def check_contract(model, label)
    found = described_class.validate(model)
    expect(found).to be_a(Array), label
    expect(found.all? { it.keys == %i[path message] && it[:path].is_a?(String) && it[:message].is_a?(String) }).to be(true), label
    begin
      expect(described_class.new(model).to_inp).to be_a(String), label
      expect(found).to be_empty, label
    rescue Swmm::InvalidInput => e
      expect(e.errors).to eq(found), label
    end
  rescue Swmm::InvalidInput
    raise
  rescue StandardError => e
    RSpec::Expectations.fail_with("#{label}: #{e.class}: #{e.message[0, 200]}")
  end

  it 'never raises in validate on generated garbage' do
    rng = Random.new(1234)
    Dir.mktmpdir do |dir|
      full = SwmmFixtures.full(dir)
      paths = SwmmGarbage.leaf_paths(full)
      Timeout.timeout(10) do
        200.times { |i| check_contract(Swmm::Schema::SECTIONS.keys.sample(random: rng).then { { it => SwmmGarbage.garbage(rng) } }, "section garbage ##{i}") }
        200.times { |i| check_contract(SwmmGarbage.garbage(rng), "top-level garbage ##{i}") }
        400.times do |i|
          m = Marshal.load(Marshal.dump(full))
          picked = Array.new(1 + rng.rand(3)) { paths.sample(random: rng) }
          picked.each do |p|
            parent = p[0..-2].reduce(m) { |o, k| o.is_a?(Hash) || o.is_a?(Array) ? o[k] : nil }
            parent[p.last] = SwmmGarbage.garbage(rng) if parent.is_a?(Hash) || (parent.is_a?(Array) && p.last.is_a?(Integer))
          end
          check_contract(m, "mutant ##{i} at #{picked.inspect}")
        end
      end
    end
  end

  # The same defects seen through the real engine. A model that crashes the process runs in a child Ruby.
  context 'with the engine', :libswmm5 do
    def run_model(model) = Timeout.timeout(10) { Swmm.run(model) }

    def base_plus(**extra) = SwmmFixtures.base.tap { |m| extra.each { |s, rows| m[s] = (m[s] || []) + rows } }

    it 'does not let section header names change the model silently' do
      %w[[JUNCTIONS] [OUTFALLS]].each do |name|
        m = base_plus(junctions: [{ name: name, elevation: 1 }])
        next if described_class.validate(m).any? # rejected at the cause

        result = run_model(m)
        expect(!result.ok? || result.nodes.ids.include?(name)).to be(true), "#{name}: run is ok but the node is gone: #{result.nodes.ids}"
      end
    end

    # The reproduction from the test plan: in the middle of [JUNCTIONS] the same name re-routed the next rows into
    # [OUTFALLS] and the run failed with the generic 200 (ERROR 205 on J2), far from the cause. Now the contract names it.
    it 'rejects a section header name before other rows at the cause' do
      m = SwmmFixtures.base.merge(junctions: [SwmmFixtures.base[:junctions][0], { name: '[OUTFALLS]', elevation: 1 }, SwmmFixtures.base[:junctions][1]])
      expect(described_class.validate(m)).to eq([{ path: 'junctions[1].name', message: %(must not start with "[") }])
      expect { Swmm.run(m) }.to raise_error(Swmm::InvalidInput)
    end

    # Any leading "[" is refused, not only the known section names: the engine reads the line as a header anyway.
    it 'rejects a name that starts with a bracket even when it is not a known section' do
      m = base_plus(junctions: [{ name: '[FOO]', elevation: 1 }])
      expect(described_class.validate(m)).to eq([{ path: 'junctions[2].name', message: %(must not start with "[") }])
    end

    # Pass 1 (strtok) reads the quoted name as the object '"[JUNCTIONS]', pass 2 (getTokens) as a header: the object
    # counts disagree and libswmm5 dereferences NULL in swmm_open/output_open. SIGSEGV takes the whole Ruby process.
    it 'does not let a quoted section header name kill the process' do
      {
        'junction [JUNCTIONS] x' => base_plus(junctions: [{ name: '[JUNCTIONS] x', elevation: 1 }]),
        'junction [OUTFALLS]<tab>x' => base_plus(junctions: [{ name: "[OUTFALLS]\tx", elevation: 1 }]),
        'time series [REPORT] x' => base_plus(timeseries: [{ name: '[REPORT] x', points: [[0, 1]] }])
      }.each do |label, m|
        next if described_class.validate(m).any?

        script = 'require "swmm_standalone"; r = Swmm.run(Marshal.load($stdin.read)); print r.ok? || r.error[:code].is_a?(Integer)'
        out, status = Timeout.timeout(20) do
          Open3.capture2(RbConfig.ruby, '-I', File.expand_path('../../support', __dir__), '-e', script, stdin_data: Marshal.dump(m), err: File::NULL)
        end
        expect(status.success? && out == 'true').to be(true), "#{label}: child Ruby #{status.inspect}"
      end
    end

    # getTokens understands quotes, the counting pass (strtok) does not: an object whose name holds a blank is
    # counted as '"J' and then looked up as 'J 1'. The contract quotes such names but the engine can never define
    # them; it fails with ERROR 209 on every line that uses the name.
    it 'lets names with blanks be used' do
      b = SwmmFixtures.base
      m = b.merge(junctions: [b[:junctions][0].merge(name: 'J 1'), b[:junctions][1]],
                  conduits: [b[:conduits][0].merge(from_node: 'J 1'), b[:conduits][1]], inflows: [{ node: 'J 1', series: 'Q' }])
      next if described_class.validate(m).any? # rejected at the cause

      result = run_model(m)
      expect(result).to be_ok, result.error.inspect
    end

    # Typed Hash rows only: a 521-character (1032-byte) junction line passed the contract; fgets splits it after
    # 1023 bytes and the tail " 0 0 0 0" became a junction named "0". Run is "ok".
    it 'does not split a multibyte line into two objects' do
      name = 'é' * 510
      m = base_plus(junctions: [{ name: name, elevation: 10 }])
      next if described_class.validate(m).any? # the contract counts bytes now

      nodes = run_model(m).nodes.ids
      expect(nodes.sort).to eq(['J1', 'J2', 'O1', name].sort), "nodes: #{nodes.map { it.size > 10 ? "#{it[0, 3]}…" : it }}"
    end

    # The same split with a raw Array row places any row the caller wants: J10 appears from one J9 row.
    it 'does not let a raw row smuggle a second row' do
      m = base_plus(junctions: [['J9', 5, 0, 0, 0, 0, 'é' * 505, 'J10', 3]])
      expect(described_class.validate(m).any? || !run_model(m).nodes.ids.include?('J10')).to be(true), 'J10 was created'
    end

    it 'does not let a title smuggle a section' do
      m = SwmmFixtures.base.merge(title: ["#{'T' * 1023}[JUNCTIONS]", 'J10 3'])
      expect(described_class.validate(m).any? || !run_model(m).nodes.ids.include?('J10')).to be(true), 'J10 was created'
    end

    it 'does not let a control action smuggle a section' do
      m = SwmmFixtures.base.merge(controls: [{ name: 'R', if: ['NODE J1 DEPTH > 100'], then: ["CONDUIT C1 STATUS = OPEN\n[JUNCTIONS]\nJ12 3"] }])
      expect(described_class.validate(m).any? || !run_model(m).nodes.ids.include?('J12')).to be(true), 'J12 was created'
    end

    # NUL ends the C string: "J1 FLOW Q\0x FLOW 1.0 2.0 0" is read as "J1 FLOW Q", so scale_factor 2 is ignored.
    it 'does not let NUL drop the rest of the line' do
      scaled = SwmmFixtures.base.merge(inflows: [{ node: 'J1', series: 'Q', scale_factor: 2 }])
      with_nul = SwmmFixtures.base.merge(inflows: [{ node: 'J1', series: "Q\0x", scale_factor: 2 }])
      next if described_class.validate(with_nul).any? # rejected at the cause

      expect(run_model(with_nul).links['C2'][:flow].values.max).to eq(run_model(scaled).links['C2'][:flow].values.max)
    end

    it 'runs the longest accepted lines as written' do
      full_line = base_plus(junctions: [['J9', 5, 0, 0, 0, 0, 'x' * 1010]]) # 1023 characters
      forty = base_plus(junctions: [['J9', 5, 0, 0, 0, 0, *Array.new(34) { 'x' }]]) # 40 items
      [full_line, forty].each do |m|
        expect(SwmmEngineView.violations(m)).to be_empty
        result = run_model(m)
        expect(result).to be_ok, result.error.inspect
        expect(result.nodes.ids.sort).to eq(%w[J1 J2 J9 O1])
      end
    end

    # Accepted-but-odd models: the outcome is a normal Result (ok, or an engine error with an Integer code).
    it 'gives odd accepted models back as results' do
      b = SwmmFixtures.base
      nbsp = 'J 1'
      models = {
        'empty model' => [{}, 191],
        'title only' => [{ title: 'only a title' }, 191],
        'unicode-space id' => [b.merge(junctions: [b[:junctions][0].merge(name: nbsp), b[:junctions][1]],
                                       conduits: [b[:conduits][0].merge(from_node: nbsp), b[:conduits][1]], inflows: [{ node: nbsp, series: 'Q' }]), 0],
        'Latin-1 id alone' => [base_plus(junctions: [{ name: (+"Po\xE7o").force_encoding('ISO-8859-1'), elevation: 1 }]), 0],
        'binary id alone' => [base_plus(junctions: [{ name: "Po\xC3\xA7o".b, elevation: 1 }]), 0],
        'elevation 1e308' => [base_plus(junctions: [{ name: 'J9', elevation: 1e308 }]), nil],
        'barrels 2**40' => [b.merge(xsections: [b[:xsections][0].merge(barrels: 2**40), b[:xsections][1]]), 200],
        'start_time 99:99' => [b.merge(options: b[:options].merge(start_time: '99:99')), nil],
        'empty raw row' => [base_plus(junctions: [[]]), 0]
      }
      models.each do |label, (m, code)|
        expect(described_class.validate(m)).to be_empty, label
        result = run_model(m)
        expect(result).to be_a(Swmm::Result)
        expect(result.ok? || result.error[:code].is_a?(Integer)).to be(true), label
        expect(result.ok? ? 0 : result.error[:code]).to eq(code), label if code
      end
      expect(run_model(models['unicode-space id'][0]).nodes.ids).to include(nbsp), 'a Unicode space is part of the id end to end'
    end
  end
end
