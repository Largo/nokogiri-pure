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

  FIXTURES = %w[staff.xml address_book.xml po.xml atom.xml snuggles.xml valid_bar.xml bogus.xml exslt.xml
    iso-8859-1.xml namespace_pressure_test.xml xinclude.xml to_be_xincluded.xml shift_jis.xml].freeze

  module_function

  def all(kinds = nil)
    out = []
    add = ->(kind, input, opts, enc = nil, url = nil) { out << [input, opts, enc, url, kind] if kinds.nil? || kinds.include?(kind) }
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
    add.("enc", "<a>\xe9</a>".b, DEFAULT, "ISO-8859-1")
    add.("enc", "<a>x</a>", DEFAULT, "bogus")
    add.("enc", "<?xml version='1.0' encoding='UTF-8'?><a>\xe9</a>".b, DEFAULT, "ISO-8859-1")
    add.("enc", "\xEF\xBB\xBF<a/>".b, DEFAULT, "UTF-8")
    add.("enc", "<a/>", DEFAULT, "UTF-16")
    out
  end
end
