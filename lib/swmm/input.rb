# frozen_string_literal: true

module Swmm
  # The input contract: a model as a Hash whose keys are the +.inp+ sections in lowercase (+options:+, +junctions:+,
  # +conduits:+, ...; the columns of each are in +docs/input-contract.md+), checked and written as +.inp+ text. Every
  # violation is collected and raised together as {InvalidInput}, never a partial file. Any row may also be a raw Array
  # of tokens, written as given (the escape hatch for exotic lines).
  #
  # @example
  #   input = Swmm::Input.new(options: { flow_units: "LPS" }, junctions: [{ name: "J1", elevation: 10 }], ...)
  #   input.to_inp                  # => "[OPTIONS]\nFLOW_UNITS           LPS\n\n[JUNCTIONS]\n..."
  #   input.write("model.inp")
  #   Swmm::Input.validate(hash)    # => [{ path: "junctions[0].elevation", message: "must be a number, got \"x\"" }]
  class Input
    # The +.inp+ text of a model, as {Input} takes it (a {Model}), so that a model written by the SWMM GUI, the +swmm5+
    # CLI or {Input} can be read, changed and run again: +Swmm::Input.new(Swmm::Input.parse(text))+ writes it back.
    #
    # Sections present in the file come back with their lowercase names; empty ones are left out. Values are typed:
    # numbers as Integer / Float, YES/NO as true / false, keywords in the case the schema lists them, MM/DD/YYYY dates
    # as Date, clock times as +"H:MM[:SS]"+ text, time steps as {TimeStep}, names and labels as String. A row that does
    # not fit its section's columns is kept as the Array of its tokens.
    #
    # @param text [String] the +.inp+ contents (UTF-8, or Windows-1252 as older GUIs write)
    # @param only [Array<Symbol>, nil] the sections to read; the others are not read at all
    # @return [Model]
    # @raise [InvalidInput] for what the contract cannot hold (an unknown section, option, keyword or report line, a
    #   malformed table line), with every problem and its line
    # @raise [ArgumentError] for an unknown section in +only+
    # @example
    #   Swmm::Input.parse(text, only: %i[junctions conduits coordinates])
    def self.parse(text, only: nil) = Parser.new(text:, only:).parse

    # {.parse} of a file.
    #
    # @param path [String] the +.inp+
    # @param only [Array<Symbol>, nil] the sections to read
    # @return [Model]
    # @raise [InvalidInput] see {.parse}
    def self.read(path, only: nil) = parse(File.binread(path), only:)

    # @param data [Hash] the model
    # @return [Array<Hash{Symbol => String}>] every violation, +{ path:, message: }+; empty when the model is valid
    def self.validate(data)
      new(data)
      []
    rescue InvalidInput => e
      e.errors
    end

    # @return [String] the +.inp+ text
    attr_reader :to_inp
    alias to_s to_inp

    # @param data [Hash] the model: sections as keys (Symbols or Strings, any case)
    # @raise [InvalidInput] with every violation of the contract
    def initialize(data)
      @to_inp = Renderer.new(data).to_inp
    end

    # @param path [String] where to write the +.inp+
    # @return [Integer] the bytes written
    def write(path) = File.write(path, to_inp)
  end
end
