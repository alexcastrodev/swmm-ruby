# frozen_string_literal: true

module Swmm
  # SWMM's binary results file (+.out+): its header, and the objects of each kind it saved as a {Collection}.
  #
  # Only the objects listed in +[REPORT]+ (+SUBCATCHMENTS+ / +NODES+ / +LINKS+) are saved by the engine; the system
  # always is. {.read} keeps only the header in memory (ids, types, units: a few KB) and reads the values from the file
  # when they are asked for, {.chunk_bytes} at a time, so the file must stay where it is while it is used.
  # +OutputFile.new(bytes:)+ reads a +.out+ already in memory.
  #
  # @example
  #   output = Swmm::OutputFile.read("model.out")
  #   output.times                     # => [2026-03-24 00:10:00 UTC, ...]
  #   output.links["C1"][:flow]        # => #<Swmm::Series links "C1" flow (LPS): 12 values>
  #   output.links.frames(:depth)      # => #<Swmm::Frames links depth (m): 12 periods x 608 objects>
  #   output.links.records.first.to_h  # => { time: ..., id: "C1", flow: 0.12, depth: 0.3, ... }
  class OutputFile
    # @return [Array<Symbol>] the kinds of objects a +.out+ saves: +:subcatchments+, +:nodes+, +:links+, +:system+
    KINDS = OutputReader::KINDS

    # @return [Hash{Symbol => Array<String>}] the types of nodes and links, in the order of the engine's codes
    TYPES = OutputReader::TYPES

    class << self
      # Opens a +.out+ to read it as it is used: only its header is read now.
      #
      # @param path [String] the +.out+ file
      # @return [OutputFile]
      # @raise [OutputFormatError] for a file SWMM did not write, or a truncated one
      # @raise [Errno::ENOENT] when the file is not there
      def read(path) = new(path:)

      # How many Ractors {Collection#to_h} and {Collection#to_csv} split a big kind across (1 turns them off).
      # @return [Integer] default: the CPU count, up to 6
      def ractors = OutputReader.ractors

      # @param count [Integer]
      def ractors=(count)
        OutputReader.ractors = count
      end

      # From how many values (objects x variables x periods) a kind is read in Ractors.
      # @return [Integer] default: 250 000
      def parallel_from = OutputReader.parallel_from

      # @param count [Integer]
      def parallel_from=(count)
        OutputReader.parallel_from = count
      end

      # How many bytes of the file a streaming read takes at a time: the memory it needs.
      # @return [Integer] default: 8 MB
      def chunk_bytes = OutputReader.chunk_bytes

      # @param bytes [Integer]
      def chunk_bytes=(bytes)
        OutputReader.chunk_bytes = bytes
      end
    end

    # Give one of the two.
    #
    # @param bytes [String, nil] a whole +.out+ already in memory
    # @param path [String, nil] the +.out+ to read as it is used (see {.read})
    # @raise [OutputFormatError] for contents SWMM did not write
    # @raise [TypeError] when +bytes+ is not a String (nor +path+ given)
    # @raise [ArgumentError] for both
    def initialize(bytes: nil, path: nil)
      @reader = OutputReader.new(bytes:, path:)
      @collections = {}
    end

    # @return [String, nil] the file it reads; nil for one in memory
    def path = @reader.path

    # @return [Array<Time>] the time of each reporting period (UTC: SWMM dates carry no zone)
    def times = @reader.times

    # @return [Integer] how many reporting periods the file saved
    def periods = @reader.periods

    # @return [TimeStep] the reporting step
    def report_step = @reader.report_step

    # @return [String] the flow units, one of {Options::FlowUnits} (+"LPS"+, +"CFS"+, ...)
    def flow_units = @reader.flow_units

    # @return [Array<String>] the pollutants of the model, in the order of their +:"quality:<name>"+ variables
    def pollutants = @reader.pollutants

    # @return [Time] the start of the run as the file saves it: one report step before the first saved period
    def start_time = @reader.start

    # @return [Time, nil] the time of the last saved period; nil when the file saved none
    def end_time = times.last

    # @return [String] the engine version that wrote the file (+"5.2.4"+)
    def engine_version = @reader.engine_version

    # @return [Integer] the error code the engine stored in the file (0: the run finished)
    def engine_error = @reader.engine_error

    # @return [Collection] the subcatchments the file saved
    def subcatchments = self[:subcatchments]

    # @return [Collection] the nodes the file saved
    def nodes = self[:nodes]

    # @return [Collection] the links the file saved
    def links = self[:links]

    # @return [Collection] the system (one object, +"system"+)
    def system = self[:system]

    # @param kind [Symbol, String] one of {KINDS}
    # @return [Collection] the objects of that kind
    # @raise [UnknownObject] for another kind
    def [](kind)
      kind = OutputReader.kind!(kind)
      @collections[kind] ||= Collection.new(reader: @reader, kind:)
    end

    # @return [String]
    def inspect = "#<#{self.class.name} #{path || "#{@reader.size} bytes"}, #{periods} periods, #{KINDS.map { "#{self[it].size} #{it}" }.join(', ')}>"
  end
end
