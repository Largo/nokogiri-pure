# frozen_string_literal: true

# Differential runner. Usage:
#   ruby test-pure/schema/regexp/run_diff.rb [--refresh] [--verbose] [suite...]
# Suites are defined in corpus.rb. For each suite the cases and the native oracle results are
# cached in fixtures/<suite>.json (regenerated when missing, when the generated cases changed,
# or with --refresh); the pure results are then compared case by case.
require "json"
require "digest"
require "zlib"
require "rbconfig"
require "timeout"
require_relative "corpus"
require_relative "pure_adapter"

DIR = __dir__
FIXTURES = File.join(DIR, "fixtures")

def fixture_for(suite, refresh: false)
  cases = RegexpCorpus.suite(suite)
  digest = Digest::SHA256.hexdigest(JSON.generate(cases))
  path = File.join(FIXTURES, "#{suite}.json.gz")
  if !refresh && File.exist?(path)
    data = JSON.parse(Zlib::GzipReader.open(path, &:read))
    return data if data["digest"] == digest
  end
  cases_path = File.join(FIXTURES, ".#{suite}.cases.json")
  res_path = File.join(FIXTURES, ".#{suite}.results.json")
  File.write(cases_path, JSON.generate(cases))
  # run the oracle in a clean process (no -I of nokogiri-pure)
  ok = system({ "RUBYLIB" => nil, "RUBYOPT" => nil }, RbConfig.ruby, File.join(DIR, "oracle_native.rb"), cases_path, res_path)
  raise "oracle failed for #{suite}" unless ok

  results = JSON.parse(File.read(res_path))
  File.delete(cases_path, res_path)
  data = { "digest" => digest, "cases" => cases, "results" => results }
  Zlib::GzipWriter.open(path) { |gz| gz.write(JSON.generate(data)) }
  data
end

def run_pure(kase, timeout = 60)
  api = PureRegexpAdapter.new
  r = Timeout.timeout(timeout) do
    if kase["kind"] == "regexp"
      RegexpHarness.run_regexp_case(api, kase)
    else
      RegexpHarness.run_automata_case(api, kase)
    end
  end
  JSON.parse(JSON.generate(r))
rescue StandardError, SystemStackError, Timeout::Error => e
  { "exception" => "#{e.class}: #{e.message}", "bt" => e.backtrace.first(5) }
end

# cases on which libxml2 hits MAX_PUSH (10M backtracking saves, result -6): identical in the
# port but ~1 minute each in Ruby, so they only run with --slow
def slow_case?(expected)
  expected["exec"]&.include?(-6) ||
    (expected["runs"]&.any? { |r| r.is_a?(Array) && r.any? { |x| x["ret"] == -6 } })
end

def compare_suite(suite, refresh: false, verbose: false, slow: false)
  compare_data(fixture_for(suite, refresh: refresh), slow: slow)
end

def compare_data(data, slow: false)
  fails = []
  skipped = 0
  data["cases"].each_with_index do |kase, i|
    expected = data["results"][i]
    if expected["timeout"] || expected["crash"]
      # libxml2 itself does not terminate (or crashes) on this case
      skipped += 1
      next
    end
    if slow_case?(expected) && !slow
      skipped += 1
      next
    end
    actual = run_pure(kase, slow ? 3600 : 60)
    fails << [kase, expected, actual] if expected != actual
  end
  [data["cases"].size, fails, skipped]
end

def first_diff(a, b, path = "")
  return nil if a == b
  if a.is_a?(Hash) && b.is_a?(Hash)
    (a.keys | b.keys).each do |k|
      d = first_diff(a[k], b[k], "#{path}.#{k}")
      return d if d
    end
  elsif a.is_a?(Array) && b.is_a?(Array)
    [a.size, b.size].max.times do |i|
      d = first_diff(a[i], b[i], "#{path}[#{i}]")
      return d if d
    end
  end
  "#{path}: native=#{a.inspect[0, 600]} pure=#{b.inspect[0, 600]}"
end

if $PROGRAM_NAME == __FILE__
  refresh = ARGV.delete("--refresh")
  verbose = ARGV.delete("--verbose")
  slow = ARGV.delete("--slow")
  suites = ARGV.empty? ? RegexpCorpus::SUITES : ARGV
  total_fail = 0
  suites.each do |suite|
    t = Time.now
    n, fails, skipped = compare_suite(suite, refresh: !refresh.nil?, slow: !slow.nil?)
    total_fail += fails.size
    puts format("%-22s %5d cases, %4d mismatches, %d skipped (native hang/crash, or MAX_PUSH without --slow) (%.1fs)", suite, n, fails.size, skipped, Time.now - t)
    $stdout.flush
    fails.first(verbose ? 50 : 5).each do |kase, exp, act|
      puts "  CASE #{JSON.generate(kase)[0, 400]}"
      puts "    #{first_diff(exp, act)}"
    end
  end
  exit(total_fail.zero? ? 0 : 1)
end
