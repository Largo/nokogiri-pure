$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "nokogiri"
require "benchmark"
files = Dir["/root/workspace/nokogiri-upstream/test/files/*.html"]
big = files.map { |f| File.binread(f) }.join * 20
puts "size #{big.bytesize}"
t = Benchmark.realtime { Nokogiri::Pure::HTMLParser.read_memory(big, nil, "UTF-8", 1) }
puts "pure: #{t.round(2)}s (#{(big.bytesize / t / 1024).round} KB/s)"
