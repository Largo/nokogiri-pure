# frozen_string_literal: true

# Differential cases aimed at the evaluator's fast paths (memoized sibling counts, document-order
# sorting shortcuts, specialised traversals and predicates):
#   ruby test-pure/xpath/compare.rb test-pure/xpath/perf_cases.rb
load File.join(__dir__, "cases.rb")

DOCS.merge!(
  "sib" => <<~XML,
    <?xml version="1.0"?>
    <?lead x?>
    <!DOCTYPE r [<!ENTITY e "<i>ent</i>tail"><!ELEMENT r ANY>]>
    <!--c0-->
    <r xmlns:p="urn:p">t0<a/>t1<p:a/><b>x<a/></b><!--c1--><?pi y?><a id="4"/><![CDATA[cd]]>&e;<b/><a p:k="1" k="2"><a/><a/><b><a/></b></a>t9</r>
    <!--c2-->
  XML
  "rows" => "<t>" + (1..40).map { |i| "<tr n='#{i}' class='r#{i % 4} x'>" + (1..(i % 5)).map { |j| "<td>#{i}.#{j}</td>" }.join + "</tr>" }.join + "</t>",
  "html2" => <<~HTML,
    <!DOCTYPE html>
    <html><body><div class="item c1 featured" id="d1"><p>Para <a href="/x/1" rel="n">link 1</a> &amp; <b>bold</b></p><ul><li>a</li><li class="sel">b</li><li>c</li></ul></div>
    <div class="item c2" id="d2"><p>Para <a href="/x/2">link 2</a></p><ul><li class=" sel  q">a</li></ul><div class="c1"><a href="/y">in</a></div></div>
    <div class="c1" id="d3">text<a href="/x/13" class="c1">x</a></div></body></html>
  HTML
)

SIB_AXES = %w[preceding-sibling following-sibling].freeze
SIB_TESTS = %w[* node() text() comment() processing-instruction() a b p:a *[1] a[@id]].freeze

EXPRS = []
SIB_AXES.each do |ax|
  SIB_TESTS.each do |t|
    EXPRS << ["/", "//node()[count(#{ax}::#{t}) = 1]"]
    EXPRS << ["/", "//node()[count(#{ax}::#{t}) mod 2 = 0]", { ns: { "p" => "urn:p" } }]
    EXPRS << ["/", "count(//node()[count(#{ax}::#{t}) > 2])", { ns: { "p" => "urn:p" } }]
    EXPRS << ["/", "/node()[count(#{ax}::#{t}) >= 0]", { ns: { "p" => "urn:p" } }]
    EXPRS << ["/", "//@*[count(#{ax}::#{t}) = 0]", { ns: { "p" => "urn:p" } }]
    EXPRS << ["/", "//namespace::*[count(#{ax}::#{t}) = 0]", { ns: { "p" => "urn:p" } }]
  end
  EXPRS << ["/", "//*[count(#{ax}::*) = count(#{ax}::*)]"]
  EXPRS << ["/", "sum(//*/@n[count(#{ax}::*) = 0])"]
  EXPRS << ["/", "//*[count(#{ax}::*) = last() - position()]"]
  EXPRS << ["/", "//*[count(#{ax}::*) = $v]", { vars: { "v" => "2" } }]
  EXPRS << ["/", "//*[count(#{ax}::q:x) = 1]", { ns: { "q" => "urn:c" } }]
  EXPRS << ["/", "//*[count(#{ax}::q:x) = 1]"]
  EXPRS << ["/", "//*[nokogiri:thing(count(#{ax}::*)) = 1]", { handler: true }]
  EXPRS << ["/", "//*[count(#{ax}::*) = 1][nokogiri:nodes(.)]", { handler: true }]
end

# CSS-generated shapes
%w[
  //li[count(preceding-sibling::*)=1] //li[count(following-sibling::*)=0]
  //*[((count(preceding-sibling::*)+1)>=1)\ and\ ((((count(preceding-sibling::*)+1)-1)\ mod\ 2)=0)]
  //tr[((count(preceding-sibling::*)+1)\ mod\ 3)=0]//td //td[count(preceding-sibling::td)=0]
  //tr[count(preceding-sibling::*)=0\ and\ count(following-sibling::*)=0]
].each { |e| EXPRS << ["/", e.gsub("\\ ", " ")] }

# document order of multi-context results (sorting)
%w[
  //*/* //*/text() //*/node() //*/@* //tr/td //td/.. //td/../.. //e/f //e/f/text() //*/*/*
  //td/following-sibling::td //td/preceding-sibling::td //td/ancestor::* //*/descendant::td
  //a/ancestor-or-self::* (//td|//tr)/@n //li/../li //node()/.. //@*/.. //tr[38]/following::td
  //a/preceding::* //*/namespace::* //c:x/../*
].each do |e|
  EXPRS << ["/", e, { ns: { "c" => "urn:c" } }]
  EXPRS << ["/", "(#{e})[last()]", { ns: { "c" => "urn:c" } }]
  EXPRS << ["/", "(#{e})[1]", { ns: { "c" => "urn:c" } }]
  EXPRS << ["/", "count(#{e})", { ns: { "c" => "urn:c" } }]
  EXPRS << ["/", "string(#{e})", { ns: { "c" => "urn:c" } }]
end

# descendant traversals from various context nodes
["/", "/*", "//*[2]", "//text()[1]", "//@*[1]"].each do |ctx|
  %w[descendant::* descendant::node() descendant-or-self::node() .//a .//text() .//@* .//comment()
     descendant::a[1] descendant::*[last()] .//processing-instruction() .//b//a].each do |e|
    EXPRS << [ctx, e]
  end
end

# predicates
%w[
  //div[nokogiri-builtin:css-class(@class,'c1')] //*[nokogiri-builtin:css-class(@class,'sel')]
  //div[nokogiri-builtin:css-class(@class,'c1')]//a //li[nokogiri-builtin:css-class(@class,'')]
  //a[starts-with(@href,'/x/1')] //a[contains(@href,'x')] //*[@class='c1'] //*[@id='d2']/p
  //a[@rel] //tr[@n=7] //tr[@n>35]/@n //*[contains(.,'link')] //*[starts-with(.,'t')]
  //div[contains(concat('\ ',normalize-space(@class),'\ '),'\ c1\ ')]
].each { |e| EXPRS << ["/", e.gsub("\\ ", " ")] }

# parent / ancestor axes
%w[
  //node()/.. //@*/.. //text()/.. //comment()/.. //processing-instruction()/.. /node()/..
  //node()/ancestor::* //node()/ancestor::node() //node()/ancestor-or-self::node() //@*/ancestor::*
  //@*/ancestor-or-self::node() //text()/ancestor::b //node()/ancestor::p:* //node()/ancestor::*[1]
  //node()/parent::* //node()/parent::node() //node()/parent::a //*[parent::r] //*[ancestor::b]
  //node()[..] //node()[ancestor::*] //namespace::*/.. //namespace::*/ancestor::* //namespace::*/parent::node()
  count(//node()/ancestor-or-self::node()) //text()[ancestor-or-self::a] //td/../..//td /.. //*/ancestor-or-self::text()
].each do |e|
  EXPRS << ["/", e, { ns: { "p" => "urn:p" } }]
end
["//text()[1]", "//@*[1]", "//comment()[1]", "/*", "//e[2]"].each do |ctx|
  %w[.. ../.. ancestor::* ancestor::node() ancestor-or-self::node() parent::node() ancestor::*[2]
     count(ancestor::node()) ..//text()].each { |e| EXPRS << [ctx, e] }
end
%w[
  /node()/node() /node()/node()/.. /node()/node()/ancestor::node() /node()/node()/node()/ancestor::node()
  /node()/node()/node()/.. /node()/node()/ancestor-or-self::node() /node()//node() /node()/descendant::node()
  /node()/node()/following-sibling::node() /node()/node()/preceding-sibling::node()
  /node()/node()[count(preceding-sibling::node())=1]
].each { |e| EXPRS << ["/", e] }
%w[//node()/..[1] //node()/parent::*[1] //@*/..[1] //node()/parent::node()[2] (//node()/..)[1]].each { |e| EXPRS << ["/", e] }
# string predicates with a context step / "." and a literal
%w[
  //*[contains(.,'1')] //*[starts-with(.,'t')] //@*[contains(.,'x')] //*[contains(@n,'3')] //*[starts-with(@class,'r1')]
  //*[contains(text(),'e')] //*[starts-with(text(),'')] //*[contains(node(),'a')] //*[contains(@*,'1')]
  //*[starts-with(preceding-sibling::*,'t')] //*[contains(following-sibling::node(),'t')] //*[contains(ancestor::*,'t')]
  //*[nokogiri-builtin:css-class(.,'x')] //*[nokogiri-builtin:css-class(text(),'t1')] //*[nokogiri-builtin:css-class(@*,'x')]
  //*[nokogiri-builtin:css-class(ancestor::*/@class,'c1')] //*[contains(@p:k,'1')] //*[nokogiri-builtin:css-class(@class,1)]
  //namespace::*[contains(.,'urn')] //*[contains(.,'é')] //*[starts-with(normalize-space(.),'t')]
].each { |e| EXPRS << ["/", e, { ns: { "p" => "urn:p" } }] }
EXPRS << ["/", "//*[contains(@p:k,'1')]"]
%w[
  //*[substring-before(.,'1')] //*[substring-after(@n,'1')] //*[concat(.,'x')] //*[string(@n)]
  //*[boolean(contains(@class,'r'))] //*[not(starts-with(@n,'1'))] //*[contains(@n,'1') and nokogiri-builtin:css-class(@class,'x')]
].each { |e| EXPRS << ["/", e] }
%w[
  //*[@n='3'] //*[@n!='3'] //*[@class='r1\ x'] //*[@n=3] //*[@missing='x'] //*[@missing!='x'] //*[@p:k='1'] //*[@k='2'] //*[@rel]
  //*[@p:k] //*[@*] //@*[@n] //text()[@n] //*[not(@n)] //*[@n='3']/@n //*[@id='d2'] //*[@class='c1']
].each { |e| EXPRS << ["/", e.gsub("\\ ", " "), { ns: { "p" => "urn:p" } }] }
# numeric comparisons (CSS :nth-child & co.)
%w[
  //*[position()<3] //*[position()>=last()-1] //*[last()=1] //*[position()=last()] //*[1<position()]
  //*[position()!=2] //*[-position()<-2] //*[position()*2=4] //*[position()div\ 2=1] //*[position()mod\ 2=0]
  //*[(position()+1)mod\ 3=0] //*[position()=0\ div\ 0] //*[position()!=0\ div\ 0] //*[position()<1\ div\ 0]
  //*[position()>-1\ div\ 0] //*[position()\ mod\ 0=1] //*[count(preceding-sibling::*)+1=position()]
  //*[((count(preceding-sibling::*)+1)mod\ 3)=0] //*[((count(following-sibling::*)+1)>=1)\ and\ ((((count(following-sibling::*)+1)-1)mod\ 2)=0)]
  //*[count(preceding-sibling::*)=count(following-sibling::*)] //*[(count(preceding-sibling::*))=(1)] //*[+count(preceding-sibling::*)=1]
  //*[boolean(position()=2)] //*[(position()=2)=true()] //*[not(count(preceding-sibling::*)<2)]
  //namespace::*[position()=1] //namespace::*[count(preceding-sibling::*)=0] //@*[count(preceding-sibling::*)=0]
  count(//*[position()=last()]) //*[position()=1.5] //*[position()>=1.0] //*[-(-position())=2]
].each { |e| EXPRS << ["/", e.gsub("\\ ", " ")] }
EXPRS << ["/", "position() = 1"] << ["/", "last() - position()"] << ["/", "count(preceding-sibling::*) = 0"]
# steps without predicates / with an axis range from node-sets (whole-set child & attribute loops)
%w[
  //*/*[2] //node()/node()[3] //*/@*[1] //*/@*[2] //*/text()[2] //tr/td[2] /node()/node()[1] //node()/comment()[1]
  //@*/node() //@*/text()[1] //node()/processing-instruction()[1] //*/*[0] //*/*[-1] //*/node()[1] (/|/*)/node()
  //*/p:* //*/@p:* //*/@p:*[1] //*/p:*[1] //node()/node() //node()/* //*/@n //*/@* /node()/node()/node()[2]
].each { |e| EXPRS << ["/", e, { ns: { "p" => "urn:p" } }] }
