# frozen_string_literal: true

require "test_helper"

class TimeStepTest < Minitest::Test
  def step(seconds) = Swmm::TimeStep.new(seconds)

  def test_gives_its_seconds_and_its_hh_mm_ss
    assert_equal [300, "00:05:00", "00:05:00"], [step(300).in_seconds, step(300).formatted, step(300).to_s]
    assert_equal "25:01:01", step(90_061).formatted
    assert_equal "100:00:00", step(360_000).formatted
    assert_equal "00:00:00", step(0).formatted
  end

  def test_keeps_a_fraction_of_a_second_for_a_routing_step_of_half_a_second
    half = step(0.5)
    assert_equal [0.5, "00:00:00.5", false], [half.in_seconds, half.formatted, half.whole?]
    assert_instance_of Integer, step(5.0).in_seconds
  end

  def test_reads_h_mm_ss_and_decimal_seconds_or_hours
    assert_equal step(300), Swmm::TimeStep.parse("0:05:00")
    assert_equal step(5400), Swmm::TimeStep.parse("1:30")
    assert_equal step(5), Swmm::TimeStep.parse("5.00")
    assert_equal step(900), Swmm::TimeStep.parse("0.25", decimal: :hours)
    assert_raises(ArgumentError) { Swmm::TimeStep.parse("5 min") }
  end

  def test_takes_what_the_input_takes
    assert_equal step(60), Swmm::TimeStep.from(60)
    assert_equal step(60), Swmm::TimeStep.from("0:01:00")
    one = step(60)
    assert_same one, Swmm::TimeStep.from(one)
    assert_raises(ArgumentError) { Swmm::TimeStep.from(nil) }
    assert_raises(ArgumentError) { step(Float::INFINITY) }
  end

  def test_compares_with_other_steps_is_a_hash_key_and_is_seconds_as_json
    assert_operator step(60), :<, step(300)
    refute_equal 60, step(60), "a number is not a step"
    assert_equal 1, { step(60) => 1 }[step(60.0)]
    assert_equal '{"step":300}', JSON.generate(step: step(300))
    assert_equal "#<Swmm::TimeStep 00:05:00>", step(300).inspect
    assert_predicate step(300), :frozen?
  end

  def test_goes_into_the_input_and_comes_back_from_it
    model = { options: { flow_units: "LPS", report_step: step(900), routing_step: step(0.5) } }
    inp = Swmm::Input.new(model).to_inp
    assert_includes inp, "REPORT_STEP          00:15:00"
    assert_includes inp, "ROUTING_STEP         0.5"
    options = Swmm::Input.parse(inp)[:options]
    assert_equal [step(900), step(0.5)], options.values_at(:report_step, :routing_step)
    model[:options][:minimum_step] = step(0.25)
    model[:raingages] = [{ name: "RG1", format: "INTENSITY", interval: step(900), source: "TIMESERIES", series: "RAIN" }]
    model[:timeseries] = [{ name: "RAIN", points: [[0, 0]] }]
    read = Swmm::Input.parse(Swmm::Input.new(model).to_inp)
    assert_equal step(0.25), read[:options][:minimum_step]
    assert_equal step(900), read[:raingages].first[:interval]
    refute_empty Swmm::Input.validate(options: { minimum_step: "0:00:01" }), "MINIMUM_STEP is decimal seconds only"
    error = assert_raises(Swmm::InvalidInput) { Swmm::Input.new(options: { report_step: step(0.5) }).to_inp }
    assert_match(/whole seconds/, error.message)
  end
end
