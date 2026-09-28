# frozen_string_literal: true
# usage: ruby [-Ilib] test-pure/xpath/bench.rb [native]
if ARGV[0] == "native"
  gem "nokogiri", "1.19.4"
end
require "nokogiri"
require "benchmark"

html = +"<html><body>"
200.times do |i|
  html << "<div class='item c#{i % 7} box' id='d#{i}'><h2>Title #{i}</h2><p class='text'>Para <a href='/x#{i}'>link</a> <span>s</span></p>"
  html << "<ul>" + (1..5).map { |j| "<li class='li#{j}'>item #{j}</li>" }.join + "</ul>"
  html << "<div class='inner'><p>inner <b>bold</b></p></div></div>"
end
html << "</body></html>"
doc = Nokogiri::HTML4(html)

queries = {
  "css div.item" => -> { doc.css("div.item").length },
  "css div p" => -> { doc.css("div p").length },
  "css li:nth-child(2)" => -> { doc.css("li:nth-child(2)").length },
  "css #d150" => -> { doc.css("#d150").length },
  "css ul > li.li3" => -> { doc.css("ul > li.li3").length },
  "xpath //a/@href" => -> { doc.xpath("//a/@href").length },
  "xpath //p[contains(.,'bold')]" => -> { doc.xpath("//p[contains(.,'bold')]").length },
  "xpath count(//*)" => -> { doc.xpath("count(//*)") },
  "xpath (//li)[last()]" => -> { doc.xpath("(//li)[last()]").length },
  "at_css span" => -> { doc.at_css("span").name },
}
n = (ENV["N"] || 20).to_i
queries.each do |name, q|
  r = q.call
  t = Benchmark.realtime { n.times { q.call } }
  printf("%-34s %8.2f ms/iter  (%s)\n", name, t * 1000 / n, r)
end
