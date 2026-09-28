# frozen_string_literal: true

# Data structures of libxml2's W3C XML Schema implementation (schemasInternals.h, the private
# structs at the top of xmlschemas.c). Field names are snake_case versions of the C field names
# (typeName -> type_name, nbItems -> see SchemaItemList). Integer fields default to 0, pointer
# fields to nil. Constants keep their exact C names.
#
# Conventions used by all of lib/nokogiri/pure/schemas/*.rb (see also docs in test-pure/schema/README):
# - every function of xmlschemas.c is a method of module Nokogiri::Pure::Schemas (the module
#   `extend self`s, so functions call each other without a receiver). Naming: drop the leading
#   "xmlSchema" (or "xml" for other names) and snake_case: xmlSchemaParseElement -> parse_element,
#   xmlSchemaPErr -> p_err, xmlSchemaCheckCOSSTDerivedOK -> check_cosst_derived_ok,
#   xmlGetMaxOccurs -> get_max_occurs.
# - functions of xmlschemastypes.c live in Nokogiri::Pure::Schemas::Types, same naming rule.
# - out-parameters: a C function with out-params returns [c_return_value, out1, out2, ...]
#   (without c_return_value if the C function is void). String-buffer functions whose C return
#   value is the (re)allocated buffer itself just take no buffer and return the string.

module Nokogiri
  module Pure
    module Schemas
      extend self

      # tiny struct DSL: fields default to nil; pass `name: default` for non-nil defaults
      def self.struct_class(*fields, **defaults, &blk)
        all = fields + defaults.keys
        klass = Class.new do
          attr_accessor(*all)
        end
        # keyword arguments with literal defaults: no Hash allocation per instance
        params = all.map { |f| "#{f}: #{defaults.key?(f) ? defaults[f].inspect : "nil"}" }.join(", ")
        init = +"def initialize(#{params})\n"
        reserved = %i[next end def class if then else do begin rescue ensure when case in not and or self nil true false redo retry return yield super undef alias module unless until while for break defined?]
        all.each do |f|
          init << (reserved.include?(f) ? "  @#{f} = binding.local_variable_get(:#{f})\n" : "  @#{f} = #{f}\n")
        end
        init << "end\n"
        klass.class_eval(init)
        klass.class_eval(&blk) if blk
        klass
      end

      XML_SCHEMAS_NS = "http://www.w3.org/2001/XMLSchema"
      XML_SCHEMA_INSTANCE_NS = "http://www.w3.org/2001/XMLSchema-instance"
      XML_NAMESPACE_NS = "http://www.w3.org/2000/xmlns/"
      XML_XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace"
      UNBOUNDED = 1 << 30
      XML_SCHEMAS_NO_NAMESPACE = "##"

      # xmlSchemaValType
      XML_SCHEMAS_UNKNOWN = 0
      XML_SCHEMAS_STRING = 1
      XML_SCHEMAS_NORMSTRING = 2
      XML_SCHEMAS_DECIMAL = 3
      XML_SCHEMAS_TIME = 4
      XML_SCHEMAS_GDAY = 5
      XML_SCHEMAS_GMONTH = 6
      XML_SCHEMAS_GMONTHDAY = 7
      XML_SCHEMAS_GYEAR = 8
      XML_SCHEMAS_GYEARMONTH = 9
      XML_SCHEMAS_DATE = 10
      XML_SCHEMAS_DATETIME = 11
      XML_SCHEMAS_DURATION = 12
      XML_SCHEMAS_FLOAT = 13
      XML_SCHEMAS_DOUBLE = 14
      XML_SCHEMAS_BOOLEAN = 15
      XML_SCHEMAS_TOKEN = 16
      XML_SCHEMAS_LANGUAGE = 17
      XML_SCHEMAS_NMTOKEN = 18
      XML_SCHEMAS_NMTOKENS = 19
      XML_SCHEMAS_NAME = 20
      XML_SCHEMAS_QNAME = 21
      XML_SCHEMAS_NCNAME = 22
      XML_SCHEMAS_ID = 23
      XML_SCHEMAS_IDREF = 24
      XML_SCHEMAS_IDREFS = 25
      XML_SCHEMAS_ENTITY = 26
      XML_SCHEMAS_ENTITIES = 27
      XML_SCHEMAS_NOTATION = 28
      XML_SCHEMAS_ANYURI = 29
      XML_SCHEMAS_INTEGER = 30
      XML_SCHEMAS_NPINTEGER = 31
      XML_SCHEMAS_NINTEGER = 32
      XML_SCHEMAS_NNINTEGER = 33
      XML_SCHEMAS_PINTEGER = 34
      XML_SCHEMAS_INT = 35
      XML_SCHEMAS_UINT = 36
      XML_SCHEMAS_LONG = 37
      XML_SCHEMAS_ULONG = 38
      XML_SCHEMAS_SHORT = 39
      XML_SCHEMAS_USHORT = 40
      XML_SCHEMAS_BYTE = 41
      XML_SCHEMAS_UBYTE = 42
      XML_SCHEMAS_HEXBINARY = 43
      XML_SCHEMAS_BASE64BINARY = 44
      XML_SCHEMAS_ANYTYPE = 45
      XML_SCHEMAS_ANYSIMPLETYPE = 46

      # xmlSchemaTypeType
      XML_SCHEMA_TYPE_BASIC = 1
      XML_SCHEMA_TYPE_ANY = 2
      XML_SCHEMA_TYPE_FACET = 3
      XML_SCHEMA_TYPE_SIMPLE = 4
      XML_SCHEMA_TYPE_COMPLEX = 5
      XML_SCHEMA_TYPE_SEQUENCE = 6
      XML_SCHEMA_TYPE_CHOICE = 7
      XML_SCHEMA_TYPE_ALL = 8
      XML_SCHEMA_TYPE_SIMPLE_CONTENT = 9
      XML_SCHEMA_TYPE_COMPLEX_CONTENT = 10
      XML_SCHEMA_TYPE_UR = 11
      XML_SCHEMA_TYPE_RESTRICTION = 12
      XML_SCHEMA_TYPE_EXTENSION = 13
      XML_SCHEMA_TYPE_ELEMENT = 14
      XML_SCHEMA_TYPE_ATTRIBUTE = 15
      XML_SCHEMA_TYPE_ATTRIBUTEGROUP = 16
      XML_SCHEMA_TYPE_GROUP = 17
      XML_SCHEMA_TYPE_NOTATION = 18
      XML_SCHEMA_TYPE_LIST = 19
      XML_SCHEMA_TYPE_UNION = 20
      XML_SCHEMA_TYPE_ANY_ATTRIBUTE = 21
      XML_SCHEMA_TYPE_IDC_UNIQUE = 22
      XML_SCHEMA_TYPE_IDC_KEY = 23
      XML_SCHEMA_TYPE_IDC_KEYREF = 24
      XML_SCHEMA_TYPE_PARTICLE = 25
      XML_SCHEMA_TYPE_ATTRIBUTE_USE = 26
      XML_SCHEMA_FACET_MININCLUSIVE = 1000
      XML_SCHEMA_FACET_MINEXCLUSIVE = 1001
      XML_SCHEMA_FACET_MAXINCLUSIVE = 1002
      XML_SCHEMA_FACET_MAXEXCLUSIVE = 1003
      XML_SCHEMA_FACET_TOTALDIGITS = 1004
      XML_SCHEMA_FACET_FRACTIONDIGITS = 1005
      XML_SCHEMA_FACET_PATTERN = 1006
      XML_SCHEMA_FACET_ENUMERATION = 1007
      XML_SCHEMA_FACET_WHITESPACE = 1008
      XML_SCHEMA_FACET_LENGTH = 1009
      XML_SCHEMA_FACET_MAXLENGTH = 1010
      XML_SCHEMA_FACET_MINLENGTH = 1011
      XML_SCHEMA_EXTRA_QNAMEREF = 2000
      XML_SCHEMA_EXTRA_ATTR_USE_PROHIB = 2001

      # xmlSchemaContentType
      XML_SCHEMA_CONTENT_UNKNOWN = 0
      XML_SCHEMA_CONTENT_EMPTY = 1
      XML_SCHEMA_CONTENT_ELEMENTS = 2
      XML_SCHEMA_CONTENT_MIXED = 3
      XML_SCHEMA_CONTENT_SIMPLE = 4
      XML_SCHEMA_CONTENT_MIXED_OR_ELEMENTS = 5
      XML_SCHEMA_CONTENT_BASIC = 6
      XML_SCHEMA_CONTENT_ANY = 7

      # xmlSchemaWhitespaceValueType (xmlschemastypes.h)
      XML_SCHEMA_WHITESPACE_UNKNOWN = 0
      XML_SCHEMA_WHITESPACE_PRESERVE = 1
      XML_SCHEMA_WHITESPACE_REPLACE = 2
      XML_SCHEMA_WHITESPACE_COLLAPSE = 3

      XML_SCHEMAS_ANYATTR_SKIP = 1
      XML_SCHEMAS_ANYATTR_LAX = 2
      XML_SCHEMAS_ANYATTR_STRICT = 3
      XML_SCHEMAS_ANY_SKIP = 1
      XML_SCHEMAS_ANY_LAX = 2
      XML_SCHEMAS_ANY_STRICT = 3
      XML_SCHEMAS_ATTR_USE_PROHIBITED = 0
      XML_SCHEMAS_ATTR_USE_REQUIRED = 1
      XML_SCHEMAS_ATTR_USE_OPTIONAL = 2
      XML_SCHEMAS_ATTR_GLOBAL = 1 << 0
      XML_SCHEMAS_ATTR_NSDEFAULT = 1 << 7
      XML_SCHEMAS_ATTR_INTERNAL_RESOLVED = 1 << 8
      XML_SCHEMAS_ATTR_FIXED = 1 << 9
      XML_SCHEMAS_WILDCARD_COMPLETE = 1 << 0
      XML_SCHEMAS_ATTRGROUP_WILDCARD_BUILDED = 1 << 0
      XML_SCHEMAS_ATTRGROUP_GLOBAL = 1 << 1
      XML_SCHEMAS_ATTRGROUP_MARKED = 1 << 2
      XML_SCHEMAS_ATTRGROUP_REDEFINED = 1 << 3
      XML_SCHEMAS_ATTRGROUP_HAS_REFS = 1 << 4

      XML_SCHEMAS_TYPE_MIXED = 1 << 0
      XML_SCHEMAS_TYPE_DERIVATION_METHOD_EXTENSION = 1 << 1
      XML_SCHEMAS_TYPE_DERIVATION_METHOD_RESTRICTION = 1 << 2
      XML_SCHEMAS_TYPE_GLOBAL = 1 << 3
      XML_SCHEMAS_TYPE_OWNED_ATTR_WILDCARD = 1 << 4
      XML_SCHEMAS_TYPE_VARIETY_ABSENT = 1 << 5
      XML_SCHEMAS_TYPE_VARIETY_LIST = 1 << 6
      XML_SCHEMAS_TYPE_VARIETY_UNION = 1 << 7
      XML_SCHEMAS_TYPE_VARIETY_ATOMIC = 1 << 8
      XML_SCHEMAS_TYPE_FINAL_EXTENSION = 1 << 9
      XML_SCHEMAS_TYPE_FINAL_RESTRICTION = 1 << 10
      XML_SCHEMAS_TYPE_FINAL_LIST = 1 << 11
      XML_SCHEMAS_TYPE_FINAL_UNION = 1 << 12
      XML_SCHEMAS_TYPE_FINAL_DEFAULT = 1 << 13
      XML_SCHEMAS_TYPE_BUILTIN_PRIMITIVE = 1 << 14
      XML_SCHEMAS_TYPE_MARKED = 1 << 16
      XML_SCHEMAS_TYPE_BLOCK_DEFAULT = 1 << 17
      XML_SCHEMAS_TYPE_BLOCK_EXTENSION = 1 << 18
      XML_SCHEMAS_TYPE_BLOCK_RESTRICTION = 1 << 19
      XML_SCHEMAS_TYPE_ABSTRACT = 1 << 20
      XML_SCHEMAS_TYPE_FACETSNEEDVALUE = 1 << 21
      XML_SCHEMAS_TYPE_INTERNAL_RESOLVED = 1 << 22
      XML_SCHEMAS_TYPE_INTERNAL_INVALID = 1 << 23
      XML_SCHEMAS_TYPE_WHITESPACE_PRESERVE = 1 << 24
      XML_SCHEMAS_TYPE_WHITESPACE_REPLACE = 1 << 25
      XML_SCHEMAS_TYPE_WHITESPACE_COLLAPSE = 1 << 26
      XML_SCHEMAS_TYPE_HAS_FACETS = 1 << 27
      XML_SCHEMAS_TYPE_NORMVALUENEEDED = 1 << 28
      XML_SCHEMAS_TYPE_FIXUP_1 = 1 << 29
      XML_SCHEMAS_TYPE_REDEFINED = 1 << 30

      XML_SCHEMAS_ELEM_NILLABLE = 1 << 0
      XML_SCHEMAS_ELEM_GLOBAL = 1 << 1
      XML_SCHEMAS_ELEM_DEFAULT = 1 << 2
      XML_SCHEMAS_ELEM_FIXED = 1 << 3
      XML_SCHEMAS_ELEM_ABSTRACT = 1 << 4
      XML_SCHEMAS_ELEM_TOPLEVEL = 1 << 5
      XML_SCHEMAS_ELEM_REF = 1 << 6
      XML_SCHEMAS_ELEM_NSDEFAULT = 1 << 7
      XML_SCHEMAS_ELEM_INTERNAL_RESOLVED = 1 << 8
      XML_SCHEMAS_ELEM_CIRCULAR = 1 << 9
      XML_SCHEMAS_ELEM_BLOCK_ABSENT = 1 << 10
      XML_SCHEMAS_ELEM_BLOCK_EXTENSION = 1 << 11
      XML_SCHEMAS_ELEM_BLOCK_RESTRICTION = 1 << 12
      XML_SCHEMAS_ELEM_BLOCK_SUBSTITUTION = 1 << 13
      XML_SCHEMAS_ELEM_FINAL_ABSENT = 1 << 14
      XML_SCHEMAS_ELEM_FINAL_EXTENSION = 1 << 15
      XML_SCHEMAS_ELEM_FINAL_RESTRICTION = 1 << 16
      XML_SCHEMAS_ELEM_SUBST_GROUP_HEAD = 1 << 17
      XML_SCHEMAS_ELEM_INTERNAL_CHECKED = 1 << 18

      XML_SCHEMAS_FACET_UNKNOWN = 0
      XML_SCHEMAS_FACET_PRESERVE = 1
      XML_SCHEMAS_FACET_REPLACE = 2
      XML_SCHEMAS_FACET_COLLAPSE = 3

      XML_SCHEMAS_QUALIF_ELEM = 1 << 0
      XML_SCHEMAS_QUALIF_ATTR = 1 << 1
      XML_SCHEMAS_FINAL_DEFAULT_EXTENSION = 1 << 2
      XML_SCHEMAS_FINAL_DEFAULT_RESTRICTION = 1 << 3
      XML_SCHEMAS_FINAL_DEFAULT_LIST = 1 << 4
      XML_SCHEMAS_FINAL_DEFAULT_UNION = 1 << 5
      XML_SCHEMAS_BLOCK_DEFAULT_EXTENSION = 1 << 6
      XML_SCHEMAS_BLOCK_DEFAULT_RESTRICTION = 1 << 7
      XML_SCHEMAS_BLOCK_DEFAULT_SUBSTITUTION = 1 << 8
      XML_SCHEMAS_INCLUDING_CONVERT_NS = 1 << 9

      # xmlschemas.h
      XML_SCHEMA_VAL_VC_I_CREATE = 1 << 0
      XML_SCHEMA_VAL_XSI_ASSEMBLE = 1 << 1 # not public, but used

      # private (xmlschemas.c)
      SUBSET_RESTRICTION = 1 << 0
      SUBSET_EXTENSION = 1 << 1
      SUBSET_SUBSTITUTION = 1 << 2
      SUBSET_LIST = 1 << 3
      SUBSET_UNION = 1 << 4

      XML_SCHEMA_CTXT_PARSER = 1
      XML_SCHEMA_CTXT_VALIDATOR = 2

      XML_SCHEMA_SCHEMA_MAIN = 0
      XML_SCHEMA_SCHEMA_IMPORT = 1
      XML_SCHEMA_SCHEMA_INCLUDE = 2
      XML_SCHEMA_SCHEMA_REDEFINE = 3

      XML_SCHEMA_BUCKET_MARKED = 1 << 0
      XML_SCHEMA_BUCKET_COMPS_ADDED = 1 << 1

      XML_SCHEMA_ATTR_USE_FIXED = 1 << 0

      XML_SCHEMAS_PARSE_ERROR = 1

      XML_SCHEMA_MODEL_GROUP_DEF_MARKED = 1 << 0
      XML_SCHEMA_MODEL_GROUP_DEF_REDEFINED = 1 << 1

      XPATH_STATE_OBJ_TYPE_IDC_SELECTOR = 1
      XPATH_STATE_OBJ_TYPE_IDC_FIELD = 2
      XPATH_STATE_OBJ_MATCHES = -2
      XPATH_STATE_OBJ_BLOCKED = -3
      IDC_MATCHER = 0

      XML_SCHEMA_NODE_INFO_FLAG_OWNED_NAMES = 1 << 0
      XML_SCHEMA_NODE_INFO_FLAG_OWNED_VALUES = 1 << 1
      XML_SCHEMA_ELEM_INFO_NILLED = 1 << 2
      XML_SCHEMA_ELEM_INFO_LOCAL_TYPE = 1 << 3
      XML_SCHEMA_NODE_INFO_VALUE_NEEDED = 1 << 4
      XML_SCHEMA_ELEM_INFO_EMPTY = 1 << 5
      XML_SCHEMA_ELEM_INFO_HAS_CONTENT = 1 << 6
      XML_SCHEMA_ELEM_INFO_HAS_ELEM_CONTENT = 1 << 7
      XML_SCHEMA_ELEM_INFO_ERR_BAD_CONTENT = 1 << 8
      XML_SCHEMA_NODE_INFO_ERR_NOT_EXPECTED = 1 << 9
      XML_SCHEMA_NODE_INFO_ERR_BAD_TYPE = 1 << 10

      XML_SCHEMAS_ATTR_UNKNOWN = 1
      XML_SCHEMAS_ATTR_ASSESSED = 2
      XML_SCHEMAS_ATTR_PROHIBITED = 3
      XML_SCHEMAS_ATTR_ERR_MISSING = 4
      XML_SCHEMAS_ATTR_INVALID_VALUE = 5
      XML_SCHEMAS_ATTR_ERR_NO_TYPE = 6
      XML_SCHEMAS_ATTR_ERR_FIXED_VALUE = 7
      XML_SCHEMAS_ATTR_DEFAULT = 8
      XML_SCHEMAS_ATTR_VALIDATE_VALUE = 9
      XML_SCHEMAS_ATTR_ERR_WILD_STRICT_NO_DECL = 10
      XML_SCHEMAS_ATTR_HAS_ATTR_USE = 11
      XML_SCHEMAS_ATTR_HAS_ATTR_DECL = 12
      XML_SCHEMAS_ATTR_WILD_SKIP = 13
      XML_SCHEMAS_ATTR_WILD_LAX_NO_DECL = 14
      XML_SCHEMAS_ATTR_ERR_WILD_DUPLICATE_ID = 15
      XML_SCHEMAS_ATTR_ERR_WILD_AND_USE_ID = 16
      XML_SCHEMAS_ATTR_META = 17

      XML_SCHEMA_ATTR_INFO_META_XSI_TYPE = 1
      XML_SCHEMA_ATTR_INFO_META_XSI_NIL = 2
      XML_SCHEMA_ATTR_INFO_META_XSI_SCHEMA_LOC = 3
      XML_SCHEMA_ATTR_INFO_META_XSI_NO_NS_SCHEMA_LOC = 4
      XML_SCHEMA_ATTR_INFO_META_XMLNS = 5

      XML_SCHEMA_VALID_CTXT_FLAG_STREAM = 1

      # xmlSchemaItemList: a growable array. `items` is a Ruby Array; nb_items == items.size.
      class SchemaItemList
        attr_accessor :items

        def initialize
          @items = []
        end

        def nb_items = @items.size
      end

      # --- schemasInternals.h -------------------------------------------------------------

      SchemaAnnot = struct_class(:next, :content)

      SchemaAttribute = struct_class(:next, :name, :id, :ref, :ref_ns, :type_name, :type_ns,
        :annot, :base, :def_value, :subtypes, :node, :target_namespace, :ref_prefix, :def_val,
        :ref_decl, type: XML_SCHEMA_TYPE_ATTRIBUTE, occurs: 0, flags: 0)

      SchemaAttributeLink = struct_class(:next, :attr)

      SchemaWildcardNs = struct_class(:next, :value)

      SchemaWildcard = struct_class(:id, :annot, :node, :ns_set, :neg_ns_set,
        type: XML_SCHEMA_TYPE_ANY, min_occurs: 0, max_occurs: 0, process_contents: 0, any: 0, flags: 0)

      SchemaAttributeGroup = struct_class(:next, :name, :id, :ref, :ref_ns, :annot, :attributes,
        :node, :attribute_wildcard, :ref_prefix, :ref_item, :target_namespace, :attr_uses,
        type: XML_SCHEMA_TYPE_ATTRIBUTEGROUP, flags: 0)

      SchemaTypeLink = struct_class(:next, :type)

      SchemaFacetLink = struct_class(:next, :facet)

      SchemaType = struct_class(:next, :name, :id, :ref, :ref_ns, :annot, :subtypes, :attributes,
        :node, :base, :base_ns, :base_type, :facets, :redef, :attribute_uses, :attribute_wildcard,
        :member_types, :facet_set, :ref_prefix, :content_type_def, :cont_model, :target_namespace,
        :attr_uses,
        type: 0, min_occurs: 0, max_occurs: 0, flags: 0, content_type: 0, recurse: 0, built_in_type: 0) do
        def inspect
          "#<Schemas::SchemaType type=#{@type} name=#{@name.inspect} ns=#{@target_namespace.inspect} builtin=#{@built_in_type}>"
        end
      end

      SchemaElement = struct_class(:next, :name, :id, :ref, :ref_ns, :annot, :subtypes, :attributes,
        :node, :target_namespace, :named_type, :named_type_ns, :subst_group, :subst_group_ns, :scope,
        :value, :ref_decl, :cont_model, :ref_prefix, :def_val, :idcs,
        type: XML_SCHEMA_TYPE_ELEMENT, min_occurs: 0, max_occurs: 0, flags: 0, content_type: 0) do
        def inspect
          "#<Schemas::SchemaElement name=#{@name.inspect} ns=#{@target_namespace.inspect}>"
        end
      end

      SchemaFacet = struct_class(:next, :value, :id, :annot, :node, :val, :regexp,
        type: 0, fixed: 0, whitespace: 0)

      SchemaNotation = struct_class(:name, :annot, :identifier, :target_namespace,
        type: XML_SCHEMA_TYPE_NOTATION)

      # xmlSchema. The xmlHashTable slots are Ruby Hashes keyed by the local name
      # (schemas_imports: keyed by namespace name, XML_SCHEMAS_NO_NAMESPACE for none).
      Schema = struct_class(:name, :target_namespace, :version, :id, :doc, :annot,
        :type_decl, :attr_decl, :attrgrp_decl, :elem_decl, :nota_decl, :schemas_imports,
        :_private, :group_decl, :dict, :includes, :idc_def, :volatiles,
        flags: 0, preserve: 0, counter: 0)

      # --- private structs of xmlschemas.c ---------------------------------------------------

      SchemaSchemaRelation = struct_class(:next, :import_namespace, :bucket, type: 0)

      # xmlSchemaBucket / xmlSchemaImport / xmlSchemaInclude (one class; `schema` is only used by
      # import/main buckets, `owner_import` only by include/redefine buckets)
      SchemaBucket = struct_class(:schema_location, :orig_target_namespace, :target_namespace,
        :doc, :relations, :globals, :locals, :schema, :owner_import,
        type: 0, flags: 0, located: 0, parsed: 0, imported: 0, preserve_doc: 0)

      SchemaBasicItem = struct_class(type: 0)

      SchemaAttributeUse = struct_class(:annot, :next, :attr_decl, :node, :def_value, :def_val,
        type: XML_SCHEMA_TYPE_ATTRIBUTE_USE, flags: 0, occurs: 0)

      SchemaAttributeUseProhib = struct_class(:node, :name, :target_namespace,
        type: XML_SCHEMA_EXTRA_ATTR_USE_PROHIB, is_ref: 0)

      SchemaRedef = struct_class(:next, :item, :reference, :target, :ref_name, :ref_target_ns,
        :target_bucket)

      SchemaConstructionCtxt = struct_class(:main_schema, :main_bucket, :dict, :buckets, :bucket,
        :pending, :subst_groups, :redefs, :last_redef)

      # xmlSchemaParserCtxt. `serror` is the structured error callback (a callable taking a
      # Pure::XmlError) or nil; `err_ctxt` is unused in Ruby.
      SchemaParserCtxt = struct_class(:err_ctxt, :error, :warning, :serror, :constructor,
        :schema, :url, :doc, :buffer, :am, :start, :end, :state, :dict, :ctxt_type, :vctxt,
        :target_namespace, :redefined, :redef, :attr_prohibs,
        type: XML_SCHEMA_CTXT_PARSER, err: 0, nberrors: 0, owns_constructor: 0, counter: 0,
        preserve: 0, size: 0, options: 0, is_s4s: 0, is_redefine: 0, xsi_assemble: 0, stop: 0,
        redef_counter: 0)

      SchemaQNameRef = struct_class(:item, :item_type, :name, :target_namespace, :node,
        type: XML_SCHEMA_EXTRA_QNAMEREF)

      SchemaParticle = struct_class(:annot, :next, :children, :node,
        type: XML_SCHEMA_TYPE_PARTICLE, min_occurs: 0, max_occurs: 0)

      SchemaModelGroup = struct_class(:annot, :next, :children, :node, type: 0)

      SchemaModelGroupDef = struct_class(:annot, :next, :children, :name, :target_namespace, :node,
        type: XML_SCHEMA_TYPE_GROUP, flags: 0)

      SchemaIDCSelect = struct_class(:next, :idc, :xpath, :xpath_comp, index: 0)

      SchemaIDC = struct_class(:annot, :next, :node, :name, :target_namespace, :selector, :fields,
        :ref, type: 0, nb_fields: 0)

      SchemaIDCAug = struct_class(:next, :def, keyref_depth: 0)

      PSVIIDCKey = struct_class(:type, :val)

      # keys: Array of PSVIIDCKey
      PSVIIDCNode = struct_class(:node, :keys, node_line: 0, node_qname_id: 0)

      # node_table: Array of PSVIIDCNode (nb_nodes == node_table.size); dupls: SchemaItemList
      PSVIIDCBinding = struct_class(:next, :definition, :node_table, :dupls)

      # history: Array of ints (nb_history == history.size)
      IDCStateObj = struct_class(:next, :history, :matcher, :sel, :xpath_ctxt,
        type: 0, depth: 0)

      # key_seqs: Array (index by depth) of key-sequence Arrays; targets: SchemaItemList; htab: Hash
      IDCMatcher = struct_class(:next, :next_cached, :aidc, :key_seqs, :targets, :htab,
        type: 0, depth: 0, idc_type: 0, size_key_seqs: 0)

      # ns_bindings: flat Array [prefix, href, prefix, href, ...] like the C array
      SchemaNodeInfo = struct_class(:node, :local_name, :ns_name, :value, :val, :type_def,
        :decl, :idc_table, :idc_matchers, :regex_ctxt, :ns_bindings,
        node_type: 0, node_line: 0, flags: 0, val_needed: 0, norm_val: 0, depth: 0,
        nb_ns_bindings: 0, size_ns_bindings: 0, has_keyrefs: 0, applied_xpath: 0)

      SchemaAttrInfo = struct_class(:node, :local_name, :ns_name, :value, :val, :type_def,
        :decl, :use, :vc_value, :parent,
        node_type: 0, node_line: 0, flags: 0, state: 0, meta_type: 0)

      # xmlSchemaValidCtxt. elem_infos / attr_infos / idc_nodes / idc_keys are Ruby Arrays.
      SchemaValidCtxt = struct_class(:err_ctxt, :error, :warning, :serror, :schema, :doc,
        :input, :enc, :sax, :parser_ctxt, :user_data, :filename, :node, :cur, :regexp, :value,
        :validation_root, :pctxt, :elem_infos, :inode, :aidcs, :xpath_states, :xpath_state_pool,
        :idc_matcher_cache, :idc_nodes, :idc_keys, :dict, :reader, :attr_infos, :node_qnames,
        :loc_func, :loc_ctxt,
        type: XML_SCHEMA_CTXT_VALIDATOR, err: 0, nberrors: 0, value_ws: 0, options: 0,
        xsi_assemble: 0, depth: 0, size_elem_infos: 0, nb_idc_nodes: 0, size_idc_nodes: 0,
        nb_idc_keys: 0, size_idc_keys: 0, flags: 0, nb_attr_infos: 0, size_attr_infos: 0,
        skip_depth: 0, has_keyrefs: 0, create_idc_node_tables: 0, psvi_expose_idc_node_tables: 0)

      SchemaSubstGroup = struct_class(:head, :members)
    end
  end
end
