# frozen_string_literal: true

# ruby compare.rb [FILTER] [-v]
# Runs run_cases.rb in both modes over cases/cases.json and reports the differences.
require "json"
require "rbconfig"

here = File.expand_path(__dir__)
filter = ARGV.find { |a| !a.start_with?("-") }
verbose = ARGV.include?("-v")
cases = ENV["CASES"] ? File.expand_path(ENV["CASES"], here) : File.join(here, "cases", "cases.json")
abort "run extract_suites.rb first" unless File.exist?(cases)

tmp = File.join(here, "cases")
outs = {}
%w[oracle pure].map do |mode|
  out = File.join(tmp, "#{mode}.json")
  outs[mode] = out
  Thread.new do
    system(RbConfig.ruby, File.join(here, "run_cases.rb"), mode, cases, out, *[filter].compact) || warn("#{mode} run failed")
  end
end.each(&:join)

oracle = JSON.parse(File.read(outs["oracle"]))
pure = JSON.parse(File.read(outs["pure"]))
# libxml2 randomises its hash tables, so errors reported while scanning them (define
# combination, references, interleaves) come in random order: compare those as multisets too
def unordered(r)
  return r unless r.is_a?(Hash)

  r = r.dup
  r["stderr"] = r["stderr"].lines.sort if r["stderr"].is_a?(String)
  if r["parse"].is_a?(Hash) && r["parse"]["errors"]
    r["parse"] = r["parse"].merge("errors" => r["parse"]["errors"].sort_by(&:to_s),
                                  "message" => r["parse"]["message"].to_s.lines.sort)
  end
  r
end

total = 0
same = 0
reordered = []
diffs = []
oracle.each do |id, o|
  total += 1
  pr = pure[id]
  if o == pr
    same += 1
  elsif unordered(o) == unordered(pr)
    reordered << id
  else
    diffs << id
    next unless verbose

    puts "=== #{id}"
    puts "oracle: #{JSON.generate(o)[0, 3000]}"
    puts "pure:   #{JSON.generate(pr)[0, 3000]}"
  end
end
# retry the oracle on the differing cases: libxml2's hash order also decides e.g. which
# interleave is checked first (the others are skipped once an error was reported)
unless diffs.empty?
  all = JSON.parse(File.read(cases)).select { |c| diffs.include?(c["id"]) }
  sub = File.join(tmp, "retry.json")
  File.write(sub, JSON.generate(all))
  alt = File.join(tmp, "oracle-retry.json")
  8.times do
    break if diffs.empty?

    system(RbConfig.ruby, File.join(here, "run_cases.rb"), "oracle", sub, alt, err: File::NULL)
    o2 = JSON.parse(File.read(alt))
    matched = diffs.select { |id| o2[id] == pure[id] || unordered(o2[id]) == unordered(pure[id]) }
    reordered.concat(matched)
    diffs -= matched
  end
end

puts "identical: #{same}/#{total}"
puts "same as libxml2 up to its random hash order: #{reordered.join(" ")}" unless reordered.empty?
puts "differing: #{diffs.join(" ")}" unless diffs.empty?
