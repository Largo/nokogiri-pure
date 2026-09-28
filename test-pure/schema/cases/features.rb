# Hand-written differential cases: each entry is a schema (xsd_string) plus inline instances.
XS = 'xmlns:xs="http://www.w3.org/2001/XMLSchema"'

CASES << {
  id: "idc/key-keyref",
  xsd_string: <<~X,
    <xs:schema #{XS}>
      <xs:element name="root">
        <xs:complexType><xs:sequence>
          <xs:element name="item" maxOccurs="unbounded">
            <xs:complexType><xs:attribute name="id" type="xs:string"/><xs:attribute name="ref" type="xs:string"/>
              <xs:attribute name="n" type="xs:int"/></xs:complexType>
          </xs:element>
        </xs:sequence></xs:complexType>
        <xs:key name="k"><xs:selector xpath="item"/><xs:field xpath="@id"/></xs:key>
        <xs:keyref name="kr" refer="k"><xs:selector xpath="item"/><xs:field xpath="@ref"/></xs:keyref>
        <xs:unique name="u"><xs:selector xpath="./item"/><xs:field xpath="@n"/></xs:unique>
      </xs:element>
    </xs:schema>
  X
  instances_inline: [
    ["ok", %(<root><item id="a" n="1"/><item id="b" ref="a" n="2"/></root>)],
    ["dup-key", %(<root><item id="a"/>\n<item id="a"/></root>)],
    ["missing-key", %(<root><item n="1"/></root>)],
    ["bad-ref", %(<root><item id="a"/>\n<item id="b" ref="c"/></root>)],
    ["dup-unique", %(<root><item id="a" n="01"/><item id="b" n="1"/></root>)],
  ],
}

CASES << {
  id: "idc/nested",
  xsd_string: <<~X,
    <xs:schema #{XS} xmlns:t="urn:t" targetNamespace="urn:t" elementFormDefault="qualified">
      <xs:element name="lib">
        <xs:complexType><xs:sequence>
          <xs:element name="shelf" maxOccurs="unbounded"><xs:complexType><xs:sequence>
            <xs:element name="book" maxOccurs="unbounded"><xs:complexType><xs:sequence>
              <xs:element name="isbn" type="xs:string"/><xs:element name="title" type="xs:string"/>
            </xs:sequence></xs:complexType></xs:element>
          </xs:sequence></xs:complexType></xs:element>
          <xs:element name="loan" minOccurs="0" maxOccurs="unbounded"><xs:complexType>
            <xs:attribute name="isbn" type="xs:string"/></xs:complexType></xs:element>
        </xs:sequence></xs:complexType>
        <xs:key name="isbnKey"><xs:selector xpath=".//t:book"/><xs:field xpath="t:isbn"/></xs:key>
        <xs:keyref name="loanRef" refer="t:isbnKey"><xs:selector xpath="t:loan"/><xs:field xpath="@isbn"/></xs:keyref>
      </xs:element>
    </xs:schema>
  X
  instances_inline: [
    ["ok", %(<lib xmlns="urn:t"><shelf><book><isbn>1</isbn><title>a</title></book></shelf><loan isbn="1"/></lib>)],
    ["dup", %(<lib xmlns="urn:t"><shelf><book><isbn>1</isbn><title>a</title></book></shelf>\n<shelf><book><isbn>1</isbn><title>b</title></book></shelf></lib>)],
    ["noref", %(<lib xmlns="urn:t"><shelf><book><isbn>1</isbn><title>a</title></book></shelf>\n<loan isbn="2"/></lib>)],
  ],
}

CASES << {
  id: "content/choice-seq",
  xsd_string: <<~X,
    <xs:schema #{XS}>
      <xs:element name="r"><xs:complexType><xs:sequence>
        <xs:element name="a" minOccurs="0"/>
        <xs:choice maxOccurs="3"><xs:element name="b"/><xs:element name="c"/><xs:any namespace="urn:x" processContents="lax"/></xs:choice>
        <xs:element name="d" minOccurs="2" maxOccurs="4"/>
      </xs:sequence><xs:attribute name="x" type="xs:boolean" use="required"/></xs:complexType></xs:element>
    </xs:schema>
  X
  instances_inline: [
    ["ok", %(<r x="true"><a/><b/><c/><d/><d/></r>)],
    ["missing", %(<r x="1"><a/></r>)],
    ["unexpected", %(<r x="0"><e/></r>)],
    ["too-many", %(<r x="0"><b/><b/><b/><b/><d/><d/></r>)],
    ["attr", %(<r y="1"><b/><d/><d/></r>)],
    ["attr-bad", %(<r x="yes"><b/><d/><d/></r>)],
    ["text", %(<r x="true">hi<b/><d/><d/></r>)],
    ["d5", %(<r x="true"><b/><d/><d/><d/><d/><d/></r>)],
    ["any", %(<r x="true"><q:z xmlns:q="urn:x"/><d/><d/></r>)],
  ],
}

CASES << {
  id: "content/all",
  xsd_string: <<~X,
    <xs:schema #{XS}>
      <xs:element name="r"><xs:complexType><xs:all>
        <xs:element name="a"/><xs:element name="b" minOccurs="0"/><xs:element name="c"/>
      </xs:all></xs:complexType></xs:element>
    </xs:schema>
  X
  instances_inline: [
    ["ok", %(<r><c/><a/></r>)],
    ["dup", %(<r><a/><a/><c/></r>)],
    ["missing", %(<r><b/></r>)],
  ],
}

CASES << {
  id: "types/simple",
  xsd_string: <<~X,
    <xs:schema #{XS}>
      <xs:simpleType name="small"><xs:restriction base="xs:integer"><xs:minInclusive value="-3"/><xs:maxExclusive value="10"/></xs:restriction></xs:simpleType>
      <xs:simpleType name="code"><xs:restriction base="xs:token"><xs:pattern value="[A-Z]{2}\\d+"/><xs:maxLength value="5"/></xs:restriction></xs:simpleType>
      <xs:simpleType name="color"><xs:restriction base="xs:string"><xs:enumeration value="red"/><xs:enumeration value="green"/></xs:restriction></xs:simpleType>
      <xs:simpleType name="list"><xs:list itemType="small"/></xs:simpleType>
      <xs:simpleType name="shortlist"><xs:restriction base="list"><xs:length value="2"/></xs:restriction></xs:simpleType>
      <xs:simpleType name="u"><xs:union memberTypes="small color xs:date"/></xs:simpleType>
      <xs:simpleType name="dec"><xs:restriction base="xs:decimal"><xs:totalDigits value="4"/><xs:fractionDigits value="2"/></xs:restriction></xs:simpleType>
      <xs:element name="r"><xs:complexType><xs:sequence>
        <xs:element name="s" type="small" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="c" type="code" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="col" type="color" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="l" type="shortlist" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="u" type="u" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="d" type="dec" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="dt" type="xs:dateTime" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="f" type="xs:string" fixed="abc" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="q" type="xs:QName" minOccurs="0" maxOccurs="unbounded"/>
      </xs:sequence></xs:complexType></xs:element>
    </xs:schema>
  X
  instances_inline: [
    ["ok", %(<r><s>3</s><c>AB12</c><col>red</col><l>1 2</l><u>2020-01-01</u><d>12.34</d><dt>2001-10-26T21:32:52Z</dt><f>abc</f><f/><q>xs:int</q></r>)],
    ["bad", %(<r>\n<s>10</s>\n<s>-4</s>\n<c>AB123456</c>\n<c>ab1</c>\n<col>blue</col>\n<l>1 2 3</l>\n<l>1 x</l>\n<u>nope</u>\n<d>123.456</d>\n<d>12345</d>\n<dt>2001-13-26T21:32:52Z</dt>\n<f>abd</f>\n<q>zz:int</q></r>)],
  ],
}

CASES << {
  id: "xsi/type-nil",
  xsd_string: <<~X,
    <xs:schema #{XS}>
      <xs:complexType name="base"><xs:sequence><xs:element name="a" type="xs:int"/></xs:sequence></xs:complexType>
      <xs:complexType name="ext"><xs:complexContent><xs:extension base="base"><xs:sequence><xs:element name="b"/></xs:sequence></xs:extension></xs:complexContent></xs:complexType>
      <xs:complexType name="abs" abstract="true"/>
      <xs:element name="r"><xs:complexType><xs:sequence>
        <xs:element name="e" type="base" nillable="true" maxOccurs="unbounded"/>
        <xs:element name="n" type="xs:int" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="x" type="abs" minOccurs="0"/>
      </xs:sequence></xs:complexType></xs:element>
    </xs:schema>
  X
  instances_inline: [
    ["ok", %(<r xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><e><a>1</a></e><e xsi:type="ext"><a>1</a><b/></e><e xsi:nil="true"/></r>)],
    ["bad", %(<r xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n<e xsi:type="nope"><a>1</a></e>\n<e xsi:nil="true"><a>1</a></e>\n<e xsi:nil="maybe"><a>1</a></e>\n<e xsi:type="xs:int" xmlns:xs="http://www.w3.org/2001/XMLSchema">3</e>\n<n xsi:nil="true"/>\n<x/></r>)],
  ],
}

CASES << {
  id: "subst/groups",
  xsd_string: <<~X,
    <xs:schema #{XS}>
      <xs:element name="head" type="xs:string" abstract="true"/>
      <xs:element name="m1" type="xs:string" substitutionGroup="head"/>
      <xs:element name="m2" substitutionGroup="head"><xs:simpleType><xs:restriction base="xs:string"><xs:maxLength value="2"/></xs:restriction></xs:simpleType></xs:element>
      <xs:element name="r"><xs:complexType><xs:sequence><xs:element ref="head" maxOccurs="unbounded"/></xs:sequence></xs:complexType></xs:element>
    </xs:schema>
  X
  instances_inline: [
    ["ok", %(<r><m1>x</m1><m2>ab</m2></r>)],
    ["bad", %(<r><head>x</head><m2>abc</m2><zz/></r>)],
  ],
}

CASES << {
  id: "schema-errors/various",
  xsd_string: <<~X,
    <xs:schema #{XS}>
      <xs:element name="a" type="undefinedType"/>
      <xs:element name="b"><xs:complexType><xs:sequence><xs:element ref="nope"/></xs:sequence></xs:complexType></xs:element>
      <xs:attribute name="c" type="xs:int" default="x"/>
      <xs:simpleType name="d"><xs:restriction base="xs:int"><xs:maxLength value="3"/></xs:restriction></xs:simpleType>
      <xs:complexType name="e"><xs:choice><xs:element name="x"/><xs:element name="x" type="xs:int"/></xs:choice></xs:complexType>
      <xs:element name="f" minOccurs="1"/>
      <xs:group name="g"><xs:sequence><xs:group ref="g"/></xs:sequence></xs:group>
    </xs:schema>
  X
  instances_inline: [],
}

CASES << {
  id: "schema-errors/nondeterministic",
  xsd_string: <<~X,
    <xs:schema #{XS}>
      <xs:element name="r"><xs:complexType><xs:choice><xs:sequence><xs:element name="a"/><xs:element name="b"/></xs:sequence>
        <xs:sequence><xs:element name="a"/><xs:element name="c"/></xs:sequence></xs:choice></xs:complexType></xs:element>
    </xs:schema>
  X
  instances_inline: [["x", "<r><a/><b/></r>"]],
}
