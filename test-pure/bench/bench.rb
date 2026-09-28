# Usage: ruby bench.rb native|pure   (prints ops timings as JSON-ish lines)
mode = ARGV[0] || "pure"
if mode == "native"
  gem "nokogiri", "1.19.4"
else
  $LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
end
require "nokogiri"
require "benchmark"

xml = +"<?xml version=\"1.0\"?>\n<catalog xmlns:x=\"urn:x\">\n"
2000.times { |i| xml << %(  <book id="b#{i}" x:lang="en"><title>Title #{i} &amp; more</title><author>Author #{i % 37}</author><price>#{i}.99</price><desc>Some <em>descriptive</em> text for book #{i}.</desc></book>\n) }
xml << "</catalog>\n"
html = +"<!DOCTYPE html><html><head><title>t</title></head><body>"
1500.times { |i| html << %(<div class="item c#{i % 10}" id="d#{i}"><p>Para <a href="/x/#{i}">link #{i}</a> &amp; <b>bold</b></p><ul><li>a</li><li>b</li></ul></div>) }
html << "</body></html>"

def t(label)
  GC.start
  r = Benchmark.realtime { yield }
  printf("%-28s %8.3f s\n", label, r)
end

puts "#{mode} #{RUBY_VERSION} yjit=#{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?} xml=#{xml.bytesize}B html=#{html.bytesize}B"
doc = nil
t("XML parse") { 3.times { doc = Nokogiri::XML(xml) } }
t("XML to_xml") { 3.times { doc.to_xml } }
t("XPath //book[author=..]") { 20.times { doc.xpath("//book[author='Author 3']") } }
t("CSS book > title") { 20.times { doc.css("book > title") } }
t("traverse + attrs") { 3.times { doc.traverse { |n| n["id"] if n.element? } } }
t("SAX parse") { 3.times { Nokogiri::XML::SAX::Parser.new(Nokogiri::XML::SAX::Document.new).parse(xml) } }
t("Reader") { Nokogiri::XML::Reader(xml).each { |n| n.name } }
h4 = nil
t("HTML4 parse") { 3.times { h4 = Nokogiri::HTML4(html) } }
t("HTML4 to_html") { 3.times { h4.to_html } }
t("HTML4 CSS div.c3 a") { 20.times { h4.css("div.c3 a") } }
h5 = nil
t("HTML5 parse") { 3.times { h5 = Nokogiri::HTML5(html) } }
t("HTML5 to_html") { 3.times { h5.to_html } }
t("build via Builder") { Nokogiri::XML::Builder.new { |b| b.root { 3000.times { |i| b.item(i, id: i) } } }.to_xml }
