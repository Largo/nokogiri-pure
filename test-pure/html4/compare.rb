# frozen_string_literal: true
# Usage: ruby compare.rb [filter]   -- builds cases, runs oracle and pure dumpers, diffs
require "stringio"
here = __dir__
load File.join(here, "cases.rb")
cases = HTML4Cases.all
cases = cases.each_with_index.select { |c, i| ARGV[0].nil? || i.to_s == ARGV[0] || c[1].to_s.include?(ARGV[0]) }.map(&:first)
File.binwrite("/tmp/claude-0/html4_cases.marshal", Marshal.dump(cases))
lib = File.expand_path("../../lib", here)
oracle = "ruby -e 'gem \"nokogiri\", \"1.19.4\"; require \"nokogiri\"; load \"#{here}/dump.rb\"' /tmp/claude-0/html4_cases.marshal /tmp/claude-0/html4_oracle.marshal"
pure = "ruby -I#{lib} #{here}/dump.rb /tmp/claude-0/html4_cases.marshal /tmp/claude-0/html4_pure.marshal"
system("mkdir -p /tmp/claude-0")
File.binwrite("/tmp/claude-0/html4_cases.marshal", Marshal.dump(cases))
t = Time.now
system(oracle) or abort("oracle failed")
t1 = Time.now - t
t = Time.now
system(pure) or abort("pure failed")
t2 = Time.now - t
o = Marshal.load(File.binread("/tmp/claude-0/html4_oracle.marshal"))
pr = Marshal.load(File.binread("/tmp/claude-0/html4_pure.marshal"))
fails = 0
cases.each_with_index do |c, i|
  next if o[i] == pr[i]

  fails += 1
  next if fails > (ENV["SHOW"] || 8).to_i

  puts "=== case #{i}: #{c[0]} #{c[1][0, 200].inspect} enc=#{c[3].inspect} opts=#{c[4]}"
  a = o[i]
  b = pr[i]
  n = [a.size, b.size].max
  shown = 0
  n.times do |k|
    next if a[k] == b[k]

    puts "  oracle[#{k}]: #{a[k].inspect[0, 400]}"
    puts "  pure  [#{k}]: #{b[k].inspect[0, 400]}"
    shown += 1
    break if shown >= 3
  end
end
puts "#{cases.size - fails}/#{cases.size} match (oracle #{t1.round(2)}s, pure #{t2.round(2)}s)"
