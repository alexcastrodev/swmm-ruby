require 'open3'
require 'rbconfig'
require 'timeout'
require 'tmpdir'

# Timeout starts one background thread on first use and keeps it: start it now so Thread.list.size baselines are stable.
Timeout.timeout(1) { nil }

# FRONT D (risk R4): run_many, the engine pool, threads, Ractor reads and the process lifecycle.
module SwmmConcurrency
  ROOT = File.expand_path('../..', __dir__) # the repository

  # Lets an example observe / break Engine#run for any engine instance (a no-op while +hook+ is nil).
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

  def model(peak) = SwmmFixtures.base.merge(timeseries: [{ name: 'Q', points: [[0, 0], [0.5, peak / 2.0], [1, peak], [2, 0]] }])

  def bad_model = SwmmFixtures.base.merge(conduits: [{ name: 'C1', from_node: 'J1', to_node: 'NOPE', length: 1, roughness: 0.01, in_offset: 0, out_offset: 0 }])

  def flow(result) = result.links['C2'][:flow].values

  def peaks = [10, 20, 40, 80, 160, 320]

  def pool_size = Swmm::Engine.instance_variable_get(:@pool)&.size.to_i

  # Counts Engine#run calls (thread safe) while the block runs; the block receives the counter.
  def count_engine_runs(raise_on: nil)
    calls = 0
    lock = Mutex.new
    EngineSpy.hook = lambda {
      n = lock.synchronize { calls += 1 }
      raise 'boom' if n == raise_on
    }
    yield -> { calls }
  ensure
    EngineSpy.hook = nil
  end

  # Waits (bounded) until the threads of a finished/failed run_many are gone; true when the count is back to +baseline+.
  def threads_settle?(baseline)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 while Thread.list.size > baseline && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    Thread.list.size <= baseline
  end

  # Dir.tmpdir is read from ENV["TMPDIR"] on every call, so a private one is not polluted by the other test processes.
  # The library copies directory must already exist (Engine.pool is called first) so it is not created inside it.
  def with_private_tmpdir
    Swmm::Engine.pool(1)
    old = ENV.fetch('TMPDIR', nil)
    Dir.mktmpdir('swmm-conc-test') do |dir|
      ENV['TMPDIR'] = dir
      yield dir
    ensure
      old ? ENV['TMPDIR'] = old : ENV.delete('TMPDIR')
    end
  end

  def swmm_dirs(dir) = Dir.glob(File.join(dir, 'swmm*'))

  # Runs a Ruby script in a FRESH process (cwd = the pack, the pack loaded by spec/support/swmm_standalone.rb, the fixtures
  # requireable as "swmm_fixtures"). Returns [stdout, stderr, status]; kills it on timeout.
  def ruby(script, env: {})
    Open3.popen3(env, RbConfig.ruby, '-Ispec/support', '-e', script, chdir: ROOT) do |stdin, stdout, stderr, waiter|
      stdin.close
      out = Thread.new { stdout.read }
      err = Thread.new { stderr.read }
      unless waiter.join(60)
        Process.kill('KILL', waiter.pid)
        RSpec::Expectations.fail_with('subprocess hung (killed)')
      end
      [out.value, err.value, waiter.value]
    end
  end

  # 8 threads make the first use of the engine at once (Engine.available? or Swmm.run, per +first+) and print what they got
  def race(first)
    <<~RUBY
      require "swmm_standalone"; require "swmm_fixtures"; require "json"
      start = Queue.new
      first = #{first.inspect}
      out = Queue.new
      threads = Array.new(8) do |i|
        Thread.new do
          start.pop
          begin
            if first == "available" then Swmm::Engine.available? else r = Swmm.run(SwmmFixtures.base); raise "run failed" unless r.ok? end
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
  end
end
