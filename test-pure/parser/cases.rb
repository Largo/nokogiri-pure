# frozen_string_literal: true

# Corpus for the parser differential harness. Each case: [input, options, encoding, url, kind]
module ParserCases
  RECOVER = 1
  NOENT = 2
  DTDLOAD = 4
  DTDATTR = 8
  DTDVALID = 16
  NOBLANKS = 256
  SAX1 = 512
  NONET = 2048
  NSCLEAN = 8192
  NOCDATA = 16384
  OLD10 = 131072
  HUGE = 524288
  BIG_LINES = 4194304
  DEFAULT = RECOVER | NONET | BIG_LINES
  STRICT = NONET | BIG_LINES

  BASIC = [
    "<a/>", "<a></a>", "<a>text</a>", "<a><b></a>", "<a><b></b>", "<a>", "<a", "<", "", " ", "x",
    "<a b='1' c=\"2\"/>", "<a b='1' b='2'/>", "<a b=1/>", "<a b/>", "<a b='<'/>", "<a b='&lt;&amp;&#65;&#x42;'/>",
    "<a>&lt;&gt;&amp;&quot;&apos;</a>", "<a>&#65;&#x42;&#0;&#xD800;&#1114112;</a>", "<a>&foo;</a>", "<a>&foo</a>",
    "<a>& b</a>", "<a>&#;</a>", "<a>&#x;</a>", "<a>&#12a;</a>", "<a>]]></a>", "<a>x]]>y</a>",
    "<?xml version='1.0'?><a/>", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><a/>",
    "<?xml version='1.0' standalone='yes'?><a/>", "<?xml version='1.1'?><a/>", "<?xml version='2.0'?><a/>",
    "<?xml version='1.0' encoding='utf-8' standalone='no'?>\n<a/>", "<?xml?><a/>", "<?xml version=1.0?><a/>",
    "<?xml version='1.0'><a/>", "<?xml encoding='UTF-8'?><a/>", " <?xml version='1.0'?><a/>",
    "<a/><b/>", "<a/>text", "<a/><!-- c --><?pi x?>", "<!-- c --><a/>", "<?pi?><a/>", "<?xml-stylesheet href='x'?><a/>",
    "<?xmlfoo bar?><a/>", "<?XML x?><a/>", "<a><?pi data?></a>", "<a><?pi data</a>", "<a><?ns:pi x?></a>",
    "<a><!-- c --></a>", "<a><!-- c -- d --></a>", "<a><!-- c</a>", "<a><!----></a>", "<a><!---></a>", "<a><!-- - --></a>",
    "<a><![CDATA[x<y]]></a>", "<a><![CDATA[]]></a>", "<a><![CDATA[x]]><![CDATA[y]]></a>", "<a><![CDATA[x</a>",
    "<a><![CDATA[x]]]></a>", "<a><![cdata[x]]></a>",
    "<a>\n  <b>\n    text\n  </b>\n</a>\n", "<a>\r\n<b/>\r\n</a>", "<a>x\ry</a>", "<a b='x\ny\tz\r\nw'/>",
    "<a xmlns='urn:x'><b/></a>", "<p:a xmlns:p='urn:p'><p:b/><c/></p:a>", "<p:a/>", "<a p:b='1'/>",
    "<a xmlns:p='urn:p' p:b='1' p:b='2'/>", "<a xmlns:p='urn:p' xmlns:q='urn:p' p:b='1' q:b='2'/>",
    "<a xmlns:p=''/>", "<a xmlns:xml='http://www.w3.org/XML/1998/namespace'/>", "<a xmlns:xml='urn:x'/>",
    "<a xmlns='http://www.w3.org/XML/1998/namespace'/>", "<a xmlns:xmlns='urn:x'/>", "<a xmlns:p='http://www.w3.org/2000/xmlns/'/>",
    "<a xmlns='rel'/>", "<a xmlns='a b'/>", "<a xmlns:p='a b'/>", "<a xmlns='urn:x' xmlns='urn:y'/>",
    "<a xml:lang='en' xml:space='preserve'> </a>", "<a xml:space='bogus'/>", "<a:b:c/>", "<a:/>", "<:a/>", "<1a/>",
    "<a><b></c></a>", "<a></a></a>", "<a><b/></b></a>", "</a>", "<a></ a>", "<a></a >", "<a></a b>",
    "<a b='1'c='2'/>", "<a b='1' / >", "<a b='1'", "<a b='1", "<a b=\"1'/>", "<a\n  b='1'\n  c='2'>\n</a>",
    "<é/>", "<a é='ü'>ö</a>", "<a>\u00e9\u4e2d\u{1F600}</a>", "<a>\u{FFFE}</a>", "<a>\x01</a>", "<a>\x00b</a>",
    "<a>\xff</a>".b, "<a>\xc3</a>".b, "<a b='\xff'/>".b, "<a>abc\xe3".b, "<\xff/>".b,
    "\xEF\xBB\xBF<a/>".b, "\xEF\xBB\xBF<?xml version='1.0' encoding='UTF-8'?><a/>".b,
    "\xEF\xBB\xBF<?xml version='1.0' encoding='latin1'?><a/>".b,
    "\xFF\xFE<\x00a\x00/\x00>\x00".b, "\xFE\xFF\x00<\x00a\x00/\x00>".b, "<\x00?\x00x\x00m\x00l\x00 \x00v\x00e\x00r\x00s\x00i\x00o\x00n\x00=\x00'\x001\x00.\x000\x00'\x00?\x00>\x00<\x00a\x00/\x00>\x00".b,
    "<?xml version='1.0' encoding='ISO-8859-1'?><a>\xe9</a>".b, "<?xml version='1.0' encoding='shift_jis'?><a>\x82\xa0</a>".b,
    "<?xml version='1.0' encoding='bogus'?><a/>", "<?xml version='1.0' encoding='ascii'?><a>\xe9</a>".b,
    "<?xml version='1.0' encoding='UTF-16'?><a/>", "<?xml version='1.0' encoding=''?><a/>", "<?xml version='1.0' encoding='1x'?><a/>",
    "<a>" + ("x" * 1000) + "</a>", "<a>" + ("é" * 500) + "</a>", "<a>" + ("xé" * 400) + "</a>",
    "<a>" + ("<b>" * 300) + "</a>", "<a>" + ("<b>t</b>" * 100) + "</a>",
    "<!DOCTYPE a><a/>", "<!DOCTYPE a SYSTEM 'a.dtd'><a/>", "<!DOCTYPE a PUBLIC '-//X//Y' 'a.dtd'><a/>", "<!DOCTYPE a PUBLIC 'x'><a/>",
    "<!DOCTYPE><a/>", "<!DOCTYPE a [<!ELEMENT a (#PCDATA)>]><a/>", "<!DOCTYPE a [<!ELEMENT a EMPTY>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a ANY><!ELEMENT b (c,d?,(e|f)*)+>]><a/>", "<!DOCTYPE a [<!ELEMENT a (#PCDATA|b|c)*>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a (b,c|d)>]><a/>", "<!DOCTYPE a [<!ELEMENT a (b>]><a/>", "<!DOCTYPE a [<!ELEMENT a>]><a/>",
    "<!DOCTYPE a [<!ATTLIST a b CDATA #IMPLIED c ID #REQUIRED d (x|y) 'x' e NOTATION (n) #IMPLIED f CDATA #FIXED 'z'>]><a c='1'/>",
    "<!DOCTYPE a [<!ATTLIST a b CDATA 'def'>]><a/>", "<!DOCTYPE a [<!ATTLIST a b NMTOKENS '  x   y  '>]><a b='  p   q '/>",
    "<!DOCTYPE a [<!ATTLIST a xmlns CDATA 'urn:d'>]><a/>", "<!DOCTYPE a [<!ATTLIST a xmlns:p CDATA 'urn:p'>]><a><p:b/></a>",
    "<!DOCTYPE a [<!ATTLIST a b CDATA 'x'><!ATTLIST a b CDATA 'y'>]><a/>", "<!DOCTYPE a [<!ATTLIST a id ID #IMPLIED>]><a id='x'><b/></a>",
    "<!DOCTYPE a [<!ENTITY e 'val'>]><a>&e;</a>", "<!DOCTYPE a [<!ENTITY e '<b>x</b>'>]><a>&e;&e;</a>",
    "<!DOCTYPE a [<!ENTITY e 'x&f;y'><!ENTITY f 'F'>]><a>&e;</a>", "<!DOCTYPE a [<!ENTITY e '&e;'>]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e 'v'>]><a b='&e;'/>", "<!DOCTYPE a [<!ENTITY e '<'>]><a b='&e;'/>", "<!DOCTYPE a [<!ENTITY e SYSTEM 'e.xml'>]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e SYSTEM 'e.xml'>]><a b='&e;'/>", "<!DOCTYPE a [<!ENTITY e SYSTEM 'e.xml' NDATA n><!NOTATION n SYSTEM 'x'>]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY % p 'x'>]><a/>", "<!DOCTYPE a [<!ENTITY % p '<!ENTITY e \"pe\">'>%p;]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY % p SYSTEM 'p.ent'>%p;]><a>&e;</a>", "<!DOCTYPE a [%undefined;]><a/>", "<!DOCTYPE a [<!ENTITY e '%p;'>]><a/>",
    "<!DOCTYPE a [<!ENTITY lt '<'>]><a/>", "<!DOCTYPE a [<!ENTITY lt '&#60;'>]><a/>", "<!DOCTYPE a [<!ENTITY amp '&#38;'>]><a/>",
    "<!DOCTYPE a [<!ENTITY e 'a'><!ENTITY e 'b'>]><a>&e;</a>", "<!DOCTYPE a [<!ENTITY e 'a'>", "<!DOCTYPE a [<!ENTITY e 'a>]><a/>",
    "<!DOCTYPE a [<!NOTATION n PUBLIC 'p'><!NOTATION m SYSTEM 's'><!NOTATION o PUBLIC 'p' 's'>]><a/>", "<!DOCTYPE a [<!NOTATION n>]><a/>",
    "<!DOCTYPE a [<!-- c --><?pi x?>]><a/>", "<!DOCTYPE a [<!FOO>]><a/>", "<!DOCTYPE a [ ]><a/>", "<!DOCTYPE a [ ] ><a/>",
    "<!DOCTYPE a [<![INCLUDE[<!ELEMENT a ANY>]]>]><a/>", "<!DOCTYPE a []><a/><!DOCTYPE b>", "<a/><!DOCTYPE a>",
    "<!DOCTYPE a [<!ENTITY e 'x'>]><a>&e;&amp;&e;</a>", "<!DOCTYPE a [<!ENTITY e ''>]><a>&e;</a>", "<!DOCTYPE a [<!ENTITY e ''>]><a b='&e;'/>",
    "<!DOCTYPE a [<!ENTITY e 'x'>]><a b='x&e;y&amp;z&#38;'/>", "<!DOCTYPE a [<!ELEMENT a (b)*><!ELEMENT b EMPTY>]><a>\n <b/>\n</a>",
  ].freeze

  BASES = [
    "<?xml version='1.0'?>\n<!DOCTYPE r [<!ENTITY e 'ent'><!ATTLIST r d CDATA 'def'>]>\n<r xmlns:p='urn:p' a='1'>\n <p:c x='&e;'>t&e;x<![CDATA[cd]]></p:c>\n <!-- com --><?pi d?>\n</r>\n",
    "<root><a href=\"x\">link</a><b><c/>tail</b>&amp;<d>&#233;</d></root>",
  ].freeze

  FRAGMENTS = ["<b/>", "text", "<b>x</b><c/>", "<b>", "</x>", "<p:b/>", "<b xmlns='urn:q'/>", "&amp;&e;", "<b a='1' a='2'/>",
    "<!-- c --><?pi?>", "<![CDATA[x]]>", "", " ", "<b><c></b>", "x<y", "<b p:a='1'/>"].freeze
  CONTEXTS = ["<root/>", "<root xmlns:p='urn:p'><c ctx='1'/></root>", "<!DOCTYPE r [<!ENTITY e 'E'>]><r/>",
    "<?xml version='1.0' encoding='ISO-8859-1'?><r/>"].freeze

  VALID = [
    "<!DOCTYPE a [<!ELEMENT a (b,c)><!ELEMENT b EMPTY><!ELEMENT c (#PCDATA)>]><a><b/><c>x</c></a>",
    "<!DOCTYPE a [<!ELEMENT a (b,c)><!ELEMENT b EMPTY><!ELEMENT c (#PCDATA)>]><a><c>x</c><b/></a>",
    "<!DOCTYPE a [<!ELEMENT a (b,c)><!ELEMENT b EMPTY><!ELEMENT c (#PCDATA)>]><a><b>t</b></a>",
    "<!DOCTYPE a [<!ELEMENT a (b|c)*><!ELEMENT b EMPTY><!ELEMENT c ANY>]><a>text<b/></a>",
    "<!DOCTYPE a [<!ELEMENT a (#PCDATA|b)*><!ELEMENT b EMPTY>]><a>x<b/>y<c/></a>",
    "<!DOCTYPE a [<!ELEMENT a (#PCDATA)>]><a>x<!-- c --><?p?><b/></a>",
    "<!DOCTYPE a [<!ELEMENT a (b+)><!ELEMENT b EMPTY>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a (b?,c*)><!ELEMENT b EMPTY><!ELEMENT c EMPTY>]><a><c/><c/><b/></a>",
    "<!DOCTYPE a [<!ELEMENT a ((b,c)|(b,d))><!ELEMENT b EMPTY><!ELEMENT c EMPTY><!ELEMENT d EMPTY>]><a><b/><d/></a>",
    "<!DOCTYPE a [<!ELEMENT a EMPTY><!ATTLIST a x CDATA #REQUIRED y (p|q) 'p' z ID #IMPLIED>]><a y='r' z='1x'/>",
    "<!DOCTYPE a [<!ELEMENT a (b*)><!ELEMENT b EMPTY><!ATTLIST b id ID #IMPLIED ref IDREF #IMPLIED refs IDREFS #IMPLIED>]><a><b id='x' ref='y'/><b id='x' refs='x z'/></a>",
    "<!DOCTYPE a [<!ELEMENT a EMPTY><!ATTLIST a f CDATA #FIXED 'v'>]><a f='w'/>",
    "<!DOCTYPE a [<!ELEMENT a EMPTY><!ATTLIST a n NOTATION (x) #IMPLIED><!NOTATION x SYSTEM 'x'>]><a n='y'/>",
    "<!DOCTYPE a [<!ELEMENT a EMPTY><!ATTLIST a e ENTITY #IMPLIED es ENTITIES #IMPLIED><!ENTITY u SYSTEM 'u' NDATA x><!NOTATION x SYSTEM 'x'><!ENTITY t 'txt'>]><a e='t' es='u v'/>",
    "<!DOCTYPE b [<!ELEMENT a EMPTY>]><a/>", "<!DOCTYPE a [<!ELEMENT a EMPTY>]><a>x</a>", "<!DOCTYPE a [<!ELEMENT a EMPTY>]><a><b/></a>",
    "<!DOCTYPE a [<!ELEMENT a ANY><!ELEMENT a EMPTY>]><a/>", "<!DOCTYPE a [<!ELEMENT a (#PCDATA|b|b)*>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a ((b,c)|(b,d))>]><a/>", "<!DOCTYPE a [<!ELEMENT a (b)><!ATTLIST a id ID 'x'>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a ANY><!ATTLIST a xmlns CDATA #FIXED 'urn:x'>]><a xmlns='urn:y'/>",
    "<!DOCTYPE p:a [<!ELEMENT p:a (p:b)><!ELEMENT p:b EMPTY><!ATTLIST p:a xmlns:p CDATA #FIXED 'urn:p'>]><p:a xmlns:p='urn:p'><p:b/></p:a>",
    "<!DOCTYPE a [<!ELEMENT a (b)><!ELEMENT b (#PCDATA)><!ENTITY e '<b>x</b>'>]><a>&e;</a>",
    "<!DOCTYPE a [<!ELEMENT a (b)><!ELEMENT b EMPTY>]><a>\n  <b/>\n</a>", "<!DOCTYPE a [<!ELEMENT a (b)><!ELEMENT b EMPTY>]><a><![CDATA[x]]><b/></a>",
    "<!DOCTYPE a [<!ELEMENT a (b,(c|d)+,e?)*><!ELEMENT b EMPTY><!ELEMENT c EMPTY><!ELEMENT d EMPTY><!ELEMENT e EMPTY>]><a><b/><c/><d/><b/><e/></a>",
    "<!DOCTYPE a><a/>", "<a/>", "<!DOCTYPE a [<!ATTLIST a x CDATA #IMPLIED>]><a x='1' y='2'/>",
    "<!DOCTYPE a [<!ELEMENT a EMPTY><!ATTLIST a x NMTOKEN #IMPLIED y NMTOKENS #IMPLIED z IDREF #IMPLIED>]><a x='a b' y=' a  b ' z='1'/>",
  ].freeze

  EXTERNAL = [
    "<!DOCTYPE doc SYSTEM 'ext.dtd'><doc><item id='x'>&extent;|&frompe;|&inc;|&ign;</item></doc>",
    "<!DOCTYPE doc SYSTEM 'ext.dtd'><doc><item id='x'>&chapter;</item><note>&chapter;</note></doc>",
    "<!DOCTYPE doc SYSTEM 'missing.dtd'><doc/>", "<!DOCTYPE doc SYSTEM 'bad.dtd'><doc/>",
    "<!DOCTYPE doc SYSTEM 'http://example.com/x.dtd'><doc/>", "<!DOCTYPE doc PUBLIC '-//X//DTD X//EN' 'ext.dtd'><doc/>",
    "<!DOCTYPE doc [<!ENTITY l SYSTEM 'latin1.ent'>]><doc>&l;</doc>",
    "<!DOCTYPE doc [<!ENTITY % p SYSTEM 'pe.ent'> %p;]><doc>&fromfile;</doc>",
    "<!DOCTYPE doc [<!ENTITY % p SYSTEM 'pe.ent'> %p; <!ENTITY e 'x'>]><doc>&e;</doc>",
    "<!DOCTYPE doc [<!ENTITY e SYSTEM 'nofile.xml'>]><doc>&e;</doc>",
    "<!DOCTYPE doc [<!ENTITY e SYSTEM 'chapter.xml'>]><doc a='&e;'>&e;</doc>",
    "<?xml version='1.0' standalone='yes'?><!DOCTYPE doc SYSTEM 'ext.dtd'><doc><item id='x'>&extent;</item></doc>",
    "<!DOCTYPE doc SYSTEM 'ext.dtd' [<!ENTITY extent 'internal wins'>]><doc><item id='x'>&extent;</item></doc>",
  ].freeze

  ENCODED = [
    ["<?xml version='1.0' encoding='ISO-8859-1'?><a b='\xe9'>caf\xe9</a>".b, nil],
    ["<?xml version='1.0' encoding='windows-1252'?><a>\x80\x93</a>".b, nil],
    ["<?xml version='1.0' encoding='Shift_JIS'?><a>\x82\xa0\x93\xfa</a>".b, nil],
    ["<?xml version='1.0' encoding='Shift_JIS'?><a>\x82\xa0\xff\xfe</a>".b, nil],
    ["<?xml version='1.0' encoding='EUC-JP'?><a>\xa4\xa2</a>".b, nil],
    ["<?xml version='1.0' encoding='UTF-16'?>".encode("UTF-16LE").b + "<a>\u00e9</a>".encode("UTF-16LE").b, nil],
    ["\xFF\xFE".b + "<?xml version='1.0' encoding='UTF-16'?><a>x\u4e2d</a>".encode("UTF-16LE").b, nil],
    ["\xFE\xFF".b + "<?xml version='1.0'?><a>x\u4e2d</a>".encode("UTF-16BE").b, nil],
    ["\xFF\xFE".b + "<?xml version='1.0' encoding='ISO-8859-1'?><a/>".encode("UTF-16LE").b, nil],
    ["\xFF\xFE".b + "<a>x</a>".encode("UTF-16LE").b + "\x00".b, nil],
    ["\xFF\xFE".b + "<a>\x00\xD8</a>".b, nil],
    ["<a>caf\xe9</a>".b, "ISO-8859-1"], ["<a>caf\xe9</a>".b, "UTF-8"], ["<?xml version='1.0' encoding='UTF-8'?><a>caf\xe9</a>".b, "ISO-8859-1"],
    ["<a>x</a>".encode("UTF-16LE").b, "UTF-16LE"], ["<a>x</a>".encode("UTF-16BE").b, "UTF-16"],
    ["<?xml version='1.0' encoding='ISO-8859-1'?>".b + "<a>#{"x\xe9" * 3000}</a>".b, nil],
    ["<?xml version='1.0' encoding='ascii'?>".b + "<a>#{"x" * 5000}\xe9</a>".b, nil],
    ["<?xml version='1.0' encoding='ascii'?>".b + "<a>#{"x" * 150}\xe9</a>".b, nil],
    ["<?xml version='1.0' encoding='UTF-8'?><a>\xe9</a>".b, nil], ["\xEF\xBB\xBF<?xml version='1.0' encoding='UTF-16'?><a/>".b, nil],
  ].freeze

  FIXTURES = %w[staff.xml address_book.xml po.xml atom.xml snuggles.xml valid_bar.xml bogus.xml exslt.xml
    iso-8859-1.xml namespace_pressure_test.xml xinclude.xml to_be_xincluded.xml shift_jis.xml].freeze

  module_function

  def all(kinds = nil)
    out = []
    add = ->(kind, input, opts, enc = nil, url = nil, mode = nil) { out << [input, opts, enc, url, kind, mode] if kinds.nil? || kinds.include?(kind) }
    BASIC.each do |s|
      add.("basic", s, DEFAULT)
      add.("strict", s, STRICT)
    end
    BASIC.grep(/DOCTYPE|&/).each do |s|
      add.("noent", s, DEFAULT | NOENT)
      add.("dtdattr", s, DEFAULT | DTDLOAD | DTDATTR)
    end
    BASIC.first(60).each { |s| add.("noblanks", s, DEFAULT | NOBLANKS) }
    BASIC.first(60).each { |s| add.("sax1", s, DEFAULT | SAX1) }
    BASES.each do |base|
      (0..base.bytesize).each { |i| add.("trunc", base.byteslice(0, i), DEFAULT) }
      (0...base.bytesize).each { |i| add.("delete", base.byteslice(0, i) + base.byteslice(i + 1..), DEFAULT) }
    end
    dir = "/root/workspace/nokogiri-upstream/test/files"
    FIXTURES.each do |f|
      path = File.join(dir, f)
      next unless File.exist?(path)

      data = File.binread(path)
      add.("fixture", data, DEFAULT, nil, path)
      add.("fixture", data, DEFAULT | NOENT | DTDLOAD, nil, path)
    end
    BASIC.each do |s|
      next if s.empty?

      add.("sax", s, 0, nil, nil, :sax)
      add.("sax_recover", s, RECOVER, nil, nil, :sax)
      add.("io", s, DEFAULT, nil, nil, :io)
    end
    BASIC.first(120).each do |s|
      add.("push1", s, DEFAULT, nil, nil, [:push, 1])
      add.("push7", s, 0, nil, nil, [:push, 7])
    end
    BASES.each { |b| [1, 2, 3, 5, 16, 64].each { |n| add.("pushbase", b, DEFAULT, nil, nil, [:push, n]) } }
    FRAGMENTS.each do |f|
      CONTEXTS.each do |c|
        add.("fragment", f, DEFAULT, nil, nil, [:fragment, c])
        add.("fragment_strict", f, 0, nil, nil, [:fragment, c])
      end
    end
    rng = Random.new(42)
    alphabet = ["<", ">", "/", "&", ";", "'", "\"", "=", "!", "?", "[", "]", "-", " ", "\n", "\r", "\t", "a", ":", "#", "x",
      "%", "\u00e9", "\xFF".b, "\x00", "<!--", "]]>", "<![CDATA[", "&#", "</", "/>", "xmlns:", "<?", "?>"]
    pool = BASES + BASIC.select { |b| b.bytesize > 8 }
    1500.times do |n|
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
      add.("fuzz", src, n.even? ? DEFAULT : STRICT)
      add.("fuzzsax", src, RECOVER, nil, nil, :sax) if n % 5 == 0
      add.("fuzzpush", src, DEFAULT, nil, nil, [:push, 1 + rng.rand(9)]) if n % 5 == 1
    end
    VALID.each do |v|
      add.("valid_parse", v, DEFAULT | DTDVALID)
      add.("valid_parse_strict", v, STRICT | DTDVALID)
      add.("validate", v, DEFAULT, nil, nil, :validate)
      add.("valid_sax", v, 1 | 16, nil, nil, [:push, 3])
    end
    fdir = File.join(__dir__, "files")
    doc_url = File.join(fdir, "doc.xml")
    EXTERNAL.each do |x|
      [DEFAULT, DEFAULT | NOENT, DEFAULT | DTDLOAD, DEFAULT | DTDLOAD | NOENT, DEFAULT | DTDLOAD | DTDATTR | NOENT,
        DEFAULT | DTDVALID, STRICT | DTDLOAD | NOENT, DEFAULT | DTDLOAD & ~NONET].each do |o|
        add.("external", x, o, nil, doc_url)
      end
      add.("external_sax", x, RECOVER | NOENT, nil, nil, :sax)
    end
    add.("external", File.binread(doc_url), DEFAULT | DTDLOAD | NOENT, nil, doc_url)
    add.("external", File.binread(doc_url), DEFAULT | DTDVALID | NOENT, nil, doc_url)
    add.("external", File.binread(doc_url), DEFAULT | DTDLOAD, nil, doc_url)
    add.("external", File.binread(doc_url), DEFAULT, nil, doc_url)
    add.("external", File.binread(doc_url), DEFAULT | DTDLOAD | NOENT, nil, "doc.xml")
    ENCODED.each do |e, enc|
      add.("encoded", e, DEFAULT, enc)
      add.("encoded", e, STRICT, enc)
      add.("encoded_push", e, DEFAULT, nil, nil, [:push, 3])
      add.("encoded_io", e, DEFAULT, enc, nil, :io)
    end
    add.("enc", "<a>\xe9</a>".b, DEFAULT, "ISO-8859-1")
    add.("enc", "<a>x</a>", DEFAULT, "bogus")
    add.("enc", "<?xml version='1.0' encoding='UTF-8'?><a>\xe9</a>".b, DEFAULT, "ISO-8859-1")
    add.("enc", "\xEF\xBB\xBF<a/>".b, DEFAULT, "UTF-8")
    add.("enc", "<a/>", DEFAULT, "UTF-16")
    out
  end
end
