# frozen_string_literal: true
# Differential test over real-world HTML files. usage: ruby corpus.rb file_list.txt
require "stringio"
require_relative "saxdump"
HTMLSAX = ENV["HTMLSAX"] || "/tmp/claude-0/-root-workspace/548d09b2-03e4-44e3-9288-5b2fb6d3d1fa/scratchpad/htmlsax"
files = File.readlines(ARGV[0], chomp: true)
configs = (ENV["CONFIGS"] || "pulldom:0:1:-,pull:0:1:-,pushdom:4096:1:-").split(",").map { |c| m, ch, o, e = c.split(":"); [m, ch.to_i, o.to_i, e] }
fails = 0
total = 0
files.each do |path|
  configs.each do |mode, chunk, opts, enc|
    total += 1
    expected = IO.popen([HTMLSAX, mode, chunk.to_s, opts.to_s, enc, path], "rb", &:read)
    out = StringIO.new(+"".b)
    old = $stdout
    $stdout = out
    begin
      SaxDump.run(mode, chunk, opts, enc == "-" ? nil : enc, path)
    rescue StandardError => e
      puts "EXCEPTION #{e.class}: #{e.message}\n#{e.backtrace.first(6).join("\n")}"
    ensure
      $stdout = old
    end
    actual = out.string.b
    next if actual == expected

    fails += 1
    el = expected.lines
    al = actual.lines
    k = (0...[el.size, al.size].max).find { |j| el[j] != al[j] }
    puts "=== #{path} mode=#{mode} chunk=#{chunk} opts=#{opts} enc=#{enc} line #{k}"
    puts "  C:    #{el[k].inspect[0, 300]}"
    puts "  Ruby: #{al[k].inspect[0, 300]}"
  end
end
puts "#{total - fails}/#{total} identical"
