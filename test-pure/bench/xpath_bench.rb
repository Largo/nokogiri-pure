# frozen_string_literal: true

# XPath / CSS search benchmark (evaluation + result wrapping), pure vs native.
#   ruby test-pure/bench/xpath_bench.rb [pure|native] [filter-regexp]      (N=iterations, default 10)
#   ruby --yjit test-pure/bench/xpath_bench.rb pure
# Prints the best-of-5 time per query (ms) and the result size, so that runs can be diffed.
mode = ARGV[0] || "pure"
filter = ARGV[1] && Regexp.new(ARGV[1])
if mode == "native"
  gem "nokogiri", "1.19.4"
else
  $LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
end
require "nokogiri"

xml = +%(<?xml version="1.0"?>\n<catalog xmlns:x="urn:x" xmlns:d="urn:d">\n)
2000.times do |i|
  xml << %(  <book id="b#{i}" x:lang="#{%w[en de fr][i % 3]}" year="#{1950 + i % 70}"><title>Title #{i} &amp; more</title>) +
    %(<author>Author #{i % 37}</author><price>#{i}.99</price><d:note>n#{i}</d:note>) +
    %(<desc>Some <em>descriptive</em> text for book #{i}.</desc></book>\n)
end
xml << "</catalog>\n"

html = +"<!DOCTYPE html><html><head><title>t</title></head><body><div id='main'>"
1500.times do |i|
  html << %(<div class="item c#{i % 10}#{i % 7 == 0 ? " featured" : ""}" id="d#{i}" data-n="#{i}">) +
    %(<p>Para <a href="/x/#{i}"#{i.even? ? ' rel="nofollow"' : ""}>link #{i}</a> &amp; <b>bold</b></p>) +
    %(<ul><li>a</li><li class="sel">b</li><li>c</li></ul><span>s#{i}</span></div>)
end
html << "</div><table>" + (1..200).map { |r| "<tr>" + (1..5).map { |c| "<td>#{r}.#{c}</td>" }.join + "</tr>" }.join + "</table></body></html>"

xdoc = Nokogiri::XML(xml)
h4 = Nokogiri::HTML4(html)
h5 = Nokogiri::HTML5(html)
book = xdoc.at_xpath("//book[100]")
div = h4.at_css("#d700")

QUERIES = [
  # CSS on XML
  ["xml", "css book > title", -> { xdoc.css("book > title") }],
  ["xml", "css book title", -> { xdoc.css("book title") }],
  ["xml", "css book[id=b1500]", -> { xdoc.css("book[id=b1500]") }],
  ["xml", "css book:nth-child(3n) price", -> { xdoc.css("book:nth-child(3n) price") }],
  ["xml", "css x|lang attr", -> { xdoc.css("book[x|lang=de]") }],
  # XPath on XML
  ["xml", "//book[author='Author 3']", -> { xdoc.xpath("//book[author='Author 3']") }],
  ["xml", "//book[@id='b500']/title", -> { xdoc.xpath("//book[@id='b500']/title") }],
  ["xml", "/catalog/book[position()<50]", -> { xdoc.xpath("/catalog/book[position() < 50]") }],
  ["xml", "(//book)[last()]", -> { xdoc.xpath("(//book)[last()]") }],
  ["xml", "//book[5]/title/text()", -> { xdoc.xpath("//book[5]/title/text()") }],
  ["xml", "count(//book)", -> { xdoc.xpath("count(//book)") }],
  ["xml", "sum(//price)", -> { xdoc.xpath("sum(//price)") }],
  ["xml", "//book[price > 1900]/@id", -> { xdoc.xpath("//book[price > 1900]/@id") }],
  ["xml", "//title/text()", -> { xdoc.xpath("//title/text()") }],
  ["xml", "//book[contains(title,'99')]", -> { xdoc.xpath("//book[contains(title, '99')]") }],
  ["xml", "//d:note (ns)", -> { xdoc.xpath("//d:note", "d" => "urn:d") }],
  ["xml", "//book/@x:lang (ns)", -> { xdoc.xpath("//book/@x:lang", "x" => "urn:x") }],
  ["xml", "//em/ancestor::book", -> { xdoc.xpath("//em/ancestor::book") }],
  ["xml", "//book[@year=1960][1]", -> { xdoc.xpath("//book[@year=1960][1]") }],
  ["xml", "//book[100] foll-sib[1]", -> { xdoc.xpath("//book[100]/following-sibling::book[1]") }],
  ["xml", "string(//book[7]/title)", -> { xdoc.xpath("string(//book[7]/title)") }],
  ["xml", "node.xpath ./title", -> { book.xpath("./title") }],
  ["xml", "node.at_css author", -> { book.at_css("author") }],
  ["xml", "//*", -> { xdoc.xpath("//*") }],
  # HTML4
  ["html4", "css div.c3 a", -> { h4.css("div.c3 a") }],
  ["html4", "css #d150", -> { h4.css("#d150") }],
  ["html4", "css li:nth-child(2)", -> { h4.css("li:nth-child(2)") }],
  ["html4", "css ul > li.sel", -> { h4.css("ul > li.sel") }],
  ["html4", "css a[href^='/x/1']", -> { h4.css("a[href^='/x/1']") }],
  ["html4", "css a[rel]", -> { h4.css("a[rel]") }],
  ["html4", "css div.featured > p", -> { h4.css("div.featured > p") }],
  ["html4", "css li:last-child", -> { h4.css("li:last-child") }],
  ["html4", "css td", -> { h4.css("td") }],
  ["html4", "css tr:nth-child(odd) td", -> { h4.css("tr:nth-child(odd) td") }],
  ["html4", "//a/@href", -> { h4.xpath("//a/@href") }],
  ["html4", "//p[contains(.,'link 1')]", -> { h4.xpath("//p[contains(., 'link 1')]") }],
  ["html4", "count(//*)", -> { h4.xpath("count(//*)") }],
  ["html4", "//span/text()", -> { h4.xpath("//span/text()") }],
  ["html4", "at_css span", -> { h4.at_css("span") }],
  ["html4", "node.css a", -> { div.css("a") }],
  ["html4", "search div > p, li.sel", -> { h4.search("div > p, li.sel") }],
  # HTML5
  ["html5", "css div.c3 a", -> { h5.css("div.c3 a") }],
  ["html5", "css li:nth-child(2)", -> { h5.css("li:nth-child(2)") }],
  ["html5", "css div[data-n='42']", -> { h5.css("div[data-n='42']") }],
  ["html5", "//div[@class]/p/a", -> { h5.xpath("//div[@class]/p/a") }],
]

n = (ENV["N"] || 10).to_i
def cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
def size_of(r) = r.respond_to?(:length) && !r.is_a?(String) ? r.length : r.inspect[0, 20]

puts "#{mode} ruby #{RUBY_VERSION} yjit=#{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? true : false} " \
  "xml=#{xml.bytesize}B html=#{html.bytesize}B N=#{n}"
total = 0.0
QUERIES.each do |doc, name, q|
  label = "#{doc} #{name}"
  next if filter && !filter.match?(label)

  r = q.call
  2.times { q.call } # warm up (YJIT, caches)
  best = Array.new(5) { t0 = cpu; n.times { q.call }; (cpu - t0) / n }.min
  total += best
  printf("%-44s %9.3f ms  (%s)\n", label, best * 1000, size_of(r))
end
printf("%-44s %9.3f ms\n", "TOTAL", total * 1000)
