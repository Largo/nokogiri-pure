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
  ["//div/@class", "self::node()"], ["//div/@class", "child::node()"], ["//div/@class", "following-sibling::node()"], ["//div/@class", "../@id"], ["//div/@class", "name()"],
]
