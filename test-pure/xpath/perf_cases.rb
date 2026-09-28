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
