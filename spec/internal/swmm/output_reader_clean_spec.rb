require_relative '../../swmm_helper'

# clean: pure, no engine
RSpec.describe Swmm::OutputReader, '.clean' do
  def float32(value) = [value].pack('e').unpack1('e')

  it 'turns non-finite floats into nil and keeps zero' do
    expect(described_class.clean(Float::NAN)).to be_nil
    expect(described_class.clean(Float::INFINITY)).to be_nil
    expect(described_class.clean(-Float::INFINITY)).to be_nil
    expect(described_class.clean(0.0)).to eq(0.0)
    expect(described_class.clean(-0.0).abs).to eq(0.0)
  end

  it 'removes the float32 noise' do
    expect(described_class.clean(float32(0.1))).to eq(0.1)
    expect(described_class.clean(float32(1.2438242))).to eq(1.243824)
    expect(described_class.clean(float32(995.296204))).to eq(995.2962)
  end

  # Surprising but acceptable (the header comment says "the 7 digits that mean something"): a float32 holds ~7.2 digits and needs
  # 9 to round-trip, so clean(x) is within 5e-7 relative of x but is not always the same float32 again.
  it 'keeps the relative error at most 5e-7 over the float32 range' do
    rng = Random.new(20_260_416)
    worst = 0.0
    changed = 0
    2000.times do
      exponent = rng.rand(-37..37)
      x = float32(rng.rand(1.0..9.999999) * (10.0**exponent) * (rng.rand < 0.5 ? 1 : -1))
      c = described_class.clean(x)
      worst = [worst, ((c - x) / x).abs].max
      changed += 1 unless float32(c) == x
    end
    expect(worst).to be <= 5.0001e-7
    expect(changed).to be > 0, 'documented: not every float32 survives the 7-digit round trip'
  end

  it 'handles the extremes of the float32 range' do
    big = float32(3.4028234e38)
    expect(described_class.clean(big)).to be_within(big * 5e-7).of(big)
    tiny = float32(1.17549435e-38) # smallest normal float32
    expect(described_class.clean(tiny)).to be_within(tiny * 5e-7).of(tiny)
    denormal = float32(1e-45) # smallest subnormal float32 (about 1.4e-45)
    expect(described_class.clean(denormal)).to be > 0.0
    expect(described_class.clean(denormal)).to be_within(denormal * 0.5).of(denormal)
  end
end
