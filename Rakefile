# frozen_string_literal: true

require "rake/testtask"
require "fileutils"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.pattern = "test/**/*_test.rb"
end

task default: :test

namespace :swmm do
  desc "Build libswmm5 from the EPA sources into vendor/swmm (SWMM_VERSION=v5.2.4)"
  task :build do
    version = ENV.fetch("SWMM_VERSION", "v5.2.4")
    src = "tmp/swmm-src"
    build = "tmp/swmm-build"
    flags = ["-DCMAKE_BUILD_TYPE=Release"]
    if RUBY_PLATFORM.include?("darwin") # Apple clang ships without OpenMP: use Homebrew's libomp
      omp = `brew --prefix libomp 2>/dev/null`.strip
      abort "libomp not found: brew install libomp" if omp.empty?
      flags += ["-DOpenMP_C_FLAGS=\"-Xpreprocessor -fopenmp -I#{omp}/include\"", "-DOpenMP_C_LIB_NAMES=omp",
                "-DOpenMP_omp_LIBRARY=#{omp}/lib/libomp.dylib"]
    end
    sh "git clone --depth 1 --branch #{version} https://github.com/USEPA/Stormwater-Management-Model.git #{src}" unless Dir.exist?(src)
    sh "cmake -S #{src} -B #{build} #{flags.join(" ")}"
    sh "cmake --build #{build} --target swmm5 -j"
    lib = Dir["#{build}/**/libswmm5.{dylib,so}"].first or abort "libswmm5 was not produced"
    FileUtils.mkdir_p("vendor/swmm")
    FileUtils.cp(lib, "vendor/swmm/")
    puts "libswmm5 -> vendor/swmm/#{File.basename(lib)}"
  end
end

desc "Regenerate docs/input-contract.md from Swmm::Schema"
task :contract do
  require_relative "lib/swmm"
  FileUtils.mkdir_p("docs")
  File.write("docs/input-contract.md", Swmm::Schema.describe)
end
