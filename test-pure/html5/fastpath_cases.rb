# frozen_string_literal: false
# Random tag/attribute/text/char-ref heavy inputs for the HTML5 differential harness, aimed at the
# tokenizer/tree-construction fast paths. ruby fastpath_cases.rb SEED COUNT OUT   (BIG=1: long inputs)
# then: ruby fuzz_oracle.rb OUT OUT.oracle (native gem); CASES=OUT ruby -Ilib compare.rb OUT.oracle
PIECES = ["a", "b c", "\n", "\r\n", "\r", "\t", " ", "\f", "é", "€", "😀", "日本語", "\u0085", "﷐", "\xEF\xBF\xBE", "\xED\xA0\x80", "\xE9", "\xC3",
  "&amp;", "&#233;", "&nbsp;", "&notin", "<b>", "</b>", "<p>", "</p>", "<br/>", "<br />", "<a href=\"x&amp;y é\">", "</a>", "<!-- cé -->",
  "<script>", "</script>", "<style>", "</style>", "<div class=\"é x\"\n id='a'>", "</div>", "<td nowrap>", "\0", "\x01",
  "<img src=é alt=\"日本\">", "<input value='\r\n'>", "<title>", "</title>", "<textarea>", "</textarea>", "é" * 50, "a" * 100,
  "<a b=c>", "<a b = \"c\">", "<a b=c&amp;d>", "<a b='x'c=d>", "<A HREF=\"X\" Id=q>", "<p id=a id=b class=c class=d>",
  "<a b=c/>", "<a b=\"c\"/>", "<a b/>", "<a b />", "<a\tb=c\td>", "<a b=`c`>", "<a b=c\"d>", "<a b=\"\">", "<a b=''>", "<a =b>",
  "<a b\"c=d>", "<a<b>", "<a/b>", "</a b>", "</a/>", "</A>", "</a >", "</a\n>", "<svg viewBox=\"0 0 1 1\"><path d=M0/></svg>",
  "<math><mi>x</mi></math>", "<table><tr><td>", "</td></tr></table>", "<select><option>1", "<ul><li>x<li>y</ul>",
  "<x-y z:w=1 data-a=\"é\">", "<a b=\"\u0085\">", "<a b=\"x y\">", "<a b=\"\t\n\f\">", "<h1>", "</h1>", "<a b=1 c=2 d=3 e=4 f=5>",
  "<frameset>", "<noscript>", "<template>", "</template>", "<iframe>", "</iframe>", "<plaintext>", "<xmp>", "</xmp>", "<![CDATA[y]]>", "<svg><foreignObject>", "</foreignObject>", "<svg><desc>", "<math><annotation-xml encoding=text/html>", "<i>", "</i>", "<a>", "<nobr>", "<font color=red>", "</font>",
  "&amp;", "&#65;", "&#x41;", "&#0;", "&#x110000;", "&#xD800;", "&#128;", "&#x9F;", "&#13;", "&#xFFFE;", "&#31;", "&#x1F;", "&#30;",
  "&notin;", "&noti", "&not", "&amp", "&AElig;", "&NotEqualTilde;", "&#9;", "&#12;", "&#x0C;", "&#10;", "&#32;", "&#1114111;", "&#00000065;",
  "&#x00041;", "&nbsp;&nbsp;", "&lt;b&gt;", "&#x1F600;", "&#xfdd0;", "&#127;", "&#159;", "&zzz;", "&a", "&#", "&#x", "&#x;", "&#;"]
seed = Integer(ARGV[0]); count = Integer(ARGV[1]); rng = Random.new(seed)
cases = count.times.map do |i|
  s = String.new(encoding: Encoding::BINARY)
  rng.rand(1..(ENV["BIG"] ? 400 : 50)).times { s << PIECES[rng.rand(PIECES.size)].b }
  s = "<!DOCTYPE html>".b + s if rng.rand(2) == 0
  opts = { max_errors: [-1, -1, 5].sample(random: rng), parse_noscript_content_as_text: rng.rand(2) == 1,
           max_attributes: [400, 400, 2, 0, -1].sample(random: rng), max_tree_depth: [400, 400, 5, -1].sample(random: rng) }
  { id: "x#{seed}:#{i}", data: s.force_encoding(Encoding::UTF_8), context: [nil, nil, nil, "div", "table", "svg", "template"].sample(random: rng),
    script: opts[:parse_noscript_content_as_text], opts: opts }
end
File.binwrite(ARGV[2], Marshal.dump(cases))
