require 'json'
require 'stringio'
require_relative 'support/swmm_standalone'
require_relative 'support/swmm_fixtures'

# Specs tagged :libswmm5 need the engine: they skip themselves when it is missing (rake swmm:build, or SWMM_LIB).
module SwmmSpecHelpers
  # Swmm.run of a model that must succeed; +label+ names it in the failure message
  def run_ok(model, label = nil)
    result = Swmm.run(model)
    expect(result).to be_ok, "#{label}: #{result.error&.fetch(:details, nil)&.join('; ')}"
    result
  end

  # [stdout, stderr] written while the block ran
  def capture_io
    stdout = $stdout
    stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout = stdout
    $stderr = stderr
  end
end

RSpec.configure do |config|
  config.include SwmmSpecHelpers
  config.before(:each, :libswmm5) do
    skip 'libswmm5 not found: run `rake swmm:build` or set SWMM_LIB' unless Swmm::Engine.available?
  end
end
