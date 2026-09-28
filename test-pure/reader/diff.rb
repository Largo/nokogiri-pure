# frozen_string_literal: true

# Differential test for Nokogiri::XML::Reader: runs every case with the native nokogiri 1.19.4 gem
# (oracle) and with nokogiri-pure, compares the full per-step traces.
#
#   ruby test-pure/reader/diff.rb [-v] [-n MAX_SHOWN] [-k KIND,...] [filter]
require "tmpdir"
require_relative "cases"

verbose = ARGV.delete("-v")
kinds = nil
if (i = ARGV.index("-k"))
  kinds = ARGV[i + 1].split(",")
  ARGV.slice!(i, 2)
end
max_shown = 5
if (i = ARGV.index("-n"))
  max_shown = ARGV[i + 1].to_i
  ARGV.slice!(i, 2)
end
filter = ARGV[0]

cases = ReaderCases.all
cases = cases.select { |c| kinds.include?(c[0]) } if kinds
cases = cases.select { |c| c[0].include?(filter) || c[1].include?(filter.b) } if filter
here = __dir__
lib = File.expand_path("../../lib", here)
files_dir = "/root/workspace/nokogiri-upstream/test/files"

Dir.mktmpdir do |dir|
  cf = File.join(dir, "cases")
  File.binwrite(cf, Marshal.dump(cases))
  oracle = File.join(dir, "oracle")
  pure = File.join(dir, "pure")
  runner = File.join(here, "run_cases.rb")
  t1 = Thread.new do
    system("ruby", "-e", 'gem "nokogiri", "1.19.4"; require "nokogiri"; load ARGV.shift', runner, cf, oracle,
      chdir: files_dir, err: File::NULL)
  end
  t0 = Time.now
  ok = system("ruby", "-W0", "-I", lib, "-rnokogiri", runner, cf, pure, chdir: files_dir)
  tp = Time.now - t0
  t1.join
  abort "pure run failed" unless ok
  a = Marshal.load(File.binread(oracle))
  b = Marshal.load(File.binread(pure))
  fails = 0
  shown = 0
  by_kind = Hash.new { |h, k| h[k] = [0, 0] }
  cases.each_with_index do |c, idx|
    by_kind[c[0]][0] += 1
    next if a[idx] == b[idx]

    by_kind[c[0]][1] += 1
    fails += 1
    next unless verbose && shown < max_shown

    shown += 1
    puts "=== #{c[0]} ##{idx} source=#{c[2].inspect} url=#{c[3].inspect} enc=#{c[4].inspect} opts=#{c[5]} mode=#{c[6]}"
    puts "input: #{c[1].byteslice(0, 300).inspect}#{c[1].bytesize > 300 ? "...(#{c[1].bytesize})" : ""}"
    ta = a[idx]
    tb = b[idx]
    if ta.is_a?(Array) && tb.is_a?(Array) && ta[0].is_a?(Array) && tb[0].is_a?(Array)
      k = (0...[ta.size, tb.size].max).find { |j| ta[j] != tb[j] }
      puts "first diff at step #{k} (oracle #{ta.size} steps, pure #{tb.size} steps)"
      puts "  prev:   #{ta[k - 1].inspect[0, 400]}" if k && k > 0
      puts "  oracle: #{ta[k].inspect[0, 1500]}"
      puts "  pure:   #{tb[k].inspect[0, 1500]}"
    else
      puts "  oracle: #{ta.inspect[0, 1500]}"
      puts "  pure:   #{tb.inspect[0, 1500]}"
    end
  end
  by_kind.sort.each do |k, (n, f)|
    puts format("%-22s %5d cases %5d fail", k, n, f) if f > 0 || verbose
  end
  puts "#{cases.size} cases, #{fails} failures (pure run #{tp.round(1)}s)"
  exit(fails.zero? ? 0 : 1)
end
