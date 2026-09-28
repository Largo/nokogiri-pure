# frozen_string_literal: true

# Differential test: runs the corpus through the native gem and nokogiri-pure and compares.
#   ruby test-pure/xslt/compare.rb [filter-regex] [-v]
require "json"
require "open3"

dir = __dir__
filter = ARGV.find { |a| !a.start_with?("-") }
verbose = ARGV.include?("-v")
cases_json = if ENV["CASES"]
  File.binread(ENV["CASES"])
else
  Open3.capture2("ruby", File.join(dir, "corpus.rb"), *[filter].compact, binmode: true)[0]
end
cases = Marshal.load(cases_json)
cache = "/tmp/xslt-native-#{filter.to_s.gsub(/\W/, "_")}.bin"
cache = "#{ENV["CASES"]}.native" if ENV["CASES"]
native = if File.exist?(cache) && File.mtime(cache) > (ENV["CASES"] ? File.mtime(ENV["CASES"]) : [File.mtime(File.join(dir, "corpus.rb")), File.mtime(File.join(dir, "inline_cases.rb"))].max) && !ENV["REFRESH"]
  Marshal.load(File.binread(cache))
else
  out, = Open3.capture2("ruby", File.join(dir, "runner.rb"), "native", stdin_data: cases_json, binmode: true)
  File.binwrite(cache, out)
  Marshal.load(out)
end
t = Time.now
pure_out, err_s = Open3.capture3("ruby", File.join(dir, "runner.rb"), "pure", stdin_data: cases_json, binmode: true)
elapsed = Time.now - t
pure = begin
  Marshal.load(pure_out)
rescue StandardError
  warn err_s[-3000..] || err_s
  exit 1
end
pass = 0
fails = []
cases.each do |c|
  n = native[c["name"]]
  p = pure[c["name"]]
  if n == p
    pass += 1
  else
    fails << c["name"]
    next unless verbose

    puts "=== #{c["name"]}"
    %w[error serialize to_s].each do |k|
      next if n[k] == p[k]

      puts "--- #{k} native:"
      puts n[k].to_s[0, 1500]
      puts "--- #{k} pure:"
      puts p[k].to_s[0, 1500]
    end
  end
end
puts "PASS #{pass}/#{cases.length} (pure #{elapsed.round(1)}s)"
puts "FAIL: #{fails.join(" ")}" unless fails.empty?
