# frozen_string_literal: true

# Unit tests for lib/nokogiri/pure/schemas/errors.rb and components.rb (worker A).
# Expected strings come from the native nokogiri 1.19.4 / libxml2 2.13.9 gem (see comments) or
# from reading xmlschemas.c. Run: ruby -Ilib test-pure/schema/unit_a/test_errors_components.rb

$LOAD_PATH.unshift(File.expand_path("../../../lib", __dir__))
require "minitest/autorun"
require "nokogiri"
require "nokogiri/pure/schemas/components"

S = Nokogiri::Pure::Schemas
P = Nokogiri::Pure
T = P::Tree

# Stubs for functions owned by other workers, only if they are not loaded yet.
module Nokogiri
  module Pure
    module Schemas
      unless method_defined?(:facet_type_to_string)
        def facet_type_to_string(type)
          { XML_SCHEMA_FACET_PATTERN => "pattern", XML_SCHEMA_FACET_MAXEXCLUSIVE => "maxExclusive",
            XML_SCHEMA_FACET_MAXINCLUSIVE => "maxInclusive", XML_SCHEMA_FACET_MINEXCLUSIVE => "minExclusive",
            XML_SCHEMA_FACET_MININCLUSIVE => "minInclusive", XML_SCHEMA_FACET_WHITESPACE => "whiteSpace",
            XML_SCHEMA_FACET_ENUMERATION => "enumeration", XML_SCHEMA_FACET_LENGTH => "length",
            XML_SCHEMA_FACET_MAXLENGTH => "maxLength", XML_SCHEMA_FACET_MINLENGTH => "minLength",
            XML_SCHEMA_FACET_TOTALDIGITS => "totalDigits",
            XML_SCHEMA_FACET_FRACTIONDIGITS => "fractionDigits" }.fetch(type, "Internal Error")
        end
      end
      unless method_defined?(:get_white_space_facet_value)
        def get_white_space_facet_value(_type) = XML_SCHEMA_WHITESPACE_PRESERVE
      end
      unless const_defined?(:Types, false)
        # minimal stand-in: values are FakeVal
        FakeVal = Struct.new(:vt, :str, :canon, :nxt)
        module Types
          extend self
          def value_get_next(v) = v.nxt
          def get_val_type(v) = v.vt
          def value_get_as_string(v) = v.str
          def collapse_string(_s) = nil
          def white_space_replace(_s) = nil
          def get_canon_value(v) = [0, v.canon.dup]
          def get_facet_value_as_u_long(f) = f.value.to_i
          def get_predefined_type(_n, _ns) = nil
        end
      end
    end
  end
end

class TestSchemasWorkerA < Minitest::Test
  XS = S::XML_SCHEMAS_NS

  def setup
    @doc = T.new_doc
    @errors = []
    @pctxt = S::SchemaParserCtxt.new(serror: ->(e) { @errors << e })
    @xsns = P::XmlNs.new(XS, "xs")
  end

  def xs_elem(name = "element")
    n = T.new_doc_node(@doc, @xsns, name)
    n.line = 1
    n
  end

  # ---------------------------------------------------------------- formatting helpers

  def test_format_q_name
    assert_equal "{urn:x}a", S.format_q_name("urn:x", "a")
    assert_equal "a", S.format_q_name(nil, "a")
    assert_equal "(NULL)", S.format_q_name(nil, nil)
    assert_equal "{urn:x}(NULL)", S.format_q_name("urn:x", nil)
    assert_equal "{urn:x}a", S.format_q_name_ns(P::XmlNs.new("urn:x", "p"), "a")
  end

  def test_item_type_and_designation
    t = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_COMPLEX, name: "t", target_namespace: "urn:t")
    assert_equal "complex type definition '{urn:t}t'", S.get_component_designation(t)
    b = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_BASIC, name: "anyType", built_in_type: S::XML_SCHEMAS_ANYTYPE)
    assert_equal "complex type definition '{#{XS}}anyType'", S.get_component_designation(b)
    b2 = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_BASIC, name: "string", built_in_type: S::XML_SCHEMAS_STRING)
    assert_equal "simple type definition '{#{XS}}string'", S.get_component_designation(b2)
    # native: "... The attribute use 'x' violates this constraint."
    au = S::SchemaAttributeUse.new(attr_decl: S::SchemaAttribute.new(name: "x"))
    assert_equal "attribute use 'x'", S.get_component_designation(au)
    idc = S::SchemaIDC.new(type: S::XML_SCHEMA_TYPE_IDC_KEYREF, name: "k", target_namespace: nil)
    assert_equal "keyref identity-constraint 'k'", S.get_idc_designation(idc)
    assert_equal "Not a schema component", S.item_type_to_str(999)
    assert_equal "invalid process contents", S.wildcard_pc_to_string(0)
  end

  def test_format_item_for_report
    atomic = S::XML_SCHEMAS_TYPE_VARIETY_ATOMIC
    glob = S::XML_SCHEMAS_TYPE_GLOBAL
    # native: "atomic type 's': The facet 'totalDigits' is not allowed on types derived from
    # the type atomic type 'xs:string'."
    st = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE, name: "s", flags: atomic | glob)
    assert_equal "atomic type 's'", S.format_item_for_report(nil, st, nil)
    bt = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_BASIC, name: "string", flags: atomic)
    assert_equal "atomic type 'xs:string'", S.format_item_for_report(nil, bt, nil)
    lt = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE, name: "s", flags: S::XML_SCHEMAS_TYPE_VARIETY_LIST)
    assert_equal "local list type", S.format_item_for_report(nil, lt, nil)
    ct = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_COMPLEX, name: "t", flags: glob)
    assert_equal "complex type 't'", S.format_item_for_report(nil, ct, nil)
    ct.flags = 0
    assert_equal "local complex type", S.format_item_for_report(nil, ct, nil)
    el = S::SchemaElement.new(name: "a", target_namespace: "urn:t")
    assert_equal "element decl. '{urn:t}a'", S.format_item_for_report(nil, el, nil)
    at = S::SchemaAttribute.new(name: "a")
    assert_equal "attribute decl. 'a'", S.format_item_for_report(nil, at, nil)
    ag = S::SchemaAttributeGroup.new(name: "g", target_namespace: "urn:t")
    assert_equal "attribute group definition '{urn:t}g'", S.format_item_for_report(nil, ag, nil)
    assert_equal "attribute use (unknown)", S.format_item_for_report(nil, S::SchemaAttributeUse.new, nil)
    wc = S::SchemaWildcard.new(type: S::XML_SCHEMA_TYPE_ANY_ATTRIBUTE, process_contents: S::XML_SCHEMAS_ANY_LAX)
    assert_equal "lax wildcard", S.format_item_for_report(nil, wc, nil)
    mg = S::SchemaModelGroupDef.new(name: "g")
    assert_equal "model group def. 'g'", S.format_item_for_report(nil, mg, nil)
    assert_equal "model group (choice)", S.format_item_for_report(nil, S::SchemaModelGroup.new(type: S::XML_SCHEMA_TYPE_CHOICE), nil)
    assert_equal "keyRef 'k'", S.format_item_for_report(nil, S::SchemaIDC.new(type: S::XML_SCHEMA_TYPE_IDC_KEYREF, name: "k"), nil)
    assert_equal "facet 'maxLength'", S.format_item_for_report(nil, S::SchemaFacet.new(type: S::XML_SCHEMA_FACET_MAXLENGTH), nil)
    nota = S::SchemaNotation.new(name: "n")
    assert_equal "notation declaration 'n'", S.format_item_for_report(nil, nota, nil)
    # notation falls through to "unnamed": the node overrides it
    e = xs_elem
    assert_equal "Element '{#{XS}}element'", S.format_item_for_report(nil, nota, e)
    # node-only; attribute node appends ", attribute '...'"
    attr = T.new_prop(e, "maxOccurs", "0")
    assert_equal "Element '{#{XS}}element', attribute 'maxOccurs'", S.format_item_for_report(nil, nil, attr)
    assert_equal "des, attribute 'maxOccurs'", S.format_item_for_report("des", nil, attr)
    assert_nil S.format_item_for_report(nil, nil, nil)
    # escaping of '%'
    el2 = S::SchemaElement.new(name: "a%s")
    assert_equal "element decl. 'a%%s'", S.format_item_for_report(nil, el2, nil)
    plain = T.new_doc_node(@doc, nil, "plain")
    assert_equal "Element 'plain'", S.format_item_for_report(nil, nil, plain)
  end

  def test_format_node_for_error
    e = xs_elem
    assert_equal "Element '{#{XS}}element': ", S.format_node_for_error(@pctxt, e)
    a = T.new_prop(e, "min%", "x")
    assert_equal "Element '{#{XS}}element', attribute 'min%%': ", S.format_node_for_error(@pctxt, a)
    assert_equal "", S.format_node_for_error(@pctxt, nil)
    assert_equal "", S.format_node_for_error(@pctxt, T.new_doc_text(@doc, "x"))
    v = S::SchemaValidCtxt.new(depth: 1)
    v.elem_infos = [nil, S::SchemaNodeInfo.new(local_name: "r", ns_name: "urn:t", node_type: P::ELEMENT_NODE)]
    v.inode = S::SchemaAttrInfo.new(local_name: "at", ns_name: nil, node_type: P::ATTRIBUTE_NODE)
    assert_equal "Element '{urn:t}r', attribute 'at': ", S.format_node_for_error(v, nil)
    v.inode = v.elem_infos[1]
    assert_equal "Element '{urn:t}r': ", S.format_node_for_error(v, nil)
  end

  def test_complex_type_err_expected_list
    v = S::SchemaValidCtxt.new(depth: 0, serror: ->(e) { @errors << e })
    v.inode = S::SchemaNodeInfo.new(local_name: "r", ns_name: "urn:t", node_type: P::ELEMENT_NODE)
    vals = ["e|urn:t", "l|urn:t", "not *|urn:t", "z|urn:t"]
    S.complex_type_err(v, P::ErrCode::SCHEMAV_ELEMENT_CONTENT, nil, nil, "Missing child element(s)", 4, 0, vals)
    # native: "Element '{urn:t}r': Missing child element(s). Expected is one of ( {urn:t}e, ...,
    # ##other{urn:t}*, {urn:t}z )."
    assert_equal "Element '{urn:t}r': Missing child element(s). Expected is one of ( {urn:t}e, {urn:t}l, ##other{urn:t}*, {urn:t}z ).\n",
      @errors.last.message
    assert_equal P::Domain::SCHEMASV, @errors.last.domain
    S.complex_type_err(v, P::ErrCode::SCHEMAV_ELEMENT_CONTENT, nil, nil, "This element is not expected", 0, 0, [])
    assert_equal "Element '{urn:t}r': This element is not expected.\n", @errors.last.message
    S.complex_type_err(v, 1871, nil, nil, "x", 1, 2, ["a", "*|b", "*|*"])
    # negated: "*|b" -> "{##other:b}*"; "*|*" with nbneg skipped (the separator of the previous
    # entry stays, as in C)
    assert_equal "Element '{urn:t}r': x. Expected is one of ( a, {##other:b}*,  ).\n", @errors.last.message
    assert_equal 3, v.nberrors
    assert_equal 1871, v.err
  end

  # ---------------------------------------------------------------- parser error functions

  def test_p_missing_attr_err
    e = xs_elem
    S.p_missing_attr_err(@pctxt, P::ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, e, "name", nil)
    err = @errors.last
    assert_equal "Element '{#{XS}}element': The attribute 'name' is required but missing.\n", err.message
    assert_equal 3036, err.code
    assert_equal P::Domain::SCHEMASP, err.domain
    assert_equal P::Level::ERROR, err.level
    assert_equal "Element '{#{XS}}element'", err.str1
    assert_equal "name", err.str2
    assert_nil err.str3
    assert_equal 1, err.line
    assert_same e, err.node
    assert_equal 1, @pctxt.nberrors
    assert_equal 3036, @pctxt.err
  end

  def test_p_illegal_attr_err
    e = xs_elem
    a = T.new_prop(e, "foo", "1")
    S.p_illegal_attr_err(@pctxt, P::ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, a)
    err = @errors.last
    assert_equal "Element '{#{XS}}element': The attribute 'foo' is not allowed.\n", err.message
    assert_equal "Element '{#{XS}}element': ", err.str1
    assert_equal "foo", err.str2
    assert_equal 1, err.line
    assert_same e, err.node # xmlVUpdateError walks up to the element
  end

  def test_p_res_comp_attr_err
    e = xs_elem
    el = S::SchemaElement.new(name: "a")
    S.p_res_comp_attr_err(@pctxt, P::ErrCode::SCHEMAP_SRC_RESOLVE, el, e, "type", "foo", XS,
      S::XML_SCHEMA_TYPE_SIMPLE, "type definition")
    err = @errors.last
    assert_equal "element decl. 'a', attribute 'type': The QName value '{#{XS}}foo' does not resolve to a(n) type definition.\n", err.message
    assert_nil err.str1
    S.p_res_comp_attr_err(@pctxt, 1, el, e, "ref", "g", nil, S::XML_SCHEMA_TYPE_GROUP, nil)
    assert_equal "element decl. 'a', attribute 'ref': The QName value 'g' does not resolve to a(n) model group definition.\n", @errors.last.message
  end

  def test_p_simple_type_err
    e = xs_elem
    a = T.new_prop(e, "minOccurs", "x")
    S.p_simple_type_err(@pctxt, P::ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, a, nil,
      "xs:nonNegativeInteger", "x", nil, nil, nil)
    err = @errors.last
    assert_equal "Element '{#{XS}}element', attribute 'minOccurs': The value 'x' is not valid. Expected is 'xs:nonNegativeInteger'.\n", err.message
    assert_equal "x", err.str1
    # type given: native "..., attribute 'nillable': 'maybe' is not a valid value of the
    # atomic type 'xs:boolean'."
    bt = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_BASIC, name: "boolean",
      built_in_type: S::XML_SCHEMAS_BOOLEAN, flags: S::XML_SCHEMAS_TYPE_VARIETY_ATOMIC)
    a2 = T.new_prop(e, "nillable", "maybe")
    S.p_simple_type_err(@pctxt, P::ErrCode::SCHEMAP_INVALID_BOOLEAN, nil, a2, bt, nil, "maybe", nil, nil, nil)
    assert_equal "Element '{#{XS}}element', attribute 'nillable': 'maybe' is not a valid value of the atomic type 'xs:boolean'.\n",
      @errors.last.message
    # native (pct case): value with '%' is an argument, not part of the format
    S.p_simple_type_err(@pctxt, 1824, nil, a2, bt, nil, "a%s", nil, nil, nil)
    assert_equal "Element '{#{XS}}element', attribute 'nillable': 'a%s' is not a valid value of the atomic type 'xs:boolean'.\n",
      @errors.last.message
    # custom message
    S.p_simple_type_err(@pctxt, 1, nil, e, nil, nil, nil, "Foo '%s' bar '%s'", "A", "B")
    assert_equal "Element '{#{XS}}element': Foo 'A' bar 'B'.\n", @errors.last.message
    assert_nil @errors.last.str1 # strData1..3 of xmlSchemaPErrExt are NULL here
  end

  def test_p_custom_attr_err_and_mutual_excl
    e = xs_elem
    a = T.new_prop(e, "maxOccurs", "0")
    S.p_custom_attr_err(@pctxt, P::ErrCode::SCHEMAP_P_PROPS_CORRECT_2_2, nil, nil, a,
      "The value must be greater than or equal to 1")
    assert_equal "Element '{#{XS}}element', attribute 'maxOccurs': The value must be greater than or equal to 1.\n",
      @errors.last.message
    assert_equal 3044, @errors.last.code
    d = T.new_prop(e, "default", "1")
    S.p_mutual_excl_attr_err(@pctxt, P::ErrCode::SCHEMAP_SRC_ELEMENT_1, nil, d, "default", "fixed")
    assert_equal "Element '{#{XS}}element': The attributes 'default' and 'fixed' are mutually exclusive.\n",
      @errors.last.message
  end

  def test_p_content_err_and_facets
    e = xs_elem
    child = xs_elem("foo")
    S.p_content_err(@pctxt, P::ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, e, child, nil,
      "(annotation?, ((simpleType | complexType)?, (unique | key | keyref)*))")
    err = @errors.last
    assert_equal "Element '{#{XS}}element': The content is not valid. Expected is (annotation?, ((simpleType | complexType)?, (unique | key | keyref)*)).\n", err.message
    assert_same child, err.node
    assert_equal "Element '{#{XS}}element'", err.str1

    st = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE, name: "s", node: e,
      flags: S::XML_SCHEMAS_TYPE_VARIETY_ATOMIC | S::XML_SCHEMAS_TYPE_GLOBAL)
    bt = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_BASIC, name: "string", flags: S::XML_SCHEMAS_TYPE_VARIETY_ATOMIC)
    f = S::SchemaFacet.new(type: S::XML_SCHEMA_FACET_TOTALDIGITS)
    S.p_illegal_facet_atomic_err(@pctxt, P::ErrCode::SCHEMAP_INVALID_FACET, st, bt, f)
    assert_equal "atomic type 's': The facet 'totalDigits' is not allowed on types derived from the type atomic type 'xs:string'.\n", @errors.last.message
    lt = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE, name: "s2", node: e,
      flags: S::XML_SCHEMAS_TYPE_VARIETY_LIST | S::XML_SCHEMAS_TYPE_GLOBAL)
    S.p_illegal_facet_list_union_err(@pctxt, P::ErrCode::SCHEMAP_INVALID_FACET_VALUE, lt, f)
    assert_equal "list type 's2': The facet 'totalDigits' is not allowed.\n", @errors.last.message
    assert_equal "list type 's2'", @errors.last.str1
    assert_equal "totalDigits", @errors.last.str2
  end

  def test_custom_err_parser_with_item
    # native: "complex type 't': There must not exist more than one attribute declaration of
    # type 'xs:ID' (or derived from 'xs:ID'). The attribute use 'x' violates this constraint."
    e = xs_elem("complexType")
    ct = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_COMPLEX, name: "t", node: e, flags: S::XML_SCHEMAS_TYPE_GLOBAL)
    au = S::SchemaAttributeUse.new(attr_decl: S::SchemaAttribute.new(name: "x"))
    S.custom_err(@pctxt, P::ErrCode::SCHEMAP_AG_PROPS_CORRECT, nil, ct,
      "There must not exist more than one attribute declaration of type 'xs:ID' (or derived from 'xs:ID'). The %s violates this constraint",
      S.get_component_designation(au), nil)
    err = @errors.last
    assert_equal "complex type 't': There must not exist more than one attribute declaration of type 'xs:ID' (or derived from 'xs:ID'). The attribute use 'x' violates this constraint.\n", err.message
    assert_equal "attribute use 'x'", err.str1
    assert_same e, err.node
    # warnings do not count as errors
    n = @pctxt.nberrors
    S.custom_warning(@pctxt, 1, e, nil, "w %s", "A", nil, nil)
    assert_equal "Element '{#{XS}}complexType': w A.\n", @errors.last.message
    assert_equal P::Level::WARNING, @errors.last.level
    assert_equal n, @pctxt.nberrors
  end

  def test_internal_err
    S.internal_err(@pctxt, "xmlSchemaFoo", "bar")
    err = @errors.last
    assert_equal "Internal error: xmlSchemaFoo, bar.\n", err.message
    assert_equal P::ErrCode::SCHEMAP_INTERNAL, err.code
    assert_equal "xmlSchemaFoo", err.str1
  end

  # ---------------------------------------------------------------- validator error functions

  def vctxt_with(elem_node)
    v = S::SchemaValidCtxt.new(depth: 0, serror: ->(e) { @errors << e })
    v.inode = S::SchemaNodeInfo.new(node: elem_node, local_name: elem_node&.name, ns_name: elem_node&.ns&.href,
      node_type: P::ELEMENT_NODE)
    v
  end

  def test_simple_type_err_validator
    ns = P::XmlNs.new("urn:t", nil)
    i = T.new_doc_node(@doc, ns, "i")
    i.line = 3
    v = vctxt_with(i)
    int = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_BASIC, name: "int", built_in_type: S::XML_SCHEMAS_INT,
      flags: S::XML_SCHEMAS_TYPE_VARIETY_ATOMIC)
    S.simple_type_err(v, P::ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_1, i, "x", int, 1)
    err = @errors.last
    assert_equal "Element '{urn:t}i': 'x' is not a valid value of the atomic type 'xs:int'.\n", err.message
    assert_equal 3, err.line
    assert_equal "x", err.str1
    lst = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE, name: "lst", target_namespace: "urn:t",
      flags: S::XML_SCHEMAS_TYPE_VARIETY_LIST | S::XML_SCHEMAS_TYPE_GLOBAL)
    S.simple_type_err(v, 1825, nil, "1 x", lst, 1)
    assert_equal "Element '{urn:t}i': '1 x' is not a valid value of the list type '{urn:t}lst'.\n", @errors.last.message
    assert_same i, @errors.last.node # taken from vctxt->inode
    loc = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE, flags: S::XML_SCHEMAS_TYPE_VARIETY_ATOMIC)
    S.simple_type_err(v, 1824, i, "x", loc, 1)
    assert_equal "Element '{urn:t}i': 'x' is not a valid value of the local atomic type.\n", @errors.last.message
    S.simple_type_err(v, 1824, i, "x", loc, 0)
    assert_equal "Element '{urn:t}i': The character content is not a valid value of the local atomic type.\n", @errors.last.message
    assert_nil @errors.last.str1
  end

  def test_facet_err_validator
    ns = P::XmlNs.new("urn:t", nil)
    r = T.new_doc_node(@doc, ns, "r")
    l = T.new_doc_node(@doc, ns, "l")
    v = vctxt_with(l)
    f = S::SchemaFacet.new(type: S::XML_SCHEMA_FACET_MAXLENGTH, value: "2")
    f.val = nil
    unless S.const_defined?(:FakeVal)
      skip "real Types loaded; facet length value needs a computed val" unless Nokogiri::Pure::Schemas::Types.respond_to?(:get_facet_value_as_u_long)
    end
    if S.const_defined?(:FakeVal)
      S.facet_err(v, P::ErrCode::SCHEMAV_CVC_MAXLENGTH_VALID, l, "abc", 3, nil, f, nil, nil, nil)
      assert_equal "Element '{urn:t}l': [facet 'maxLength'] The value has a length of '3'; this exceeds the allowed maximum length of '2'.\n", @errors.last.message
      assert_equal ["3", "2", nil], [@errors.last.str1, @errors.last.str2, @errors.last.str3]
      al = T.new_prop(r, "al", "abc")
      S.facet_err(v, P::ErrCode::SCHEMAV_CVC_MAXLENGTH_VALID, al, "abc", 3, nil, f, nil, nil, nil)
      assert_equal "Element '{urn:t}r', attribute 'al': [facet 'maxLength'] The value 'abc' has a length of '3'; this exceeds the allowed maximum length of '2'.\n", @errors.last.message
      assert_equal ["abc", "3", "2"], [@errors.last.str1, @errors.last.str2, @errors.last.str3]
      # enumeration set, '%' in the set is an argument
      e1 = S::SchemaFacet.new(type: S::XML_SCHEMA_FACET_ENUMERATION, val: S::FakeVal.new(S::XML_SCHEMAS_STRING, "a"))
      e2 = S::SchemaFacet.new(type: S::XML_SCHEMA_FACET_ENUMERATION, val: S::FakeVal.new(S::XML_SCHEMAS_STRING, "b%s"))
      e1.next = e2
      base = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_BASIC, name: "string", built_in_type: S::XML_SCHEMAS_STRING)
      en = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE, facets: e1, base_type: base)
      S.facet_err(v, P::ErrCode::SCHEMAV_CVC_ENUMERATION_VALID, l, "c", 0, en, nil, nil, nil, nil)
      assert_equal "Element '{urn:t}l': [facet 'enumeration'] The value 'c' is not an element of the set {'a', 'b%s'}.\n", @errors.last.message
      assert_equal "'a', 'b%s'", @errors.last.str2
    end
    pf = S::SchemaFacet.new(type: S::XML_SCHEMA_FACET_PATTERN, value: "[a-c]+")
    S.facet_err(v, P::ErrCode::SCHEMAV_CVC_PATTERN_VALID, l, "x", 0, nil, pf, nil, nil, nil)
    assert_equal "Element '{urn:t}l': [facet 'pattern'] The value 'x' is not accepted by the pattern '[a-c]+'.\n", @errors.last.message
    mi = S::SchemaFacet.new(type: S::XML_SCHEMA_FACET_MININCLUSIVE, value: "5")
    S.facet_err(v, 1833, l, "1", 0, nil, mi, nil, nil, nil)
    assert_equal "Element '{urn:t}l': [facet 'minInclusive'] The value '1' is less than the minimum value allowed ('5').\n", @errors.last.message
  end

  def test_canon_value_list_and_hash
    skip "needs stub Types" unless S.const_defined?(:FakeVal)
    v2 = S::FakeVal.new(S::XML_SCHEMAS_DECIMAL, nil, "2.0")
    v1 = S::FakeVal.new(S::XML_SCHEMAS_DECIMAL, nil, "1.5", v2)
    assert_equal [0, "1.5 2.0"], S.get_canon_value_whtsp_ext(v1, S::XML_SCHEMA_WHITESPACE_COLLAPSE)
    assert_equal [0, "1.5 2"], S.get_canon_value_hash(v1)
    assert_equal [-1, nil], S.get_canon_value_hash(nil)
  end

  def test_illegal_attr_and_keyref_err
    ns = P::XmlNs.new("urn:t", nil)
    r = T.new_doc_node(@doc, ns, "r")
    v = vctxt_with(r)
    a = T.new_prop(r, "foo", "1")
    S.illegal_attr_err(v, P::ErrCode::SCHEMAV_CVC_COMPLEX_TYPE_3_2_1, nil, a)
    assert_equal "Element '{urn:t}r', attribute 'foo': The attribute 'foo' is not allowed.\n", @errors.last.message
    assert_equal "foo", @errors.last.str1
    q = P::XmlNs.new("urn:q", "q")
    b = T.new_ns_prop(r, q, "bar", "2")
    S.illegal_attr_err(v, 1866, nil, b)
    assert_equal "Element '{urn:t}r', attribute '{urn:q}bar': The attribute '{urn:q}bar' is not allowed.\n", @errors.last.message

    # keyref: explicit line, node dropped, file from doc URL
    @doc.url = "file.xml"
    v.doc = @doc
    v.node_qnames = S::SchemaItemList.new
    v.node_qnames.items.push("k", "urn:t")
    idc_node = S::PSVIIDCNode.new(node_line: 7, node_qname_id: 0)
    S.keyref_err(v, P::ErrCode::SCHEMAV_CVC_IDC, idc_node, nil, "No match found for key-sequence %s of keyref '%s'", "['1']", "kr")
    err = @errors.last
    assert_equal "Element '{urn:t}k': No match found for key-sequence ['1'] of keyref 'kr'.\n", err.message
    assert_equal 7, err.line
    assert_nil err.node
    assert_equal "file.xml", err.file
    assert_equal "{urn:t}k", err.str1
  end

  def test_err4_line_stream_mode
    input = Struct.new(:filename, :line, :col).new("s.xml", 12, 5)
    pc = Struct.new(:input).new(input)
    v = S::SchemaValidCtxt.new(depth: 0, parser_ctxt: pc, serror: ->(e) { @errors << e })
    v.inode = S::SchemaNodeInfo.new(local_name: "r", node_type: P::ELEMENT_NODE, node_line: 4)
    S.custom_err(v, 1871, nil, nil, "msg", nil, nil)
    err = @errors.last
    assert_equal "Element 'r': msg.\n", err.message
    assert_equal ["s.xml", 4, 0], [err.file, err.line, err.int2]
    v.inode = nil
    v.depth = -1
    S.err(v, 1, nil, "x", nil, nil)
    assert_equal ["s.xml", 12, 5], [@errors.last.file, @errors.last.line, @errors.last.int2]
    # locFunc fills in missing file/line
    v2 = S::SchemaValidCtxt.new(depth: -1, loc_func: ->(_c) { ["loc.xml", 9] }, serror: ->(e) { @errors << e })
    S.err(v2, 1, nil, "x", nil, nil)
    assert_equal ["loc.xml", 9], [@errors.last.file, @errors.last.line]
    v3 = S::SchemaValidCtxt.new(depth: -1, filename: "f.xml", serror: ->(e) { @errors << e })
    S.err(v3, 1, nil, "x", nil, nil)
    assert_equal "f.xml", @errors.last.file
  end

  # ---------------------------------------------------------------- components

  def new_pctxt_with_constructor
    main = S.new_schema(@pctxt)
    @pctxt.constructor = S::SchemaConstructionCtxt.new(main_schema: main, buckets: S.item_list_create)
    @pctxt.schema = main
    main
  end

  def test_item_list_functions
    l = S.item_list_create
    assert_equal 0, S.item_list_add(l, :a)
    S.item_list_insert(l, :b, 0)
    S.item_list_insert(l, :c, 10)
    assert_equal %i[b a c], l.items
    assert_equal(-1, S.item_list_remove(l, 3))
    assert_equal 0, S.item_list_remove(l, 1)
    assert_equal %i[b c], l.items
    ret, l2 = S.add_item_size(nil, 10, :x)
    assert_equal 0, ret
    assert_equal [:x], l2.items
    ret, l3 = S.add_item_size(l2, 10, :y)
    assert_same l2, l3
    assert_equal %i[x y], l2.items
  end

  def test_bucket_create_and_lookup
    main = new_pctxt_with_constructor
    b = S.bucket_create(@pctxt, S::XML_SCHEMA_SCHEMA_MAIN, "urn:a")
    assert_equal S::XML_SCHEMA_SCHEMA_MAIN, b.type
    assert_same main, b.schema
    assert_equal "urn:a", main.target_namespace
    assert_same b, main.schemas_imports["urn:a"]
    @pctxt.constructor.bucket = b
    imp = S.bucket_create(@pctxt, S::XML_SCHEMA_SCHEMA_IMPORT, nil)
    assert_same imp, main.schemas_imports[S::XML_SCHEMAS_NO_NAMESPACE]
    refute_same main, imp.schema
    inc = S.bucket_create(@pctxt, S::XML_SCHEMA_SCHEMA_INCLUDE, "urn:a")
    assert_same b, inc.owner_import
    assert_equal [inc], main.includes.items
    @pctxt.constructor.bucket = inc
    inc2 = S.bucket_create(@pctxt, S::XML_SCHEMA_SCHEMA_REDEFINE, "urn:a")
    assert_same b, inc2.owner_import
    assert_equal 4, @pctxt.constructor.buckets.nb_items
    # duplicate import namespace
    assert_nil S.bucket_create(@pctxt, S::XML_SCHEMA_SCHEMA_IMPORT, nil)
    assert_equal "Internal error: xmlSchemaBucketCreate, failed to add the schema bucket to the hash.\n", @errors.last.message
    assert_nil S.bucket_create(@pctxt, S::XML_SCHEMA_SCHEMA_MAIN, nil)
    assert_equal "Internal error: xmlSchemaBucketCreate, main bucket but it's not the first one.\n", @errors.last.message

    # lookups
    @pctxt.constructor.bucket = b
    main.elem_decl = { "e" => :main_e }
    imp.schema.elem_decl = { "e" => :imp_e }
    assert_equal :main_e, S.get_elem(main, "e", "urn:a")
    assert_equal :imp_e, S.get_elem(main, "e", nil)
    assert_nil S.get_elem(main, "e", "urn:none")
    assert_nil S.get_group(main, "g", "urn:a")
    assert_equal :imp_e, S.get_named_component(main, S::XML_SCHEMA_TYPE_ELEMENT, "e", nil)
    # with a single import only the schema's own tables are searched
    solo = S::Schema.new(target_namespace: nil, schemas_imports: { "##" => b }, type_decl: { "t" => :t })
    assert_equal :t, S.get_type(solo, "t", nil)
    assert_nil S.get_type(solo, "t", "urn:x")
  end

  def test_first_bucket_include_is_error
    new_pctxt_with_constructor
    assert_nil S.bucket_create(@pctxt, S::XML_SCHEMA_SCHEMA_INCLUDE, nil)
    assert_equal "Internal error: xmlSchemaBucketCreate, first bucket but it's an include or redefine.\n", @errors.last.message
    @pctxt.constructor.main_schema = nil
    assert_nil S.bucket_create(@pctxt, S::XML_SCHEMA_SCHEMA_MAIN, nil)
    assert_equal "Internal error: xmlSchemaBucketCreate, no main schema on constructor.\n", @errors.last.message
  end

  def test_add_components
    main = new_pctxt_with_constructor
    b = S.bucket_create(@pctxt, S::XML_SCHEMA_SCHEMA_MAIN, nil)
    @pctxt.constructor.bucket = b
    t = S.add_type(@pctxt, main, S::XML_SCHEMA_TYPE_COMPLEX, "t", nil, nil, 1)
    lt = S.add_type(@pctxt, main, S::XML_SCHEMA_TYPE_SIMPLE, nil, nil, nil, 0)
    e = S.add_element(@pctxt, "e", nil, nil, 1)
    p_ = S.add_particle(@pctxt, nil, 1, S::UNBOUNDED)
    mg = S.add_model_group(@pctxt, main, S::XML_SCHEMA_TYPE_ALL, nil)
    seq = S.add_model_group(@pctxt, main, S::XML_SCHEMA_TYPE_SEQUENCE, nil)
    idc = S.add_idc(@pctxt, main, "k", nil, S::XML_SCHEMA_TYPE_IDC_KEYREF, nil)
    nota = S.add_notation(@pctxt, main, "n", nil, nil)
    assert_equal [t, e, idc, nota], b.globals.items
    assert_equal [lt, p_, mg, seq], b.locals.items
    assert_equal [t, lt, e, seq, idc], @pctxt.constructor.pending.items
    assert_equal S::UNBOUNDED, p_.max_occurs
    # redefine bookkeeping
    @pctxt.is_redefine = 1
    @pctxt.redefined = b
    g = S.add_model_group_definition(@pctxt, main, "g", nil, nil)
    ag = S.add_attribute_group_definition(@pctxt, main, "ag", nil, nil)
    assert_same g, @pctxt.constructor.redefs.item
    assert_same ag, @pctxt.constructor.redefs.next.item
    assert_same @pctxt.redef, @pctxt.constructor.last_redef
    assert_equal S::XML_SCHEMAS_ATTRGROUP_GLOBAL, ag.flags
    # redefinition lookup in the bucket graph
    assert_same g, S.find_redef_comp_in_graph(b, S::XML_SCHEMA_TYPE_GROUP, "g", nil)
    assert_nil S.find_redef_comp_in_graph(b, S::XML_SCHEMA_TYPE_GROUP, "g", "urn:x")
    b2 = S::SchemaBucket.new(globals: S::SchemaItemList.new)
    b2.relations = S::SchemaSchemaRelation.new(bucket: b)
    assert_same t, S.find_redef_comp_in_graph(b2, S::XML_SCHEMA_TYPE_COMPLEX, "t", nil)
  end

  def test_subst_groups
    new_pctxt_with_constructor
    head = S::SchemaElement.new(name: "h", target_namespace: "urn:t")
    m1 = S::SchemaElement.new(name: "m1")
    m2 = S::SchemaElement.new(name: "m2")
    assert_nil S.subst_group_get(@pctxt, head)
    assert_equal 0, S.add_element_substitution_member(@pctxt, head, m1)
    assert_equal 0, S.add_element_substitution_member(@pctxt, head, m2)
    g = S.subst_group_get(@pctxt, head)
    assert_same head, g.head
    assert_equal [m1, m2], g.members.items
    assert_nil S.subst_group_add(@pctxt, head)
    assert_equal "Internal error: xmlSchemaSubstGroupAdd, failed to add a new substitution container.\n", @errors.last.message
  end

  def test_misc_utilities
    e = xs_elem
    T.new_prop(e, "name", "a")
    x = P::XmlNs.new("urn:x", "x")
    T.new_ns_prop(e, x, "name", "b")
    assert_equal "a", S.get_prop_node(e, "name").children.content
    assert_equal "b", S.get_prop_node_ns(e, "urn:x", "name").children.content
    assert_equal "a", S.get_prop(@pctxt, e, "name")
    assert_nil S.get_prop(@pctxt, e, "nope")
    assert_equal "", S.get_node_content(@pctxt, e)
    assert_equal 1, S.is_blank(nil, -1)
    assert_equal 1, S.is_blank(" \t\r\n", -1)
    assert_equal 0, S.is_blank(" x", -1)
    assert_equal 1, S.is_blank(" x", 1)
    assert_equal 1, S.is_global_item(S::SchemaModelGroupDef.new)
    assert_equal 0, S.is_global_item(S::SchemaElement.new)
    assert_equal 1, S.is_global_item(S::SchemaAttributeGroup.new)
  end
end
