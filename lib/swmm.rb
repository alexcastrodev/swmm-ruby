# frozen_string_literal: true

require "etc"
require "fileutils"
require "tmpdir"
require_relative "swmm/version"
require_relative "swmm/errors"
require_relative "swmm/types"
require_relative "swmm/schema"
require_relative "swmm/input"
require_relative "swmm/input_parser"
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
  # Raises ArgumentError for a workers below 1 or an inputs that is not a list (a single model Hash is not one).
  def self.run_many(inputs, workers: Etc.nprocessors)
    raise ArgumentError, "inputs must be a list of models, got #{inputs.class}" unless inputs.is_a?(Enumerable) && !inputs.is_a?(Hash)

    inputs = inputs.map { to_input(_1) }
    return [] if inputs.empty? # nothing to do: workers is not looked at

    raise ArgumentError, "workers must be a number >= 1, got #{workers.inspect}" unless workers.is_a?(Numeric) && workers >= 1

    jobs = Queue.new
    inputs.each_with_index { |input, i| jobs << [input, i] }
    results = Array.new(inputs.size)
    threads = Engine.pool([workers, inputs.size].min).map do |engine|
      Thread.new do
        Thread.current.report_on_exception = false # the caller gets the error from #value, once
        while (input, i = jobs.pop(timeout: 0))
          results[i] = Dir.mktmpdir("swmm") { |tmp| run_in(tmp, input, engine: engine, keep: false) }
        end
      rescue StandardError
        jobs.clear # the other workers take no more jobs
        raise
      end
    end
    begin
      threads.each(&:value)
    ensure
      threads.each { |t| t.join rescue nil } # no worker outlives the call; the first error is already on its way
    end
    results
  end

  # Result from files SWMM already wrote (rpt:, out:), without running the engine: see Result.from_files.
  def self.read(rpt:, out: nil) = Result.from_files(rpt: rpt, out: out)

  def self.validate(data) = Input.validate(data)

  def self.version = Engine.version

  # nil and blank paths would expand to the current directory and reach the engine as a "model"
  def self.to_input(input)
    return Input.new(input) if input.is_a?(Hash)
    raise ArgumentError, "a model must be a Hash, a Swmm::Input or the path of a .inp, got #{input.inspect}" if input.nil? || input.to_s.strip.empty?

    input
  end

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
