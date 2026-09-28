# frozen_string_literal: true

# ruby fuzz_oracle.rb CASES OUT   (native gem)
gem "nokogiri", "1.19.4"
require "nokogiri"
require_relative "dump_native"
cases = Marshal.load(File.binread(ARGV[0]))
File.binwrite(ARGV[1], Marshal.dump(cases.to_h { |c| [c[:id], DumpNative.run(c)] }))
