# frozen_string_literal: true

# ruby test-pure/html5/gen_oracle.rb OUTFILE  (run WITHOUT -I lib: uses the native gem)
gem "nokogiri", "1.19.4"
require "nokogiri"
abort "not native" unless Nokogiri.uses_gumbo? && !$LOAD_PATH.any? { |p| p.include?("nokogiri-pure") }
require_relative "cases"
require_relative "dump_native"

results = {}
Html5Cases.all.each { |c| results[c[:id]] = DumpNative.run(c) }
File.binwrite(ARGV[0], Marshal.dump(results))
puts "#{results.size} cases"
