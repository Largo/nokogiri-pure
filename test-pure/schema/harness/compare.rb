# frozen_string_literal: true

# ruby compare.rb native.json pure.json [--verbose]
require "json"
native = JSON.parse(File.read(ARGV[0]))
pure = JSON.parse(File.read(ARGV[1]))
verbose = ARGV.include?("--verbose") || ARGV.include?("-v")

if ARGV.include?("--ignore-lines")
  strip = lambda do |o|
    case o
    when Hash then o.to_h { |k, v| [k, k == "line" ? nil : (k == "message" && v.is_a?(String) ? v.sub(/\A-?\d+:\d+: /, "") : strip.(v))] }
    when Array then o.map { |x| strip.(x) }
    else o
    end
  end
  native = strip.(native)
  pure = strip.(pure)
end
pass = 0
fail = []
native.each do |id, n|
  p = pure[id]
  if p == n
    pass += 1
  else
    fail << id
  end
end
missing = native.keys - pure.keys

def show_diff(a, b, path = "")
  if a.is_a?(Hash) && b.is_a?(Hash)
    (a.keys | b.keys).each { |k| show_diff(a[k], b[k], "#{path}/#{k}") }
  elsif a.is_a?(Array) && b.is_a?(Array)
    [a.size, b.size].max.times { |i| show_diff(a[i], b[i], "#{path}[#{i}]") }
  elsif a != b
    puts "    #{path}:\n      native: #{a.inspect[0, 600]}\n      pure:   #{b.inspect[0, 600]}"
  end
end

fail.each do |id|
  puts "FAIL #{id}"
  show_diff(native[id], pure[id]) if verbose
end
puts "#{pass}/#{native.size} cases identical (#{fail.size} differ#{missing.empty? ? "" : ", #{missing.size} missing"})"
