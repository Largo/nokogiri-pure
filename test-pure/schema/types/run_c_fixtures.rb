# frozen_string_literal: true

# Replays fixtures/c_oracle.json.gz against the pure-Ruby port and reports mismatches.
# usage: ruby -Ilib test-pure/schema/types/run_c_fixtures.rb [-v] [kind-letters]
require "json"
require "zlib"
require_relative "c_requests"

verbose = ARGV.delete("-v")
kinds = ARGV[0]
cases = JSON.parse(Zlib::GzipReader.open(File.join(__dir__, "fixtures", "c_oracle.json.gz"), &:read))
responder = TypesPureResponder.new
stats = Hash.new { |h, k| h[k] = [0, 0] }
fails = []
cases.each do |req, want|
  k = req[0]
  next if kinds && !kinds.include?(k)

  got = begin
    responder.respond(req)
  rescue StandardError => e
    "EXC #{e.class}: #{e.message} #{e.backtrace.first(3).join(" | ")}"
  end
  stats[k][0] += 1
  if got == want
    stats[k][1] += 1
  else
    fails << [req, want, got]
  end
end
stats.each { |k, (n, ok)| puts format("%s: %d/%d", k, ok, n) }
dec = ->(line) { line.split("\t").map { |x| x.match?(/\A[0-9a-f]{2,}\z/) && x.size.even? && x !~ /\A\d+\z/ ? [x].pack("H*").inspect : x }.join(" ") }
fails.first(verbose ? 200 : 25).each do |req, want, got|
  puts "REQ  #{dec.(req)}"
  puts "WANT #{dec.(want)}"
  puts "GOT  #{dec.(got)}"
end
exit(fails.empty? ? 0 : 1)
