require_relative '../swmm_helper'
require_relative '../support/swmm_concurrency'

# run_many, the engine pool, threads, Ractor reads and the process lifecycle (see spec/support/swmm_concurrency.rb).
RSpec.describe Swmm, 'concurrency', :libswmm5 do
  include SwmmConcurrency

  describe 'run_many arguments' do
    def expected_flows = peaks.map { |q| flow(described_class.run(model(q))) }

    it 'gives the results in input order for every workers value' do
      expected = expected_flows
      expect(expected.uniq.size).to eq(peaks.size), 'the models really produce different results'
      [1, 2, 3, peaks.size, 50, nil].each do |workers|
        results = workers ? described_class.run_many(peaks.map { model(it) }, workers: workers) : described_class.run_many(peaks.map { model(it) })
        expect(results.all?(&:ok?)).to be(true), "workers: #{workers.inspect}"
        expect(results.map { flow(it) }).to eq(expected), "workers: #{workers.inspect}"
      end
    end

    it 'creates no extra engine copies for more workers than inputs' do
      Swmm::Engine.pool(2)
      before = pool_size
      described_class.run_many([SwmmFixtures.base, SwmmFixtures.base], workers: 500)
      expect(pool_size).to eq(before), 'at most 2 workers are needed for 2 inputs, 2 copies already existed'
    end

    it 'grows the pool to the largest size requested and reuses it' do
      described_class.run_many([SwmmFixtures.base] * 4, workers: 4)
      size = pool_size
      expect(size).to be >= 4
      3.times { described_class.run_many([SwmmFixtures.base] * 3, workers: 2) }
      expect(pool_size).to eq(size)
      expect(Swmm::Engine.pool(4)).to eq(Swmm::Engine.pool(4)), 'the same engine objects come back'
      expect(Swmm::Engine.pool(2)).to eq(Swmm::Engine.pool(4).first(2))
    end

    it 'runs everything on the first pool engine, not the default one, with one worker' do
      first = Swmm::Engine.pool(1).first
      expect(first).not_to be(Swmm::Engine.default), 'the pool has its own library copies'
      used = []
      first.singleton_class.prepend(Module.new do 
        define_method(:run) do |*a| 
          used << :first
          super(*a)
        end
      end)
      expect(described_class.run_many([SwmmFixtures.base] * 3, workers: 1).all?(&:ok?)).to be(true)
      expect(used).to eq(%i[first] * 3)
    end

    it 'returns an empty Array for an empty list and creates nothing' do
      before = pool_size
      expect(described_class.run_many([])).to eq([])
      expect(described_class.run_many([], workers: 0)).to eq([]), 'nothing to do: workers is never looked at'
      expect(pool_size).to eq(before)
    end

    it 'gives independent equal results for the same object repeated' do
      input = Swmm::Input.new(model(40))
      hash = model(40)
      [[input] * 5, [hash] * 5].each do |list|
        results = described_class.run_many(list, workers: 3)
        expect(results.map(&:object_id).uniq.size).to eq(5), 'one Result per slot'
        expect(results.map { flow(it) }.uniq.size).to eq(1)
        expect(flow(results.first)).to eq(flow(described_class.run(hash)))
      end
    end

    it 'takes Hashes, Inputs and .inp paths mixed' do
      Dir.mktmpdir do |dir|
        Swmm::Input.new(model(160)).write(inp = File.join(dir, 'm.inp'))
        list = [model(10), Swmm::Input.new(model(40)), inp, model(80), inp]
        results = described_class.run_many(list, workers: 2)
        expect(results.map { flow(it) }).to eq([10, 40, 160, 80, 160].map { flow(described_class.run(model(it))) })
        expect(results.all? { it.files.nil? }).to be(true), 'run_many only uses temp files'
      end
    end

    # Characterisation: workers: 2.5 is accepted (Array#first and Integer comparison truncate / accept it).
    it 'accepts a Float worker count' do
      results = described_class.run_many([SwmmFixtures.base] * 3, workers: 2.5)
      expect(results.map(&:ok?)).to eq([true] * 3)
    end

    # Characterisation: nil, "3" and -1 raise ArgumentError before anything runs (the messages are not very friendly:
    # "comparison of Integer with nil failed", "negative array size").
    it 'raises ArgumentError for nil, String and negative worker counts without running' do
      count_engine_runs do |calls|
        [nil, '3', -1].each do |workers|
          expect { Timeout.timeout(10) { described_class.run_many([SwmmFixtures.base] * 2, workers: workers) } }.to raise_error(ArgumentError), "workers: #{workers.inspect}"
        end
        expect(calls.call).to eq(0)
      end
    end

    it 'does not take zero workers silently as a list of nils' do
      out = begin
        Timeout.timeout(10) { described_class.run_many([SwmmFixtures.base] * 3, workers: 0) }
      rescue ArgumentError
        :argument_error
      end
      expect(out == :argument_error || out.all?(Swmm::Result)).to be(true), "expected ArgumentError or real Results, got #{out.inspect}"
    end

    it 'does not take a Hash for a list of models' do
      out = begin
        described_class.run_many(SwmmFixtures.base)
      rescue ArgumentError, TypeError, Swmm::InvalidInput
        :rejected
      end
      expect(out.is_a?(Array) ? "#{out.size} results, errors #{out.map { it.error[:code] }.uniq}" : out).to eq(:rejected)
    end

    it 'rejects nil elements like other bad inputs' do
      expect { described_class.run_many([nil]) }.to raise_error(a_kind_of(ArgumentError).or(a_kind_of(TypeError)).or(a_kind_of(Swmm::InvalidInput)))
    end

    # Characterisation: a path that does not exist is NOT a contract error (paths are not checked), it is an engine error.
    it 'gives a missing .inp path as an error result for that slot only' do
      results = described_class.run_many([SwmmFixtures.base, '/nonexistent/model.inp', SwmmFixtures.base], workers: 2)
      expect(results.map(&:ok?)).to eq([true, false, true])
      expect(results[1].error[:code]).to eq(303)
    end
  end

  describe 'run_many errors' do
    it 'keeps an engine error in its own slot whatever the position' do
      good = flow(described_class.run(SwmmFixtures.base))
      [[bad_model, SwmmFixtures.base, SwmmFixtures.base], [SwmmFixtures.base, bad_model, SwmmFixtures.base],
       [SwmmFixtures.base, SwmmFixtures.base, bad_model], [bad_model] * 3].each do |list|
        [1, 2, 3].each do |workers|
          results = described_class.run_many(list, workers: workers)
          expect(results.map(&:ok?)).to eq(list.map { !it.equal?(bad_model) && it != bad_model }), "workers #{workers}"
          results.each { |r| r.ok? ? expect(flow(r)).to(eq(good)) : expect(r.error[:code]).to(eq(200)) }
        end
      end
    end

    it 'raises a contract error before any simulation or engine copy starts' do
      before = pool_size
      count_engine_runs do |calls|
        expect { described_class.run_many(([SwmmFixtures.base] * 4) + [{ junctions: [{ name: 'J' }] }], workers: 8) }
          .to raise_error(Swmm::InvalidInput, /junctions\[0\]/)
        expect(calls.call).to eq(0), 'no simulation may start'
      end
      expect(pool_size).to eq(before), 'no engine copy may be created'
    end

    it 'lets an exception in a worker reach the caller, and the next run_many works' do
      with_private_tmpdir do |dir|
        baseline = Thread.list.size
        count_engine_runs(raise_on: 2) do
          capture_io do # the failed thread also reports itself on stderr, see 'does not let a failed worker write to stderr'
            expect { Timeout.timeout(10) { described_class.run_many(peaks.map { model(it) }, workers: 2) } }.to raise_error(RuntimeError, 'boom')
          end
        end
        expect(threads_settle?(baseline)).to be(true), "worker threads are still alive: #{Thread.list.size} vs #{baseline}"
        expect(swmm_dirs(dir)).to be_empty, 'temp dirs of the failed run were removed'
        results = Timeout.timeout(10) { described_class.run_many(peaks.map { model(it) }, workers: 2) }
        expect(results.map { flow(it) }).to eq(peaks.map { flow(described_class.run(model(it))) })
      end
    end

    it 'stops the other workers taking jobs after one fails' do
      total = 40
      count_engine_runs(raise_on: 2) do |calls|
        capture_io do
          expect { Timeout.timeout(20) { described_class.run_many([SwmmFixtures.base] * total, workers: 2) } }.to raise_error(RuntimeError)
        end
        expect(calls.call).to be <= 4, "2 workers: one dies at call 2, the other may finish the job it holds, then stops (ran #{calls.call} of #{total})"
      end
    end

    it 'does not let a failed worker write to stderr' do
      count_engine_runs(raise_on: 1) do
        _out, err = capture_io { expect { described_class.run_many([SwmmFixtures.base] * 3, workers: 2) }.to raise_error(RuntimeError) }
        expect(err).to be_empty
      end
    end
  end

  describe 'state hygiene' do
    it 'does not let a failed run poison the next one on the default engine' do
      good = described_class.run(model(80))
      3.times do
        expect(described_class.run(bad_model)).not_to be_ok
        again = described_class.run(model(80))
        expect(again).to be_ok
        expect(flow(again)).to eq(flow(good))
        expect(again.continuity).to eq(good.continuity)
        expect(again.to_h(series: false).except(:files)).to eq(good.to_h(series: false).except(:files))
      end
    end

    it 'does not let a failed run poison the next one on a pool engine' do
      good = described_class.run_many([model(80)], workers: 1).first
      10.times do
        expect(described_class.run_many([bad_model, model(80)], workers: 1).map(&:ok?)).to eq([false, true]), 'a single engine runs both, in order'
      end
      expect(flow(described_class.run_many([model(80)], workers: 1).first)).to eq(flow(good))
    end

    it 'follows an error after the engine started with a clean run' do
      good = flow(described_class.run(model(40)))
      # a model without an outfall is refused by the engine after the file was parsed (the other example fails at open)
      no_outfall = SwmmFixtures.base.merge(outfalls: [], conduits: [SwmmFixtures.base[:conduits].first.merge(to_node: 'J2')], xsections: [SwmmFixtures.base[:xsections].first])
      failed = described_class.run(no_outfall)
      expect(failed).not_to be_ok
      expect(failed.error[:message]).to match(/ERROR \d+/)
      expect(flow(described_class.run(model(40)))).to eq(good)
    end

    it 'leaves no temp dirs and no new engine copies after many sequential runs' do
      with_private_tmpdir do |dir|
        size = pool_size
        threads = Thread.list.size
        100.times { |i| expect(described_class.run(i.even? ? SwmmFixtures.base : model(30 + i))).to be_ok }
        expect(swmm_dirs(dir)).to be_empty
        expect(described_class.run(bad_model)).not_to be_ok
        expect(swmm_dirs(dir)).to be_empty, 'also after an engine error'
        expect { described_class.run(junctions: [{ name: 'J' }]) }.to raise_error(Swmm::InvalidInput)
        expect(swmm_dirs(dir)).to be_empty, 'also after a contract error'
        expect(pool_size).to eq(size), 'Swmm.run uses the default engine, not the pool'
        expect(Thread.list.size).to eq(threads)
      end
    end

    it 'leaves no temp dirs, no threads and a bounded pool after run_many rounds' do
      with_private_tmpdir do |dir|
        described_class.run_many([SwmmFixtures.base] * 3, workers: 3)
        size = pool_size
        threads = Thread.list.size
        5.times { |i| expect(described_class.run_many([SwmmFixtures.base, bad_model, model(20 * (i + 1))], workers: 3).one? { !it.ok? }).to be(true) }
        expect(swmm_dirs(dir)).to be_empty
        expect(pool_size).to eq(size)
        expect(Thread.list.size).to eq(threads), 'run_many joins its workers'
      end
    end

    it 'keeps only its own files in a dir: run' do
      with_private_tmpdir do |dir|
        Dir.mktmpdir('keep') do |keep|
          result = described_class.run(SwmmFixtures.base, dir: keep)
          expect(result).to be_ok
          expect(swmm_dirs(dir)).to be_empty
          expect(Dir.children(keep).sort).to eq(%w[model.inp model.out model.rpt])
        end
      end
    end
  end

  describe 'parallel callers' do
    def run_threads(count, &)
      Timeout.timeout(30) { Array.new(count) { |i| Thread.new { yield i } }.map(&:value) }
    end

    it 'gives correct distinct results to Swmm.run from many threads' do
      expected = Array.new(8) { |i| flow(described_class.run(model(10 * (i + 1)))) }
      expect(expected.uniq.size).to eq(8)
      3.times do
        got = run_threads(8) { |i| flow(described_class.run(model(10 * (i + 1)))) }
        expect(got).to eq(expected)
      end
    end

    it 'keeps each result with its caller in Swmm.run threads mixed with failures' do
      expected = flow(described_class.run(model(70)))
      got = run_threads(8) { |i| i.odd? ? described_class.run(bad_model).error&.fetch(:code) : flow(described_class.run(model(70))) }
      got.each_with_index { |r, i| i.odd? ? expect(r).to(eq(200)) : expect(r).to(eq(expected)) }
    end

    it 'runs Swmm.run threads at the same time as run_many' do
      list = peaks.map { model(it) }
      expected = list.map { flow(described_class.run(it)) }
      got = run_threads(5) do |i|
        if i.zero?
          described_class.run_many(list, workers: 3).map { flow(it) }
        else
          flow(described_class.run(list[i]))
        end
      end
      expect(got[0]).to eq(expected)
      (1..4).each { expect(got[it]).to eq(expected[it]) }
    end

    it 'shares the pool between two overlapping run_many calls and stays correct' do
      a = peaks.map { model(it) }
      b = peaks.reverse.map { model(it + 5) }
      expected = [a, b].map { |list| list.map { flow(described_class.run(it)) } }
      before = pool_size
      3.times do
        got = run_threads(2) { |i| described_class.run_many(i.zero? ? a : b, workers: 3).map { flow(it) } }
        expect(got).to eq(expected)
      end
      expect(pool_size).to be <= [before, 3].max, 'both calls asked for at most 3 engines'
    end

    it 'runs four run_many calls with failures at once' do
      list = [bad_model, model(30), model(60), bad_model, model(90)]
      got = run_threads(4) { described_class.run_many(list, workers: 2).map(&:ok?) }
      expect(got).to eq([[false, true, true, false, true]] * 4)
    end
  end

  describe 'Ractor reads under threads' do
    def with_knobs(ractors:, parallel_from:)
      was = [Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from]
      Swmm::OutputFile.ractors = ractors
      Swmm::OutputFile.parallel_from = parallel_from
      yield
    ensure
      Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from = was
    end

    def everything(result) = { h: result.to_h, csv: %i[nodes links system].to_h { [it, result[it].to_csv] }, series: Swmm::OutputFile::KINDS.to_h { [it, result.output[it].to_h] } }

    def sequential(result) = with_knobs(ractors: 1, parallel_from: 250_000) { everything(result) }

    it 'gives identical results to four threads reading the same output file' do
      result = described_class.run(SwmmFixtures.base)
      expected = sequential(result)
      with_knobs(ractors: 3, parallel_from: 0) do
        expect(everything(result)).to eq(expected), 'Ractors in one thread'
        3.times do
          got = Timeout.timeout(30) { Array.new(4) { Thread.new { everything(result) } }.map(&:value) }
          expect(got).to eq([expected] * 4)
        end
      end
    end

    it 'reads four different output files from four threads' do
      results = [30, 60, 90, 120].map { described_class.run(model(it)) }
      expected = results.map { sequential(it) }
      expect(expected.map { it[:csv][:links] }.uniq.size).to eq(4)
      with_knobs(ractors: 3, parallel_from: 0) do
        2.times do
          got = Timeout.timeout(30) { results.map { |r| Thread.new { everything(r) } }.map(&:value) }
          expect(got).to eq(expected)
        end
      end
    end

    it 'gives the big model identical with and without Ractors across threads' do
      Dir.mktmpdir do |dir|
        result = described_class.run(SwmmFixtures.full(dir))
        expect(result).to be_ok
        expected = sequential(result)
        with_knobs(ractors: 3, parallel_from: 0) do
          got = Timeout.timeout(60) { Array.new(4) { Thread.new { everything(result) } }.map(&:value) }
          expect(got).to eq([expected] * 4)
        end
      end
    end

    it 'restores the experimental warning after Ractor reads' do
      result = described_class.run(SwmmFixtures.base)
      was = Warning[:experimental]
      with_knobs(ractors: 3, parallel_from: 0) do
        [true, false].each do |value|
          Warning[:experimental] = value
          everything(result)
          expect(Warning[:experimental]).to eq(value), "was #{value}"
        end
      end
    ensure
      Warning[:experimental] = was
    end

    it 'restores the experimental warning when a Ractor raises' do
      result = described_class.run(SwmmFixtures.base)
      was = Warning[:experimental]
      orig_columns = Swmm::OutputReader.method(:read_columns).unbind
      orig_rows = Swmm::OutputReader.method(:csv_rows).unbind
      Swmm::OutputReader.singleton_class.class_eval do # plain `def`s: no closure, so they stay usable inside a Ractor
        def read_columns(*) = raise('boom in ractor')
        def csv_rows(*) = raise('boom in ractor')
      end
      with_knobs(ractors: 2, parallel_from: 0) do
        [true, false].each do |value|
          Warning[:experimental] = value
          # (Ruby itself prints "terminated with exception" for each failed Ractor on the real stderr; capture_io cannot catch it)
          expect { result.output.nodes.to_h }.to raise_error(StandardError)
          expect { result.nodes.to_csv }.to raise_error(StandardError) if value
          expect(Warning[:experimental]).to eq(value), "was #{value}"
        end
      end
    ensure
      Swmm::OutputReader.singleton_class.class_eval do
        define_method(:read_columns, orig_columns)
        define_method(:csv_rows, orig_rows)
      end
      Warning[:experimental] = was
    end

    it "does not lose the user's experimental setting to concurrent Ractor reads" do
      was = Warning[:experimental]
      Warning[:experimental] = true
      entered_a = Queue.new
      entered_b = Queue.new
      a_done = Queue.new
      a = Thread.new do
        Swmm::OutputReader.without_experimental_warning do
          entered_a << 1
          entered_b.pop
        end
        a_done << 1
      end
      b = Thread.new do
        entered_a.pop
        Swmm::OutputReader.without_experimental_warning do
          entered_b << 1
          a_done.pop
        end
      end
      Timeout.timeout(10) { [a, b].each(&:join) }
      expect(Warning[:experimental]).to be(true)
    ensure
      Warning[:experimental] = was
    end

    # Characterisation of the knobs. ractors <= 1 (0, -1) means "sequential"; a huge value is capped by the object count
    # (all_series) or by the number of periods (csv_rows); parallel_from -1 means "always parallel".
    it 'gives the same data for odd Ractor counts and thresholds' do
      result = described_class.run(SwmmFixtures.base)
      expected = sequential(result)
      [[0, 0], [-1, 0], [10_000, 0], [3, -1], [10_000, -1], [1, 0], [3, 10**12], [10_000, 10**12]].each do |ractors, from|
        with_knobs(ractors: ractors, parallel_from: from) do
          expect(Timeout.timeout(30) { everything(result) }).to eq(expected), "ractors #{ractors}, parallel_from #{from}"
        end
      end
    end

    # Characterisation: nil knobs are not defaulted, they raise (NoMethodError for ractors, ArgumentError for parallel_from).
    it 'raises for nil knobs instead of hanging' do
      result = described_class.run(SwmmFixtures.base)
      with_knobs(ractors: nil, parallel_from: 0) do
        expect { Timeout.timeout(10) { result.output.nodes.to_h } }.to raise_error(a_kind_of(NoMethodError).or(a_kind_of(ArgumentError)))
        expect { Timeout.timeout(10) { result.nodes.to_csv } }.to raise_error(a_kind_of(NoMethodError).or(a_kind_of(ArgumentError)))
      end
      with_knobs(ractors: 3, parallel_from: nil) do
        expect { Timeout.timeout(10) { result.output.nodes.to_h } }.to raise_error(ArgumentError)
        expect { Timeout.timeout(10) { result.nodes.to_csv } }.to raise_error(ArgumentError)
      end
    end

    it 'restores the knobs in with_knobs even after a failure' do
      before = [Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from]
      expect { with_knobs(ractors: 7, parallel_from: 1) { raise 'x' } }.to raise_error(RuntimeError)
      expect([Swmm::OutputFile.ractors, Swmm::OutputFile.parallel_from]).to eq(before)
    end
  end

  describe 'a fresh process' do
    it 'creates exactly one default engine on first use from eight threads, via available?' do
      out, err, status = ruby(race('available'))
      expect(status).to be_success, err
      expect(JSON.parse(out)).to eq('ok' => 8, 'ids' => 1, 'errors' => [], 'engines' => 1)
    end

    it 'creates exactly one default engine on first use from eight threads, via run' do
      out, err, status = ruby(race('run'))
      expect(status).to be_success, err
      expect(JSON.parse(out)).to eq('ok' => 8, 'ids' => 1, 'errors' => [], 'engines' => 1)
    end

    it 'creates one set of copies on first use of the pool from eight threads' do
      script = <<~RUBY
        require "swmm_standalone"; require "swmm_fixtures"; require "json"
        start = Queue.new
        ths = Array.new(8) { Thread.new { start.pop; Swmm.run_many([SwmmFixtures.base] * 3, workers: 3).map(&:ok?) } }
        8.times { start << 1 }
        res = ths.map(&:value)
        pool = Swmm::Engine.instance_variable_get(:@pool)
        puts JSON.generate(res: res, pool: pool.size, copies: Dir.children(Swmm::Engine.instance_variable_get(:@copies)).size)
      RUBY
      out, err, status = ruby(script)
      expect(status).to be_success, err
      expect(JSON.parse(out)).to eq('res' => [[true] * 3] * 8, 'pool' => 3, 'copies' => 3)
    end

    it 'removes the library copies when the process exits normally' do
      Dir.mktmpdir do |tmp|
        script = 'require "swmm_standalone"; require "swmm_fixtures"; Swmm.run_many([SwmmFixtures.base] * 3, workers: 3); ' \
                 'd = Swmm::Engine.instance_variable_get(:@copies); puts d, Dir.children(d).size'
        out, err, status = ruby(script, env: { 'TMPDIR' => tmp })
        expect(status).to be_success, err
        dir, count = out.lines.map(&:chomp)
        expect(count).to eq('3'), 'the copies existed while the process ran'
        expect(dir.start_with?(File.realpath(tmp), tmp)).to be(true), "the copies were made under TMPDIR (#{dir})"
        expect(Dir.children(tmp)).to be_empty, 'nothing left under TMPDIR after a normal exit'
      end
    end

    it 'removes the library copies when the process dies with an exception' do
      Dir.mktmpdir do |tmp|
        script = 'require "swmm_standalone"; require "swmm_fixtures"; Swmm.run_many([SwmmFixtures.base] * 2, workers: 2); raise "crash"'
        _out, err, status = ruby(script, env: { 'TMPDIR' => tmp })
        expect(status).not_to be_success
        expect(err).to include('crash')
        expect(Dir.children(tmp)).to be_empty
      end
    end

    it 'removes the library copies after a SIGTERM' do
      Dir.mktmpdir do |tmp|
        script = 'require "swmm_standalone"; require "swmm_fixtures"; Swmm.run_many([SwmmFixtures.base] * 2, workers: 2); puts "ready"; $stdout.flush; sleep 30'
        Open3.popen3({ 'TMPDIR' => tmp }, RbConfig.ruby, '-Ispec/support', '-e', script, chdir: SwmmConcurrency::ROOT) do |stdin, stdout, stderr, waiter|
          stdin.close
          expect(Timeout.timeout(30) { stdout.gets.to_s.chomp }).to eq('ready')
          Process.kill('TERM', waiter.pid)
          unless waiter.join(30)
            Process.kill('KILL', waiter.pid)
            RSpec::Expectations.fail_with('did not exit on SIGTERM')
          end
          stderr.read
        end
        expect(Dir.children(tmp)).to be_empty
      end
    end

    it "does not let a forked child exiting remove the parent's library copies" do
      script = <<~RUBY
        require "swmm_standalone"; require "swmm_fixtures"
        Swmm.run_many([SwmmFixtures.base] * 2, workers: 2)
        Process.wait(fork { exit 0 })
        puts Swmm.run_many([SwmmFixtures.base] * 4, workers: 4).map(&:ok?).inspect
      RUBY
      out, err, status = ruby(script)
      expect(status).to be_success, err
      expect(out.strip).to eq('[true, true, true, true]')
    end

    it 'prints no experimental warning for Ractor reads and restores the flag' do
      script = <<~RUBY
        require "swmm_standalone"; require "swmm_fixtures"
        r = Swmm.run(SwmmFixtures.base)
        Swmm::OutputFile.ractors = 3
        Swmm::OutputFile.parallel_from = 0
        r.to_h; r.nodes.to_csv
        puts Warning[:experimental]
      RUBY
      out, err, status = ruby(script)
      expect(status).to be_success, err
      expect(out.strip).to eq('true'), 'the default (true) is back'
      expect(err).not_to match(/experimental/i)
      expect(err).to be_empty
    end

    # SWMM_LIB handling. The vendor/ build is also a candidate, so the checks compare entry points with each other instead of
    # assuming the vendor file is missing.
    it 'gives the same answer for run and run_many with a bad SWMM_LIB path' do
      Dir.mktmpdir do |tmp|
        fake = File.join(tmp, 'libswmm5.fake')
        File.write(fake, 'not a library')
        script = <<~RUBY
          require "swmm_standalone"; require "swmm_fixtures"
          one = (Swmm.run(SwmmFixtures.base).ok? rescue $!.class)
          many = (Swmm.run_many([SwmmFixtures.base]).first.ok? rescue $!.class)
          puts one.inspect, many.inspect
        RUBY
        out, err, status = ruby(script, env: { 'SWMM_LIB' => fake })
        expect(status).to be_success, err
        one, many = out.lines.map(&:chomp)
        expect(many).to eq(one), "Swmm.run -> #{one}, Swmm.run_many -> #{many} (stderr: #{err})"
      end
    end

    # Characterisation: an unusable SWMM_LIB is silently skipped when another candidate (vendor/, system) loads.
    # run_many needs that candidate as a file, so vendor/ (where the CI and prod images put it) is the one to look for.
    it 'falls back to the next candidate for a missing SWMM_LIB path' do
      vendor = File.join(Swmm::Engine::ROOT, 'vendor', 'swmm', "libswmm5.#{FFI::Platform::LIBSUFFIX}")
      skip "no libswmm5 in #{vendor} to fall back to (bin/rails swmm:build)" unless File.file?(vendor)
      out, err, status = ruby('require "swmm_standalone"; require "swmm_fixtures"; puts Swmm::Engine.available?, Swmm.run(SwmmFixtures.base).ok?, Swmm.run_many([SwmmFixtures.base]).first.ok?',
                              env: { 'SWMM_LIB' => '/nonexistent/libswmm5.so' })
      expect(status).to be_success, err
      expect(out.lines.map(&:chomp)).to eq(%w[true true true])
    end

    it 'is not available with no loadable candidate, and the error names every path tried' do
      Dir.mktmpdir do |tmp|
        fake = File.join(tmp, 'libswmm5.fake')
        File.write(fake, 'not a library')
        # replaces the candidate list so that the result does not depend on vendor/ or a system install
        script = <<~RUBY
          require "swmm_standalone"; require "swmm_fixtures"
          class << Swmm::Engine
            def library_candidates = [ENV["SWMM_LIB"], "/nonexistent/libswmm5.so"]
          end
          puts Swmm::Engine.available?
          [-> { Swmm.run(SwmmFixtures.base) }, -> { Swmm.run_many([SwmmFixtures.base]) }, -> { Swmm.version }, -> { Swmm::Engine.new([ENV["SWMM_LIB"]]) }].each do |call|
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
        out, err, status = ruby(script, env: { 'SWMM_LIB' => fake })
        expect(status).to be_success, err
        lines = out.lines.map(&:chomp)
        expect(lines.first).to eq('false')
        lines[1..4].each do |message|
          expect(message).to match(%r{\Alibswmm5 not found \(tried #{Regexp.escape(fake)}, /nonexistent/libswmm5\.so\)})
          expect(message).to include('rake swmm:build')
        end
        expect(lines.size).to eq(5), lines.inspect
        expect(Dir.children(tmp) - ['libswmm5.fake']).to be_empty
      end
    end

    it 'creates no copies directory with only missing candidates' do
      script = <<~RUBY
        require "swmm_standalone"; require "swmm_fixtures"
        class << Swmm::Engine
          def library_candidates = ["/nonexistent/a.so", "/nonexistent/b.so"]
        end
        begin; Swmm.run_many([SwmmFixtures.base]); rescue Swmm::LibraryNotFound => e; puts e.message; end
        p Swmm::Engine.instance_variable_get(:@copies), Swmm::Engine.instance_variable_get(:@pool)
      RUBY
      Dir.mktmpdir do |tmp|
        out, err, status = ruby(script, env: { 'TMPDIR' => tmp })
        expect(status).to be_success, err
        message, copies, pool = out.lines.map(&:chomp)
        expect(message).to include('tried /nonexistent/a.so, /nonexistent/b.so)')
        expect(copies).to eq('nil')
        expect(%w[nil []]).to include(pool), 'no engine was created' # nil: it failed before the pool was touched
        expect(Dir.children(tmp)).to be_empty
      end
    end

    it 'raises LibraryNotFound in Engine.new for a missing file and for a non-library' do
      Dir.mktmpdir do |tmp|
        fake = File.join(tmp, 'x.dylib')
        File.write(fake, 'not a library')
        [fake, File.join(tmp, 'missing.so')].each do |path|
          expect { Swmm::Engine.new([path]) }.to raise_error(Swmm::LibraryNotFound, /libswmm5 not found/)
        end
      end
    end
  end
end
