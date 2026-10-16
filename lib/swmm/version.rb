# frozen_string_literal: true

module Swmm
  VERSION = "0.1.0"

  # SWMM's integer version (52004) as "5.2.4"
  def self.format_version(code) = "#{code / 10_000}.#{code / 1000 % 10}.#{code % 1000}"
end
