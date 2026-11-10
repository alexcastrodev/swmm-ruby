# frozen_string_literal: true

require 'etc'
require 'zeitwerk'

# Runs EPA SWMM 5 from Ruby, and reads the files it writes. The model goes in as a Hash ({Swmm::Input}, the input
# contract) and the results come out as a {Swmm::Result} (the output contract).
#
# @example
#   result = Swmm.run(options: { flow_units: "LPS", ... }, junctions: [...], conduits: [...], report: { nodes: "ALL", links: "ALL" })
#   result.ok?                         # => true
#   result.nodes["J1"][:depth].values  # => [0.0, 0.12, ...] one per reporting period
#   Swmm.read(rpt: "model.rpt", out: "model.out")   # the same Result, from files SWMM already wrote
module Swmm
  # Runs one simulation. An engine failure comes back as {Result#error}, not as an exception.
  #
  # @param input [Hash, Input, String, nil] the model: a Hash (checked as an {Input}), an {Input}, or the path of an
  #   existing +.inp+; nil to give its sections as keywords
  # @param dir [String, nil] keep +model.inp+ / +model.rpt+ / +model.out+ there ({Result#files} lists them) and read
  #   the +.out+ from there as it is used; nil: a temp dir, removed after the run, so the whole +.out+ is loaded
  # @param sections [Hash] the sections of the model, when +input+ is nil (+Swmm.run(options: { ... }, junctions: [...])+)
  # @return [Result]
  # @raise [InvalidInput] for a model that breaks the contract
  # @raise [LibraryNotFound] when libswmm5 cannot be loaded
  def self.run(input = nil, dir: nil, **sections) = Runner.run(input: input.nil? ? sections : input, dir:)

  # Runs several models at once, one engine copy per worker thread. Every contract is checked before anything runs;
  # if a worker raises, the others stop and the exception reaches the caller. Temp files only (for +dir:+, {.run}).
  #
  # @param inputs [Enumerable] the models, each anything {.run} takes
  # @param workers [Integer] simulations at the same time
  # @return [Array<Result>] in the order of +inputs+
  # @raise [InvalidInput] for a model that breaks the contract
  # @raise [ArgumentError] for +workers+ below 1, or +inputs+ that is not a list (a single model Hash is not one)
  def self.run_many(inputs, workers: Etc.nprocessors) = Runner.run_many(inputs:, workers:)

  # A {Result} from files SWMM already wrote, without running the engine (see {Result.from_files}).
  #
  # @param rpt [String] the +.rpt+
  # @param out [String, nil] the +.out+
  # @return [Result]
  def self.read(rpt:, out: nil) = Result.from_files(rpt:, out:)

  # @param data [Hash] a model
  # @return [Array<Hash{Symbol => String}>] its violations of the contract (see {Input.validate})
  def self.validate(data) = Input.validate(data)

  # @return [String] the version of the loaded libswmm5 (+"5.2.4"+)
  # @raise [LibraryNotFound] when libswmm5 cannot be loaded
  def self.version = Engine.version

  # @param code [Integer] SWMM's integer version (+52004+)
  # @return [String] as +"5.2.4"+
  def self.format_version(code) = "#{code / 10_000}.#{code / 1000 % 10}.#{code % 1000}"
end

# One file per constant under lib/swmm. Eager: the .out reader runs in Ractors, which cannot autoload.
Zeitwerk::Loader.for_gem.tap(&:setup).eager_load
