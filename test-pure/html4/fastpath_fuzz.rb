# frozen_string_literal: false
# Differential fuzzing of the HTML4 parser's fast paths / express lanes against libxml2 (htmlsax.c):
# multibyte text, long runs, CR/LF, script/style, attributes, entities, comments, push chunk sizes.
# usage: HTMLSAX=/path/to/htmlsax ruby fastpath_fuzz.rb [seed] [count]   (BIG=1 for long inputs)
require "stringio"
require "tmpdir"
require_relative "saxdump"
HTMLSAX = ENV["HTMLSAX"] || "/tmp/claude-0/-root-workspace/548d09b2-03e4-44e3-9288-5b2fb6d3d1fa/scratchpad/htmlsax"
r = Random.new((ARGV[0] || 1).to_i)
pieces = ["a", "b c", "\n", "\r\n", "\r", "\t", " ", "é", "€", "😀", "日本語", "\xEF\xBF\xBE", "\xED\xA0\x80", "\xE9", "\xC3", "\xF4\x90\x80\x80",
  "&amp;", "&#233;", "&nbsp;", "<b>", "</b>", "<p>", "<br/>", "<a href=\"x&amp;y é\">", "</a>", "<!-- cé -->", "<script>", "</script>",
  "<style>", "</style>", "<div class=\"é x\"\n id='a'>", "</div>", "<td nowrap>", "\0", "\x01", "<meta charset=\"UTF-8\">",
  "<img src=é alt=\"日本\">", "<input value='\r\n'>", "<title>", "</title>", "é" * 400, "a" * 997, "😀" * 300,
  '<a b=c>', '<a b = "c">', '<a b=c&amp;d>', "<a " + "n" * 101 + "=v>", "<a " + "n" * 100 + "=v x>", '<a b=">', "<a b='x'c=d>",
  '<A HREF="X" Id=q>', "<p id=a id=b class=c class=d>", "<a b=c/>", "<br/ >", "<a b='\u00e9\te'>", "<a b=\"\x01\">", '<a b="">',
  "<a b=\u00e9>", "<a b=\"\xE9\">", "<a b=x\xE9>", '<a b=x"y>', "<a =x>", "<a b\0=c>", "<a b=c\0>", "<a b=\"c\0d\">", "<a :b=1 _c=2 .d=3>",
  "<a b\n=\nc>", "<a\r\nb=c>", '<meta http-equiv=Content-Type content="text/html; charset=ISO-8859-1">', "<div ",
  '<a b="' + "x" * 300 + '">', "<a b=" + "x" * 300 + ">", "<a b='\u65e5\u672c' c=\u00e9\u00e9>",
  "<!--", "-->", "--!>", "<!-->", "<!--->", "<!---->", "<!-- a -- b -->", "<!--\u00e9\u65e5-->", "<!--\x01-->", "<!--\xE9-->", "<!--\0-->",
  "<!--" + "c" * 300 + "-->", "<!--" + "\u00e9" * 200 + "\n-->", "<!--a\r\nb\nc-->", "<!-- x --!> y -->", "<!-- x ---> y", "<!--" + "z" * 4100 + "-->",
  "&#x1F600;", "&#X41;", "&#0;", "&#1114112;", "&#1114111;", "&#xD800;", "&#xFFFE;", "&copy", "&foo;", "&Amp;", "&a.b;", "&#00000065;", "&#0000065;",
  "&#x0000041;", "&#x000041;", "&nbsp;x", "&lt;&gt;", "&#9;", "&#13;", "&#x;", "&#;", "&;", "& ;", "&hearts;&euro;",
  "<a href='?a=1&amp;b=2&c=3'>", "<a t=\"&#233;&#x41;&nbsp;&foo;&#0;&#xD800;\">", "<a t=&lt;&gt;>", "<a t=x&amp;>", "<a t='&amp'>", "<a t=\"&#1114112;\">",
  "<a t=\"&amp;&amp;&copy;\u00e9\">", "<a t=&a.b;>", "<a t=\"&#65\">",
  "<b\n\tclass=x\r\n id=y>", "<img src=x/>", "<p/>", "<input disabled>", "<input disabled name=x>", "<option selected>", "<span a=1 a=2>",
  "<div>" * 130, "</div>" * 50, "<x-y>", "<foo>", "<a1b2 c=d>", "<table><tr><td>", "<ul><li>", "<dl><dt>x<dd>y", "<select><option>1<option>2",
  "<h1\n>", "<em\t\t>", "<p\r>", "<i  title = 'x' >", "<div class=\"a\"\nid=\"b\"\n>",
  "<script>x</noscript>y</script>", "<noscript>", "</noscript>", "<style>a</b></style>", "<script>a<b>c</script>", "</scriptx>", "<scriptx>",
  "<script>if (a < b) {}</script>", "<style>p{}</style >"].map(&:b)
count = (ARGV[1] || 200).to_i
configs = [["pull", 0, 1, "-"], ["pulldom", 0, 1, "-"], ["pulldom", 0, 1, "UTF-8"], ["push", 1, 1, "-"], ["push", 7, 1, "UTF-8"],
           ["pushdom", 3, 1, "-"], ["pushdom", 1000, 1, "UTF-8"], ["push", 300, 1, "-"], ["push", 64, 1, "UTF-8"], ["pulldom", 0, 0, "ISO-8859-1"], ["pulldom", 0, 1, "EUC-JP"]]
fails = total = 0
Dir.mktmpdir do |dir|
  path = File.join(dir, "in.html")
  count.times do |i|
    inp = +"".b
    r.rand(1..(ENV["BIG"] ? 600 : 60)).times { inp << pieces[r.rand(pieces.size)] }
    inp = "<html><body>".b + inp if r.rand(2) == 0
    File.binwrite(path, inp)
    configs.each do |mode, chunk, opts, enc|
      next if mode.start_with?("push") && chunk < 5 && inp.bytesize > 20000
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
      next if fails > 5
      el = expected.lines
      al = actual.lines
      k = (0...[el.size, al.size].max).find { |j| el[j] != al[j] }
      puts "=== #{i} #{inp[0, 100].inspect} mode=#{mode} chunk=#{chunk} opts=#{opts} enc=#{enc}"
      puts "  C:    #{el[k].inspect[0, 300]}"
      puts "  Ruby: #{al[k].inspect[0, 300]}"
    end
  end
end
puts "#{total - fails}/#{total} identical"
