# frozen_string_literal: true

# Corpus for the XML::Reader differential harness.
# Each case: [kind, input(bytes), source, url, encoding, options, mode]
#   source: :memory | :io | [:io_small, n] | :io_toomuch | [:io_raise, after_n_calls] | :io_nonstring
#   mode:   :light (read + cheap accessors) | :full (every accessor) | :outer | :attrs | :next_only
require_relative "../parser/cases"

module ReaderCases
  STRICT = 0
  RECOVER = 1
  NOENT = 2
  DTDLOAD = 4
  DTDATTR = 8
  DTDVALID = 16
  NOBLANKS = 256
  SAX1 = 512
  XINCLUDE = 1024
  NONET = 2048
  NOCDATA = 16384
  HUGE = 524288
  BIG_LINES = 4194304
  DEFAULT = RECOVER | NONET | BIG_LINES

  EXTRA = [
    "<x xmlns:tenderlove='http://tenderlovemaking.com/'>\n  <tenderlove:foo awesome='true'>snuggles!</tenderlove:foo>\n</x>",
    "<x xmlns:tenderlove='http://tenderlovemaking.com/'>\n  <tenderlove:foo awesome='true'>snuggles!</tenderlove:foo>\n  <foo>\n</x>",
    "<a xml:lang='en'><b xml:lang='fr'>x</b><c>y</c></a>",
    "<a xml:base='http://example.com/a/'><b xml:base='b/'><c xml:base='../c'>t</c></b></a>",
    "<a xml:space='preserve'> <b>  </b><c xml:space='default'> </c></a>",
    "<a>  </a>", "<a> <b/> </a>", "<a>\n\t\r\n</a>", "<a><![CDATA[  ]]></a>", "<a><![CDATA[x]]>y<![CDATA[z]]></a>",
    "<a b='1' xmlns='urn:d' xmlns:p='urn:p' p:c='2'><p:d p:e='3'/></a>",
    "<a xmlns:a='urn:a' xmlns:b='urn:b' a:x='1' b:x='2' x='3'/>",
    "<a b='&lt;x&gt;&#65;'>&lt;&amp;</a>",
    "<!DOCTYPE a [<!ENTITY e 'x<b>y</b>z'><!ENTITY f '&e;&e;'>]><a>1&e;2&f;3</a>",
    "<!DOCTYPE a [<!ENTITY e '<b>hi</b>'>]><a>&e;<c/></a>",
    "<!DOCTYPE a [<!ATTLIST a d CDATA 'def' e CDATA #FIXED 'fix'>]><a x='1'/>",
    "<!DOCTYPE a SYSTEM 'x.dtd'><a/>", "<!DOCTYPE a PUBLIC '-//X//EN' 'x.dtd' [<!ELEMENT a ANY>]><!-- c --><a/><?pi?>",
    "<?xml version='1.0' encoding='UTF-8' standalone='yes'?><a/>", "<?xml version='1.1'?><a/>",
    "<a><b><c><d><e>deep</e></d></c></b></a>", "<a/>", "<a></a>", "<a>t</a>", "<a><b/></a>", "<a><b></b></a>",
    "<a><?pi data?><!-- comment --></a>", "<?pi?><!--c--><a/><!--d--><?q?>",
    "<a>x</a>  \n", "<a>x</a><b/>", "<a>x</a>junk", "<a>&bogus;</a>", "&bogus;", "", "   ", "<", "<a", "<a>", "<a><b>",
    "<a></b>", "<a b='1' b='2'/>", "<a>\xff</a>".b, "<a>x\x01y</a>", "<p:a/>", "<a xmlns:p='urn:p'><p:b><q:c/></p:b></a>",
    "<xi:include xmlns:xi='http://www.w3.org/2001/XInclude' href='to_be_xincluded.xml'/>",
    "<a xmlns:xi='http://www.w3.org/2001/XInclude'><xi:include href='to_be_xincluded.xml'/><b/></a>",
    "<a xmlns:xi='http://www.w3.org/2001/XInclude'><xi:include href='nonexistent.xml'/></a>",
    "<a xmlns:xi='http://www.w3.org/2001/XInclude'><xi:include href='nonexistent.xml'><xi:fallback><f/></xi:fallback></xi:include></a>",
  ].freeze

  module_function

  # documents large enough to cross the 512-byte chunk / 4096-byte read boundaries
  def big_docs
    rng = Random.new(7)
    docs = []
    docs << "<root>" + (1..300).map { |i| "<item id='#{i}'>value #{i}</item>" }.join("\n") + "</root>"
    docs << "<root>#{"x" * 10_000}</root>"
    docs << "<root><![CDATA[#{"y" * 9000}]]></root>"
    docs << "<root>" + ("<a>" * 200) + "t" + ("</a>" * 200) + "</root>"
    docs << "<root>" + (1..200).map { |i| "<e a='#{"v" * (i % 37)}'/>" }.join + "</root>"
    docs << "<root>" + (1..100).map { |i| "<!-- #{"c" * i} --><?p #{"d" * i}?>" }.join + "</root>"
    docs << "<root xmlns='urn:x' xmlns:p='urn:p'>" + (1..150).map { |i| "<p:e p:a='#{i}'>\r\n#{"é" * i}</p:e>" }.join + "</root>"
    docs << "<root>" + (1..600).map { |i| "<a>#{i}</a>" }.join + "</root>"
    # an error beyond the first chunks
    docs << "<root>" + (1..200).map { |i| "<item>#{i}</item>" }.join + "<bad></root>"
    docs << "<root>" + (1..200).map { |i| "<item>#{i}</item>" }.join + "</root><extra/>"
    docs << "<root>" + (1..200).map { |i| "<item>#{i}</item>" }.join + "&undefined;</root>"
    docs << "<root>" + (1..200).map { |i| "<item>#{i}</item>" }.join
    # CR at chunk boundaries
    [510, 511, 512, 513, 1023, 1024, 4095, 4096, 4097].each do |pos|
      pre = "<root>"
      filler = "a" * (pos - pre.bytesize)
      docs << pre + filler + "\r\n<b>x\r\ny</b></root>"
    end
    # random trees
    20.times do
      depth = 0
      out = +"<r>"
      stack = []
      (200 + rng.rand(400)).times do
        case rng.rand(8)
        when 0, 1
          name = "e#{rng.rand(5)}"
          out << "<#{name}#{rng.rand(3) == 0 ? " a='#{rng.rand(100)}'" : ""}>"
          stack << name
        when 2
          out << "</#{stack.pop}>" unless stack.empty?
        when 3 then out << "text#{rng.rand(1000)}"
        when 4 then out << "<empty/>"
        when 5 then out << " " * rng.rand(5) + "\n"
        when 6 then out << "&amp;&lt;"
        when 7 then out << "<![CDATA[c#{rng.rand(10)}]]>"
        end
      end
      out << stack.reverse.map { |n| "</#{n}>" }.join
      out << "</r>"
      docs << out
    end
    docs
  end

  def all
    out = []
    add = ->(kind, input, source: :memory, url: nil, enc: nil, opts: STRICT, mode: :light) do
      out << [kind, input.b, source, url, enc, opts, mode]
    end
    ParserCases::BASIC.each do |s|
      add.("basic", s)
      add.("basic_full", s, mode: :full)
      add.("basic_recover", s, opts: DEFAULT)
      add.("basic_io", s, source: :io)
    end
    ParserCases::BASIC.grep(/DOCTYPE|&/).each do |s|
      add.("noent", s, opts: NOENT, mode: :full)
      add.("dtdattr", s, opts: DTDLOAD | DTDATTR, mode: :full)
    end
    ParserCases::BASIC.first(80).each do |s|
      add.("noblanks", s, opts: NOBLANKS)
      add.("sax1", s, opts: SAX1, mode: :full)
      add.("nocdata", s, opts: NOCDATA)
    end
    ParserCases::BASES.each do |base|
      (0..base.bytesize).each { |i| add.("trunc", base.byteslice(0, i)) }
      (0...base.bytesize).each { |i| add.("delete", base.byteslice(0, i) + base.byteslice(i + 1..)) }
      add.("base_full", base, mode: :full)
      add.("base_outer", base, mode: :outer)
    end
    EXTRA.each do |s|
      url = "/root/workspace/nokogiri-upstream/test/files/x.xml"
      [:light, :full, :outer, :attrs, :next_only].each { |m| add.("extra", s, mode: m, url: url) }
      add.("extra_noent", s, opts: NOENT, mode: :full, url: url)
      add.("extra_xinclude", s, opts: XINCLUDE, mode: :full, url: url)
      add.("extra_xinclude_noent", s, opts: XINCLUDE | NOENT, mode: :light, url: url)
      add.("extra_io1", s, source: [:io_small, 1])
      add.("extra_io3", s, source: [:io_small, 3], mode: :full)
    end
    big_docs.each_with_index do |d, i|
      add.("big", d)
      add.("big_full", d, mode: :full) if i % 2 == 0
      add.("big_outer", d, mode: :outer) if i % 3 == 0
      add.("big_attrs", d, mode: :attrs) if i % 3 == 1
      add.("big_io", d, source: :io)
      add.("big_io7", d, source: [:io_small, 7]) if i % 4 == 0
      add.("big_io_many", d, source: [:io_small, 1000]) if i % 4 == 1
      add.("big_toomuch", d, source: :io_toomuch) if i % 5 == 0
      add.("big_raise", d, source: [:io_raise, 2]) if i % 5 == 1
      add.("big_noblanks", d, opts: NOBLANKS) if i % 3 == 2
    end
    add.("io_nonstring", "<a/>", source: :io_nonstring)
    add.("io_raise0", "<a/>", source: [:io_raise, 0])
    add.("io_raise1", "<a/>", source: [:io_raise, 1])
    dir = "/root/workspace/nokogiri-upstream/test/files"
    ParserCases::FIXTURES.each do |f|
      path = File.join(dir, f)
      next unless File.exist?(path)

      data = File.binread(path)
      add.("fixture", data, url: path)
      add.("fixture_full", data, url: path, mode: :full)
      add.("fixture_io", data, url: path, source: :io)
      add.("fixture_noent", data, url: path, opts: NOENT | DTDLOAD, mode: :full)
      add.("fixture_xinclude", data, url: path, opts: XINCLUDE, mode: :full)
    end
    fdir = File.expand_path("../parser/files", __dir__)
    doc_url = File.join(fdir, "doc.xml")
    ParserCases::EXTERNAL.each do |x|
      [STRICT, NOENT, DTDLOAD, DTDLOAD | NOENT, DTDLOAD | DTDATTR | NOENT].each do |o|
        add.("external", x, opts: o, url: doc_url, mode: :full)
      end
    end
    ParserCases::ENCODED.each do |e, enc|
      add.("encoded", e, enc: enc, mode: :full)
      add.("encoded_io", e, enc: enc, source: [:io_small, 5])
    end
    [["<a>\xe9</a>".b, "ISO-8859-1"], ["<a>x</a>", "bogus"], ["<?xml version='1.0' encoding='UTF-8'?><a>\xe9</a>".b, "ISO-8859-1"],
      ["\xEF\xBB\xBF<a/>".b, "UTF-8"], ["<a/>", "UTF-16"], ["<a>x</a>", "UTF-8"], ["<a>x</a>", "ascii"]].each do |s, enc|
      add.("enc", s, enc: enc, mode: :full)
    end
    ParserCases::VALID.each do |v|
      add.("valid_dtd", v, opts: DTDVALID, mode: :light)
      add.("valid_dtd_recover", v, opts: DTDVALID | RECOVER, mode: :full)
    end
    rng = Random.new(1234)
    alphabet = ["<", ">", "/", "&", ";", "'", "\"", "=", "!", "?", "[", "]", "-", " ", "\n", "\r", "\t", "a", ":", "#", "x",
      "%", "é", "\xFF".b, "\x00", "<!--", "]]>", "<![CDATA[", "&#", "</", "/>", "xmlns:", "<?", "?>"]
    pool = ParserCases::BASES + EXTRA.select { |b| b.bytesize > 8 } + ParserCases::BASIC.select { |b| b.bytesize > 8 }
    1200.times do |n|
      src = pool[rng.rand(pool.size)].b.dup
      (1 + rng.rand(3)).times do
        pos = rng.rand(src.bytesize + 1)
        case rng.rand(3)
        when 0 then src = src.byteslice(0, pos) + alphabet[rng.rand(alphabet.size)].b + src.byteslice(pos..).to_s
        when 1 then src = src.byteslice(0, pos) + src.byteslice(pos + 1 + rng.rand(4)..).to_s
        else
          l = rng.rand(10)
          src = src.byteslice(0, pos) + src.byteslice(pos, l).to_s + src.byteslice(pos..).to_s
        end
      end
      mode = [:light, :full, :outer, :attrs][n % 4]
      add.("fuzz", src, mode: mode, opts: n % 3 == 0 ? DEFAULT : STRICT)
      add.("fuzz_io", src, source: [:io_small, 1 + rng.rand(6)], opts: [NOENT, DTDLOAD | DTDATTR, NOBLANKS, SAX1][n % 4],
        mode: n.even? ? :light : :full) if n % 3 == 1
    end
    # fuzz on bigger documents
    bigs = big_docs
    300.times do |n|
      src = bigs[rng.rand(bigs.size)].b.dup
      (1 + rng.rand(2)).times do
        pos = rng.rand(src.bytesize + 1)
        case rng.rand(2)
        when 0 then src = src.byteslice(0, pos) + alphabet[rng.rand(alphabet.size)].b + src.byteslice(pos..).to_s
        else src = src.byteslice(0, pos) + src.byteslice(pos + 1 + rng.rand(4)..).to_s
        end
      end
      add.("bigfuzz", src, mode: n.even? ? :light : :full)
    end
    out
  end
end
