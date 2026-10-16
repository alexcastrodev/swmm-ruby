# frozen_string_literal: true

require "test_helper"
require "timeout"

# Front B of docs/test-plan.md (risk R2): hostile or corrupted .out bytes.
# Contract: Swmm::OutputFile.new(bytes) builds a valid reader or raises Swmm::OutputFormatError, in bounded time and
# memory; on an accepted file every public reader works and values are Float or nil.
# Mutations start from real files written by the engine (Fixtures.base and Fixtures.full) and are seeded.
module OutputFuzz
  # Raised by the guard below instead of letting the reader unpack more int32 than the file holds: a count of 2**31-1
  # in a variable block makes String#unpack pad ~2**31 nils (5 GB, 4 s for a 19 KB file). With the guard a test that
  # still meets that bug fails at once instead of exhausting memory.
  HugeRead = Class.new(StandardError)

  module Guard
    private

    def read_ints(n)
      if Thread.current[:output_fuzz_guard] && n.is_a?(Integer) && n > @bytes.bytesize / 4
        raise HugeRead, "asked to unpack #{n} int32 from a #{@bytes.bytesize}-byte file"
      end

      super
    end
  end
  Swmm::OutputFile.prepend(Guard) # inert unless a test of this file turns the flag on

  INT_EXTREMES = [0, -1, 1, (2**31) - 1, -(2**31)].freeze

  module_function

  def i32(bytes, offset, value) = bytes.dup.tap { _1[offset, 4] = [value].pack("l<") }
  def f64(bytes, offset, value) = bytes.dup.tap { _1[offset, 8] = [value].pack("E") }

  def flip(bytes, positions) = bytes.dup.tap { |m| positions.each { |pos, bit| m.setbyte(pos, m.getbyte(pos) ^ (1 << bit)) } }

  # Offsets of every structural field of a well-formed file (header layout: see Swmm::OutputFile).
  def layout(b)
    _, _, _, n_sub, n_node, n_link, n_pol = b.unpack("l<7")
    e = b.bytesize - 24
    at = { magic: 0, version: 4, units: 8, n_sub: 12, n_node: 16, n_link: 20, n_pol: 24,
           id_pos: e, input_pos: e + 4, output_pos: e + 8, periods: e + 12, error: e + 16, magic_end: e + 20 }
    cursor = 28
    at[:id_lens] = Array.new(n_sub + n_node + n_link + n_pol) { cursor.tap { cursor += 4 + b.unpack1("l<", offset: cursor) } }
    at[:pol_units] = cursor
    at[:input] = cursor += 4 * n_pol
    cursor += 8 + (4 * n_sub) + 16 + (12 * n_node) + 24 + (20 * n_link)
    at[:var_counts] = []
    at[:var_codes] = []
    4.times do
      at[:var_counts] << cursor
      at[:var_codes] << (cursor + 4)
      cursor += 4 + (4 * b.unpack1("l<", offset: cursor))
    end
    at[:start] = cursor
    at[:step] = cursor + 8
    at[:output] = cursor + 12
    at
  end

  # nil when the bytes were rejected with OutputFormatError, the reader when accepted; anything else is recorded.
  def build(bytes, label, violations)
    Swmm::OutputFile.new(bytes)
  rescue Swmm::OutputFormatError
    nil
  rescue StandardError, NoMemoryError => e
    violations << "#{label}: OutputFile.new raised #{e.class}: #{e.message[0, 90]}"
    nil
  end

  # Every public reader of an accepted file. KeyError is only allowed for ids/variables the file does not list.
  def read_everything(out, label, violations)
    Swmm::OutputFile::KINDS.each do |kind|
      ids = kind == :system ? ["system"] : out.ids.fetch(kind)
      all = out.all_series(kind)
      violations << "#{label}: all_series(#{kind}) lost objects" unless all.size == ids.uniq.size
      ids.each do |id|
        out.variables.fetch(kind).each do |var|
          values = out.series(kind, id, var)
          violations << "#{label}: #{kind} #{id} #{var} has #{values.size} values" unless values.size == out.periods
          bad = values.find { !(_1.nil? || (_1.is_a?(Float) && _1.finite?)) }
          violations << "#{label}: #{kind} #{id} #{var} holds #{bad.inspect}" if bad
        end
      end
    end
    out.times
    out.units
    result = Swmm::Result.new(version: 52_004, raw: { code: 0, continuity: {} }, report: "", output: out, files: nil)
    Swmm::OutputFile::KINDS.each { result.to_csv(_1) }
    result.to_json
  rescue StandardError => e
    violations << "#{label}: reader raised #{e.class}: #{e.message[0, 90]}"
  end

  # Runs every case under the allocation guard and one overall timeout; returns the readers that were accepted.
  def check(cases, readers: true)
    violations = []
    accepted = []
    Thread.current[:output_fuzz_guard] = true
    Timeout.timeout(10) do
      cases.each do |label, bytes|
        out = build(bytes, label, violations) or next
        read_everything(out, label, violations) if readers
        accepted << [label, out]
      end
    end
    [violations, accepted]
  ensure
    Thread.current[:output_fuzz_guard] = nil
  end

  def assert_contract(test, cases, readers: true)
    violations, accepted = check(cases, readers: readers)
    test.assert violations.empty?, "#{violations.size} of #{cases.size} cases broke the contract:\n#{violations.first(15).join("\n")}"
    accepted
  end
end

# Bytes built by hand: no engine needed.
class OutputFuzzSyntheticTest < Minitest::Test
  MAGIC = Swmm::OutputFile::MAGIC

  def test_short_or_foreign_strings_raise_format_error
    cases = ["", "x", "\0" * 51, "\0" * 52, "x" * 52, "\xFF".b * 52, [MAGIC].pack("l<") * 13, "é" * 26]
    cases.each_with_index { |s, i| assert_raises(Swmm::OutputFormatError, "case #{i}") { Swmm::OutputFile.new(s) } }
  end

  def test_header_only_file_of_the_minimum_size_raises_format_error
    skip "BUG: a 52-byte file with both magics and zero counts raises ArgumentError (offset outside of string) in OutputFile#read_ints"
    header = [MAGIC, 52_004, 4, 0, 0, 0, 0].pack("l<7")
    [28, 52].each do |output_pos|
      bytes = header + [28, 28, output_pos, 0, 0, MAGIC].pack("l<6")
      assert_raises(Swmm::OutputFormatError, "output_pos #{output_pos}") { Swmm::OutputFile.new(bytes) }
    end
  end

  def test_non_string_input_raises_a_clear_error
    skip "BUG: nil / Integer / Symbol / Array / IO raise NoMethodError (undefined method 'b') in OutputFile#initialize"
    [nil, 1, :out, [], $stdin, 1.5].each do |input|
      assert_raises(Swmm::OutputFormatError, TypeError, input.inspect) { Swmm::OutputFile.new(input) }
    end
  end
end

# Mutations of real engine output.
class OutputFuzzTest < Minitest::Test
  include NeedsEngine
  include OutputFuzz

  FILES = {} # per-process cache of the two real files

  def real(name)
    FILES[name] ||= Dir.mktmpdir do |dir|
      model = name == :base ? Fixtures.base : Fixtures.full(dir)
      File.binread(Swmm.run(model, dir: dir).files[:out]).freeze
    end
  end

  def each_file(&) = %i[base full].each { |name| yield name, real(name), layout(real(name)) }

  def test_layout_helper_matches_the_reader
    each_file do |name, bytes, at|
      out = Swmm::OutputFile.new(bytes)
      assert_equal bytes.unpack1("l<", offset: at[:output_pos]), at[:output], name
      assert_equal out.variables.values.map(&:size), at[:var_counts].map { bytes.unpack1("l<", offset: _1) }, name
      assert_equal out.report_step, bytes.unpack1("l<", offset: at[:step]), name
    end
    assert_equal 2, Swmm::OutputFile.new(real(:full)).pollutants.size, "full model must exercise pollutants"
    refute_empty Swmm::OutputFile.new(real(:full)).ids[:subcatchments]
  end

  # --- passing today --------------------------------------------------------------------------------------------

  def test_plain_truncation_anywhere_raises_format_error
    rng = Random.new(1234)
    each_file do |name, bytes, at|
      cuts = [0, 1, 4, 27, 28, 51, 52, at[:pol_units], at[:input], *at[:var_counts], at[:start], at[:output],
              at[:output] + 8, bytes.bytesize - 24, bytes.bytesize - 1] + Array.new(40) { rng.rand(bytes.bytesize) }
      assert_contract(self, cuts.map { ["#{name} cut #{_1}", bytes[0, _1]] }, readers: false)
      cuts.each { |c| assert_raises(Swmm::OutputFormatError, "#{name} cut #{c}") { Swmm::OutputFile.new(bytes[0, c]) } }
    end
  end

  def test_truncated_periods_with_the_epilogue_kept_raise_format_error
    rng = Random.new(1234)
    each_file do |name, bytes, at|
      tail = bytes[-24, 24]
      body = bytes.bytesize - 24
      cuts = [at[:start], at[:step], at[:output], at[:output] + 4, at[:output] + 8, body - 4, body - 1] +
             Array.new(30) { rng.rand(at[:start]...body) }
      cases = cuts.map { ["#{name} cut #{_1} + epilogue", bytes[0, _1] + tail] }
      cases << ["#{name} trailing garbage", bytes + "\0garbage"] << ["#{name} 4 bytes before epilogue", bytes[0, body] + ("\0" * 4) + tail]
      cases << ["#{name} epilogue twice", bytes + tail]
      assert_contract(self, cases, readers: false)
      cases.each { |label, m| assert_raises(Swmm::OutputFormatError, label) { Swmm::OutputFile.new(m) } }
    end
  end

  def test_magic_and_position_fields_set_to_extremes_raise_format_error
    each_file do |name, bytes, at|
      %i[magic magic_end id_pos input_pos output_pos periods].each do |field|
        INT_EXTREMES.each do |v|
          assert_raises(Swmm::OutputFormatError, "#{name} #{field}=#{v}") { Swmm::OutputFile.new(i32(bytes, at[field], v)) }
        end
      end
      assert_raises(Swmm::OutputFormatError) { Swmm::OutputFile.new(i32(bytes, at[:units], 6)) }
      assert_raises(Swmm::OutputFormatError) { Swmm::OutputFile.new(i32(bytes, at[:units], (2**31) - 1)) }
    end
  end

  def test_bit_flips_in_the_values_area_are_accepted_and_every_reader_holds
    rng = Random.new(1234)
    each_file do |name, bytes, at|
      body = bytes.bytesize - 24
      cases = Array.new(60) do
        positions = Array.new(rng.rand(1..3)) { [rng.rand(at[:output]...body), rng.rand(8)] }
        ["#{name} flip #{positions}", flip(bytes, positions)]
      end
      nan = [Float::NAN].pack("e")
      cases << ["#{name} float NaN/Inf", bytes.dup.tap { |m| m[at[:output] + 8, 12] = nan + [Float::INFINITY, -Float::INFINITY].pack("e2") }]
      accepted = assert_contract(self, cases)
      assert_equal cases.size, accepted.size, "#{name}: a flip in the values area must not make the header invalid"
      out = accepted.last.last
      first = Swmm::OutputFile::KINDS.find { !out.ids.fetch(_1, ["system"]).empty? }
      id = first == :system ? "system" : out.ids[first].first
      assert_equal [nil, nil, nil], out.variables[first].first(3).map { out.series(first, id, _1).first }, "NaN/Infinity read as nil"
    end
  end

  def test_ractor_reads_of_a_mutated_file_equal_the_sequential_read
    rng = Random.new(1234)
    bytes = real(:full)
    at = layout(bytes)
    positions = Array.new(40) { [rng.rand(at[:output]...(bytes.bytesize - 24)), rng.rand(8)] }
    mutated = flip(bytes, positions)
    mutated[at[:output] + 8, 4] = [Float::NAN].pack("e")
    was = [Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from]
    Swmm::OutputFile.ractors = 1
    seq = Swmm::OutputFile.new(mutated)
    result = ->(out) { Swmm::Result.new(version: 52_004, raw: { code: 0, continuity: {} }, report: "", output: out, files: nil) }
    expected = Swmm::OutputFile::KINDS.to_h { [_1, seq.all_series(_1)] }
    expected_csv = Swmm::OutputFile::KINDS.to_h { [_1, result.(seq).to_csv(_1)] }
    Swmm::OutputFile.ractors = 3
    Swmm::OutputFile.parallel_from = 0
    par = Swmm::OutputFile.new(mutated)
    Timeout.timeout(10) do
      assert_equal expected, Swmm::OutputFile::KINDS.to_h { [_1, par.all_series(_1)] }
      assert_equal expected_csv, Swmm::OutputFile::KINDS.to_h { [_1, result.(par).to_csv(_1)] }
    end
  ensure
    Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from = was
  end

  def test_zero_periods_is_an_empty_but_valid_file
    each_file do |name, bytes, at|
      empty = bytes[0, at[:output]] + bytes[-24, 24]
      empty[-12, 4] = [0].pack("l<")
      out = Swmm::OutputFile.new(empty)
      assert_equal [0, []], [out.periods, out.times], name
      assert_empty assert_contract(self, [["#{name} zero periods", empty]]).first.last.series(:system, "system", "rainfall")
      assert_equal 1, Swmm::Result.new(version: 1, raw: { code: 0 }, report: "", output: out, files: nil).to_csv(:links).lines.size
    end
  end

  def test_ids_duplicated_or_not_utf8_are_readable
    bytes = real(:full)
    dup = bytes.dup.tap { _1[_1.index("J2"), 2] = "J1" }
    junk = bytes.dup.tap { _1[_1.index("J3"), 2] = "\xFF\xFE".b }
    quoted = bytes.dup.tap { _1[_1.index("J4"), 2] = "a\"" }
    assert_contract(self, [["duplicated id", dup], ["non-UTF-8 id", junk], ["quote in id", quoted]])
    ids = Swmm::OutputFile.new(junk).ids[:nodes]
    assert ids.all?(&:valid_encoding?), "ids are scrubbed to valid UTF-8"
    assert_equal "��", ids[2]
    # Current behaviour (a corrupted file only: the engine rejects duplicate names): series finds the first "J1",
    # all_series keeps one "J1" entry.
    assert_equal %w[J1 J1], Swmm::OutputFile.new(dup).ids[:nodes].first(2)
    assert_equal 8, Swmm::OutputFile.new(dup).all_series(:nodes).size
  end

  def test_report_step_version_and_error_code_are_taken_as_written
    # Current behaviour: none of these fields is checked. A non-zero error code is exposed as #engine_error (Result.from_files
    # uses it); report_step 0 or negative and any version are passed on as written.
    bytes = real(:base)
    at = layout(bytes)
    assert_equal 0, Swmm::OutputFile.new(i32(bytes, at[:step], 0)).report_step
    assert_equal(-1, Swmm::OutputFile.new(i32(bytes, at[:step], -1)).report_step)
    assert_equal [12, 317], Swmm::OutputFile.new(i32(bytes, at[:error], 317)).then { [_1.periods, _1.engine_error] }
    assert_equal "-1.9.999", Swmm::OutputFile.new(i32(bytes, at[:version], -1)).engine_version
  end

  def test_swmm_read_of_a_corrupted_out_raises_format_error
    skip "BUG: Swmm.read hands on-disk .out bytes to OutputFile.new, so a bad id length surfaces as NoMethodError (#read_ids)"
    Dir.mktmpdir do |dir|
      files = Swmm.run(Fixtures.base, dir: dir).files
      File.binwrite(files[:out], i32(File.binread(files[:out]), 28, -1))
      assert_raises(Swmm::OutputFormatError) { Swmm.read(rpt: files[:rpt], out: files[:out]) }
    end
  end

  def test_frozen_and_differently_encoded_strings_are_read_like_binary
    bytes = real(:base)
    reference = Swmm::OutputFile.new(bytes).all_series(:nodes)
    [bytes.dup.force_encoding(Encoding::UTF_8), bytes.dup.force_encoding(Encoding::UTF_16LE), bytes.dup.freeze].each do |s|
      assert_equal reference, Swmm::OutputFile.new(s).all_series(:nodes), s.encoding.name
    end
    copy = bytes.dup.force_encoding(Encoding::UTF_8)
    Swmm::OutputFile.new(copy)
    assert_equal Encoding::UTF_8, copy.encoding, "the caller's string is not modified"
  end

  # --- BUG: kept as reproductions -------------------------------------------------------------------------------

  def test_huge_variable_count_is_rejected_without_allocating
    skip "BUG: a variable count of 2**31-1 makes OutputFile#read_ints unpack ~2**31 nils (5 GB RSS, ~4 s) before an IndexError"
    each_file do |name, bytes, at|
      at[:var_counts].each_with_index do |offset, k|
        assert_empty check([["#{name} var_count#{k}=2**31-1", i32(bytes, offset, (2**31) - 1)]], readers: false).first
      end
    end
  end

  def test_object_counts_out_of_range_raise_format_error
    skip "BUG: negative object counts raise ArgumentError (negative array size, #read_ids); huge ones ArgumentError (offset outside of string, #read_ints)"
    cases = []
    each_file do |name, bytes, at|
      %i[n_sub n_node n_link n_pol].each { |f| INT_EXTREMES.each { |v| cases << ["#{name} #{f}=#{v}", i32(bytes, at[f], v)] } }
    end
    assert_contract(self, cases)
  end

  def test_id_length_prefixes_out_of_range_raise_format_error
    skip "BUG: id length -1 raises NoMethodError (force_encoding for nil, #read_ids); 0 or past the end ArgumentError (#read_ints)"
    cases = []
    each_file do |name, bytes, at|
      [at[:id_lens].first, at[:id_lens].last].each do |offset|
        [0, -1, -100, bytes.bytesize, (2**31) - 1, -(2**31)].each { |v| cases << ["#{name} id length @#{offset}=#{v}", i32(bytes, offset, v)] }
      end
    end
    assert_contract(self, cases)
  end

  def test_altered_variable_blocks_raise_format_error
    skip "BUG: variable codes past the pollutants raise IndexError (#variable_names), count -1 ArgumentError (#read_ints), negative codes are accepted as nil/duplicate names"
    cases = []
    each_file do |name, bytes, at|
      at[:var_counts].each_with_index { |o, k| [-1, 1, 100].each { |v| cases << ["#{name} var_count#{k}=#{v}", i32(bytes, o, v)] } }
      at[:var_codes].each_with_index { |o, k| [-1, -100, 100, (2**31) - 1].each { |v| cases << ["#{name} var_code#{k}=#{v}", i32(bytes, o, v)] } }
    end
    violations, accepted = check(cases)
    accepted.each { |label, out| out.variables.each { |kind, names| violations << "#{label}: accepted #{kind} variables #{names.inspect}" unless names.all?(String) && names.uniq == names } }
    assert violations.empty?, violations.first(15).join("\n")
  end

  def test_non_finite_dates_raise_format_error_or_read_as_nil
    skip "BUG: a NaN/Infinity start date raises FloatDomainError (#parse); a NaN period date is accepted and then #times raises FloatDomainError"
    cases = []
    each_file do |name, bytes, at|
      [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |v|
        cases << ["#{name} start=#{v}", f64(bytes, at[:start], v)] << ["#{name} period date=#{v}", f64(bytes, at[:output], v)]
      end
    end
    assert_contract(self, cases)
  end

  def test_unit_codes_out_of_range_raise_format_error
    skip "BUG: flow units -1..-6 and pollutant units -1..-3 index FLOW_UNITS / POLLUTANT_UNITS from the end (-1 reads MLD / #/L) in #parse"
    each_file do |name, bytes, at|
      [-1, -6].each { |v| assert_raises(Swmm::OutputFormatError, "#{name} units=#{v}") { Swmm::OutputFile.new(i32(bytes, at[:units], v)) } }
      next if at[:pol_units] == at[:input]

      [-1, 3, 9].each { |v| assert_raises(Swmm::OutputFormatError, "#{name} pollutant unit=#{v}") { Swmm::OutputFile.new(i32(bytes, at[:pol_units], v)) } }
    end
  end

  def test_truncation_with_the_epilogue_kept_anywhere_raises_format_error
    skip "BUG: cuts in the id/input/variable blocks raise ArgumentError, IndexError or NoMethodError (#read_ints, #read_ids, #variable_names)"
    rng = Random.new(1234)
    cases = []
    each_file do |name, bytes, at|
      cuts = [28, 29, 32, *at[:id_lens], at[:pol_units], at[:input], *at[:var_counts], *at[:var_codes]] + Array.new(40) { rng.rand(28...at[:start]) }
      cuts.uniq.each { |c| cases << ["#{name} cut #{c} + epilogue", bytes[0, c] + bytes[-24, 24]] }
    end
    assert_contract(self, cases)
  end

  def test_seeded_corruption_anywhere_keeps_the_contract
    skip "BUG: flips/overwrites before the values area raise IndexError, ArgumentError, NoMethodError or FloatDomainError (#parse and its readers)"
    rng = Random.new(1234)
    cases = []
    each_file do |name, bytes, at|
      60.times do
        positions = Array.new(rng.rand(1..3)) { [rng.rand(bytes.bytesize), rng.rand(8)] }
        cases << ["#{name} flip #{positions}", flip(bytes, positions)]
      end
      (0...at[:output]).step(4) { |o| cases << ["#{name} i32@#{o}=#{v = rng.rand(-1000..1000)}", i32(bytes, o, v)] }
      20.times { o = rng.rand(at[:output] - 8); cases << ["#{name} 8 random bytes @#{o}", bytes.dup.tap { _1[o, 8] = rng.bytes(8) }] }
    end
    assert_contract(self, cases)
  end
end
