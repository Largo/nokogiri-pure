# frozen_string_literal: true

# usage: ruby run_cases.rb CASEFILE OUTFILE   (CASEFILE: Marshal dump of [[input, opts, enc, url], ...])
require_relative "dump"
cases = Marshal.load(File.binread(ARGV[0]))
require "stringio"
results = cases.map do |input, opts, enc, url, mode|
  ParserDump.dispatch(input, opts, enc, url, mode)
rescue Exception => e # rubocop:disable Lint/RescueException
  { crash: e.class.name, message: e.message, bt: e.backtrace&.first(8) }
end
File.binwrite(ARGV[1], Marshal.dump(results))
