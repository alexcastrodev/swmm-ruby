require 'stringio'
require_relative '../../swmm_helper'

# OutputFile.read(path) reads the file as it is used (only the header in memory); OutputFile.new(bytes) the same file
# in memory. Both must give the same answers, whatever the span size and with or without Ractors.
RSpec.describe Swmm::OutputFile, 'read from the file', :libswmm5 do
  around do |example|
    saved = [described_class.chunk_bytes, described_class.ractors, described_class.parallel_from]
    example.run
  ensure
    described_class.chunk_bytes, described_class.ractors, described_class.parallel_from = saved
  end

  def run_full(dir) = Swmm.run(SwmmFixtures.full(dir), dir: dir)

  def answers(out)
    described_class::KINDS.to_h do |kind|
      objects = out[kind]
      first = objects.ids.first
      [kind, { all: objects.to_h, series: objects.variables.to_h { [it, objects[first][it].values] }, records: objects.records.to_a,
               frames: objects.variables.map { objects.frames(it).rows }, csv: objects.to_csv }]
    end
  end

  it 'keeps only the header in memory and answers what the bytes in memory answer' do
    Dir.mktmpdir do |dir|
      path = run_full(dir).files[:out]
      memory = described_class.new(bytes: File.binread(path))
      file = described_class.read(path)
      expect(file.path).to eq(path)
      expect(memory.path).to be_nil
      expect(file.instance_variable_get(:@reader).instance_variable_get(:@bytes).bytesize).to be < File.size(path) / 2, 'the period records stay in the file'
      header = ->(out) { [out.times, out.nodes.types, out.links.types] + described_class::KINDS.map { [out[it].ids, out[it].variables, out[it].units] } }
      expect(header.call(file)).to eq(header.call(memory))
      expected = answers(memory)
      [1, 100, 8 * 1024 * 1024].each do |chunk| # a period per span, a few, all at once
        described_class.chunk_bytes = chunk
        [[1, 250_000], [3, -1]].each do |ractors, from| # sequential, then always in Ractors
          described_class.ractors = ractors
          described_class.parallel_from = from
          expect(answers(file)).to eq(expected), "chunk #{chunk}, ractors #{ractors}"
        end
      end
    end
  end

  it 'streams the CSV to an io, the same as the String' do
    Dir.mktmpdir do |dir|
      result = run_full(dir)
      described_class.chunk_bytes = 64
      described_class::KINDS.each do |kind|
        expect(result[kind].to_csv(StringIO.new).string).to eq(result[kind].to_csv), kind.to_s
      end
      memory = Swmm::Result.new(version: 1, raw: { code: 0 }, report: '', output: described_class.new(bytes: File.binread(result.files[:out])), files: nil)
      expect(memory.nodes.to_csv(StringIO.new).string).to eq(result.nodes.to_csv), 'from the bytes in memory too'
    end
  end

  it 'gives a record per period and object, time-major, one period at a time' do
    Dir.mktmpdir do |dir|
      out = described_class.read(run_full(dir).files[:out])
      described_class.chunk_bytes = 64
      enum = out.nodes.records
      expect(enum).to be_a(Enumerator)
      expect(enum.size).to eq(out.nodes.size * out.periods), 'the size is known before reading'
      first = enum.first(out.nodes.size)
      expect(first.map(&:time).uniq).to eq([out.times.first])
      expect(first.map(&:id)).to eq(out.nodes.ids)
      expect(first.first.depth).to eq(out.nodes[out.nodes.ids.first][:depth].values.first)
      expect(enum.map(&:time).uniq).to eq(out.times)
      expect(out.system.records.count).to eq(out.periods)
    end
  end

  it 'says the file is gone, and a file cut while reading it is an OutputFormatError' do
    out = nil
    path = nil
    Dir.mktmpdir do |dir|
      path = run_full(dir).files[:out]
      out = described_class.read(path)
      cut = File.join(dir, 'cut.out')
      File.binwrite(cut, File.binread(path))
      reader = described_class.read(cut)
      File.truncate(cut, File.size(cut) / 2)
      expect { reader.nodes.to_h }.to raise_error(Swmm::OutputFormatError, /changed or was truncated/)
      expect { reader.system['system'][:rainfall].values }.to raise_error(Swmm::OutputFormatError)
    end
    expect { out.nodes['J1'][:depth].values }.to raise_error(Swmm::Error, /the .out is gone/)
    expect { out.nodes.to_h }.to raise_error(Swmm::Error, /the .out is gone/)
    expect(out.nodes.ids).not_to be_empty, 'the header is still there'
  end

  it 'loads the whole .out of a run without dir: (its temp dir goes away)' do
    result = Swmm.run(SwmmFixtures.base)
    expect(result.output.path).to be_nil
    expect(result.nodes['J1'][:depth].values.size).to eq(result.output.periods)
  end
end
