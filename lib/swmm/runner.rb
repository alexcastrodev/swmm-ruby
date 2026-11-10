# frozen_string_literal: true

require 'etc'
require 'fileutils'
require 'tmpdir'

module Swmm
  # Behind Swmm.run and Swmm.run_many: writes each model's .inp, runs the engine on it and reads what it wrote into a
  # Result. Engine failures come back as Result#error; contract violations raise InvalidInput before anything runs.
  module Runner
    module_function

    # input: a Hash (validated into an Input), a Swmm::Input or the path of an existing .inp. dir: keep model.inp /
    # model.rpt / model.out there and read the .out from there as it is used; nil: a temp dir, removed after the run,
    # so the whole .out is loaded.
    def run(input:, dir: nil)
      input = to_input(input)
      return run_in(dir: File.expand_path(FileUtils.mkdir_p(dir).first), input:, keep: true) if dir

      Dir.mktmpdir('swmm') { |tmp| run_in(dir: tmp, input:, keep: false) }
    end

    # Several models at once, one engine copy per worker thread (see Engine.pool); Results in the order of +inputs+.
    # All contracts are checked before anything runs. Temp files only.
    def run_many(inputs:, workers: Etc.nprocessors)
      raise ArgumentError, "inputs must be a list of models, got #{inputs.class}" unless inputs.is_a?(Enumerable) && !inputs.is_a?(Hash)

      inputs = inputs.map { to_input(it) }
      return [] if inputs.empty? # nothing to do: workers is not looked at

      raise ArgumentError, "workers must be a number >= 1, got #{workers.inspect}" unless workers.is_a?(Numeric) && workers >= 1

      jobs = Queue.new
      inputs.each_with_index { |input, i| jobs << [input, i] }
      results = Array.new(inputs.size)
      threads = Engine.pool([workers, inputs.size].min).map do |engine|
        Thread.new do
          Thread.current.report_on_exception = false # the caller gets the error from #value, once
          while (input, i = jobs.pop(timeout: 0))
            results[i] = Dir.mktmpdir('swmm') { |tmp| run_in(dir: tmp, input:, engine:, keep: false) }
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

    # nil and blank paths would expand to the current directory and reach the engine as a "model"
    def to_input(input)
      return Input.new(input) if input.is_a?(Hash)
      raise ArgumentError, "a model must be a Hash, a Swmm::Input or the path of a .inp, got #{input.inspect}" if input.nil? || input.to_s.strip.empty?

      input
    end

    def run_in(dir:, input:, keep:, engine: Engine.default)
      inp = File.join(dir, 'model.inp')
      rpt = File.join(dir, 'model.rpt')
      out = File.join(dir, 'model.out')
      input.is_a?(Input) ? input.write(inp) : inp = File.expand_path(input.to_s)
      raw = engine.run(inp, rpt, out)
      report = Report.new(File.exist?(rpt) ? File.binread(rpt) : '')
      # kept files are read as they are used; a temp dir goes away with the run, so its .out is loaded whole
      output = (keep ? OutputFile.read(out) : OutputFile.new(bytes: File.binread(out))) if raw[:code].zero? && File.exist?(out)

      Result.new(version: engine.version, raw: raw, report: report, output: output,
                 files: keep ? { inp: inp, rpt: rpt, out: out } : nil)
    end
  end
end
