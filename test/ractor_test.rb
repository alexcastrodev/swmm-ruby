# frozen_string_literal: true

require "test_helper"

# The engine's frozen FFI module is shareable, so a Ractor can call it. These tests call the engine without its Mutex
# (Engine#run takes it); that is fine here because minitest runs the tests one at a time.
class RactorTest < Minitest::Test
  include NeedsEngine

  def setup
    super
    @was = Warning[:experimental]
    Warning[:experimental] = false # Ruby 4.0 prints "Ractor API is experimental" on the first Ractor
  end

  def teardown = Warning[:experimental] = @was

  def lib = Swmm::Engine.default.instance_variable_get(:@lib)

  def test_the_ffi_module_is_shareable
    assert Ractor.shareable?(lib)
  end

  def test_a_ractor_reads_the_engine_version
    version = Ractor.new(lib) { |l| l.swmm_getVersion }.value
    assert_equal Swmm::Engine.version, "#{version / 10_000}.#{version / 1000 % 10}.#{version % 1000}"
  end

  def test_a_ractor_opens_and_closes_an_inp
    Dir.mktmpdir do |dir|
      inp = File.join(dir, "m.inp")
      Swmm::Input.new(Fixtures.base).write(inp)
      args = [lib, inp, File.join(dir, "m.rpt"), File.join(dir, "m.out")]
      assert_equal [0, 0], Ractor.new(*args) { |l, *paths| [l.swmm_open(*paths), l.swmm_close] }.value
    end
  end
end
