# frozen_string_literal: true

# Schema documents exercising the parse phase of xmlschemas.c (worker B's range). Every case
# is expected to produce at least one parse-phase error in libxml2, so that xmlSchemaParse
# stops right after xmlSchemaParseNewDocWithContext and the native error list is exactly the
# list produced by the parse phase.
module UnitBCases
  XS = 'xmlns:xs="http://www.w3.org/2001/XMLSchema"'

  def self.s(body, attrs = "")
    %(<xs:schema #{XS}#{attrs.empty? ? "" : " " + attrs}>\n#{body}\n</xs:schema>\n)
  end

  FILES_DIR = File.expand_path("files", __dir__)

  CASES = {
    "illegal_attrs_element" => s(%(<xs:element name="a" minOccurs="1" foo="1" xs:bar="2" other:x="1" xmlns:other="urn:o"/>)),
    "element_missing_name" => s(%(<xs:element type="xs:string"/>)),
    "element_bad_name" => s(%(<xs:element name="1a"/>)),
    "element_ref_and_name" => s(%(<xs:complexType name="t"><xs:sequence><xs:element ref="b" name="a" type="xs:string" minOccurs="2"/></xs:sequence></xs:complexType><xs:element name="b"/>)),
    "element_default_fixed" => s(%(<xs:element name="a" default="1" fixed="2"/>)),
    "element_bad_block_final" => s(%(<xs:element name="a" block="foo" final="list" abstract="maybe" nillable="nope"/>)),
    "element_type_and_complex" => s(%(<xs:element name="a" type="xs:string"><xs:complexType/></xs:element><xs:element name="b" type="xs:string"><xs:simpleType><xs:restriction base="xs:string"/></xs:simpleType></xs:element>)),
    "element_bad_children" => s(%(<xs:element name="a"><xs:annotation/><xs:sequence/></xs:element>)),
    "element_form_invalid" => s(%(<xs:complexType name="t"><xs:sequence><xs:element name="a" form="bogus"/></xs:sequence></xs:complexType>)),
    "occurs_invalid" => s(%(<xs:complexType name="t"><xs:sequence><xs:element name="a" minOccurs="-1"/><xs:element name="b" maxOccurs="abc"/><xs:element name="c" minOccurs="unbounded"/><xs:element name="d" minOccurs=" "/><xs:element name="e" maxOccurs=" 3x"/></xs:sequence></xs:complexType>)),
    "occurs_particle_correct" => s(%(<xs:complexType name="t"><xs:sequence><xs:element name="a" minOccurs="1" maxOccurs="0"/><xs:element name="b" minOccurs="5" maxOccurs="2"/><xs:any minOccurs="3" maxOccurs="1"/></xs:sequence></xs:complexType>)),
    "occurs_huge" => s(%(<xs:complexType name="t"><xs:sequence><xs:element name="a" maxOccurs="99999999999999"/><xs:element name="b" minOccurs=" 2 " maxOccurs=" 3 "/></xs:sequence></xs:complexType>)),
    "all_limited" => s(%(<xs:complexType name="t"><xs:all minOccurs="2" maxOccurs="unbounded"><xs:element name="a" maxOccurs="2"/><xs:element name="b" minOccurs="3" maxOccurs="4"/></xs:all></xs:complexType>)),
    "attr_local_errors" => s(%(<xs:complexType name="t"><xs:attribute name="a" use="bogus"/><xs:attribute name="b" default="1" use="required"/><xs:attribute name="c" default="1" fixed="2"/><xs:attribute name="d" form="x"/><xs:attribute foo="1"/></xs:complexType>)),
    "attr_local_missing_name" => s(%(<xs:complexType name="t"><xs:attribute type="xs:string"/></xs:complexType>)),
    "attr_xmlns" => s(%(<xs:complexType name="t"><xs:attribute name="xmlns"/></xs:complexType><xs:attribute name="xmlns"/>)),
    "attr_xsi" => s(%(<xs:attribute name="a"/><xs:complexType name="t"><xs:attribute name="b" form="qualified"/></xs:complexType><xs:element name="x" foo="1"/>), %(targetNamespace="http://www.w3.org/2001/XMLSchema-instance")),
    "attr_type_and_simple" => s(%(<xs:attribute name="a" type="xs:string"><xs:simpleType><xs:restriction base="xs:string"/></xs:simpleType></xs:attribute><xs:complexType name="t"><xs:attribute name="b" type="xs:int"><xs:simpleType><xs:restriction base="xs:string"/></xs:simpleType><xs:annotation/></xs:attribute></xs:complexType>)),
    "attr_ref_children" => s(%(<xs:attribute name="g"/><xs:complexType name="t"><xs:attribute ref="g" type="xs:int"/><xs:attribute ref="g"><xs:simpleType/></xs:attribute></xs:complexType><xs:complexType name="t2"><xs:attribute ref="g"><xs:sequence/></xs:attribute></xs:complexType>)),
    "attr_global_errors" => s(%(<xs:attribute name="a" default="1" fixed="2" use="required" form="qualified"/><xs:attribute/>)),
    "attr_prohibited_dupl" => s(%(<xs:complexType name="t"><xs:attribute name="a" use="prohibited"/><xs:attribute name="a" use="prohibited"><xs:annotation/><xs:sequence/></xs:attribute></xs:complexType><xs:attributeGroup name="g"><xs:attribute name="p" use="prohibited"/></xs:attributeGroup><xs:element name="z" bad="1"/>)),
    "attr_group_errors" => s(%(<xs:attributeGroup name="g" foo="1"><xs:attribute name="a"/><xs:anyAttribute/><xs:attribute name="b"/></xs:attributeGroup><xs:attributeGroup/><xs:complexType name="t"><xs:attributeGroup/><xs:attributeGroup ref="g" bar="1"><xs:annotation/><xs:annotation/></xs:attributeGroup></xs:complexType>)),
    "any_errors" => s(%(<xs:complexType name="t"><xs:sequence><xs:any processContents="bogus" namespace="##other ##any" foo="1"/><xs:any namespace="##local ##targetNamespace ##local urn:x"><xs:sequence/></xs:any></xs:sequence><xs:anyAttribute processContents="x" namespace="##any"/></xs:complexType>)),
    "any_attribute_bad_ns" => s(%(<xs:complexType name="t"><xs:anyAttribute namespace="##other"/></xs:complexType><xs:attributeGroup name="g"><xs:anyAttribute namespace="  ##any  " id="1x"/></xs:attributeGroup>)),
    "annotation_errors" => s(%(<xs:annotation foo="1" id="a"><xs:appinfo bar="1" source="x"/><xs:documentation xml:lang="en" source="y" baz="1"/><xs:element/><xs:other/></xs:annotation><xs:element name="a"><xs:annotation><xs:documentation xs:lang="x" other:lang="y" xmlns:other="urn:o"/></xs:annotation></xs:element>)),
    "duplicate_ids" => s(%(<xs:element name="a" id="x1"/><xs:element name="b" id="x1"/><xs:element name="c" id="1bad"/><xs:simpleType name="s" id="  x1  "><xs:restriction base="xs:string"/></xs:simpleType>)),
    "simple_type_errors" => s(%(<xs:simpleType name="a"/><xs:simpleType name="b"><xs:annotation/></xs:simpleType><xs:simpleType name="c"><xs:restriction base="xs:string"/><xs:list itemType="xs:string"/></xs:simpleType><xs:simpleType/><xs:simpleType name="d" final="bogus" foo="1"><xs:restriction base="xs:string"/></xs:simpleType>)),
    "simple_type_local_attrs" => s(%(<xs:element name="e"><xs:simpleType name="x" final="list"><xs:restriction base="xs:string"/></xs:simpleType></xs:element>)),
    "list_errors" => s(%(<xs:simpleType name="a"><xs:list/></xs:simpleType><xs:simpleType name="b"><xs:list itemType="xs:string"><xs:simpleType><xs:restriction base="xs:string"/></xs:simpleType></xs:list></xs:simpleType><xs:simpleType name="c"><xs:list foo="1"><xs:annotation/><xs:sequence/></xs:list></xs:simpleType>)),
    "union_errors" => s(%(<xs:simpleType name="a"><xs:union/></xs:simpleType><xs:simpleType name="b"><xs:union memberTypes="xs:string  1bad p:x"><xs:sequence/></xs:union></xs:simpleType>)),
    "restriction_simple_errors" => s(%(<xs:simpleType name="a"><xs:restriction/></xs:simpleType><xs:simpleType name="b"><xs:restriction base="xs:string"><xs:simpleType><xs:restriction base="xs:string"/></xs:simpleType></xs:restriction></xs:simpleType><xs:simpleType name="c"><xs:restriction base="xs:string" foo="1"><xs:length value="1"/><xs:sequence/></xs:restriction></xs:simpleType>)),
    "facet_errors" => s(%(<xs:simpleType name="a"><xs:restriction base="xs:string"><xs:length/><xs:pattern value="x"><xs:annotation/><xs:foo/></xs:pattern><xs:maxLength value="3" fixed="true"/></xs:restriction></xs:simpleType>)),
    "complex_type_errors" => s(%(<xs:complexType name="a" mixed="maybe" abstract="x" final="bogus" block="bogus" foo="1"/><xs:complexType/><xs:complexType name="b"><xs:sequence/><xs:choice/></xs:complexType><xs:element name="e"><xs:complexType name="n" abstract="true"/></xs:element>)),
    "complex_content_errors" => s(%(<xs:complexType name="a"><xs:complexContent/></xs:complexType><xs:complexType name="b"><xs:complexContent mixed="foo" bar="1"><xs:restriction/></xs:complexContent></xs:complexType><xs:complexType name="c"><xs:complexContent><xs:extension base="xs:anyType"><xs:sequence/><xs:sequence/></xs:extension></xs:complexContent></xs:complexType>)),
    "simple_content_errors" => s(%(<xs:complexType name="a"><xs:simpleContent/></xs:complexType><xs:complexType name="b"><xs:simpleContent foo="1"><xs:extension/></xs:simpleContent></xs:complexType><xs:complexType name="c"><xs:simpleContent><xs:restriction base="xs:string"><xs:length value="1"/><xs:sequence/></xs:restriction></xs:simpleContent></xs:complexType>)),
    "restriction_complex_errors" => s(%(<xs:complexType name="a"><xs:complexContent><xs:restriction base="xs:anyType"><xs:sequence/><xs:attribute name="x"/><xs:element name="y"/></xs:restriction></xs:complexContent></xs:complexType>)),
    "group_errors" => s(%(<xs:group name="g"><xs:sequence/><xs:choice/></xs:group><xs:group/><xs:group name="h" foo="1"><xs:all><xs:element name="a"/><xs:any/></xs:all></xs:group><xs:complexType name="t"><xs:sequence><xs:group/><xs:group ref="g" foo="1" minOccurs="x"><xs:sequence/></xs:group></xs:sequence></xs:complexType>)),
    "sequence_bad_child" => s(%(<xs:complexType name="t"><xs:sequence foo="1"><xs:element name="a"/><xs:attribute name="b"/></xs:sequence></xs:complexType><xs:group name="g"><xs:choice minOccurs="0"/></xs:group>)),
    "idc_errors" => s(%(<xs:element name="a"><xs:complexType/><xs:key name="k"/><xs:unique/><xs:keyref name="kr"><xs:selector xpath="."/><xs:field xpath="@a"/></xs:keyref><xs:key name="k2" foo="1"><xs:field xpath="a"/></xs:key><xs:unique name="u"><xs:selector/><xs:field xpath="a"/></xs:unique></xs:element>)),
    "idc_xpath_errors" => s(%(<xs:element name="a"><xs:key name="k"><xs:selector xpath="///"/><xs:field xpath="@@a" foo="1"/><xs:field xpath="p:a"/></xs:key></xs:element>)),
    "qname_undeclared_prefix" => s(%(<xs:element name="a" type="p:t"/><xs:element name="b" substitutionGroup="q:x"/><xs:attribute name="c" type="r:t"/>)),
    "src_resolve" => s(%(<xs:element name="a" type="t"/><xs:element name="b" type="o:t" xmlns:o="urn:other"/><xs:complexType name="c"><xs:sequence><xs:element ref="o:r" xmlns:o="urn:other"/><xs:group ref="o:g" xmlns:o="urn:other"/></xs:sequence><xs:attribute ref="o:a" xmlns:o="urn:other"/><xs:attributeGroup ref="o:ag" xmlns:o="urn:other"/></xs:complexType>), %(targetNamespace="urn:tns")),
    "schema_attr_errors" => s(%(<xs:element name="a"/>), %(elementFormDefault="x" attributeFormDefault="y" finalDefault="bogus" blockDefault="list" id="1bad")),
    "schema_tns_invalid" => s(%(<xs:element name="a" foo="1"/>), %(targetNamespace="a b%")),
    "top_level_bad_children" => s(%(<xs:element name="a"/><xs:sequence/><xs:annotation/><xs:foo/><xs:import namespace="urn:x"/>)),
    "notation_errors" => s(%(<xs:notation/><xs:notation name="n" public="x"><xs:annotation/><xs:foo/></xs:notation><xs:element name="a" bad="1"/>)),
    "import_errors_1_1" => s(%(<xs:import namespace="urn:tns"/><xs:element name="a"/>), %(targetNamespace="urn:tns")),
    "import_errors_1_2" => s(%(<xs:import/><xs:element name="a"/>)),
    "import_bad_attrs" => s(%(<xs:import namespace="urn:x" foo="1"><xs:annotation/><xs:foo/></xs:import><xs:element name="a" bad="1"/>)),
    "include_missing" => s(%(<xs:include schemaLocation="does-not-exist-unit-b.xsd"/><xs:element name="a"/>)),
    "include_no_location" => s(%(<xs:include/><xs:element name="a"/>)),
    "redefine_missing" => s(%(<xs:redefine schemaLocation="does-not-exist-unit-b.xsd"/><xs:element name="a"/>)),
    "import_missing_warning" => s(%(<xs:import namespace="urn:x" schemaLocation="does-not-exist-unit-b.xsd"/><xs:element name="a" bad="1"/>)),
    "not_schema_root" => %(<foo/>),
    "cdata_toplevel" => s(%(<![CDATA[x]]><xs:element name="a"/>)),
    "comments_pi" => s(%(<!-- c --><?pi x?><xs:element name="a"><!-- c --></xs:element><xs:element name="b" bad="1"/>)),
    "text_in_element" => s(%(<xs:element name="a">text</xs:element>)),
    "attr_ref_xsi" => s(%(<xs:complexType name="t"><xs:attribute ref="xsi:type" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"/></xs:complexType>)),
    "prohibited_in_extension" => s(%(<xs:complexType name="t"><xs:complexContent><xs:extension base="xs:anyType"><xs:attribute name="a" use="prohibited"/><xs:attribute ref="xml:lang" use="prohibited"/></xs:extension></xs:complexContent></xs:complexType><xs:element name="z" bad="1"/>)),
    "keyref_no_refer" => s(%(<xs:element name="a"><xs:keyref name="k" refer="p:x"><xs:selector xpath="a"/><xs:field xpath="b"/></xs:keyref><xs:keyref name="k2"><xs:selector xpath="a"/><xs:field xpath="b"/></xs:keyref></xs:element>)),
    "mixed_simple_content" => s(%(<xs:complexType name="t" mixed="true"><xs:simpleContent><xs:extension base="xs:string"><xs:attribute name="a"/><xs:anyAttribute/><xs:foo/></xs:extension></xs:simpleContent></xs:complexType>)),
    "local_named_complex" => s(%(<xs:element name="e"><xs:complexType mixed="1" block="#all"><xs:sequence minOccurs="0" maxOccurs="0"><xs:element name="x"/></xs:sequence></xs:complexType></xs:element><xs:element name="f" block="restriction substitution" final="#all" abstract="true" nillable="0" bad="x"/>)),
    "id_whitespace_dup" => s(%(<xs:element name="a" id="i"/><xs:attribute name="b" id=" i "/><xs:group name="g" id="i2"><xs:sequence id="i2"/></xs:group>)),
  }.freeze

  # file based cases: main file path relative to FILES_DIR
  FILE_CASES = {
    "file_include_ok_then_error" => "inc_main.xsd",
    "file_include_tns_mismatch" => "inc_tns_main.xsd",
    "file_include_chameleon" => "cham_main.xsd",
    "file_import_ok" => "imp_main.xsd",
    "file_include_self" => "self_inc.xsd",
    "file_include_not_schema" => "inc_notschema_main.xsd",
    "file_redefine" => "redef_main.xsd",
    "file_redefine_errors" => "redef_err_main.xsd",
    "file_import_twice" => "imp_twice_main.xsd",
    "file_nested_includes" => "nested_main.xsd",
    "file_chameleon_twice" => "cham2_main.xsd",
  }.freeze
end
