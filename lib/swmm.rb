# frozen_string_literal: true

require "etc"
require "fileutils"
require "tmpdir"
require_relative "swmm/version"
require_relative "swmm/errors"
require_relative "swmm/types"
require_relative "swmm/schema"
require_relative "swmm/input"
require_relative "swmm/engine"
require_relative "swmm/output_file"
require_relative "swmm/result"

# Wrapper for EPA SWMM5. Input contract: Swmm::Input (Hash -> validated .inp). Output contract: Swmm::Result.
#
#   result = Swmm.run(options: {...}, junctions: [...], ...)   # or Swmm.run(hash) / Swmm.run("model.inp")
#   result.ok?
#   result.series(:nodes, "J1", :depth)
module Swmm
  # input: Hash (validated into an Input), Swmm::Input, or the path of an existing .inp.
  #        The sections may also be given as keywords: Swmm.run(options: {...}, junctions: [...]).
  # dir:   keep model.inp / model.rpt / model.out there (result.files lists them); default: a temp dir, removed after the run.
  # Raises InvalidInput for contract violations; engine failures come back as result.error.
  def self.run(input = nil, dir: nil, **sections)
    input = to_input(input.nil? ? sections : input)
    return run_in(File.expand_path(FileUtils.mkdir_p(dir).first), input, keep: true) if dir

    Dir.mktmpdir("swmm") { |tmp| run_in(tmp, input, keep: false) }
  end

  # Runs several models at once, one engine copy per worker thread (see Engine.pool); Results come back in the order of
  # +inputs+. Each input is anything Swmm.run takes. All contracts are checked before anything runs (InvalidInput).
  # workers: simulations at the same time (default: CPU count). Temp files only: use Swmm.run for dir:.
  def self.run_many(inputs, workers: Etc.nprocessors)
    inputs = inputs.map { to_input(_1) }
    return [] if inputs.empty?

    jobs = Queue.new
    inputs.each_with_index { |input, i| jobs << [input, i] }
    results = Array.new(inputs.size)
    Engine.pool([workers, inputs.size].min).map do |engine|
      Thread.new do
        while (input, i = jobs.pop(timeout: 0))
          results[i] = Dir.mktmpdir("swmm") { |tmp| run_in(tmp, input, engine: engine, keep: false) }
        end
      rescue StandardError
        jobs.close # stop the other workers too
        raise
      end
    end.each(&:value)
    results
  end

  # Result from files SWMM already wrote (rpt:, out:), without running the engine: see Result.from_files.
  def self.read(rpt:, out: nil) = Result.from_files(rpt: rpt, out: out)

  def self.validate(data) = Input.validate(data)

  def self.version = Engine.version

  def self.to_input(input) = input.is_a?(Hash) ? Input.new(input) : input

  def self.run_in(dir, input, keep:, engine: Engine.default)
    inp = File.join(dir, "model.inp")
    rpt = File.join(dir, "model.rpt")
    out = File.join(dir, "model.out")
    input.is_a?(Input) ? input.write(inp) : inp = File.expand_path(input.to_s)
    raw = engine.run(inp, rpt, out)
    report = File.exist?(rpt) ? File.binread(rpt).force_encoding(Encoding::UTF_8).scrub : ""
    output = OutputFile.new(File.binread(out)) if raw[:code].zero? && File.exist?(out)

    Result.new(version: engine.version, raw: raw, report: report, output: output,
               files: keep ? { inp: inp, rpt: rpt, out: out } : nil)
  end
  private_class_method :to_input, :run_in
end
