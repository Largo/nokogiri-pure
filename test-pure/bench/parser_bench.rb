# frozen_string_literal: true

# XML parser benchmark: DOM / SAX / push parsing of several realistic documents.
#
#   ruby [--yjit] test-pure/bench/parser_bench.rb [pure|native] [-n REPS] [-o dom,sax,push] [-d doc,...]
#
# Prints MB/s per (document, mode) plus the geometric mean, best of REPS runs.
mode = ARGV.first == "native" ? ARGV.shift : (ARGV.first == "pure" ? ARGV.shift : "pure")
reps = 3
if (i = ARGV.index("-n"))
  reps = ARGV[i + 1].to_i
  ARGV.slice!(i, 2)
end
ops = %w[dom sax push]
if (i = ARGV.index("-o"))
  ops = ARGV[i + 1].split(",")
  ARGV.slice!(i, 2)
end
only = nil
if (i = ARGV.index("-d"))
  only = ARGV[i + 1].split(",")
  ARGV.slice!(i, 2)
end

if mode == "native"
  gem "nokogiri", "1.19.4"
else
  $LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
end
require "nokogiri"

srand(42)
WORDS = %w[lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut
  labore et dolore magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi
  aliquip ex ea commodo consequat Zürich naïve café].freeze
def words(n) = Array.new(n) { WORDS.sample }.join(" ")

docs = {}

# the document of bench.rb (mixed, a namespaced attribute, entity refs)
x = +"<?xml version=\"1.0\"?>\n<catalog xmlns:x=\"urn:x\">\n"
6000.times do |i|
  x << %(  <book id="b#{i}" x:lang="en"><title>Title #{i} &amp; more</title><author>Author #{i % 37}</author>) +
    %(<price>#{i}.99</price><desc>Some <em>descriptive</em> text for book #{i}.</desc></book>\n)
end
x << "</catalog>\n"
docs["catalog"] = x

# attribute-heavy (data export style)
x = +"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rows>\n"
8000.times do |i|
  x << %(  <row id="#{i}" name="item #{i}" category="cat-#{i % 13}" price="#{i * 3 % 997}.50" ) +
    %(currency="EUR" active="#{i.even?}" created="2026-09-#{(i % 28) + 1}T12:00:00Z" note='say "hi"'/>\n)
end
x << "</rows>\n"
docs["attrs"] = x

# text-heavy (articles with inline markup, some entity/char refs, long paragraphs)
x = +"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<articles>\n"
400.times do |i|
  x << "  <article n=\"#{i}\">\n    <h>#{words(8)}</h>\n"
  4.times do
    x << "    <p>#{words(60)} <i>#{words(3)}</i> #{words(40)} &amp; #{words(20)} &#169; #{words(30)}</p>\n"
  end
  x << "  </article>\n"
end
x << "</articles>\n"
docs["text"] = x

# namespaced (Atom/SOAP style: default ns + prefixes, prefixed attributes)
x = +%(<?xml version="1.0" encoding="utf-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom" ) +
  %(xmlns:media="http://search.yahoo.com/mrss/" xmlns:geo="http://www.w3.org/2003/01/geo/wgs84_pos#">\n)
3000.times do |i|
  x << %(  <entry xml:lang="en"><id>urn:uuid:#{i}</id><title type="text">#{words(5)}</title>) +
    %(<link rel="alternate" href="http://example.com/#{i}"/><media:thumbnail url="http://i.example.com/#{i}.jpg" ) +
    %(media:width="120" media:height="90"/><geo:lat>#{i % 90}.5</geo:lat><geo:long>#{i % 180}.25</geo:long>) +
    %(<summary xmlns:x="urn:x#{i % 5}" x:k="v">#{words(12)}</summary></entry>\n)
end
x << "</feed>\n"
docs["ns"] = x

# DTD with entities and defaulted attributes
x = +<<~DTD
  <?xml version="1.0"?>
  <!DOCTYPE doc [
    <!ELEMENT doc (rec*)>
    <!ELEMENT rec (#PCDATA|b)*>
    <!ELEMENT b (#PCDATA)>
    <!ATTLIST rec kind CDATA "plain" id ID #IMPLIED lvl NMTOKEN "1">
    <!ENTITY co "ACME Corporation">
    <!ENTITY sig "<b>signed</b> by &co;">
  ]>
  <doc>
DTD
6000.times do |i|
  x << %(  <rec id="r#{i}">Record #{i} of &co; &lt;#{i}&gt; #{words(6)} &sig;</rec>\n)
end
x << "</doc>\n"
docs["dtd"] = x

docs.select! { |k, _| only.include?(k) } if only

class NullSax < Nokogiri::XML::SAX::Document; end

def best(reps)
  (1..reps).map do
    GC.start
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end.min
end

yjit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
puts "#{mode} ruby #{RUBY_VERSION} yjit=#{yjit ? "on" : "off"}"
rates = []
ops.each do |op|
  docs.each do |name, xml|
    run = case op
    when "dom" then -> { Nokogiri::XML(xml) }
    when "sax" then -> { Nokogiri::XML::SAX::Parser.new(NullSax.new).parse(xml) }
    when "push"
      -> {
        pp = Nokogiri::XML::SAX::PushParser.new(NullSax.new)
        off = 0
        while off < xml.bytesize
          pp << xml.byteslice(off, 16_384)
          off += 16_384
        end
        pp.finish
      }
    end
    run.call if yjit # warm up
    t = best(reps, &run)
    mbs = xml.bytesize / t / 1_000_000.0
    rates << mbs
    printf("%-5s %-8s %7.1f KB %8.3f s %7.2f MB/s\n", op, name, xml.bytesize / 1000.0, t, mbs)
  end
end
printf("geomean %.2f MB/s\n", rates.map { |r| Math.log(r) }.sum.then { |s| Math.exp(s / rates.size) })
