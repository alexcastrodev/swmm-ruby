# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"

# Timeout starts one background thread on first use and keeps it: start it now so Thread.list.size baselines are stable.
Timeout.timeout(1) { nil }

# FRONT D (risk R4): run_many, the engine pool, threads, Ractor reads and the process lifecycle.
# Tests marked `skip "BUG: ..."` express the CORRECT behaviour and reproduce a confirmed defect when the skip is removed.
module ConcurrencySupport
  ROOT = File.expand_path("..", __dir__)

  # Lets a test observe / break Engine#run for any engine instance (a no-op while +hook+ is nil).
  module EngineSpy
    class << self
      attr_accessor :hook
    end

    def run(*args)
      EngineSpy.hook&.call
      super
    end
  end
  Swmm::Engine.prepend(EngineSpy)

  def model(peak) = Fixtures.base.merge(timeseries: [{ name: "Q", points: [[0, 0], [0.5, peak / 2.0], [1, peak], [2, 0]] }])

  def bad_model = Fixtures.base.merge(conduits: [{ name: "C1", from_node: "J1", to_node: "NOPE", length: 1, roughness: 0.01, in_offset: 0, out_offset: 0 }])

  def flow(result) = result.series(:links, "C2", :flow)

  def peaks = [10, 20, 40, 80, 160, 320]

  def pool_size = Swmm::Engine.instance_variable_get(:@pool)&.size.to_i

  # Counts Engine#run calls (thread safe) while the block runs; the block receives the counter.
  def count_engine_runs(raise_on: nil)
    calls = 0
    lock = Mutex.new
    EngineSpy.hook = lambda {
      n = lock.synchronize { calls += 1 }
      raise "boom" if n == raise_on
    }
    yield -> { calls }
  ensure
    EngineSpy.hook = nil
  end

  # Waits (bounded) until the threads of a finished/failed run_many are gone; true when the count is back to +baseline+.
  def threads_settle?(baseline)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    while Thread.list.size > baseline && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep 0.01
    end
    Thread.list.size <= baseline
  end

  # Dir.tmpdir is read from ENV["TMPDIR"] on every call, so a private one is not polluted by the other test processes.
  # The library copies directory must already exist (Engine.pool is called first) so it is not created inside it.
  def with_private_tmpdir
    Swmm::Engine.pool(1)
    old = ENV.fetch("TMPDIR", nil)
    Dir.mktmpdir("swmm-conc-test") do |dir|
      ENV["TMPDIR"] = dir
      yield dir
    ensure
      old ? ENV["TMPDIR"] = old : ENV.delete("TMPDIR")
    end
  end

  def swmm_dirs(dir) = Dir.glob(File.join(dir, "swmm*"))

  # Runs a Ruby script in a FRESH process (cwd = the gem, -Ilib -Itest). Returns [stdout, stderr, status]; kills it on timeout.
  def ruby(script, env: {})
    Open3.popen3(env, RbConfig.ruby, "-Ilib", "-Itest", "-e", script, chdir: ROOT) do |stdin, stdout, stderr, waiter|
      stdin.close
      out = Thread.new { stdout.read }
      err = Thread.new { stderr.read }
      unless waiter.join(60)
        Process.kill("KILL", waiter.pid)
        flunk "subprocess hung (killed)"
      end
      [out.value, err.value, waiter.value]
    end
  end
end

class RunManyArgumentsTest < Minitest::Test
  include NeedsEngine
  include ConcurrencySupport

  def expected_flows = peaks.map { |q| flow(Swmm.run(model(q))) }

  def test_every_workers_value_gives_the_results_in_input_order
    expected = expected_flows
    assert_equal peaks.size, expected.uniq.size, "the models really produce different results"
    [1, 2, 3, peaks.size, 50, nil].each do |workers|
      results = workers ? Swmm.run_many(peaks.map { model(_1) }, workers: workers) : Swmm.run_many(peaks.map { model(_1) })
      assert(results.all?(&:ok?), "workers: #{workers.inspect}")
      assert_equal expected, results.map { flow(_1) }, "workers: #{workers.inspect}"
    end
  end

  def test_more_workers_than_inputs_creates_no_extra_engine_copies
    Swmm::Engine.pool(2)
    before = pool_size
    Swmm.run_many([Fixtures.base, Fixtures.base], workers: 500)
    assert_equal before, pool_size, "at most 2 workers are needed for 2 inputs, 2 copies already existed"
  end

  def test_pool_grows_to_the_largest_size_requested_and_is_reused
    Swmm.run_many([Fixtures.base] * 4, workers: 4)
    size = pool_size
    assert_operator size, :>=, 4
    3.times { Swmm.run_many([Fixtures.base] * 3, workers: 2) }
    assert_equal size, pool_size
    assert_equal Swmm::Engine.pool(4), Swmm::Engine.pool(4), "the same engine objects come back"
    assert_equal Swmm::Engine.pool(4).first(2), Swmm::Engine.pool(2)
  end

  def test_workers_one_runs_everything_on_the_first_pool_engine_not_the_default_one
    first = Swmm::Engine.pool(1).first
    refute_same first, Swmm::Engine.default, "the pool has its own library copies"
    used = []
    first.singleton_class.prepend(Module.new { define_method(:run) { |*a| used << :first; super(*a) } })
    assert(Swmm.run_many([Fixtures.base] * 3, workers: 1).all?(&:ok?))
    assert_equal %i[first] * 3, used
  end

  def test_empty_list_returns_an_empty_array_and_creates_nothing
    before = pool_size
    assert_equal [], Swmm.run_many([])
    assert_equal [], Swmm.run_many([], workers: 0), "nothing to do: workers is never looked at"
    assert_equal before, pool_size
  end

  def test_the_same_object_repeated_gives_independent_equal_results
    input = Swmm::Input.new(model(40))
    hash = model(40)
    [[input] * 5, [hash] * 5].each do |list|
      results = Swmm.run_many(list, workers: 3)
      assert_equal 5, results.map(&:object_id).uniq.size, "one Result per slot"
      assert_equal 1, results.map { flow(_1) }.uniq.size
      assert_equal flow(Swmm.run(hash)), flow(results.first)
    end
  end

  def test_hashes_inputs_and_inp_paths_can_be_mixed
    Dir.mktmpdir do |dir|
      Swmm::Input.new(model(160)).write(inp = File.join(dir, "m.inp"))
      list = [model(10), Swmm::Input.new(model(40)), inp, model(80), inp]
      results = Swmm.run_many(list, workers: 2)
      assert_equal [10, 40, 160, 80, 160].map { flow(Swmm.run(model(_1))) }, results.map { flow(_1) }
      assert(results.all? { _1.files.nil? }, "run_many only uses temp files")
    end
  end

  # Characterisation: workers: 2.5 is accepted (Array#first and Integer comparison truncate / accept it).
  def test_a_float_worker_count_is_accepted
    results = Swmm.run_many([Fixtures.base] * 3, workers: 2.5)
    assert_equal [true] * 3, results.map(&:ok?)
  end

  # Characterisation: nil, "3" and -1 raise ArgumentError before anything runs (the messages are not very friendly:
  # "comparison of Integer with nil failed", "negative array size").
  def test_nil_string_and_negative_worker_counts_raise_argument_error_without_running
    count_engine_runs do |calls|
      [nil, "3", -1].each do |workers|
        assert_raises(ArgumentError, "workers: #{workers.inspect}") { Timeout.timeout(10) { Swmm.run_many([Fixtures.base] * 2, workers: workers) } }
      end
      assert_equal 0, calls.call
    end
  end

  def test_zero_workers_is_not_silently_a_list_of_nils
    out = begin
      Timeout.timeout(10) { Swmm.run_many([Fixtures.base] * 3, workers: 0) }
    rescue ArgumentError
      :argument_error
    end
    assert(out == :argument_error || out.all?(Swmm::Result), "expected ArgumentError or real Results, got #{out.inspect}")
  end

  def test_a_hash_is_not_taken_for_a_list_of_models
    out = begin
      Swmm.run_many(Fixtures.base)
    rescue ArgumentError, TypeError, Swmm::InvalidInput
      :rejected
    end
    assert_equal :rejected, out.is_a?(Array) ? "#{out.size} results, errors #{out.map { _1.error[:code] }.uniq}" : out
  end

  def test_nil_elements_are_rejected_like_other_bad_inputs
    assert_raises(ArgumentError, TypeError, Swmm::InvalidInput) { Swmm.run_many([nil]) }
  end

  # Characterisation: a path that does not exist is NOT a contract error (paths are not checked), it is an engine error.
  def test_a_missing_inp_path_is_an_error_result_for_that_slot_only
    results = Swmm.run_many([Fixtures.base, "/nonexistent/model.inp", Fixtures.base], workers: 2)
    assert_equal [true, false, true], results.map(&:ok?)
    assert_equal 303, results[1].error[:code]
  end
end

class RunManyErrorsTest < Minitest::Test
  include NeedsEngine
  include ConcurrencySupport

  def test_an_engine_error_stays_in_its_own_slot_whatever_the_position
    good = flow(Swmm.run(Fixtures.base))
    [[bad_model, Fixtures.base, Fixtures.base], [Fixtures.base, bad_model, Fixtures.base],
     [Fixtures.base, Fixtures.base, bad_model], [bad_model] * 3].each do |list|
      [1, 2, 3].each do |workers|
        results = Swmm.run_many(list, workers: workers)
        assert_equal list.map { !_1.equal?(bad_model) && _1 != bad_model }, results.map(&:ok?), "workers #{workers}"
        results.each { |r| r.ok? ? assert_equal(good, flow(r)) : assert_equal(200, r.error[:code]) }
      end
    end
  end

  def test_a_contract_error_raises_before_any_simulation_or_engine_copy_starts
    before = pool_size
    count_engine_runs do |calls|
      error = assert_raises(Swmm::InvalidInput) { Swmm.run_many([Fixtures.base] * 4 + [{ junctions: [{ name: "J" }] }], workers: 8) }
      assert_match(/junctions\[0\]/, error.message)
      assert_equal 0, calls.call, "no simulation may start"
    end
    assert_equal before, pool_size, "no engine copy may be created"
  end

  def test_an_exception_in_a_worker_reaches_the_caller_and_the_next_run_many_works
    with_private_tmpdir do |dir|
      baseline = Thread.list.size
      count_engine_runs(raise_on: 2) do
        capture_io do # the failed thread also reports itself on stderr, see test_a_failed_worker_does_not_write_to_stderr
          error = assert_raises(RuntimeError) { Timeout.timeout(10) { Swmm.run_many(peaks.map { model(_1) }, workers: 2) } }
          assert_equal "boom", error.message
        end
      end
      assert threads_settle?(baseline), "worker threads are still alive: #{Thread.list.size} vs #{baseline}"
      assert_empty swmm_dirs(dir), "temp dirs of the failed run were removed"
      results = Timeout.timeout(10) { Swmm.run_many(peaks.map { model(_1) }, workers: 2) }
      assert_equal peaks.map { flow(Swmm.run(model(_1))) }, results.map { flow(_1) }
    end
  end

  def test_after_one_worker_fails_the_others_stop_taking_jobs
    total = 40
    count_engine_runs(raise_on: 2) do |calls|
      capture_io do
        assert_raises(RuntimeError) { Timeout.timeout(20) { Swmm.run_many([Fixtures.base] * total, workers: 2) } }
      end
      assert_operator calls.call, :<=, 4, "2 workers: one dies at call 2, the other may finish the job it holds, then stops (ran #{calls.call} of #{total})"
    end
  end

  def test_a_failed_worker_does_not_write_to_stderr
    count_engine_runs(raise_on: 1) do
      _out, err = capture_io { assert_raises(RuntimeError) { Swmm.run_many([Fixtures.base] * 3, workers: 2) } }
      assert_empty err
    end
  end
end

class StateHygieneTest < Minitest::Test
  include NeedsEngine
  include ConcurrencySupport

  def test_a_failed_run_does_not_poison_the_next_one_on_the_default_engine
    good = Swmm.run(model(80))
    3.times do
      refute Swmm.run(bad_model).ok?
      again = Swmm.run(model(80))
      assert again.ok?
      assert_equal flow(good), flow(again)
      assert_equal good.continuity, again.continuity
      assert_equal good.to_h(series: false).except(:files), again.to_h(series: false).except(:files)
    end
  end

  def test_a_failed_run_does_not_poison_the_next_one_on_a_pool_engine
    good = Swmm.run_many([model(80)], workers: 1).first
    10.times do
      assert_equal [false, true], Swmm.run_many([bad_model, model(80)], workers: 1).map(&:ok?), "a single engine runs both, in order"
    end
    assert_equal flow(good), flow(Swmm.run_many([model(80)], workers: 1).first)
  end

  def test_an_error_after_the_engine_started_is_followed_by_a_clean_run
    good = flow(Swmm.run(model(40)))
    # a model without an outfall is refused by the engine after the file was parsed (the other test fails at open)
    no_outfall = Fixtures.base.merge(outfalls: [], conduits: [Fixtures.base[:conduits].first.merge(to_node: "J2")], xsections: [Fixtures.base[:xsections].first])
    failed = Swmm.run(no_outfall)
    refute failed.ok?
    assert_match(/ERROR \d+/, failed.error[:message])
    assert_equal good, flow(Swmm.run(model(40)))
  end

  def test_many_sequential_runs_leave_no_temp_dirs_and_no_new_engine_copies
    with_private_tmpdir do |dir|
      size = pool_size
      threads = Thread.list.size
      100.times { |i| assert Swmm.run(i.even? ? Fixtures.base : model(30 + i)).ok? }
      assert_empty swmm_dirs(dir)
      refute Swmm.run(bad_model).ok?
      assert_empty swmm_dirs(dir), "also after an engine error"
      assert_raises(Swmm::InvalidInput) { Swmm.run(junctions: [{ name: "J" }]) }
      assert_empty swmm_dirs(dir), "also after a contract error"
      assert_equal size, pool_size, "Swmm.run uses the default engine, not the pool"
      assert_equal threads, Thread.list.size
    end
  end

  def test_run_many_rounds_leave_no_temp_dirs_no_threads_and_a_bounded_pool
    with_private_tmpdir do |dir|
      Swmm.run_many([Fixtures.base] * 3, workers: 3)
      size = pool_size
      threads = Thread.list.size
      5.times { |i| assert(Swmm.run_many([Fixtures.base, bad_model, model(20 * (i + 1))], workers: 3).one? { !_1.ok? }) }
      assert_empty swmm_dirs(dir)
      assert_equal size, pool_size
      assert_equal threads, Thread.list.size, "run_many joins its workers"
    end
  end

  def test_a_dir_run_keeps_only_its_own_files
    with_private_tmpdir do |dir|
      Dir.mktmpdir("keep") do |keep|
        result = Swmm.run(Fixtures.base, dir: keep)
        assert result.ok?
        assert_empty swmm_dirs(dir)
        assert_equal %w[model.inp model.out model.rpt], Dir.children(keep).sort
      end
    end
  end
end

class ParallelCallersTest < Minitest::Test
  include NeedsEngine
  include ConcurrencySupport

  def run_threads(count)
    Timeout.timeout(30) { Array.new(count) { |i| Thread.new { yield i } }.map(&:value) }
  end

  def test_swmm_run_from_many_threads_gives_correct_distinct_results
    expected = Array.new(8) { |i| flow(Swmm.run(model(10 * (i + 1)))) }
    assert_equal 8, expected.uniq.size
    3.times do
      got = run_threads(8) { |i| flow(Swmm.run(model(10 * (i + 1)))) }
      assert_equal expected, got
    end
  end

  def test_swmm_run_threads_mixed_with_failures_keep_each_result_with_its_caller
    expected = flow(Swmm.run(model(70)))
    got = run_threads(8) { |i| i.odd? ? Swmm.run(bad_model).error&.fetch(:code) : flow(Swmm.run(model(70))) }
    got.each_with_index { |r, i| i.odd? ? assert_equal(200, r) : assert_equal(expected, r) }
  end

  def test_swmm_run_threads_at_the_same_time_as_run_many
    list = peaks.map { model(_1) }
    expected = list.map { flow(Swmm.run(_1)) }
    got = run_threads(5) do |i|
      if i.zero?
        Swmm.run_many(list, workers: 3).map { flow(_1) }
      else
        flow(Swmm.run(list[i]))
      end
    end
    assert_equal expected, got[0]
    (1..4).each { assert_equal expected[_1], got[_1] }
  end

  def test_two_overlapping_run_many_calls_share_the_pool_and_stay_correct
    a = peaks.map { model(_1) }
    b = peaks.reverse.map { model(_1 + 5) }
    expected = [a, b].map { |list| list.map { flow(Swmm.run(_1)) } }
    before = pool_size
    3.times do
      got = run_threads(2) { |i| Swmm.run_many(i.zero? ? a : b, workers: 3).map { flow(_1) } }
      assert_equal expected, got
    end
    assert_operator pool_size, :<=, [before, 3].max, "both calls asked for at most 3 engines"
  end

  def test_four_run_many_calls_with_failures_at_once
    list = [bad_model, model(30), model(60), bad_model, model(90)]
    got = run_threads(4) { Swmm.run_many(list, workers: 2).map(&:ok?) }
    assert_equal [[false, true, true, false, true]] * 4, got
  end
end

class RactorReadsUnderThreadsTest < Minitest::Test
  include NeedsEngine
  include ConcurrencySupport

  OutputFile = Swmm::OutputFile

  def with_knobs(ractors:, parallel_from:)
    was = [OutputFile.ractors, OutputFile.parallel_from]
    OutputFile.ractors = ractors
    OutputFile.parallel_from = parallel_from
    yield
  ensure
    OutputFile.ractors, OutputFile.parallel_from = was
  end

  def everything(result) = { h: result.to_h, csv: %i[nodes links system].to_h { [_1, result.to_csv(_1)] }, series: OutputFile::KINDS.to_h { [_1, result.output.all_series(_1)] } }

  def sequential(result) = with_knobs(ractors: 1, parallel_from: 250_000) { everything(result) }

  def test_four_threads_reading_the_same_output_file_get_identical_results
    result = Swmm.run(Fixtures.base)
    expected = sequential(result)
    with_knobs(ractors: 3, parallel_from: 0) do
      assert_equal expected, everything(result), "Ractors in one thread"
      3.times do
        got = Timeout.timeout(30) { Array.new(4) { Thread.new { everything(result) } }.map(&:value) }
        assert_equal [expected] * 4, got
      end
    end
  end

  def test_four_threads_reading_four_different_output_files
    results = [30, 60, 90, 120].map { Swmm.run(model(_1)) }
    expected = results.map { sequential(_1) }
    assert_equal 4, expected.map { _1[:csv][:links] }.uniq.size
    with_knobs(ractors: 3, parallel_from: 0) do
      2.times do
        got = Timeout.timeout(30) { results.map { |r| Thread.new { everything(r) } }.map(&:value) }
        assert_equal expected, got
      end
    end
  end

  def test_the_big_model_is_identical_with_and_without_ractors_across_threads
    Dir.mktmpdir do |dir|
      result = Swmm.run(Fixtures.full(dir))
      assert result.ok?
      expected = sequential(result)
      with_knobs(ractors: 3, parallel_from: 0) do
        got = Timeout.timeout(60) { Array.new(4) { Thread.new { everything(result) } }.map(&:value) }
        assert_equal [expected] * 4, got
      end
    end
  end

  def test_experimental_warning_is_restored_after_ractor_reads
    result = Swmm.run(Fixtures.base)
    was = Warning[:experimental]
    with_knobs(ractors: 3, parallel_from: 0) do
      [true, false].each do |value|
        Warning[:experimental] = value
        everything(result)
        assert_equal value, Warning[:experimental], "was #{value}"
      end
    end
  ensure
    Warning[:experimental] = was
  end

  def test_experimental_warning_is_restored_when_a_ractor_raises
    result = Swmm.run(Fixtures.base)
    was = Warning[:experimental]
    orig_columns = OutputFile.method(:read_columns).unbind
    orig_rows = OutputFile.method(:csv_rows).unbind
    OutputFile.singleton_class.class_eval do # plain `def`s: no closure, so they stay usable inside a Ractor
      def read_columns(*) = raise("boom in ractor")
      def csv_rows(*) = raise("boom in ractor")
    end
    with_knobs(ractors: 2, parallel_from: 0) do
      [true, false].each do |value|
        Warning[:experimental] = value
        # (Ruby itself prints "terminated with exception" for each failed Ractor on the real stderr; capture_io cannot catch it)
        assert_raises(StandardError) { result.output.all_series(:nodes) }
        assert_raises(StandardError) { result.to_csv(:nodes) } if value
        assert_equal value, Warning[:experimental], "was #{value}"
      end
    end
  ensure
    OutputFile.singleton_class.class_eval do
      define_method(:read_columns, orig_columns)
      define_method(:csv_rows, orig_rows)
    end
    Warning[:experimental] = was
  end

  def test_concurrent_ractor_reads_do_not_lose_the_users_experimental_setting
    output = Swmm.run(Fixtures.base).output
    was = Warning[:experimental]
    Warning[:experimental] = true
    entered_a = Queue.new
    entered_b = Queue.new
    a_done = Queue.new
    a = Thread.new { output.send(:without_experimental_warning) { entered_a << 1; entered_b.pop } ; a_done << 1 }
    b = Thread.new { entered_a.pop; output.send(:without_experimental_warning) { entered_b << 1; a_done.pop } }
    Timeout.timeout(10) { [a, b].each(&:join) }
    assert_equal true, Warning[:experimental]
  ensure
    Warning[:experimental] = was
  end

  # Characterisation of the knobs. ractors <= 1 (0, -1) means "sequential"; a huge value is capped by the object count
  # (all_series) or by the number of periods (csv_rows); parallel_from -1 means "always parallel".
  def test_odd_ractor_counts_and_thresholds_give_the_same_data
    result = Swmm.run(Fixtures.base)
    expected = sequential(result)
    [[0, 0], [-1, 0], [10_000, 0], [3, -1], [10_000, -1], [1, 0], [3, 10**12], [10_000, 10**12]].each do |ractors, from|
      with_knobs(ractors: ractors, parallel_from: from) do
        assert_equal expected, Timeout.timeout(30) { everything(result) }, "ractors #{ractors}, parallel_from #{from}"
      end
    end
  end

  # Characterisation: nil knobs are not defaulted, they raise (NoMethodError for ractors, ArgumentError for parallel_from).
  def test_nil_knobs_raise_instead_of_hanging
    result = Swmm.run(Fixtures.base)
    with_knobs(ractors: nil, parallel_from: 0) do
      assert_raises(NoMethodError, ArgumentError) { Timeout.timeout(10) { result.output.all_series(:nodes) } }
      assert_raises(NoMethodError, ArgumentError) { Timeout.timeout(10) { result.to_csv(:nodes) } }
    end
    with_knobs(ractors: 3, parallel_from: nil) do
      assert_raises(ArgumentError) { Timeout.timeout(10) { result.output.all_series(:nodes) } }
      assert_raises(ArgumentError) { Timeout.timeout(10) { result.to_csv(:nodes) } }
    end
  end

  def test_the_knobs_are_restored_by_with_knobs_even_after_a_failure
    before = [OutputFile.ractors, OutputFile.parallel_from]
    assert_raises(RuntimeError) { with_knobs(ractors: 7, parallel_from: 1) { raise "x" } }
    assert_equal before, [OutputFile.ractors, OutputFile.parallel_from]
  end
end

class FreshProcessTest < Minitest::Test
  include NeedsEngine
  include ConcurrencySupport

  RACE = <<~RUBY
    require "swmm"; require "fixtures"; require "json"
    start = Queue.new
    first = ARGV.first || "available"
    out = Queue.new
    threads = Array.new(8) do |i|
      Thread.new do
        start.pop
        begin
          if first == "available" then Swmm::Engine.available? else r = Swmm.run(Fixtures.base); raise "run failed" unless r.ok? end
          out << [:ok, Swmm::Engine.default.object_id]
        rescue Exception => e
          out << [:error, "\#{e.class}: \#{e.message}"]
        end
      end
    end
    8.times { start << 1 }
    threads.each(&:join)
    res = Array.new(8) { out.pop }
    puts JSON.generate(ok: res.count { _1[0] == :ok }, ids: res.select { _1[0] == :ok }.map(&:last).uniq.size,
                       errors: res.select { _1[0] == :error }.map(&:last), engines: ObjectSpace.each_object(Swmm::Engine).count)
  RUBY

  def test_first_use_from_eight_threads_creates_exactly_one_default_engine_via_available
    out, err, status = ruby(RACE.sub('ARGV.first || "available"', '"available"'))
    assert status.success?, err
    assert_equal({ "ok" => 8, "ids" => 1, "errors" => [], "engines" => 1 }, JSON.parse(out))
  end

  def test_first_use_from_eight_threads_creates_exactly_one_default_engine_via_run
    out, err, status = ruby(RACE.sub('ARGV.first || "available"', '"run"'))
    assert status.success?, err
    assert_equal({ "ok" => 8, "ids" => 1, "errors" => [], "engines" => 1 }, JSON.parse(out))
  end

  def test_first_use_of_the_pool_from_eight_threads_creates_one_set_of_copies
    script = <<~RUBY
      require "swmm"; require "fixtures"; require "json"
      start = Queue.new
      ths = Array.new(8) { Thread.new { start.pop; Swmm.run_many([Fixtures.base] * 3, workers: 3).map(&:ok?) } }
      8.times { start << 1 }
      res = ths.map(&:value)
      pool = Swmm::Engine.instance_variable_get(:@pool)
      puts JSON.generate(res: res, pool: pool.size, copies: Dir.children(Swmm::Engine.instance_variable_get(:@copies)).size)
    RUBY
    out, err, status = ruby(script)
    assert status.success?, err
    assert_equal({ "res" => [[true] * 3] * 8, "pool" => 3, "copies" => 3 }, JSON.parse(out))
  end

  def test_the_library_copies_are_removed_when_the_process_exits_normally
    Dir.mktmpdir do |tmp|
      script = 'require "swmm"; require "fixtures"; Swmm.run_many([Fixtures.base] * 3, workers: 3); ' \
               'd = Swmm::Engine.instance_variable_get(:@copies); puts d, Dir.children(d).size'
      out, err, status = ruby(script, env: { "TMPDIR" => tmp })
      assert status.success?, err
      dir, count = out.lines.map(&:chomp)
      assert_equal "3", count, "the copies existed while the process ran"
      assert dir.start_with?(File.realpath(tmp)) || dir.start_with?(tmp), "the copies were made under TMPDIR (#{dir})"
      assert_empty Dir.children(tmp), "nothing left under TMPDIR after a normal exit"
    end
  end

  def test_the_library_copies_are_removed_when_the_process_dies_with_an_exception
    Dir.mktmpdir do |tmp|
      script = 'require "swmm"; require "fixtures"; Swmm.run_many([Fixtures.base] * 2, workers: 2); raise "crash"'
      _out, err, status = ruby(script, env: { "TMPDIR" => tmp })
      refute status.success?
      assert_match(/crash/, err)
      assert_empty Dir.children(tmp)
    end
  end

  def test_the_library_copies_are_removed_after_a_sigterm
    Dir.mktmpdir do |tmp|
      script = 'require "swmm"; require "fixtures"; Swmm.run_many([Fixtures.base] * 2, workers: 2); puts "ready"; $stdout.flush; sleep 30'
      Open3.popen3({ "TMPDIR" => tmp }, RbConfig.ruby, "-Ilib", "-Itest", "-e", script, chdir: ROOT) do |stdin, stdout, stderr, waiter|
        stdin.close
        assert_equal "ready", Timeout.timeout(30) { stdout.gets.to_s.chomp }
        Process.kill("TERM", waiter.pid)
        unless waiter.join(30)
          Process.kill("KILL", waiter.pid)
          flunk "did not exit on SIGTERM"
        end
        stderr.read
      end
      assert_empty Dir.children(tmp)
    end
  end

  def test_a_forked_child_exiting_must_not_remove_the_parents_library_copies
    script = <<~RUBY
      require "swmm"; require "fixtures"
      Swmm.run_many([Fixtures.base] * 2, workers: 2)
      Process.wait(fork { exit 0 })
      puts Swmm.run_many([Fixtures.base] * 4, workers: 4).map(&:ok?).inspect
    RUBY
    out, err, status = ruby(script)
    assert status.success?, err
    assert_equal "[true, true, true, true]", out.strip
  end

  def test_ractor_reads_in_a_fresh_process_print_no_experimental_warning_and_restore_the_flag
    script = <<~RUBY
      require "swmm"; require "fixtures"
      r = Swmm.run(Fixtures.base)
      Swmm::OutputFile.ractors = 3
      Swmm::OutputFile.parallel_from = 0
      r.to_h; r.to_csv(:nodes)
      puts Warning[:experimental]
    RUBY
    out, err, status = ruby(script)
    assert status.success?, err
    assert_equal "true", out.strip, "the default (true) is back"
    refute_match(/experimental/i, err)
    assert_empty err
  end

  # SWMM_LIB handling. The vendor/ build is also a candidate, so the checks compare entry points with each other instead of
  # assuming the vendor file is missing.
  def test_a_bad_swmm_lib_path_gives_the_same_answer_for_run_and_run_many
    Dir.mktmpdir do |tmp|
      fake = File.join(tmp, "libswmm5.fake")
      File.write(fake, "not a library")
      script = <<~RUBY
        require "swmm"; require "fixtures"
        one = (Swmm.run(Fixtures.base).ok? rescue $!.class)
        many = (Swmm.run_many([Fixtures.base]).first.ok? rescue $!.class)
        puts one.inspect, many.inspect
      RUBY
      out, err, status = ruby(script, env: { "SWMM_LIB" => fake })
      assert status.success?, err
      one, many = out.lines.map(&:chomp)
      assert_equal one, many, "Swmm.run -> #{one}, Swmm.run_many -> #{many} (stderr: #{err})"
    end
  end

  # Characterisation: an unusable SWMM_LIB is silently skipped when another candidate (vendor/, system) loads.
  def test_a_missing_swmm_lib_path_falls_back_to_the_next_candidate
    out, err, status = ruby('require "swmm"; require "fixtures"; puts Swmm::Engine.available?, Swmm.run(Fixtures.base).ok?, Swmm.run_many([Fixtures.base]).first.ok?',
                            env: { "SWMM_LIB" => "/nonexistent/libswmm5.so" })
    assert status.success?, err
    assert_equal %w[true true true], out.lines.map(&:chomp)
  end

  def test_with_no_loadable_candidate_available_is_false_and_the_error_names_every_path_tried
    Dir.mktmpdir do |tmp|
      fake = File.join(tmp, "libswmm5.fake")
      File.write(fake, "not a library")
      # replaces the candidate list so that the result does not depend on vendor/ or a system install
      script = <<~RUBY
        require "swmm"; require "fixtures"
        class << Swmm::Engine
          def library_candidates = [ENV["SWMM_LIB"], "/nonexistent/libswmm5.so"]
        end
        puts Swmm::Engine.available?
        [-> { Swmm.run(Fixtures.base) }, -> { Swmm.run_many([Fixtures.base]) }, -> { Swmm.version }, -> { Swmm::Engine.new([ENV["SWMM_LIB"]]) }].each do |call|
          begin
            call.call
            puts "no error"
          rescue Swmm::LibraryNotFound => e
            puts e.message
          rescue Exception => e
            puts "UNEXPECTED \#{e.class}: \#{e.message}"
          end
        end
      RUBY
      out, err, status = ruby(script, env: { "SWMM_LIB" => fake })
      assert status.success?, err
      lines = out.lines.map(&:chomp)
      assert_equal "false", lines.first
      lines[1..4].each do |message|
        assert_match(/\Alibswmm5 not found \(tried #{Regexp.escape(fake)}, \/nonexistent\/libswmm5\.so\)/, message)
        assert_includes message, "rake swmm:build"
      end
      assert_equal 5, lines.size, lines.inspect
      assert_empty Dir.children(tmp) - ["libswmm5.fake"]
    end
  end

  def test_with_only_missing_candidates_no_copies_directory_is_created
    script = <<~RUBY
      require "swmm"; require "fixtures"
      class << Swmm::Engine
        def library_candidates = ["/nonexistent/a.so", "/nonexistent/b.so"]
      end
      begin; Swmm.run_many([Fixtures.base]); rescue Swmm::LibraryNotFound => e; puts e.message; end
      p Swmm::Engine.instance_variable_get(:@copies), Swmm::Engine.instance_variable_get(:@pool)
    RUBY
    Dir.mktmpdir do |tmp|
      out, err, status = ruby(script, env: { "TMPDIR" => tmp })
      assert status.success?, err
      message, copies, pool = out.lines.map(&:chomp)
      assert_match(%r{tried /nonexistent/a\.so, /nonexistent/b\.so\)}, message)
      assert_equal "nil", copies
      assert_includes %w[nil []], pool, "no engine was created" # nil: it failed before the pool was touched
      assert_empty Dir.children(tmp)
    end
  end

  def test_engine_new_raises_library_not_found_for_a_missing_file_and_for_a_non_library
    Dir.mktmpdir do |tmp|
      fake = File.join(tmp, "x.dylib")
      File.write(fake, "not a library")
      [fake, File.join(tmp, "missing.so")].each do |path|
        error = assert_raises(Swmm::LibraryNotFound) { Swmm::Engine.new([path]) }
        assert_match(/libswmm5 not found/, error.message)
      end
    end
  end
end
