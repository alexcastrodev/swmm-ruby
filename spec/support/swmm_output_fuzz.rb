# Front B of docs/test-plan.md (risk R2): hostile or corrupted .out bytes.
# Contract: Swmm::OutputFile.new(bytes) builds a valid reader or raises Swmm::OutputFormatError, in bounded time and
# memory; on an accepted file every public reader works and values are Float or nil.
# Mutations start from real files written by the engine (SwmmFixtures.base and SwmmFixtures.full) and are seeded.
module SwmmOutputFuzz
  # Raised by the guard below instead of letting the reader unpack more int32 than the file holds: a count of 2**31-1
  # in a variable block makes String#unpack pad ~2**31 nils (5 GB, 4 s for a 19 KB file). With the guard an example that
  # still meets that bug fails at once instead of exhausting memory.
  class HugeRead < StandardError
  end

  module Guard
    private

    def read_ints(count)
      raise HugeRead, "asked to unpack #{count} int32 from a #{@bytes.bytesize}-byte file" if Thread.current[:output_fuzz_guard] && count.is_a?(Integer) && count > @bytes.bytesize / 4

      super
    end
  end
  Swmm::OutputReader.prepend(Guard) # inert unless an example of the fuzz spec turns the flag on

  INT_EXTREMES = [0, -1, 1, (2**31) - 1, -(2**31)].freeze

  # per-process cache of the two real files
  def self.real_files = @real_files ||= {}

  module_function

  def real(name)
    SwmmOutputFuzz.real_files[name] ||= Dir.mktmpdir do |dir|
      model = name == :base ? SwmmFixtures.base : SwmmFixtures.full(dir)
      File.binread(Swmm.run(model, dir: dir).files[:out]).freeze
    end
  end

  def each_file(&) = %i[base full].each { |name| yield name, real(name), layout(real(name)) }

  def i32(bytes, offset, value) = bytes.dup.tap { it[offset, 4] = [value].pack('l<') }
  def f64(bytes, offset, value) = bytes.dup.tap { it[offset, 8] = [value].pack('E') }

  def flip(bytes, positions) = bytes.dup.tap { |m| positions.each { |pos, bit| m.setbyte(pos, m.getbyte(pos) ^ (1 << bit)) } }

  # Offsets of every structural field of a well-formed file (header layout: see Swmm::OutputReader).
  def layout(bytes)
    _, _, _, n_sub, n_node, n_link, n_pol = bytes.unpack('l<7')
    e = bytes.bytesize - 24
    at = { magic: 0, version: 4, units: 8, n_sub: 12, n_node: 16, n_link: 20, n_pol: 24,
           id_pos: e, input_pos: e + 4, output_pos: e + 8, periods: e + 12, error: e + 16, magic_end: e + 20 }
    cursor = 28
    at[:id_lens] = Array.new(n_sub + n_node + n_link + n_pol) { cursor.tap { cursor += 4 + bytes.unpack1('l<', offset: cursor) } }
    at[:pol_units] = cursor
    at[:input] = cursor += 4 * n_pol
    cursor += 8 + (4 * n_sub) + 16 + (12 * n_node) + 24 + (20 * n_link)
    at[:var_counts] = []
    at[:var_codes] = []
    4.times do
      at[:var_counts] << cursor
      at[:var_codes] << (cursor + 4)
      cursor += 4 + (4 * bytes.unpack1('l<', offset: cursor))
    end
    at[:start] = cursor
    at[:step] = cursor + 8
    at[:output] = cursor + 12
    at
  end

  # nil when the bytes were rejected with OutputFormatError, the reader when accepted; anything else is recorded.
  def build(bytes, label, violations)
    Swmm::OutputFile.new(bytes:)
  rescue Swmm::OutputFormatError
    nil
  rescue StandardError, NoMemoryError => e
    violations << "#{label}: OutputFile.new raised #{e.class}: #{e.message[0, 90]}"
    nil
  end

  # Every public reader of an accepted file. UnknownObject is only allowed for ids/variables the file does not list.
  def read_everything(out, label, violations)
    Swmm::OutputFile::KINDS.each do |kind|
      objects = out[kind]
      all = objects.to_h
      violations << "#{label}: #{kind}.to_h lost objects" unless all.size == objects.ids.uniq.size
      objects.ids.each do |id|
        objects.variables.each do |var|
          values = objects[id][var].values
          violations << "#{label}: #{kind} #{id} #{var} has #{values.size} values" unless values.size == out.periods
          bad = values.find { !(it.nil? || (it.is_a?(Float) && it.finite?)) }
          violations << "#{label}: #{kind} #{id} #{var} holds #{bad.inspect}" if bad
        end
      end
      objects.units
      objects.variables.each { objects.frames(it) }
      violations << "#{label}: #{kind}.records has not one per period and object" unless objects.records.count == objects.size * out.periods
      read_types(objects) if Swmm::OutputFile::TYPES.key?(kind)
    end
    out.times
    result = Swmm::Result.new(version: 52_004, raw: { code: 0, continuity: {} }, report: '', output: out, files: nil)
    Swmm::OutputFile::KINDS.each { result[it].to_csv }
    result.to_json
  rescue StandardError => e
    violations << "#{label}: reader raised #{e.class}: #{e.message[0, 90]}"
  end

  # The types are read when asked for: a corrupted type code is an OutputFormatError there, nothing else
  def read_types(objects)
    objects.count_by_type
  rescue Swmm::OutputFormatError => e
    raise unless e.message.include?('type code')
  end

  # Runs every case under the allocation guard and one overall timeout; returns the violations and the accepted readers.
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
end
