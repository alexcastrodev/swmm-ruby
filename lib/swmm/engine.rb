# frozen_string_literal: true

require "ffi"
require "fileutils"
require "tmpdir"

module Swmm
  # One loaded copy of libswmm5 (the EPA engine). The engine keeps global state, so a copy runs one simulation at a
  # time (lock); Engine.pool hands out private copies of the library file, which run side by side in threads.
  # A crash inside the C code takes the process with it.
  class Engine
    ROOT = File.expand_path("../..", __dir__)
    INIT = Mutex.new

    # name => [argument types, return type]
    FUNCTIONS = {
      swmm_open: [%i[string string string], :int], swmm_start: [[:int], :int], swmm_step: [[:pointer], :int],
      swmm_end: [[], :int], swmm_close: [[], :int], swmm_getMassBalErr: [%i[pointer pointer pointer], :int],
      swmm_getVersion: [[], :int], swmm_getError: [%i[pointer int], :int]
    }.freeze

    class << self
      # Where libswmm5 is looked up, in order: $SWMM_LIB, vendor/swmm (rake swmm:build), the system.
      def library_candidates
        [ENV.fetch("SWMM_LIB", nil), File.join(ROOT, "vendor", "swmm", "libswmm5.#{FFI::Platform::LIBSUFFIX}"),
         "swmm5", "libswmm5"].compact
      end

      # The copy behind Swmm.run.
      def default = INIT.synchronize { @default ||= new(library_candidates) }

      def available?
        default
        true
      rescue LibraryNotFound
        false
      end

      def version = default.version

      def run(inp, rpt, out) = default.run(inp, rpt, out)

      # n engines, each on its own copy of the library file (a copy has its own global state, so they can run at the
      # same time). Created once and reused; the copies live in a temp dir removed at exit.
      # ponytail: needs the library as a file (not just a system name); no reentrant API in SWMM 5.2.4 to avoid the copies.
      def pool(count)
        INIT.synchronize do
          @pool ||= []
          source = library_candidates.find { File.file?(_1) } or raise LibraryNotFound, library_not_found_message
          @copies ||= Dir.mktmpdir("swmm-lib").tap { |dir| at_exit { FileUtils.rm_rf(dir) } }
          while @pool.size < count
            copy = File.join(@copies, "#{@pool.size}-#{File.basename(source)}")
            FileUtils.cp(source, copy)
            @pool << new([copy])
          end
          @pool.first(count)
        end
      end

      def library_not_found_message
        "libswmm5 not found (tried #{library_candidates.join(", ")}); " \
          "run `rake swmm:build` or set SWMM_LIB to the library path"
      end
    end

    def initialize(libraries)
      @lock = Mutex.new
      @lib = Module.new { extend FFI::Library }
      @lib.ffi_lib(libraries)
      # blocking: the GVL is released during each call, so engines on different threads really run in parallel
      FUNCTIONS.each { |name, (args, ret)| @lib.attach_function(name, args, ret, blocking: true) }
      @lib.freeze # after every attach: a frozen FFI module can be used from other Ractors (see the ffi wiki, "Ractors")
    rescue LoadError
      raise LibraryNotFound, self.class.library_not_found_message
    end

    # "5.2.4"
    def version = Swmm.format_version(@lib.swmm_getVersion)

    # open -> start -> step... -> end -> close, like swmm_run but keeping the continuity errors.
    # Returns { code:, message:, continuity: { runoff:, flow_routing:, quality: } | nil }
    def run(inp, rpt, out)
      @lock.synchronize do
        code = @lib.swmm_open(inp, rpt, out)
        continuity = nil
        if code.zero?
          code = @lib.swmm_start(1)
          code = step_until_done if code.zero?
          end_code = @lib.swmm_end
          code = end_code if code.zero?
          continuity = mass_balance if code.zero?
        end
        message = error_message
        @lib.swmm_close
        { code: code, message: message, continuity: continuity }
      end
    end

    private

    def step_until_done
      elapsed = FFI::MemoryPointer.new(:double)
      loop do
        code = @lib.swmm_step(elapsed)
        return code if !code.zero? || elapsed.read_double <= 0
      end
    end

    def mass_balance
      ptrs = Array.new(3) { FFI::MemoryPointer.new(:float) }
      @lib.swmm_getMassBalErr(*ptrs)
      %i[runoff flow_routing quality].zip(ptrs.map(&:read_float)).to_h
    end

    def error_message
      buf = FFI::MemoryPointer.new(:char, 1024)
      @lib.swmm_getError(buf, 1024)
      buf.read_string.strip
    end
  end
end
