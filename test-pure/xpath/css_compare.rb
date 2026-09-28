# frozen_string_literal: true

# Differential CSS/search test on HTML4 + HTML5 documents: native gem vs nokogiri-pure.
#   ruby test-pure/xpath/css_compare.rb
require "open3"

if ENV["MODE"].nil?
  root = File.expand_path("../..", __dir__)
  n, = Open3.capture3({ "MODE" => "native" }, "ruby", __FILE__)
  pu, err, = Open3.capture3({ "MODE" => "pure" }, "ruby", "-W0", "-I#{root}/lib", __FILE__)
  warn err unless err.empty?
  nl = n.lines
  pl = pu.lines
  fails = 0
  nl.each_with_index do |l, i|
    next if l == pl[i]

    fails += 1
    puts "NATIVE: #{l}PURE:   #{pl[i]}\n"
  end
  puts "#{nl.length} results (pure #{pl.length}), #{fails} differences"
  exit(fails.zero? ? 0 : 1)
end

gem "nokogiri", "1.19.4" if ENV["MODE"] == "native"
require "nokogiri"

HTML = <<~HTML
  <!DOCTYPE html>
  <html><head><title>Test</title></head>
  <body class="main">
    <div id="a" class="box red"><p class="intro first">Hello <b>world</b></p><p>Second <i>para</i></p><span></span></div>
    <div id="b" class="box"><ul><li>1</li><li class="odd">2</li><li>3</li><li class="odd last">4</li></ul>
      <a href="http://example.com/x.pdf" title="t1">pdf</a><a href="/local" rel="nofollow">local</a><a name="anchor">n</a></div>
    <div id="c" lang="en-US"><p>Third</p><table><tr><td>a</td><td>b</td></tr><tr><td colspan="2">c</td></tr></table>
      <form><input type="text" name="q" disabled><input type="checkbox" checked><select><option selected>o</option></select></form></div>
    <svg width="10"><circle r="1"/><text>t</text></svg>
    <p id="last-p">Last <span class="x-y">z</span></p>
  </body></html>
HTML

SELECTORS = [
  "p", "div p", "div > p", "div + div", "div ~ p", "p.intro", ".box", ".box.red", "#a", "div#b", "*", "body *", "[href]", "a[href$='.pdf']",
  "a[href^='http']", "a[href*='exam']", "[class~='odd']", "[lang|='en']", "a[rel=nofollow]", "li:first-child", "li:last-child", "li:nth-child(2)",
  "li:nth-child(odd)", "li:nth-child(2n+1)", "li:nth-last-child(1)", "li:nth-of-type(3)", "p:first-of-type", "p:last-of-type", "p:only-child",
  "span:empty", "div:has(ul)", "div:not(.box)", "p:contains('Second')", "li:eq(2)", "li:first", "li:last", "li:nth(1)", "td:only-of-type",
  "input[disabled]", "input:checked", "option[selected]", "svg circle", "svg > text", "circle", "text", "ul li.odd.last", "div > *:first-child",
  "a:not([href])", "p > b, p > i", "body > p span.x-y", "div[id=c] td", "li + li", "li ~ li", "tr:nth-of-type(2) td", "td:not(:first-child)",
  "p:nth-last-of-type(1)", "div:nth-child(3)", "html > body > div", ":root", "li:nth-child(-n+2)", "li:nth-child(n+3)", "p:has(> b)",
]

def sig(set) = set.map { |n| n.path }.join(" ")

{ "html4" => Nokogiri::HTML4(HTML), "html5" => (defined?(Nokogiri::HTML5) ? Nokogiri::HTML5(HTML) : nil) }.each do |name, doc|
  next if doc.nil?

  SELECTORS.each do |sel|
    begin
      puts "#{name} css #{sel.inspect} => #{sig(doc.css(sel))}"
      puts "#{name} at_css #{sel.inspect} => #{doc.at_css(sel)&.path.inspect}"
      node = doc.at_css("#b")
      puts "#{name} #b.css #{sel.inspect} => #{sig(node.css(sel))}"
      puts "#{name} search #{sel.inspect} => #{sig(doc.search(sel))}"
    rescue => e
      puts "#{name} #{sel.inspect} => ERR #{e.class}: #{e.message}"
    end
  end
  a = doc.at_css("#a p b")
  puts "#{name} ancestors => #{a.ancestors.map(&:name).inspect}"
  puts "#{name} ancestors(div) => #{a.ancestors("div").map(&:name).inspect}"
  puts "#{name} matches => #{a.matches?("div b")} #{a.matches?("li b")}"
  puts "#{name} collect_namespaces => #{doc.collect_namespaces.inspect}"
  puts "#{name} xpath multiple => #{sig(doc.xpath("//li", "//p"))}"
  puts "#{name} css multiple => #{sig(doc.css("li", "p"))}"
  puts "#{name} at => #{doc.at("//li[2]")&.text.inspect} #{doc.at("li:nth-child(3)")&.text.inspect}"
  puts "#{name} nodeset css => #{sig(doc.css("div").css("p"))} #{sig(doc.css("div").xpath(".//li"))}"
  puts "#{name} nodeset search => #{sig(doc.css("div").search("span, i"))}"
  puts "#{name} > => #{sig(doc.css("div").first > "p")}"
  puts "#{name} / => #{sig(doc / "li")}"
  puts "#{name} % => #{(doc % "li")&.path.inspect}"
  puts "#{name} content => #{doc.xpath("string(//div[@id='a'])").inspect} #{doc.at_xpath("//li[last()]/text()").content.inspect}"
end
