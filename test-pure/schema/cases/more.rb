F = File.join(File.dirname(__FILE__), "files")
CASES << {
  id: "include-import", xsd: File.join(F, "main_include.xsd"), files: false,
  instances_inline: [
    ["ok", %(<root xmlns="urn:m"><cham>ab</cham><thing xmlns="urn:o">3</thing></root>)],
    ["bad", %(<root xmlns="urn:m"><cham>abcd</cham>\n<thing xmlns="urn:o">x</thing></root>)],
  ],
}
CASES << {
  id: "redefine", xsd: File.join(F, "redef.xsd"), files: false,
  instances_inline: [
    ["ok", %(<r a2="1"><p><name>n</name><age>3</age></p><c>ab</c><x/><y/></r>)],
    ["bad", %(<r a1="1"><p><name>n</name></p><c>abc</c><x/></r>)],
  ],
}
XS2 = 'xmlns:xs="http://www.w3.org/2001/XMLSchema"'
CASES << {
  id: "ids-notations",
  xsd_string: <<~X,
    <xs:schema #{XS2}>
      <xs:notation name="png" public="image/png"/>
      <xs:simpleType name="nt"><xs:restriction base="xs:NOTATION"><xs:enumeration value="png"/></xs:restriction></xs:simpleType>
      <xs:element name="r"><xs:complexType><xs:sequence>
        <xs:element name="e" maxOccurs="unbounded"><xs:complexType>
          <xs:attribute name="id" type="xs:ID"/><xs:attribute name="ref" type="xs:IDREF"/><xs:attribute name="refs" type="xs:IDREFS"/>
          <xs:attribute name="n" type="nt"/><xs:attribute name="toks" type="xs:NMTOKENS"/>
        </xs:complexType></xs:element>
      </xs:sequence><xs:anyAttribute namespace="##other" processContents="lax"/></xs:complexType></xs:element>
    </xs:schema>
  X
  instances_inline: [
    ["ok", %(<r xmlns:q="urn:q" q:x="1"><e id="a" n="png" toks="a b"/><e id="b" ref="a" refs="a b"/></r>)],
    ["bad", %(<r x="1">\n<e id="a"/>\n<e id="a"/>\n<e ref="zz" refs=""/>\n<e n="jpg" toks=""/>\n<e id="1x"/></r>)],
  ],
}
CASES << {
  id: "mixed-default",
  xsd_string: <<~X,
    <xs:schema #{XS2}>
      <xs:element name="r"><xs:complexType mixed="true"><xs:sequence>
        <xs:element name="d" type="xs:int" default="5" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="m" minOccurs="0" fixed="fx"><xs:complexType mixed="true"><xs:sequence><xs:element name="z" minOccurs="0"/></xs:sequence></xs:complexType></xs:element>
      </xs:sequence><xs:attribute name="at" type="xs:int" default="7"/><xs:attribute name="fa" type="xs:decimal" fixed="1.0"/></xs:complexType></xs:element>
    </xs:schema>
  X
  instances_inline: [
    ["ok", %(<r fa="1.00">text<d/><d>3</d><m>fx</m></r>)],
    ["bad", %(<r fa="2">text<d>x</d>\n<m>fy</m>\n<m><z/></m></r>)],
  ],
}
CASES << {
  id: "empty-and-simple",
  xsd_string: <<~X,
    <xs:schema #{XS2}>
      <xs:element name="r"><xs:complexType><xs:sequence>
        <xs:element name="e" minOccurs="0" maxOccurs="unbounded"><xs:complexType/></xs:element>
        <xs:element name="s" type="xs:int" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="sc" minOccurs="0" maxOccurs="unbounded"><xs:complexType><xs:simpleContent><xs:extension base="xs:date"><xs:attribute name="u"/></xs:extension></xs:simpleContent></xs:complexType></xs:element>
      </xs:sequence></xs:complexType></xs:element>
    </xs:schema>
  X
  instances_inline: [
    ["bad", %(<r>\n<e>t</e>\n<e><x/></e>\n<s><x/></s>\n<s a="1">1</s>\n<sc u="1" v="2">2020-02-30</sc>\n<sc><x/></sc></r>)],
    ["nsroot", %(<r xmlns="urn:nope"/>)],
    ["unknownroot", %(<zz/>)],
  ],
}
CASES << {
  id: "stream-files", xsd: File.join(F, "stream/r.xsd"), files: true,
  instances: Dir[File.join(F, "stream/m*.xml")].sort,
}
