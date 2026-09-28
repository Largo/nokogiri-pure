# frozen_string_literal: true
# Random differential fuzzing against libxml2 (htmlsax.c). usage: ruby fuzz.rb [count] [seed]
require "stringio"
require "tmpdir"
require_relative "saxdump"
HTMLSAX = ENV["HTMLSAX"] || "/tmp/claude-0/-root-workspace/548d09b2-03e4-44e3-9288-5b2fb6d3d1fa/scratchpad/htmlsax"

ATOMS = [
  "<", ">", "&", "\"", "'", "=", "/", "!", "?", "-", "--", " ", "\n", "\r", "\t", "\0", ";", "#", "x", "a", "b", "p",
  "div", "html", "head", "body", "title", "script", "style", "meta", "table", "tr", "td", "li", "ul", "option", "select",
  "form", "br", "img", "input", "DOCTYPE", "PUBLIC", "SYSTEM", "amp", "lt", "nbsp", "&#", "&#x", "1", "9", "F",
  "\xC3\xA9", "\xE2\x82\xAC", "\xF0\x9F\x98\x80", "\xE9", "\xFF", "\x80", "\x01", "\x7F", "charset", "http-equiv",
  "content", "Content-Type", "text/html; charset=", "UTF-8", "ISO-8859-1", "EUC-JP", "<!--", "-->", "<?", "?>", "</",
  "<![CDATA[", "]]>", "id", "name", "class", ":", "_", ".", "textarea", "pre", "frameset", "noframes", "xmp", "plaintext",
  "checked", "disabled", "selected", "a" * 120, "  \n  ", "&amp;", "&quot;", "&#65;", "&#x1F600;", "&unknown;", "&nbsp",
].map(&:b).freeze

def gen(r)
  n = ENV["BIG"] ? r.rand(200..2500) : r.rand(1..60)
  s = +"".b
  n.times { s << ATOMS[r.rand(ATOMS.size)] }
  s
end

count = (ARGV[0] || 500).to_i
seed = (ARGV[1] || 1).to_i
r = Random.new(seed)
configs = [["pull", 0, 1, "-"], ["pulldom", 0, 1, "-"], ["pulldom", 0, 257, "UTF-8"], ["push", 1, 1, "-"],
           ["push", 7, 1, "-"], ["pushdom", 3, 8193, "-"], ["pulldom", 0, 0, "ISO-8859-1"], ["pulldom", 0, 1, "EUC-JP"],
           ["pulldom", 0, 1, "Shift_JIS"], ["pushdom", 100, 1, "EUC-JP"], ["pulldom", 0, 1, "US-ASCII"]]
fails = 0
total = 0
Dir.mktmpdir do |dir|
  path = File.join(dir, "in.html")
  count.times do |i|
    inp = gen(r)
    File.binwrite(path, inp)
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
      next if fails > (ENV["SHOW"] || 5).to_i

      el = expected.lines
      al = actual.lines
      k = (0...[el.size, al.size].max).find { |j| el[j] != al[j] }
      puts "=== #{i} #{inp[0, 150].inspect}... mode=#{mode} chunk=#{chunk} opts=#{opts} enc=#{enc}"
      puts "  C:    #{el[k].inspect}"
      puts "  Ruby: #{al[k].inspect}"
      al[k + 1, 5]&.each { |l| puts "  Ruby+: #{l.inspect}" } if al[k]&.start_with?("EXCEPTION")
    end
  end
end
puts "#{total - fails}/#{total} identical"
