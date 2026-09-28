# frozen_string_literal: true
# Differential test of the pure HTML parser against a real libxml2 2.13.9 build (htmlsax.c),
# comparing SAX event streams (pull and push with various chunk sizes) and DOM dumps.
# usage: HTMLSAX=/path/to/htmlsax ruby sax_compare.rb [max_cases]
require "stringio"
require "tmpdir"
require_relative "saxdump"
load File.join(__dir__, "cases.rb")

HTMLSAX = ENV["HTMLSAX"] || "/tmp/claude-0/-root-workspace/548d09b2-03e4-44e3-9288-5b2fb6d3d1fa/scratchpad/htmlsax"
inputs = HTML4Cases::SNIPPETS.map(&:b) + HTML4Cases.fuzz(300, 1234).map(&:b)
Dir[File.join(HTML4Cases::FILES, "*.html")].sort.each { |f| inputs << File.binread(f) }
inputs += [
  "<p>a\xE9b</p>", "\xEF\xBB\xBF<p>a</p>", "<meta charset=Shift_JIS><p>a\x82\xA0b</p>",
  "<meta http-equiv='Content-Type' content='text/html; charset=EUC-JP'><p>a\xA4\xA2b</p>",
  "<p>" + "a" * 5000 + "\xE9</p>", "<?xml version='1.0'?><p>\xC3\xA9</p>",
].map(&:b)
inputs = inputs.first(ARGV[0].to_i) if ARGV[0]

configs = [
  ["pull", 0, 1, "-"], ["pulldom", 0, 1, "-"], ["pulldom", 0, 1, "UTF-8"], ["pulldom", 0, 0, "-"],
  ["pulldom", 0, 257, "-"], ["pulldom", 0, 8193, "-"],
  ["push", 0, 1, "-"], ["push", 1, 1, "-"], ["push", 3, 1, "-"], ["push", 7, 1, "-"], ["push", 64, 1, "-"],
  ["pushdom", 0, 1, "-"], ["pushdom", 2, 1, "-"], ["pushdom", 13, 1, "-"], ["pushdom", 1000, 257, "-"],
  ["push", 5, 1, "UTF-8"],
]
fails = 0
total = 0
Dir.mktmpdir do |dir|
  path = File.join(dir, "in.html")
  inputs.each_with_index do |inp, i|
    File.binwrite(path, inp)
    configs.each do |mode, chunk, opts, enc|
      next if mode.start_with?("push") && chunk == 1 && inp.bytesize > 3000

      total += 1
      expected = IO.popen([HTMLSAX, mode, chunk.to_s, opts.to_s, enc, path], "rb", &:read)
      out = StringIO.new(+"".b)
      old = $stdout
      $stdout = out
      begin
        SaxDump.run(mode, chunk, opts, enc == "-" ? nil : enc, path)
      rescue StandardError => e
        puts "EXCEPTION #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      ensure
        $stdout = old
      end
      actual = out.string.b
      next if actual == expected

      fails += 1
      next if fails > (ENV["SHOW"] || 6).to_i

      el = expected.lines
      al = actual.lines
      k = (0...[el.size, al.size].max).find { |j| el[j] != al[j] }
      puts "=== input #{i} #{inp[0, 120].inspect} mode=#{mode} chunk=#{chunk} opts=#{opts} enc=#{enc}"
      puts "  line #{k}:"
      puts "  C:    #{el[k].inspect}"
      puts "  Ruby: #{al[k].inspect}"
      puts "  C+1:    #{el[k + 1].inspect}" if el[k + 1]
      puts "  Ruby+1: #{al[k + 1].inspect}" if al[k + 1]
    end
  end
end
puts "#{total - fails}/#{total} identical"
