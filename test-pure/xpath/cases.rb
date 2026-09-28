# frozen_string_literal: true

DOCS = {
  "d1" => <<~XML,
    <root xmlns:a="urn:a" xmlns="urn:default" xml:lang="en-US">
      <item id="1" type="x">one<b>bold</b>tail</item>
      <item id="2" type="y" a:attr="aa">two</item>
      <a:item id="3">three<![CDATA[cdata!]]></a:item>
      <!-- a comment -->
      <?proc some data?>
      <group xmlns:c="urn:c" xml:lang="fr">
        <c:x c:k="1">10</c:x>
        <c:x c:k="2">20.5</c:x>
        <c:x>abc</c:x>
        <sub xmlns="urn:other"><deep>  lots   of   space  </deep></sub>
      </group>
      <num>3</num><num>-1.5</num><num>1e2</num>
    </root>
  XML
  "d2" => <<~XML,
    <html><body><div class="a b  c" id="d1"><p class="x">P1</p><p>P2<span>S</span></p></div><div class="b"><p>P3</p><div><p class="x y">P4</p></div></div><ul><li>1</li><li>2</li><li>3</li><li>4</li></ul></body></html>
  XML
  "html1" => <<~HTML,
    <!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
    <!-- lead comment -->
    <html lang="de-CH"><head><title>T &amp; t</title></head>
    <body><div id="a1" class="x y">A <b>B</b> &nbsp;&lt; C</div><p id="p1" name="n1">P1</p><a name="an">anchor</a><p lang="en">P2 <!-- c --></p>
    <table><tr><td>1</td><td>2</td></tr><tr><td>3</td></tr></table><script>if (a < b) {}</script></body></html>
  HTML
  "d3" => "<r xmlns:p='urn:p' xmlns:q='urn:q'>" + (1..30).map { |i| "<e n='#{i}' m='#{i % 3}'>t#{i}<f xmlns:z='urn:z#{i}'>#{i}</f><!--c#{i}--></e>" }.join + "</r>",
}

EXPRS = [
  ["/", "1 + 1"], ["/", "1.5"], ["/", "\"s\""], ["/", "1 = 1"], ["/", "1 div 0"], ["/", "-1 div 0"], ["/", "0 div 0"],
  ["/", "string(1 div 0)"], ["/", "string(0 div 0)"], ["/", "string(-0)"], ["/", "string(0.1 + 0.2)"], ["/", "string(1 div 3)"],
  ["/", "string(123456789012)"], ["/", "string(0.000001)"], ["/", "string(1e-7)"], ["/", "7 mod 3"], ["/", "-7 mod 3"], ["/", "7 mod -3"], ["/", "7.5 mod 2"], ["/", "5 mod 0"],
  ["/", "1 div -0"], ["/", "round(2.5)"], ["/", "round(-2.5)"], ["/", "round(-0.4)"], ["/", "1 div round(-0.4)"], ["/", "floor(-1.5)"], ["/", "ceiling(-0.5)"], ["/", "1 div ceiling(-0.5)"],
  ["/", "substring('12345', 1.5, 2.6)"], ["/", "substring('12345', 0, 3)"], ["/", "substring('12345', 0 div 0, 3)"], ["/", "substring('12345', 1, 0 div 0)"],
  ["/", "substring('12345', -42, 1 div 0)"], ["/", "substring('12345', -1 div 0, 1 div 0)"], ["/", "substring('héllo', 2, 3)"], ["/", "substring('abc', 2)"],
  ["/", "string-length('héllo')"], ["/", "translate('bar','abc','ABC')"], ["/", "translate('--aaa--','abc-','ABC')"], ["/", "translate('héllo','é','e')"],
  ["/", "normalize-space('  a  b \t c  ')"], ["/", "concat('a', 1, true(), 1 div 0)"], ["/", "concat('a')"], ["/", "contains('abc', '')"], ["/", "starts-with('abc', 'ab')"],
  ["/", "substring-before('1999/04/01','/')"], ["/", "substring-after('1999/04/01','/')"], ["/", "substring-after('abc','')"], ["/", "substring-before('abc','z')"],
  ["/", "boolean('')"], ["/", "boolean('0')"], ["/", "boolean(0)"], ["/", "not(1)"], ["/", "number('  12  ')"], ["/", "number('1e3')"], ["/", "number('abc')"],
  ["/", "'1' = 1"], ["/", "'a' = 'a'"], ["/", "true() = 'x'"], ["/", "1 < 2"], ["/", "'10' > '9'"], ["/", "true() > false()"],
  ["/", "last()"], ["/", "position()"], ["/", "count(1)"], ["/", "foo()"], ["/", "count()"], ["/", "count(//*, 1)"], ["/", "$undefined"], ["/", "x:y"],
  ["/", "//"], ["/", "/child::"], ["/", "1 +"], ["/", "'unterminated"], ["/", "a[1"], ["/", "a]"], ["/", "@"], ["/", ")"], ["/", "1 2"], ["/", "a/"], ["/", "processing-instruction(foo)"],
  ["/", "$v", { vars: { "v" => "value" } }], ["/", "$v = 'value'", { vars: { "v" => "value" } }], ["/", "concat($a, $b)", { vars: { "a" => "x", "b" => "y" } }],
  ["/", "//d:item", { ns: { "d" => "urn:default" } }], ["/", "//d:item/@id", { ns: { "d" => "urn:default" } }], ["/", "//*"], ["/", "//*[local-name()='item']"],
  ["/", "//@*"], ["/", "//text()"], ["/", "//node()"], ["/", "//comment()"], ["/", "//processing-instruction()"], ["/", "//processing-instruction('proc')"],
  ["/", "//processing-instruction('nope')"], ["/", "/*/namespace::*"], ["/", "//namespace::*"], ["/", "//namespace::a"], ["/", "count(//namespace::*)"],
  ["/", "name(/*/namespace::*[last()])"], ["/", "local-name(/*/namespace::*[2])"], ["/", "string(/*/namespace::*[2])"], ["/", "/*/namespace::*/.."],
  ["/", "//a:item", { ns: { "a" => "urn:a" } }], ["/", "//@a:attr", { ns: { "a" => "urn:a" } }], ["/", "//@a:*", { ns: { "a" => "urn:a" } }], ["/", "//a:*", { ns: { "a" => "urn:a" } }],
  ["/", "string(//*)"], ["/", "string(/)"], ["/", "name(/*)"], ["/", "local-name(/*)"], ["/", "namespace-uri(/*)"], ["/", "name(//@*[3])"], ["/", "name(//*[4])"],
  ["/", "//*[last()]"], ["/", "//*[position() = 2]"], ["/", "(//*)[2]"], ["/", "(//*)[last()]"], ["/", "(//*)[position() > 20]"], ["/", "//*[2][1]"], ["/", "//*[1][2]"],
  ["/", "sum(//*[local-name()='num'])"], ["/", "sum(//*[local-name()='x'])"], ["/", "count(//*[local-name()='x'] | //*[local-name()='num'])"],
  ["/", "//*[local-name()='num'] | //*[local-name()='x']"], ["/", "//*[local-name()='num'][. > 0]"], ["/", "//*[local-name()='num'][. = 3]"], ["/", "//*[local-name()='x'][. < 15]"],
  ["/", "//*[local-name()='x'] = 20.5"], ["/", "//*[local-name()='x'] != 20.5"], ["/", "//*[local-name()='x'] = 'abc'"], ["/", "//*[local-name()='x'] != 'abc'"],
  ["/", "//*[local-name()='x'] = //*[local-name()='num']"], ["/", "//*[local-name()='x'] > //*[local-name()='num']"], ["/", "//*[local-name()='x'] = true()"],
  ["/", "//*[lang('en')]"], ["/", "//*[lang('fr')]"], ["/", "//*[lang('EN-us')]"], ["/", "//*[lang('e')]"],
  ["/", "//*[local-name()='item'][1]/following-sibling::*"], ["/", "//*[local-name()='item'][2]/preceding-sibling::*"], ["/", "//*[local-name()='deep']/ancestor::*"],
  ["/", "//*[local-name()='deep']/ancestor-or-self::node()"], ["/", "//*[local-name()='item'][1]/following::*"], ["/", "//*[local-name()='sub']/preceding::node()"],
  ["/", "//*[local-name()='b']/.."], ["/", "//@id/.."], ["/", "//@id/parent::*"], ["/", "//@id/following::*[1]"], ["/", "//@id/preceding::*[1]"], ["/", "//@*/ancestor::*[1]"],
  ["/", "//*[local-name()='x']/@*/following-sibling::node()"], ["/", "//text()/self::node()"], ["/", "//*/self::*[@id]"], ["/", "descendant::*[3]"], ["/", "descendant-or-self::node()[3]"],
  ["/", "//*[local-name()='item']/text()[1]"], ["/", "//*[local-name()='item']//text()"], ["/", "//*[@id='2']"], ["/", "id('1')"], ["/", "//*[@id][last()]/@id"],
  ["/", "string(//*[local-name()='deep'])"], ["/", "normalize-space(//*[local-name()='deep'])"], ["/", "//*[normalize-space()='three']"], ["/", "//*[contains(., 'bold')]"],
  ["/", "//*[starts-with(name(), 'a:')]"], ["/", "//*[string-length(name()) = 3]"], ["/", "//*[local-name() = 'group']//*[1]"], ["/", "//*[local-name() = 'group']/descendant::*[2]"],
  ["/", "count(//*[local-name()='x']/@*)"], ["/", "//*[@*]"], ["/", "//*[not(@*)]"], ["/", "//*[count(*) > 1]"], ["/", "//*[* and text()]"], ["/", "//*[@id or @type]"],
  ["/", "//*[@id and @type='y']"], ["/", "(//*[local-name()='x'])[2]/@*"], ["/", "//*[local-name()='x'][position() mod 2 = 1]"], ["/", "//*[local-name()='x'][last() - 1]"],
  ["/", "-//*[local-name()='num'][1]"], ["/", "--3"], ["/", "- - -3"], ["/", "1 - -1"], ["/", "2*3"], ["/", "10 div 4"], ["/", "string(1 div 3 * 3)"],
  ["/", "/root"], ["/", "/*[1]/*[1]"], ["/", "*"], ["/", "."], ["/", ".."], ["/", "/.."], ["/", "self::node()"], ["/", "string(.)"], ["/", "//*[local-name()='x'][2]/../*[1]"],
  ["/", "//*[local-name()='item'][1]/b/../text()"], ["/", "//*[local-name()='item' and . = 'two']"], ["/", "//*[3]"], ["/", "//*[position()=last()]"],
  ["/", "//text()[normalize-space()]"], ["/", "count(//text())"], ["/", "//text()[. = 'tail']/preceding-sibling::node()"], ["/", "(//text())[last()]"],
  ["/", "nokogiri:thing(1)", { handler: true }], ["/", "nokogiri:num()", { handler: true }], ["/", "nokogiri:str('x')", { handler: true }],
  ["/", "nokogiri:nodes(//*[@id])", { handler: true }], ["/", "nokogiri:arr(//*[@id])", { handler: true }], ["/", "nokogiri:nilly()", { handler: true }],
  ["/", "nokogiri:bad()", { handler: true }], ["/", "nokogiri:args(1, 's', true(), //*[@id])", { handler: true }], ["/", "nokogiri:nope()", { handler: true }],
  ["/", "//*[nokogiri:bool()]", { handler: true }], ["/", "count(nokogiri:nodes(//*[@id]))", { handler: true }],
  ["/", "//*[nokogiri-builtin:css-class(@class, 'b')]"], ["/", "//*[nokogiri-builtin:css-class(@class, 'c')]"], ["/", "//*[nokogiri-builtin:css-class(@class, '')]"],
  ["/", "//*[nokogiri-builtin:local-name-is('p')]"], ["/", "nokogiri-builtin:css-class('a b', 'b', 'c')"],
  ["/", "//div[contains(concat(' ',normalize-space(@class),' '),' b ')]"], ["/", ".//p"], ["/", "//div//p"], ["/", "//div/p[1]"], ["/", "//div//p[1]"], ["/", "(//div//p)[1]"],
  ["/", "//li[position() > 1 and position() < 4]"], ["/", "//li[last()]"], ["/", "//li[1] | //li[3] | //li[2]"], ["/", "//ul/li[2]/following-sibling::li"], ["/", "//li[. = 3]/preceding-sibling::*[1]"],
  ["/", "//*[@class = 'x']"], ["/", "//p[span]"], ["/", "//p[not(@class)]"], ["/", "//body/*[2]/*"], ["/", "//div[@id='d1']//text()"], ["/", "count(//div//*)"],
  ["//div[2]", ".//p"], ["//div[2]", "p"], ["//div[2]", "../*"], ["//div[2]", "//p"], ["//div[2]", "preceding::p"], ["//div[2]", "following::li"], ["//div[2]", "ancestor::*"],
  ["//div[2]", "position()"], ["//div[2]", "last()"], ["//div[2]", "name()"], ["//li[3]", "string()"], ["//li[3]", "number()"], ["//li[3]", "string-length()"],
  ["//li[3]", "normalize-space()"], ["//li[3]", "preceding-sibling::li[1]"], ["//li[3]", "preceding::*[1]"], ["//li[3]", "ancestor::*[1]"], ["//li[3]", "ancestor::*[last()]"],
  ["//li[3]", "(preceding-sibling::li)[1]"], ["//li[3]", "preceding-sibling::li[last()]"], ["//li[3]", "following-sibling::li | preceding-sibling::li"],
  ["//li[3]", "text()"], ["//li[3]/text()", "."], ["//li[3]/text()", ".."], ["//li[3]/text()", "following::text()"], ["//li[3]/text()", "preceding::text()[2]"],
  ["//div/@class", "."], ["//div/@class", ".."], ["//div/@class", "string()"], ["//div/@class", "following::*[1]"], ["//div/@class", "preceding::*"], ["//div/@class", "ancestor::*"],
  ["/", "//*:item"], ["/", "//*:*"], ["/", "//@*:attr"], ["/", "//@*:*"], ["/", "count(//*:x[1])"], ["/", "*:root/*:group/*:x[2]"], ["/", "//*:li[2]"], ["/", "//*: li"], ["/", "//* :li"], ["/", "*:"],
  ["/", "string(1)", { handler: true }], ["/", "nokogiri:string(1)", { handler: true }], ["/", "nokogiri:raiser()", { handler: true }], ["/", "raiser()", { handler: true }],
  ["/", "//*[local-name()='item'][nokogiri:thing(.)]", { handler: true }],
  ["/", "//@* | //*"], ["/", "//text() | //comment() | //@*"], ["/", "//namespace::* | //*"], ["/", "//*[@n > 25]/namespace::* | //*[@n > 25]"],
  ["/", "(//*)[position() mod 3 = 0] | (//*)[position() mod 2 = 0]"], ["/", "//*[@n=7]/preceding::*[2]"], ["/", "//*[@n=7]/preceding::node()"], ["/", "//f[. = 9]/ancestor::*[2]"],
  ["/", "//f | //e[@m=1] | //@m | //comment()[contains(., '2')]"], ["/", "count(//namespace::*)"], ["/", "//e[f = 3]"], ["/", "//e[@m = 0][last()]"], ["/", "//e[position() = last() - 1]"],
  ["/", "//e[@n mod 5 = 0]/following-sibling::e[1]"], ["/", "//e[@n > 27]/following::node()"], ["/", "//*[@n=3]/following::text()[1]"], ["/", "sum(//f)"], ["/", "sum(//@n) div count(//@n)"],
  ["/", "//e[not(@m = preceding-sibling::e/@m)]"], ["/", "//e[@m = following-sibling::e[1]/@m + 1]"], ["/", "//e[string(f) = @n]"], ["/", "//e[f > 10][f < 15]"],
  ["/", "//f/namespace::*[name() = 'z']"], ["/", "//f/namespace::z"], ["/", "count(//f/namespace::*[. = 'urn:p'])"], ["/", "//namespace::*[. = 'urn:z3']/.."],
  ["/", "(//namespace::*)[3]"], ["/", "(//namespace::*)[last()]"], ["/", "//e[5]/namespace::*"], ["/", "//e[5]/f/namespace::* | //e[5]/namespace::*"],
  ["/", "nokogiri:nodes(//e[3]/f/namespace::*) | //e[3]", { handler: true }], ["/", "nokogiri:arr(//e[@m=2]) | //e[@m=1]", { handler: true }],
  ["/", "//e[3]/f/namespace::*[3]/self::node()"], ["/", "//e[3]/f/namespace::*/parent::*"], ["/", "//e[3]/f/namespace::*/following::*[1]"], ["/", "//e[3]/f/namespace::*/preceding::*[1]"],
  ["/", "//e[3]/f/namespace::*/ancestor-or-self::node()"], ["/", "//e[3]/f/namespace::*/descendant-or-self::node()"], ["/", "//e[3]/f/namespace::*/child::node()"],
  ["/", "id('a1')"], ["/", "id('p1 a1 zz')"], ["/", "id(' p1')"], ["/", "id('an')"], ["/", "id(//@id)"], ["/", "count(/node())"], ["/", "/node()"], ["/", "/comment()"],
  ["/", "//*[lang('de')]"], ["/", "//*[lang('en')]"], ["/", "string(//title)"], ["/", "//text()[contains(., '<')]"], ["/", "string-length(//div)"], ["/", "//td[. > 1]"],
  ["/", "normalize-space(//div)"], ["/", "translate(//div, ' ', '_')"], ["/", "//script/text()"], ["/", "name(/node()[1])"], ["/", "/node()[1]/self::node()"], ["/", "//node()[not(self::*)]"],
  ["/", "//h\u00e9llo"], ["/", "//\u65e5\u672c"], ["/", "'\u65e5' = '\u65e5'"], ["/", "1."], ["/", ".5"], ["/", "1e5"], ["/", "1E-2 * 100"], ["/", "1e"], ["/", "1.5.5"],
  ["/", "'a\"b'"], ["/", "\"a'b\""], ["/", "(" * 300 + "1" + ")" * 300], ["/", "(" * 600 + "1" + ")" * 600], ["/", "1" + " + 1" * 2000], ["/", "//*[" * 50 + "1" + "]" * 50],
  ["/", "a/b/c/d/e/f/g/h/i/j/k"], ["/", "//*[@*[.='x']]"], ["/", "child::*/child::*[1]/@*[1]"], ["/", "$"], ["/", "$1"], ["/", "$a:b"], ["/", "nokogiri:"], ["/", "@*/@*"],
  ["/", "count(//*) div 0 = 1 div 0"], ["/", "-(1)"], ["/", "--(1)"], ["/", "1 - - 1"], ["/", "1--1"], ["/", "1 -1"], ["/", "div"], ["/", "div div div"], ["/", "or"], ["/", "and or and"],
  ["/", "*[1]/ancestor::node()"], ["/", "node()/.."], ["/", "../.."], ["/", "self::*"], ["/", "comment"], ["/", "text"], ["/", "text ()"], ["/", "node ( )"], ["/", "processing-instruction( 'x' )"],
  ["/", "child :: *"], ["/", "child: :*"], ["/", "@ *"], ["/", "/ *"], ["/", "// *"], ["/", "*/ /*"], ["/", "count( / )"], ["/", "/|/"], ["/", "(/)[1]"], ["/", "(1)[1]"], ["/", "'x'[1]"],
  ["/", "true()[1]"], ["/", "(//*)[true()]"], ["/", "(//*)['']"], ["/", "(//*)[0]"], ["/", "(//*)[1.5]"], ["/", "(//*)[-1]"], ["/", "(//*)[1 div 0]"], ["/", "//*[0 div 0]"],
  ["/", "string(//*[2]/@*)"], ["/", "number(//*[2]/@*)"], ["/", "boolean(//*[2]/@*)"], ["/", "//*[position()]"], ["/", "//*[last()]"], ["/", "//*[last() = position()]"],
  ["/", "name(namespace::*)"], ["/", "concat(1, 2, 3, 4, 5, 6)"], ["/", "substring('abc', 2, 1, 5)"], ["/", "substring('abc')"], ["/", "translate('abc')"], ["/", "normalize-space(1, 2)"],
  ["/", "lang()"], ["/", "id()"], ["/", "true(1)"], ["/", "string-length(1, 2)"], ["/", "starts-with('a')"], ["/", "sum(1)"], ["/", "sum()"], ["/", "floor()"], ["/", "not()"],
  ["/", "local-name(1)"], ["/", "name('x')"], ["/", "namespace-uri(1, 2)"], ["/", "escape-uri('a b', true())"], ["/", "fn:escape-uri('a b/c?d', true())", { ns: { "fn" => "http://www.w3.org/2002/08/xquery-functions" } }],
  ["/", "fn:escape-uri('a b/c?d%2Fe%zz', false())", { ns: { "fn" => "http://www.w3.org/2002/08/xquery-functions" } }], ["/", "fn:escape-uri('\u00e9')", { ns: { "fn" => "http://www.w3.org/2002/08/xquery-functions" } }],
  ["/", "1 = 1 = 1"], ["/", "1 < 2 < 3"], ["/", "3 > 2 > 1"], ["/", "'abc' < 'abd'"], ["/", "//*[1] < //*[2]"], ["/", "true() = 1"], ["/", "false() = ''"], ["/", "//nothing = false()"],
  ["/", "//nothing != //nothing"], ["/", "//nothing = //nothing"], ["/", "not(//nothing = 'x')"], ["/", "//* = //*"], ["/", "//* != //*"], ["/", "1 div 0 > 1 div 0"], ["/", "1 div 0 >= 1 div 0"],
  ["/", "-1 div 0 < 0"], ["/", "0 div 0 = 0 div 0"], ["/", "0 div 0 != 0 div 0"], ["/", "number('Infinity')"], ["/", "string(number(' -0 '))"], ["/", "1 div number('-0')"],
  ["//div/@class", "self::node()"], ["//div/@class", "child::node()"], ["//div/@class", "following-sibling::node()"], ["//div/@class", "../@id"], ["//div/@class", "name()"],
]
