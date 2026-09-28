# frozen_string_literal: true

# Regenerates fixtures/c_oracle.json.gz by running the direct C oracle (see build_oracle.sh).
# usage: ruby gen_c_fixtures.rb /path/to/types_oracle
require "json"
require "zlib"
require_relative "c_requests"

oracle = ARGV[0] || File.join(__dir__, "types_oracle")
reqs = TypesCRequests.all
out = []
IO.popen([oracle], "r+") do |io|
  reqs.each do |r|
    io.puts r
    resp = io.gets or abort("oracle died on #{r}")
    out << [r, resp.chomp]
  end
end
Zlib::GzipWriter.open(File.join(__dir__, "fixtures", "c_oracle.json.gz")) { |gz| gz.write(JSON.generate(out)) }
warn "#{out.size} cases"
