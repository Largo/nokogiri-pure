# Exercises every nokogiri-pure component under ruby.wasm. Prints "ok <n>" and raises on mismatch.
t0 = Time.now
require "nokogiri"
puts "loaded nokogiri #{Nokogiri::VERSION} (pure #{Nokogiri::Pure::VERSION}) in #{(Time.now - t0).round(2)}s on #{RUBY_PLATFORM}"
def check(name, got, want)
  raise "#{name}: got #{got.inspect}, want #{want.inspect}" unless got == want
  puts "ok #{name}"
end

doc = Nokogiri::XML(%(<?xml version="1.0"?><r xmlns:x="urn:x"><a id="1">one</a><x:b>two &amp; three</x:b><c/></r>))
check "xml parse+serialize", doc.root.to_xml, %(<r xmlns:x="urn:x">\n  <a id="1">one</a>\n  <x:b>two &amp; three</x:b>\n  <c/>\n</r>)
check "xpath", doc.xpath("//x:b", "x" => "urn:x").text, "two & three"
check "css", doc.css("a[id='1']").map(&:text), ["one"]
check "errors", Nokogiri::XML("<a><b></a>").errors.first.to_s, "1:11: FATAL: Opening and ending tag mismatch: b line 1 and a"
check "html4", Nokogiri::HTML4("<p>x<div>y").at_css("body").children.map(&:name), ["p", "div"]
check "html5", Nokogiri::HTML5("<table><td>x</table>").at("td").ancestors.map(&:name).first(3), ["tr", "tbody", "table"]
check "builder", Nokogiri::XML::Builder.new { |b| b.root { b.item("x", n: 1) } }.to_xml, %(<?xml version="1.0"?>\n<root>\n  <item n="1">x</item>\n</root>\n)
events = []
sax = Class.new(Nokogiri::XML::SAX::Document) { define_method(:start_element) { |n, _a = []| events << n } }
Nokogiri::XML::SAX::Parser.new(sax.new).parse("<a><b/><c/></a>")
check "sax", events, %w[a b c]
check "reader", Nokogiri::XML::Reader("<a><b>t</b></a>").map(&:name), %w[a b #text b a]
xslt = Nokogiri::XSLT(%(<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:template match="/"><out><xsl:value-of select="count(//a)"/></out></xsl:template></xsl:stylesheet>))
check "xslt", xslt.transform(doc).root.to_s, "<out>1</out>"
xsd = Nokogiri::XML::Schema(%(<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:element name="n" type="xs:integer"/></xs:schema>))
check "xsd", xsd.validate(Nokogiri::XML("<n>x</n>")).map(&:message), ["1:0: ERROR: Element 'n': 'x' is not a valid value of the atomic type 'xs:integer'."]
rng = Nokogiri::XML::RelaxNG(%(<element name="n" xmlns="http://relaxng.org/ns/structure/1.0"><text/></element>))
check "relaxng", rng.valid?(Nokogiri::XML("<n>x</n>")), true
check "c14n", Nokogiri::XML(%(<a b="1"   a="2"/>)).canonicalize, %(<a a="2" b="1"></a>)
puts "all ok in #{(Time.now - t0).round(2)}s"
