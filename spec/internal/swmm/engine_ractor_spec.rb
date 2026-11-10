require_relative '../../swmm_helper'

# The engine's frozen FFI module is shareable, so a Ractor can call it. These examples call the engine without its Mutex
# (Engine#run takes it); that is fine here because the examples run one at a time.
RSpec.describe Swmm::Engine, 'in Ractors', :libswmm5 do
  around do |example|
    was = Warning[:experimental]
    Warning[:experimental] = false # Ruby 4.0 prints "Ractor API is experimental" on the first Ractor
    example.run
  ensure
    Warning[:experimental] = was
  end

  def lib = described_class.default.instance_variable_get(:@lib)

  it 'has a shareable FFI module' do
    expect(Ractor.shareable?(lib)).to be(true)
  end

  it 'reads the engine version from a Ractor' do
    version = Ractor.new(lib, &:swmm_getVersion).value
    expect("#{version / 10_000}.#{version / 1000 % 10}.#{version % 1000}").to eq(described_class.version)
  end

  it 'opens and closes an .inp from a Ractor' do
    Dir.mktmpdir do |dir|
      inp = File.join(dir, 'm.inp')
      Swmm::Input.new(SwmmFixtures.base).write(inp)
      args = [lib, inp, File.join(dir, 'm.rpt'), File.join(dir, 'm.out')]
      expect(Ractor.new(*args) { |l, *paths| [l.swmm_open(*paths), l.swmm_close] }.value).to eq([0, 0])
    end
  end
end
