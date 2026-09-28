# frozen_string_literal: true

# ruby -Ilib test-pure/schema/types/test_types.rb
require "minitest/autorun"
require_relative "c_requests"
require_relative "native_diff"

class TestSchemaTypes < Minitest::Test
  T = Nokogiri::Pure::Schemas::Types
  S = Nokogiri::Pure::Schemas
  XSD = "http://www.w3.org/2001/XMLSchema"

  def ty(n) = T.get_predefined_type(n, XSD)

  def test_c_oracle_fixtures
    cases = JSON.parse(Zlib::GzipReader.open(File.join(__dir__, "fixtures", "c_oracle.json.gz"), &:read))
    responder = TypesPureResponder.new
    fails = cases.reject { |req, want| responder.respond(req) == want }
    assert_empty fails.first(5), "#{fails.size}/#{cases.size} C-oracle mismatches"
  end

  def test_native_gem_fixtures
    out = capture_io { @ok = TypesNativeDiff.run }
    assert @ok, out.join
  end

  def test_bank
    assert_equal 0, T.init_types
    assert_equal 0, T.init_types
    assert_nil T.get_predefined_type("decimal", nil)
    assert_nil T.get_predefined_type(nil, XSD)
    %w[anyType anySimpleType string ID NMTOKENS gDay base64Binary].each do |n|
      t = ty(n)
      assert_equal n, t.name
      assert_equal XSD, t.target_namespace
      assert_same t, T.get_built_in_type(t.built_in_type)
    end
    assert_nil T.get_built_in_type(S::XML_SCHEMAS_UNKNOWN)
    any = ty("anyType")
    assert_same any, any.base_type
    assert_equal S::XML_SCHEMA_CONTENT_MIXED, any.content_type
    part = any.subtypes
    assert_equal [1, 1], [part.min_occurs, part.max_occurs]
    seq = part.children
    assert_equal S::XML_SCHEMA_TYPE_SEQUENCE, seq.type
    assert_equal [0, S::UNBOUNDED], [seq.children.min_occurs, seq.children.max_occurs]
    assert_equal [S::XML_SCHEMA_TYPE_ANY, 1, S::XML_SCHEMAS_ANY_LAX],
      [seq.children.children.type, seq.children.children.any, seq.children.children.process_contents]
    assert_equal [0, 1], [any.attribute_wildcard.type, any.attribute_wildcard.any]
    nmtokens = ty("NMTOKENS")
    assert_same ty("NMTOKEN"), nmtokens.subtypes
    assert_same ty("NMTOKEN"), T.get_built_in_list_simple_type_item_type(nmtokens)
    assert_equal S::XML_SCHEMA_FACET_MINLENGTH, nmtokens.facets.type
    assert_equal 1, T.get_facet_value_as_u_long(nmtokens.facets)
    assert nmtokens.flags & S::XML_SCHEMAS_TYPE_VARIETY_LIST != 0
    assert ty("decimal").flags & S::XML_SCHEMAS_TYPE_BUILTIN_PRIMITIVE != 0
    assert_equal 0, ty("integer").flags & S::XML_SCHEMAS_TYPE_BUILTIN_PRIMITIVE
    assert_same ty("short"), ty("byte").base_type
  end

  def test_is_built_in_type_facet
    assert_equal(-1, T.is_built_in_type_facet(nil, S::XML_SCHEMA_FACET_LENGTH))
    assert_equal 1, T.is_built_in_type_facet(ty("string"), S::XML_SCHEMA_FACET_LENGTH)
    assert_equal 0, T.is_built_in_type_facet(ty("boolean"), S::XML_SCHEMA_FACET_ENUMERATION)
    assert_equal 1, T.is_built_in_type_facet(ty("decimal"), S::XML_SCHEMA_FACET_TOTALDIGITS)
    assert_equal 0, T.is_built_in_type_facet(ty("integer"), S::XML_SCHEMA_FACET_TOTALDIGITS)
    assert_equal 0, T.is_built_in_type_facet(ty("float"), S::XML_SCHEMA_FACET_LENGTH)
  end

  def test_value_constructors
    q = T.new_q_name_value("urn:x", "a")
    assert_equal S::XML_SCHEMAS_QNAME, T.get_val_type(q)
    assert_equal [0, "{urn:x}urn:x"], T.get_canon_value(q)
    n = T.new_notation_value("n", nil)
    assert_equal [0, "n"], T.get_canon_value(n)
    assert_equal 0, T.compare_values(n, T.new_notation_value("n", nil))
    assert_nil T.new_string_value(S::XML_SCHEMAS_TOKEN, "x")
    s = T.new_string_value(S::XML_SCHEMAS_STRING, " a ")
    assert_equal " a ", T.value_get_as_string(s)
    assert_equal(-1, T.value_append(nil, s))
    assert_equal 0, T.value_append(s, q)
    assert_same q, T.value_get_next(s)
    assert_nil T.value_get_next(nil)
    assert_equal S::XML_SCHEMAS_UNKNOWN, T.get_val_type(nil)
    _, b = T.validate_predefined_type(ty("boolean"), " true ")
    assert_equal 1, T.value_get_as_boolean(b)
    assert_equal 0, T.value_get_as_boolean(s)
    assert_nil T.free_value(s)
  end

  def test_whitespace_helpers
    assert_nil T.white_space_replace("a b")
    assert_equal "a  b ", T.white_space_replace("a\t\nb\r")
    assert_nil T.collapse_string("a b")
    assert_equal "a b", T.collapse_string("  a \t\n b  ")
    assert_equal "a", T.collapse_string(" a")
    assert_nil T.collapse_string(nil)
  end
end
