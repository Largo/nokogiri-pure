# frozen_string_literal: true

# HTML parser benchmark (HTML4 = libxml2 HTMLparser port, HTML5 = gumbo port).
#
#   ruby test-pure/bench/html_bench.rb [pure|native] [filter]
#   ruby --yjit test-pure/bench/html_bench.rb pure
#
# Env: BENCH_FILES="a.html:b.html" adds files; BENCH_TIME=seconds per measurement (default 2).
# Prints the best time per iteration (ms) and throughput for every workload x operation.
mode = ARGV[0] || "pure"
filter = ARGV[1] && Regexp.new(ARGV[1])
if mode == "native"
  gem "nokogiri", "1.19.4"
else
  $LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
end
require "nokogiri"

UPSTREAM = "/root/workspace/nokogiri-upstream/test/files"
REF = "/root/workspace/nokogiri-pure-ref"

workloads = []
synthetic = +"<!DOCTYPE html><html><head><title>t</title></head><body>"
1500.times do |i|
  synthetic << %(<div class="item c#{i % 10}" id="d#{i}"><p>Para <a href="/x/#{i}">link #{i}</a> &amp; ) +
    %(<b>bold</b></p><ul><li>a</li><li>b</li></ul></div>)
end
synthetic << "</body></html>"
workloads << ["synthetic-tags", [synthetic]]

up = Dir[File.join(UPSTREAM, "*.html")].sort.map { |f| File.binread(f) }
workloads << ["upstream-files(#{up.size})", up] unless up.empty?

real = [
  "#{REF}/libxml2-2.13.9/doc/devhelp/libxml2-tree.html",
  "#{REF}/libxslt-1.1.43/tests/docbook/result/html/gdp-handbook.html",
  "/usr/share/doc/qemu-system-common/system/qemu-manpage.html",
  "#{UPSTREAM}/tlm.html",
] + ENV.fetch("BENCH_FILES", "").split(":")
real.each do |f|
  next unless File.file?(f)

  workloads << [File.basename(f), [File.binread(f)]]
end

BENCH_TIME = Float(ENV.fetch("BENCH_TIME", "2"))

def measure
  yield # warm-up (and YJIT compile)
  best = Float::INFINITY
  total = 0.0
  n = 0
  while total < BENCH_TIME || n < 3
    GC.start
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
    best = dt if dt < best
    total += dt
    n += 1
  end
  best
end

ops = {
  "HTML4 DOM" => ->(docs) { docs.each { |d| Nokogiri::HTML4::Document.parse(d) } },
  "HTML4 SAX" => lambda do |docs|
    docs.each { |d| Nokogiri::HTML4::SAX::Parser.new(Nokogiri::XML::SAX::Document.new).parse(d) }
  end,
  "HTML5 DOM" => ->(docs) { docs.each { |d| Nokogiri::HTML5::Document.parse(d) } },
}

yjit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
puts "# #{mode} ruby #{RUBY_VERSION} yjit=#{yjit}"
printf("%-28s %-10s %9s %10s\n", "workload", "op", "ms", "KB/s")
workloads.each do |name, docs|
  bytes = docs.sum(&:bytesize)
  ops.each do |op, fn|
    next if filter && "#{name} #{op}" !~ filter

    t = measure { fn.call(docs) }
    printf("%-28s %-10s %9.2f %10.0f\n", "#{name} #{bytes / 1024}K", op, t * 1000, bytes / 1024.0 / t)
  end
end
