# frozen_string_literal: true

# Differential test: parse each case with the native nokogiri 1.19.4 gem (oracle) and with
# nokogiri-pure, compare trees, serialisation and errors.
#
#   ruby test-pure/parser/diff.rb [-v] [-k KIND,...] [filter]
require "tmpdir"
require_relative "cases"

verbose = ARGV.delete("-v")
kinds = nil
if (i = ARGV.index("-k"))
  kinds = ARGV[i + 1].split(",")
  ARGV.slice!(i, 2)
end
filter = ARGV[0]

cases = ParserCases.all(kinds)
cases = cases.select { |c| c[4].to_s.include?(filter) || c[0].to_s.include?(filter) } if filter
here = __dir__
lib = File.expand_path("../../lib", here)
Dir.mktmpdir do |dir|
  cf = File.join(dir, "cases")
  File.binwrite(cf, Marshal.dump(cases.map { |c| c[0, 4] + [c[5]] }))
  oracle = File.join(dir, "oracle")
  pure = File.join(dir, "pure")
  t1 = Thread.new { system("ruby", "-e", 'gem "nokogiri", "1.19.4"; require "nokogiri"; load ARGV.shift', File.join(here, "run_cases.rb"), cf, oracle, chdir: here) }
  t0 = Time.now
  ok2 = system("ruby", "-I", lib, "-rnokogiri", File.join(here, "run_cases.rb"), cf, pure, chdir: here)
  tp = Time.now - t0
  t1.join
  abort "pure run failed" unless ok2
  a = Marshal.load(File.binread(oracle))
  b = Marshal.load(File.binread(pure))
  fails = 0
  by_kind = Hash.new { |h, k| h[k] = [0, 0] }
  cases.each_with_index do |c, i|
    kind = c[4]
    by_kind[kind][0] += 1
    if a[i] == b[i]
      by_kind[kind][1] += 1
      next
    end
    fails += 1
    next unless verbose || fails <= 20

    puts "=== FAIL #{kind} ##{i} opts=#{c[1]} enc=#{c[2].inspect} mode=#{c[5].inspect} input=#{c[0].inspect[0, 300]}"
    %i[exception message crash bt xml errors tree url log pos raised nodes doc verrors ids].each do |k|
      next if a[i][k] == b[i][k]

      puts "  #{k}:"
      puts "    native: #{a[i][k].inspect[0, 1500]}"
      puts "    pure:   #{b[i][k].inspect[0, 1500]}"
    end
  end
  by_kind.sort.each { |k, (n, ok)| puts format("%-20s %5d/%5d", k, ok, n) }
  puts "TOTAL #{cases.size - fails}/#{cases.size} pass (pure time #{tp.round(2)}s)"
end
