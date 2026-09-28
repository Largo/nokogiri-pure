# frozen_string_literal: true

module HTML4Cases
  DEF = 1 | 32 | 64 | 2048 | (1 << 22)
  NOBLANKS = 256
  NOIMPLIED = 1 << 13
  NODEFDTD = 4
  HUGE = 1 << 19
  FILES = "/root/workspace/nokogiri-upstream/test/files"

  SNIPPETS = [
    "<p>x<div>y", "<html><body><p>hello</p></body></html>", "", " ", "\n\n", "hello", "  <p>a</p>  ",
    "<!DOCTYPE html><p>x", "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\"><body> <b>x</b> <i>y</i> </body>",
    "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01//EN\"><body>\n<p> </p>\n</body>",
    "<!doctype html system 'about:legacy-compat'><p>x", "<!DOCTYPE>", "<!DOCTYPE html PUBLIC \"bad\x01id\">x",
    "<!DOCTYPE html PUBLIC 'x' junk junk><p>", "<!DOCTYPE html SYSTEM>", "<!DOCTYPE html PUBLIC>",
    "<p>a<!DOCTYPE html>b", "<!-- c --><!DOCTYPE html><!-- d --><html>",
    "<!--x-->", "<!-->", "<!--->", "<!-- a -- b -->", "<!-- a --!>b", "<!-- unterminated", "<!x>y", "<!>y", "<! foo bar>z",
    "<?xml version='1.0'?><p>x</p>", "<?php echo 1 ?>", "<?pi?>", "<?pi data", "<?>", "<? x>",
    "<p>&amp;&lt;&gt;&quot;&apos;&nbsp;&copy;&euro;&hearts;</p>", "<p>&foo;&bar &#65;&#x41;&#X42;&#0;&#xD800;&#1114112;&#99999999999;</p>",
    "<p>&#65</p>", "<p>&#x</p>", "<p>&#;</p>", "<p>& x</p>", "<p>&</p>", "&amp", "<p>a&amp", "&nbsp;", "a &lt b",
    "<a href='a&amp;b&c;&#65;&#x42;&nbsp;x'>t</a>", "<a href=\"x\" href=\"y\">t</a>", "<a href=x>y</a>", "<a href= >y</a>",
    "<a href>y</a>", "<a =x>y</a>", "<a 1=2>y</a>", "<a b='x>y</a>", "<a b=\"x>y</a>", "<input disabled checked=checked NAME=Foo>",
    "<input value=''><input value>", "<select><option selected>1<option>2</select>", "<td nowrap>x</td>",
    "<a id=foo name=bar>x</a><p id=baz>", "<p id=\"\">a</p><p id=\"\">", "<p id=a><a name=a>", "<a name=\"\">", "<a xml:id='1bad'>", "<a xml:id='good'>",
    "<script>if (a < b && c > d) { x = '</div>'; }</script>", "<script>a</script >b", "<script>x</SCRIPT>y",
    "<script>unterminated", "<style>p { color: red } </p></style>", "<style></style>", "<script></script>",
    "<title>a<b>c</b></title>", "<textarea><p>x</p></textarea>", "<xmp><p>x</p></xmp>", "<plaintext><p>x",
    "<table><tr><td>a<td>b<tr><td>c</table>", "<table><td>x</table>", "<ul><li>a<li>b</ul>", "<dl><dt>a<dd>b<dt>c</dl>",
    "<p>a<p>b<p>c", "<b><i>x</b></i>", "<b><p>x</b>y", "<div><span>x</div>y</span>", "</p>", "</div>x", "x</html>y",
    "<html><html>", "<head><head>", "<body><body>", "<body a=1><body b=2>", "<html a=1><body><html b=2>",
    "<head><title>t</title></head><body>b</body>", "<title>x</title><p>y", "<meta charset=utf-8><p>x",
    "<link rel=x><base href=y><p>z", "<frameset><frame src=x></frameset>", "<noframes>x</noframes>",
    "<p>x</p>\n\n<p>y</p>", "<div>\n  <p>x</p>\n  <p>y</p>\n</div>", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>",
    "<b> </b> <i> </i>", "<p><b>x</b> <i>y</i></p>", "<html> <head> <title>t</title> </head> <body> x </body> </html>",
    "<html>\n<!-- c -->\n<body>\n</body>\n</html>", "<foo>x</foo>", "<foo:bar a:b=1>x</foo:bar>", "<my-tag>x</my-tag>",
    "<a.b>x</a.b>", "<_x>y", "<:x>y", "<1x>y", "< p>", "<p/>x", "<br/>x", "<br>x</br>y", "<img src=x/>", "<p / >x",
    "<p\n class=\"a\"\n id=\"b\"\n>x</p>", "<p class=a", "<p class=\"a", "<p", "<", "a<b", "a < b", "</", "</ p>", "</p x>",
    "</>", "<p>x</p y>", "<div>x</div\n>", "<\x80>", "<p>\x00</p>", "<p a=\"\x00\">", "a\x01b\x7fc",
    "<p>line1\nline2\r\nline3\rline4</p>", "\n\n\n<p>\n\n<b>x</b>\n</p>", "<a\nhref\n=\n'x'\n>y</a>",
    "<p>" + "x" * 3000 + "</p>", "<p>" + " " * 1500 + "</p>", "<div>" + "<b>y</b>" * 300 + "</div>",
    " " * 1200 + "<p>x</p>", "<html>" + " " * 1200 + "<body>", "<p>" + "a&amp;" * 500 + "</p>",
    "<script>" + "x" * 2500 + "</script>", "<p title='" + "v" * 3000 + "'>", "<!--" + "c" * 3000 + "-->",
    "<div>" * 300, "<a " + "x" * 150 + "=1>", "<" + "t" * 150 + ">x", "<p>é中\u{1F600}</p>", "<p title='é'>",
    "<é>x", "<p>&é;</p>", "<p>\xE9</p>", "<p>\xC3\x28</p>", "<p>\xF0\x9F\x98</p>", "<p>\xED\xA0\x80</p>",
    "<!DOCTYPE html é><p>", "<?é x?>", "<p>&#128512;&#xFFFE;&#xFFFF;&#x10FFFF;</p>",
    "<p><!-- in p --></p>", "<head><!-- c --><style>x</style></head>", "text<!--c-->more", "<p>a</p><!-- trailing -->",
    "<center><p>x</center>", "<font><p>x</font>", "<a><table><a>", "<form><form></form>", "<h1><h2>x</h2></h1>",
    "<option>a<option>b", "<p><table>", "<address><p>x</address>", "<pre>\nx</pre>", "<pre>\n\nx</pre>", "<listing>\nx</listing>",
    "<object><param name=a></object>", "<isindex>", "<basefont>", "<applet>x</applet>", "<embed src=x>", "<iframe>x</iframe>",
    "<noscript><p>x</p></noscript>", "<map><area></map>", "<caption>x", "<colgroup><col><col></colgroup>", "<thead><tr><th>h",
    "<tbody><tr>", "<tfoot>x", "<legend>x", "<fieldset><legend>l</legend>x</fieldset>", "<label>x<input></label>",
    "<button>x</button>", "<q>x</q><sub>1</sub><sup>2</sup>", "<bdo dir=rtl>x</bdo>", "<ins>x</ins><del>y</del>",
    "<html><head><meta http-equiv='Content-Type' content='text/html; charset=ISO-8859-1'></head><body>\xE9</body></html>",
    "<meta http-equiv=content-type content='text/html;charset=bogus-enc'><p>x",
    "<meta charset='nosuch'><p>x", "<meta charset=UTF-8 charset=latin1>",
  ].freeze

  def self.fuzz(n, seed)
    r = Random.new(seed)
    toks = ["<p>", "</p>", "<div>", "</div>", "<b>", "</b>", "<i>", "</i>", "<table>", "<tr>", "<td>", "</td>", "</table>",
            "<li>", "<ul>", "</ul>", "text", " ", "\n", "&amp;", "&nbsp;", "&x;", "&#1;", "<!--c-->", "<br>", "<html>", "<body>",
            "<head>", "<title>", "</title>", "<script>", "</script>", "<style>", "</style>", "<a href='x'>", "</a>", "<option>",
            "<select>", "<form>", "</form>", "<h1>", "</h1>", "<foo>", "</foo>", "<?pi x?>", "<!DOCTYPE html>", "</html>",
            "</body>", "<dl>", "<dt>", "<dd>", "<span>", "</span>", "<font>", "<center>", "<pre>", "<textarea>", "<input>",
            "<meta charset=x>", "<p class=a id=b>", "<img src=y/>", "a", "<", ">", "&", "\t", "é", "</ >", "<!x>", "<caption>",
            "<col>", "<colgroup>", "<thead>", "<tbody>", "<tfoot>", "<noscript>", "<frameset>", "<frame>", "<noframes>"]
    Array.new(n) { Array.new(r.rand(1..25)) { toks[r.rand(toks.size)] }.join }
  end

  def self.all
    cases = []
    SNIPPETS.each do |s|
      cases << [:mem, s.dup.force_encoding("UTF-8"), nil, "UTF-8", DEF]
    end
    SNIPPETS.first(80).each do |s|
      cases << [:mem, s.b, nil, nil, DEF]
    end
    %w[<p>a</p>\n\n<p>b</p> <div>\n<p>x</p>\n</div> <html>\n<head>\n<title>t</title>\n</head>\n<body>\n<p>x</p>\n</body>\n</html>].each do |s|
      s = s.gsub('\n', "\n")
      [NOBLANKS, NOIMPLIED, NODEFDTD, NOBLANKS | NOIMPLIED, 0, 1].each do |o|
        cases << [:mem, s, nil, "UTF-8", o == 0 || o == 1 ? o : DEF | o]
      end
    end
    SNIPPETS.first(40).each { |s| cases << [:mem, s, nil, "UTF-8", DEF | NOIMPLIED] }
    SNIPPETS.first(40).each { |s| cases << [:mem, s, nil, "UTF-8", DEF | NOBLANKS] }
    # encodings
    [
      ["<p>a\xE9b</p>", nil], ["<p>a\xE9b</p>", "ISO-8859-1"], ["<p>a\xE9b</p>", "windows-1252"], ["<p>a\x82\xA0b</p>", "Shift_JIS"],
      ["<p>a\xFF\xFEb</p><p>more</p>", "EUC-JP"], ["<p>a\xE9b</p>", "US-ASCII"], ["<p>a\xE9b</p>", "bogus"],
      ["\xEF\xBB\xBF<p>a</p>", nil], ["\xEF\xBB\xBF<p>a</p>", "UTF-8"], ["\xFF\xFE<\x00p\x00>\x00a\x00", nil], ["\xFE\xFF\x00<\x00p\x00>\x00a", nil],
      ["<meta charset=Shift_JIS><p>a\x82\xA0b</p>", nil],
      ["<meta http-equiv='Content-Type' content='text/html; charset=EUC-JP'><p>a\xA4\xA2b</p>", nil],
      ["<p>a\xA4\xA2b</p><meta charset=EUC-JP><p>a\xA4\xA2b</p>", nil], ["<?xml version='1.0'?><p>a\xC3\xA9b</p>", nil],
      ["<p>" + "a" * 300 + "\xFF\xFE" + "b" * 300, "EUC-JP"], ["<p>" + "a" * 3000 + "\xFF\xFE" + "b" * 300, "EUC-JP"],
      ["<p>" + "a" * 5000 + "\xE9</p>", nil], ["<p>" + "a" * 5000 + "</p><meta http-equiv='content-type' content='text/html; charset=utf-8'>\xE9", nil],
      ["<meta http-equiv='content-type' content='text/html; charset=utf-8'><p>\xE9", nil],
      ["<p>x</p><!-- meta http-equiv content charset=EUC-JP --><p>\xA4\xA2", nil],
      ["<p>a\x82</p>", "Shift_JIS"], ["<p>\xE9\xE9", "UTF-8"], ["<p title='\xE9'>", "UTF-8"], ["<p>\xC3\xA9</p>", nil],
      ["<meta charset=utf-8><p>\xC3\xA9</p>", nil], ["<meta charset=UTF8><p>\xC3\xA9</p>", nil],
      ["<meta charset=ascii><p>\xC3\xA9</p>", nil], ["<meta charset=iso-8859-1><p>\xC3\xA9</p>", nil],
      ["\xEF\xBB\xBF<meta charset=iso-8859-1><p>\xC3\xA9</p>", nil],
      ["<p>\x80\x81</p>", "windows-1252"], ["<p>x</p>", "utf-16"], ["<\x00p\x00>\x00", "UTF-16LE"],
    ].each do |s, enc|
      cases << [:mem, s.b, nil, enc, DEF]
      cases << [:io, s.b, nil, enc, DEF]
    end
    Dir[File.join(FILES, "*.html")].sort.each do |f|
      data = File.binread(f)
      cases << [:mem, data, f, nil, DEF]
      cases << [:mem, data, f, "UTF-8", DEF]
      cases << [:io, data, f, nil, DEF]
    end
    fuzz(400, 42).each { |s| cases << [:mem, s, nil, "UTF-8", DEF] }
    fuzz(100, 7).each { |s| cases << [:mem, s, nil, "UTF-8", 0] }
    fuzz(100, 9).each { |s| cases << [:mem, s, nil, "UTF-8", DEF | NOBLANKS] }
    cases << [:mem, "<p>x</p>", "http://example.com/a b?c=d#e", "UTF-8", DEF]
    cases << [:mem, "<p>x</p>", "/some/path.html", "UTF-8", DEF]
    cases << [:mem, "<div>\n" + "<p>line</p>\n" * 70000 + "</div>", nil, "UTF-8", DEF]
    cases << [:mem, "<div>\n" + "text\n" * 70000 + "<b>x</b></div>", nil, "UTF-8", DEF]
    cases << [:mem, "<div>" * 300, nil, "UTF-8", DEF | HUGE]
    cases << [:mem, "<p>" + "x" * 20000 + "</p>", nil, "UTF-8", DEF]
    cases
  end
end
