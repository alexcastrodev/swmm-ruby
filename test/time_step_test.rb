# frozen_string_literal: true

require "test_helper"

class TimeStepTest < Minitest::Test
  TimeStep = Swmm::TimeStep

  def test_gives_its_seconds_and_its_hh_mm_ss
    step = TimeStep.new(300)
    assert_equal [300.0, "00:05:00", "00:05:00"], [step.in_seconds, step.formatted, step.to_s]
    assert_instance_of Float, step.in_seconds
    assert_equal [300, true], [step.to_i, step.whole?]
    assert_equal "25:01:01", TimeStep.new(90_061).formatted
    assert_equal "100:00:00", TimeStep.new(360_000).formatted
    assert_equal "00:00:00", TimeStep.new(0).formatted
  end

  def test_keeps_a_fraction_of_a_second_a_routing_step_of_half_a_second
    step = TimeStep.new(0.5)
    assert_equal [0.5, "00:00:00.5", false], [step.in_seconds, step.formatted, step.whole?]
    assert_equal 0, step.to_i, "to_i truncates"
    assert_equal 1, TimeStep.new(1.5).to_i
    assert_equal 0.25, TimeStep.new(Rational(1, 4)).in_seconds
    assert_instance_of Float, TimeStep.new(Rational(1, 4)).in_seconds
    refute_predicate TimeStep.new(-0.5), :whole?
  end

  def test_reads_clock_text_and_decimal_seconds_or_hours
    assert_equal TimeStep.new(300), TimeStep.parse("0:05:00")
    assert_equal TimeStep.new(5400), TimeStep.parse("1:30")
    assert_equal TimeStep.new(5), TimeStep.parse("5.00")
    assert_equal TimeStep.new(900), TimeStep.parse("0.25", decimal: :hours)
    assert_raises(ArgumentError) { TimeStep.parse("5 min") }
  end

  def test_takes_what_the_input_takes
    assert_equal TimeStep.new(60), TimeStep.from(60)
    assert_equal TimeStep.new(60), TimeStep.from("0:01:00")
    step = TimeStep.new(60)
    assert_same step, TimeStep.from(step)
    assert_raises(ArgumentError) { TimeStep.from(nil) }
    assert_raises(ArgumentError) { TimeStep.new(Float::INFINITY) }
  end

  def test_compares_with_other_steps_is_a_hash_key_and_is_seconds_as_json
    assert_operator TimeStep.new(60), :<, TimeStep.new(300)
    refute_equal TimeStep.new(60), 60, "a number is not a step"
    assert_equal 1, { TimeStep.new(60) => 1 }[TimeStep.new(60.0)]
    assert_equal '{"step":300.0}', JSON.generate(step: TimeStep.new(300))
    assert_equal '{"step":0.5}', JSON.generate(step: TimeStep.new(0.5))
    assert_equal "#<Swmm::TimeStep 00:05:00>", TimeStep.new(300).inspect
    assert_predicate TimeStep.new(300), :frozen?
  end

  def test_goes_into_the_input_and_comes_back_from_it
    model = { options: { flow_units: "LPS", report_step: TimeStep.new(900), routing_step: TimeStep.new(0.5) } }
    inp = Swmm::Input.new(model).to_inp
    assert_includes inp, "REPORT_STEP          00:15:00"
    assert_includes inp, "ROUTING_STEP         0.5"
    assert_includes Swmm::Input.new(options: { routing_step: TimeStep.new(30) }).to_inp, "ROUTING_STEP         30\n", "a whole step is written without .0"
    options = Swmm::Input.parse(inp)[:options]
    assert_equal TimeStep.new(900), options[:report_step]
    assert_equal TimeStep.new(0.5), options[:routing_step]

    model[:options][:minimum_step] = TimeStep.new(0.25)
    model[:raingages] = [{ name: "RG1", format: "INTENSITY", interval: TimeStep.new(900), source: "TIMESERIES", series: "RAIN" }]
    model[:timeseries] = [{ name: "RAIN", points: [[0, 0]] }]
    read = Swmm::Input.parse(Swmm::Input.new(model).to_inp)
    assert_equal TimeStep.new(0.25), read[:options][:minimum_step]
    assert_equal TimeStep.new(900), read[:raingages].first[:interval]

    refute_empty Swmm::Input.validate(options: { minimum_step: "0:00:01" }), "MINIMUM_STEP is decimal seconds only"
    error = assert_raises(Swmm::InvalidInput) { Swmm::Input.new(options: { report_step: TimeStep.new(0.5) }).to_inp }
    assert_match(/whole seconds/, error.message)
  end
end
