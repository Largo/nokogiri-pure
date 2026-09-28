# frozen_string_literal: true

# Unit / differential tests for lib/nokogiri/pure/schemas/parse.rb and parse_docs.rb (worker B).
#
# The cases in cases.rb all fail in the *parse phase* of libxml2 (xmlSchemaParse stops right
# after xmlSchemaParseNewDocWithContext when ctxt->nberrors != 0), so the native error list
# recorded in expected.json (see gen_expected.rb) must equal the list produced by the first
# half of xmlSchemaParse, which this file emulates with worker B's functions.
#
# Run from the repository root: ruby -Ilib test-pure/schema/unit_b/test_parse.rb
$LOAD_PATH.unshift(File.expand_path("../../../lib", __dir__))
require "minitest/autorun"
require "json"
require "nokogiri"

# types.rb needs types_compare.rb, which may not exist yet; nothing here needs it.
tc = File.expand_path("../../../lib/nokogiri/pure/schemas/types_compare.rb", __dir__)
$LOADED_FEATURES << tc unless File.exist?(tc)
require "nokogiri/pure/schemas/types"
require "nokogiri/pure/schemas/components"
require "nokogiri/pure/schemas/errors"
require "nokogiri/pure/schemas/parse_docs"
require "nokogiri/pure/schemas/io"
require_relative "../rexml2pure"
require_relative "cases"

module UnitBDriver
  S = Nokogiri::Pure::Schemas
  P = Nokogiri::Pure

  # parser for schema documents: the pure XML parser if it is there, REXML otherwise
  def self.parse_xml(src, url)
    if P.const_defined?(:Parser) && P::Parser.respond_to?(:read_memory)
      P::Parser.read_memory(src, url, nil, S::PARSE_NOENT)
    else
      Rexml2Pure.parse(src, url)
    end
  end

  # first half of xmlSchemaParse (up to and including xmlSchemaParseNewDocWithContext)
  def self.parse_phase(doc)
    errors = []
    ctxt = S.new_doc_parser_ctxt(doc)
    ctxt.serror = ->(e) { errors << e }
    ctxt.nberrors = 0
    ctxt.err = 0
    ctxt.counter = 0
    main_schema = S.new_schema(ctxt)
    ctxt.constructor = S.construction_ctxt_create(ctxt.dict)
    ctxt.owns_constructor = 1
    ctxt.constructor.main_schema = main_schema
    res, bucket = S.add_schema_doc(ctxt, S::XML_SCHEMA_SCHEMA_MAIN, ctxt.url, ctxt.doc, ctxt.buffer,
      ctxt.size, nil, nil, nil)
    if res == 0 && bucket
      S.parse_new_doc_with_context(ctxt, main_schema, bucket)
    end
    [ctxt, main_schema, errors]
  end

  def self.norm_native(msg)
    msg.sub(/\A(\d+:\d+: )?(WARNING|ERROR|FATAL): /, "")
  end
end

class TestSchemasWorkerBParse < Minitest::Test
  S = Nokogiri::Pure::Schemas
  EXPECTED = JSON.parse(File.read(File.expand_path("expected.json", __dir__)))

  def setup
    S.parse_memory_override = ->(content, url, _opts) { UnitBDriver.parse_xml(content, url) }
  end

  def teardown
    S.parse_memory_override = nil
  end

  def check(name, doc)
    ctxt, _schema, errors = UnitBDriver.parse_phase(doc)
    exp = EXPECTED.fetch(name)
    assert_equal "failed", exp["status"], "#{name}: native schema unexpectedly valid"
    refute_equal 0, ctxt.nberrors, "#{name}: no parse-phase error; native reported:\n" +
      exp["errors"].map { |e| e["message"] }.join("\n")
    got = errors.map { |e| [e.code, e.level, e.message.chomp] }
    want = exp["errors"].map { |e| [e["code"], e["level"], UnitBDriver.norm_native(e["message"])] }
    assert_equal want, got, "#{name}: error list differs"
    got_lines = errors.map(&:line)
    want_lines = exp["errors"].map { |e| e["line"] }
    assert_equal want_lines, got_lines, "#{name}: error lines differ" if ENV["UNIT_B_LINES"]
  end

  UnitBCases::CASES.each do |name, xsd|
    define_method("test_#{name}") do
      check(name, UnitBDriver.parse_xml(xsd, nil))
    end
  end

  UnitBCases::FILE_CASES.each do |name, file|
    define_method("test_#{name}") do
      path = File.join(UnitBCases::FILES_DIR, file)
      check(name, UnitBDriver.parse_xml(File.read(path), path))
    end
  end
end

# Isolated tests of the attribute-value helpers.
class TestSchemasWorkerBHelpers < Minitest::Test
  S = Nokogiri::Pure::Schemas
  P = Nokogiri::Pure
  T = P::Tree

  def setup
    @errors = []
    @ctxt = S.parser_ctxt_create
    @ctxt.serror = ->(e) { @errors << e }
    @doc = T.new_doc
    @xs = P::XmlNs.new(S::XML_SCHEMAS_NS, "xs")
  end

  def elem(attrs = {})
    n = T.new_doc_node(@doc, @xs, "element")
    attrs.each { |k, v| T.new_prop(n, k, v) }
    n
  end

  def test_block_final
    assert_equal [0, 0], S.p_val_attr_block_final("", 0, -1, 1, 2, 4, 8, 16)
    assert_equal [0, 32], S.p_val_attr_block_final("#all", 0, 32, 1, 2, 4, 8, 16)
    assert_equal [0, 31], S.p_val_attr_block_final("#all", 0, -1, 1, 2, 4, 8, 16)
    assert_equal [0, 3], S.p_val_attr_block_final(" extension\trestriction ", 0, -1, 1, 2, 4, 8, 16)
    # stops at the first invalid token
    assert_equal [1, 1], S.p_val_attr_block_final("extension list restriction", 0, -1, 1, 2, -1, -1, -1)
    assert_equal [1, 0], S.p_val_attr_block_final("#all extension", 0, -1, 1, 2, -1, -1, -1)
  end

  def test_form_default
    assert_equal [0, 1], S.p_val_attr_form_default("qualified", 0, 1)
    assert_equal [0, 0], S.p_val_attr_form_default("unqualified", 0, 1)
    assert_equal [1, 4], S.p_val_attr_form_default("Qualified", 4, 1)
  end

  def test_occurs
    assert_equal 1, S.get_max_occurs(@ctxt, elem, 0, S::UNBOUNDED, 1, "x")
    assert_equal S::UNBOUNDED, S.get_max_occurs(@ctxt, elem("maxOccurs" => "unbounded"), 0, S::UNBOUNDED, 1, "x")
    assert_equal 7, S.get_max_occurs(@ctxt, elem("maxOccurs" => " 7\n"), 0, S::UNBOUNDED, 1, "x")
    assert_equal 0, @ctxt.nberrors
    assert_equal 1, S.get_max_occurs(@ctxt, elem("maxOccurs" => "99999999999"), 0, S::UNBOUNDED, 1, "x")
    assert_equal 1, @ctxt.nberrors
    assert_equal 2_147_483_647, S.get_min_occurs(@ctxt, elem("minOccurs" => "99999999999"), 0, -1, 1, "x")
    assert_equal 1, S.get_min_occurs(@ctxt, elem("minOccurs" => "unbounded"), 0, -1, 1, "x")
    assert_equal 2, @ctxt.nberrors
  end

  def test_q_name_value
    root = elem
    T.new_ns(root, "urn:p", "p")
    T.new_ns(root, "urn:default", nil)
    attr = T.new_prop(root, "type", "p:t")
    schema = S::Schema.new
    assert_equal [0, "urn:p", "t"], S.p_val_attr_node_q_name(@ctxt, schema, nil, attr)
    assert_equal [0, "urn:default", "t"], S.p_val_attr_node_q_name_value(@ctxt, schema, nil, attr, "t")
    r, uri, local = S.p_val_attr_node_q_name_value(@ctxt, schema, nil, attr, "q:t")
    assert_equal [nil, "t"], [uri, local]
    assert r > 0
    r, uri, local = S.p_val_attr_node_q_name_value(@ctxt, schema, nil, attr, "1t")
    assert_equal [nil, "1t"], [uri, local]
    assert r > 0
    assert_equal 2, @errors.size
  end

  def test_q_name_chameleon_convert_ns
    root = elem
    attr = T.new_prop(root, "type", "t")
    schema = S::Schema.new(flags: S::XML_SCHEMAS_INCLUDING_CONVERT_NS)
    @ctxt.target_namespace = "urn:tns"
    assert_equal [0, "urn:tns", "t"], S.p_val_attr_node_q_name(@ctxt, schema, nil, attr)
  end

  def test_add_annotation
    t = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE)
    a1 = S::SchemaAnnot.new
    a2 = S::SchemaAnnot.new
    assert_same a1, S.add_annotation(t, a1)
    assert_same a2, S.add_annotation(t, a2)
    assert_same a1, t.annot
    assert_same a2, t.annot.next
    assert_nil S.add_annotation(t, nil)
  end

  def test_parser_ctxt_creation
    assert_nil S.new_parser_ctxt(nil)
    c = S.new_parser_ctxt("foo.xsd")
    assert_equal "foo.xsd", c.url
    assert_equal S::XML_SCHEMA_CTXT_PARSER, c.type
    assert_kind_of S::SchemaItemList, c.attr_prohibs
    assert_nil S.new_mem_parser_ctxt("", 0)
    m = S.new_mem_parser_ctxt("<x/>", 4)
    assert_equal ["<x/>", 4], [m.buffer, m.size]
    d = S.new_doc_parser_ctxt(@doc)
    assert_same @doc, d.doc
    assert_equal 1, d.preserve
    assert_equal(-1, S.parser_ctxt_set_options(d, 2))
    assert_equal 0, S.parser_ctxt_set_options(d, 1)
    assert_equal 1, S.parser_ctxt_get_options(d)
  end

  def test_build_absolute_uri
    d = T.new_doc
    d.url = "/a/b/main.xsd"
    n = T.new_doc_node(d, nil, "x")
    T.doc_set_root_element(d, n)
    assert_equal "/a/b/c.xsd", S.build_absolute_uri(nil, "c.xsd", n)
    assert_equal "c.xsd", S.build_absolute_uri(nil, "c.xsd", nil)
    assert_nil S.build_absolute_uri(nil, nil, n)
  end

  def test_cleanup_doc
    d = Rexml2Pure.parse(%(<r>\n  <a> </a>\n  <!-- c -->\n  <b xml:space="preserve"> <c/> </b>x</r>))
    root = T.doc_get_root_element(d)
    S.cleanup_doc(@ctxt, root)
    kinds = []
    walk = ->(n) { while n; kinds << [n.type, n.name]; walk.(n.children); n = n.next; end }
    walk.(root.children)
    assert_equal [[P::ELEMENT_NODE, "a"], [P::ELEMENT_NODE, "b"], [P::ELEMENT_NODE, "c"],
      [P::TEXT_NODE, "text"]], kinds
  end
end
