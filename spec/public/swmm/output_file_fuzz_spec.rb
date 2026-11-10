require 'timeout'
require_relative '../../swmm_helper'
require_relative '../../support/swmm_output_fuzz'

# Hostile or corrupted .out bytes: see spec/support/swmm_output_fuzz.rb for the contract.
RSpec.describe Swmm::OutputFile, 'with hostile bytes' do
  include SwmmOutputFuzz

  def expect_contract(cases, readers: true)
    violations, accepted = check(cases, readers: readers)
    expect(violations).to be_empty, "#{violations.size} of #{cases.size} cases broke the contract:\n#{violations.first(15).join("\n")}"
    accepted
  end

  context 'with bytes built by hand' do
    let(:magic) { Swmm::OutputReader::MAGIC }

    it 'raises a format error for short or foreign strings' do
      cases = ['', 'x', "\0" * 51, "\0" * 52, 'x' * 52, "\xFF".b * 52, [magic].pack('l<') * 13, 'é' * 26]
      cases.each { |s| expect { described_class.new(bytes: s) }.to raise_error(Swmm::OutputFormatError) }
    end

    it 'raises a format error for a header-only file of the minimum size' do
      header = [magic, 52_004, 4, 0, 0, 0, 0].pack('l<7')
      [28, 52].each do |output_pos|
        bytes = header + [28, 28, output_pos, 0, 0, magic].pack('l<6')
        expect { described_class.new(bytes: bytes) }.to raise_error(Swmm::OutputFormatError)
      end
    end

    it 'raises a clear error for input that is not a String' do
      [nil, 1, :out, [], $stdin, 1.5].each do |input|
        expect { described_class.new(bytes: input) }.to raise_error(a_kind_of(Swmm::OutputFormatError).or(a_kind_of(TypeError)))
      end
    end
  end

  context 'with mutations of real engine output', :libswmm5 do
    it 'has a layout helper that matches the reader' do
      each_file do |name, bytes, at|
        out = described_class.new(bytes: bytes)
        expect(at[:output]).to eq(bytes.unpack1('l<', offset: at[:output_pos])), name.to_s
        expect(at[:var_counts].map { bytes.unpack1('l<', offset: it) }).to eq(Swmm::OutputFile::KINDS.map { out[it].variables.size }), name.to_s
        expect(bytes.unpack1('l<', offset: at[:step])).to eq(out.report_step.in_seconds), name.to_s
      end
      expect(described_class.new(bytes: real(:full)).pollutants.size).to eq(2), 'full model must exercise pollutants'
      expect(described_class.new(bytes: real(:full)).subcatchments.ids).not_to be_empty
    end

    # --- passing today --------------------------------------------------------------------------------------------

    it 'raises a format error for plain truncation anywhere' do
      rng = Random.new(1234)
      each_file do |name, bytes, at|
        cuts = [0, 1, 4, 27, 28, 51, 52, at[:pol_units], at[:input], *at[:var_counts], at[:start], at[:output],
                at[:output] + 8, bytes.bytesize - 24, bytes.bytesize - 1] + Array.new(40) { rng.rand(bytes.bytesize) }
        expect_contract(cuts.map { ["#{name} cut #{it}", bytes[0, it]] }, readers: false)
        cuts.each { |c| expect { described_class.new(bytes: bytes[0, c]) }.to raise_error(Swmm::OutputFormatError), "#{name} cut #{c}" }
      end
    end

    it 'raises a format error for truncated periods with the epilogue kept' do
      rng = Random.new(1234)
      each_file do |name, bytes, at|
        tail = bytes[-24, 24]
        body = bytes.bytesize - 24
        cuts = [at[:start], at[:step], at[:output], at[:output] + 4, at[:output] + 8, body - 4, body - 1] +
               Array.new(30) { rng.rand(at[:start]...body) }
        cases = cuts.map { ["#{name} cut #{it} + epilogue", bytes[0, it] + tail] }
        cases << ["#{name} trailing garbage", bytes.dup.concat("\0garbage")] << ["#{name} 4 bytes before epilogue", bytes[0, body] + ("\0" * 4) + tail]
        cases << ["#{name} epilogue twice", bytes + tail]
        expect_contract(cases, readers: false)
        cases.each { |label, m| expect { described_class.new(bytes: m) }.to raise_error(Swmm::OutputFormatError), label }
      end
    end

    it 'raises a format error for magic and position fields set to extremes' do
      each_file do |name, bytes, at|
        %i[magic magic_end id_pos input_pos output_pos periods].each do |field|
          SwmmOutputFuzz::INT_EXTREMES.each do |v|
            expect { described_class.new(bytes: i32(bytes, at[field], v)) }.to raise_error(Swmm::OutputFormatError), "#{name} #{field}=#{v}"
          end
        end
        expect { described_class.new(bytes: i32(bytes, at[:units], 6)) }.to raise_error(Swmm::OutputFormatError)
        expect { described_class.new(bytes: i32(bytes, at[:units], (2**31) - 1)) }.to raise_error(Swmm::OutputFormatError)
      end
    end

    it 'accepts bit flips in the values area, and every reader holds' do
      rng = Random.new(1234)
      each_file do |name, bytes, at|
        body = bytes.bytesize - 24
        cases = Array.new(60) do
          positions = Array.new(rng.rand(1..3)) { [rng.rand(at[:output]...body), rng.rand(8)] }
          ["#{name} flip #{positions}", flip(bytes, positions)]
        end
        nan = [Float::NAN].pack('e')
        cases << ["#{name} float NaN/Inf", bytes.dup.tap { |m| m[at[:output] + 8, 12] = nan + [Float::INFINITY, -Float::INFINITY].pack('e2') }]
        accepted = expect_contract(cases)
        expect(accepted.size).to eq(cases.size), "#{name}: a flip in the values area must not make the header invalid"
        out = accepted.last.last
        first = described_class::KINDS.find { out[it].size.positive? }
        id = out[first].ids.first
        expect(out[first].variables.first(3).map { out[first][id][it].values.first }).to eq([nil, nil, nil]), 'NaN/Infinity read as nil'
      end
    end

    it 'gives in Ractor reads of a mutated file what the sequential read gives' do
      rng = Random.new(1234)
      bytes = real(:full)
      at = layout(bytes)
      positions = Array.new(40) { [rng.rand(at[:output]...(bytes.bytesize - 24)), rng.rand(8)] }
      mutated = flip(bytes, positions)
      mutated[at[:output] + 8, 4] = [Float::NAN].pack('e')
      was = [described_class.ractors, described_class.parallel_from]
      described_class.ractors = 1
      seq = described_class.new(bytes: mutated)
      result = ->(out) { Swmm::Result.new(version: 52_004, raw: { code: 0, continuity: {} }, report: '', output: out, files: nil) }
      expected = described_class::KINDS.to_h { [it, seq[it].to_h] }
      expected_csv = described_class::KINDS.to_h { [it, result.call(seq)[it].to_csv] }
      described_class.ractors = 3
      described_class.parallel_from = 0
      par = described_class.new(bytes: mutated)
      Timeout.timeout(10) do
        expect(described_class::KINDS.to_h { [it, par[it].to_h] }).to eq(expected)
        expect(described_class::KINDS.to_h { [it, result.call(par)[it].to_csv] }).to eq(expected_csv)
      end
    ensure
      described_class.ractors, described_class.parallel_from = was
    end

    it 'takes zero periods as an empty but valid file' do
      each_file do |name, bytes, at|
        empty = bytes[0, at[:output]] + bytes[-24, 24]
        empty[-12, 4] = [0].pack('l<')
        out = described_class.new(bytes: empty)
        expect([out.periods, out.times]).to eq([0, []]), name.to_s
        expect([out.start_time, out.end_time]).to eq([out.start_time, nil]), name.to_s
        expect(expect_contract([["#{name} zero periods", empty]]).first.last.system['system']['rainfall'].values).to be_empty
        expect(Swmm::Result.new(version: 1, raw: { code: 0 }, report: '', output: out, files: nil).links.to_csv.lines.size).to eq(1)
      end
    end

    it 'reads ids that are duplicated or not UTF-8' do
      bytes = real(:full)
      dup = bytes.dup.tap { it[it.index('J2'), 2] = 'J1' }
      junk = bytes.dup.tap { it[it.index('J3'), 2] = "\xFF\xFE".b }
      quoted = bytes.dup.tap { it[it.index('J4'), 2] = 'a"' }
      expect_contract([['duplicated id', dup], ['non-UTF-8 id', junk], ['quote in id', quoted]])
      ids = described_class.new(bytes: junk).nodes.ids
      expect(ids).to all(be_valid_encoding), 'ids are scrubbed to valid UTF-8'
      expect(ids[2]).to eq('��')
      # Current behaviour (a corrupted file only: the engine rejects duplicate names): series finds the first "J1",
      # all_series keeps one "J1" entry.
      expect(described_class.new(bytes: dup).nodes.ids.first(2)).to eq(%w[J1 J1])
      expect(described_class.new(bytes: dup).nodes.to_h.size).to eq(8)
    end

    it 'takes the report step, version and error code as written' do
      # Current behaviour: none of these fields is checked. A non-zero error code is exposed as #engine_error (Result.from_files
      # uses it); report_step 0 or negative and any version are passed on as written.
      bytes = real(:base)
      at = layout(bytes)
      expect(described_class.new(bytes: i32(bytes, at[:step], 0)).report_step).to eq(Swmm::TimeStep.new(0))
      expect(described_class.new(bytes: i32(bytes, at[:step], -1)).report_step.formatted).to eq('-00:00:01')
      expect(described_class.new(bytes: i32(bytes, at[:error], 317)).then { [it.periods, it.engine_error] }).to eq([12, 317])
      expect(described_class.new(bytes: i32(bytes, at[:version], -1)).engine_version).to eq('-1.9.999')
    end

    it 'raises a format error in Swmm.read of a corrupted .out' do
      Dir.mktmpdir do |dir|
        files = Swmm.run(SwmmFixtures.base, dir: dir).files
        File.binwrite(files[:out], i32(File.binread(files[:out]), 28, -1))
        expect { Swmm.read(rpt: files[:rpt], out: files[:out]) }.to raise_error(Swmm::OutputFormatError)
      end
    end

    it 'reads frozen and differently encoded strings like binary' do
      bytes = real(:base)
      reference = described_class.new(bytes: bytes).nodes.to_h
      [bytes.dup.force_encoding(Encoding::UTF_8), bytes.dup.force_encoding(Encoding::UTF_16LE), bytes.dup.freeze].each do |s|
        expect(described_class.new(bytes: s).nodes.to_h).to eq(reference), s.encoding.name
      end
      copy = bytes.dup.force_encoding(Encoding::UTF_8)
      described_class.new(bytes: copy)
      expect(copy.encoding).to eq(Encoding::UTF_8), "the caller's string is not modified"
    end

    # --- BUG: kept as reproductions -------------------------------------------------------------------------------

    it 'rejects a huge variable count without allocating' do
      each_file do |name, bytes, at|
        at[:var_counts].each_with_index do |offset, k|
          expect(check([["#{name} var_count#{k}=2**31-1", i32(bytes, offset, (2**31) - 1)]], readers: false).first).to be_empty
        end
      end
    end

    it 'raises a format error for object counts out of range' do
      cases = []
      each_file do |name, bytes, at|
        %i[n_sub n_node n_link n_pol].each { |f| SwmmOutputFuzz::INT_EXTREMES.each { |v| cases << ["#{name} #{f}=#{v}", i32(bytes, at[f], v)] } }
      end
      expect_contract(cases)
    end

    it 'raises a format error for id length prefixes out of range' do
      cases = []
      each_file do |name, bytes, at|
        [at[:id_lens].first, at[:id_lens].last].each do |offset|
          [0, -1, -100, bytes.bytesize, (2**31) - 1, -(2**31)].each { |v| cases << ["#{name} id length @#{offset}=#{v}", i32(bytes, offset, v)] }
        end
      end
      expect_contract(cases)
    end

    it 'raises a format error for altered variable blocks' do
      cases = []
      each_file do |name, bytes, at|
        at[:var_counts].each_with_index { |o, k| [-1, 1, 100].each { |v| cases << ["#{name} var_count#{k}=#{v}", i32(bytes, o, v)] } }
        at[:var_codes].each_with_index { |o, k| [-1, -100, 100, (2**31) - 1].each { |v| cases << ["#{name} var_code#{k}=#{v}", i32(bytes, o, v)] } }
      end
      violations, accepted = check(cases)
      accepted.each do |label, out|
        Swmm::OutputFile::KINDS.each do |kind|
          names = out[kind].variables
          violations << "#{label}: accepted #{kind} variables #{names.inspect}" unless names.all?(Symbol) && names.uniq == names
        end
      end
      expect(violations).to be_empty, violations.first(15).join("\n")
    end

    it 'raises a format error for non-finite dates, or reads them as nil' do
      cases = []
      each_file do |name, bytes, at|
        [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |v|
          cases << ["#{name} start=#{v}", f64(bytes, at[:start], v)] << ["#{name} period date=#{v}", f64(bytes, at[:output], v)]
        end
      end
      expect_contract(cases)
    end

    it 'raises a format error for unit codes out of range' do
      each_file do |name, bytes, at|
        [-1, -6].each { |v| expect { described_class.new(bytes: i32(bytes, at[:units], v)) }.to raise_error(Swmm::OutputFormatError), "#{name} units=#{v}" }
        next if at[:pol_units] == at[:input]

        [-1, 3, 9].each { |v| expect { described_class.new(bytes: i32(bytes, at[:pol_units], v)) }.to raise_error(Swmm::OutputFormatError), "#{name} pollutant unit=#{v}" }
      end
    end

    it 'raises a format error for truncation anywhere with the epilogue kept' do
      rng = Random.new(1234)
      cases = []
      each_file do |name, bytes, at|
        cuts = [28, 29, 32, *at[:id_lens], at[:pol_units], at[:input], *at[:var_counts], *at[:var_codes]] + Array.new(40) { rng.rand(28...at[:start]) }
        cuts.uniq.each { |c| cases << ["#{name} cut #{c} + epilogue", bytes[0, c] + bytes[-24, 24]] }
      end
      expect_contract(cases)
    end

    it 'keeps the contract for seeded corruption anywhere' do
      rng = Random.new(1234)
      cases = []
      each_file do |name, bytes, at|
        60.times do
          positions = Array.new(rng.rand(1..3)) { [rng.rand(bytes.bytesize), rng.rand(8)] }
          cases << ["#{name} flip #{positions}", flip(bytes, positions)]
        end
        (0...at[:output]).step(4) { |o| cases << ["#{name} i32@#{o}=#{v = rng.rand(-1000..1000)}", i32(bytes, o, v)] }
        20.times do
          o = rng.rand(at[:output] - 8)
          cases << ["#{name} 8 random bytes @#{o}", bytes.dup.tap { it[o, 8] = rng.bytes(8) }]
        end
      end
      expect_contract(cases)
    end
  end
end
