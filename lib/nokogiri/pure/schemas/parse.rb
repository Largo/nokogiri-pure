# frozen_string_literal: true

require_relative "structs"
require_relative "macros"
require_relative "common"
require_relative "pattern"

# Port of xmlschemas.c (libxml2 2.13.9) lines ~5730-9500 and 11148-12335: the attribute-value
# helpers used while parsing schema documents (xmlSchemaPValAttr*, xmlGetMaxOccurs, ...) and the
# xmlSchemaParse* functions that turn <xs:...> elements into schema components.
# Schema documents / buckets / import / include / redefine and the parser contexts are in
# parse_docs.rb.
#
# Ruby signatures that differ from the plain C mapping (out-params dropped, returned as
# [c_ret, out1, ...]):
#   p_val_attr_node_q_name_value(ctxt, schema, owner_item, attr, value) -> [ret, uri, local]
#   p_val_attr_node_q_name(ctxt, schema, owner_item, attr)             -> [ret, uri, local]
#   p_val_attr_q_name(ctxt, schema, owner_item, owner_elem, name)      -> [ret, uri, local]
#   p_val_attr_node(ctxt, owner_item, attr, type)                      -> [ret, value]
#   p_val_attr(ctxt, owner_item, owner_elem, name, type)               -> [ret, value]
#   parse_local_attributes(ctxt, schema, child, list, parent_type, has_refs)
#                                                    -> [ret, child, list, has_refs] (in/out)
#   p_val_attr_form_default(value, flags, flag_qualified)              -> [ret, flags]
#   p_val_attr_block_final(value, flags, flag_all, ...)                -> [ret, flags]
#   parse_element(ctxt, schema, node, top_level)                       -> [item, is_elem_ref]
#   parse_simple_content(ctxt, schema, node)          -> [ret, has_restriction_or_extension]
#   parse_complex_content(ctxt, schema, node)         -> [ret, has_restriction_or_extension]
module Nokogiri
  module Pure
    module Schemas
      extend self

      # IS_BLANK_CH-separated token scanner used by the "do { skip blanks; ... } while" loops
      BLANK_TOKEN_RE = /[^ \t\n\r]+/

      # "Check for illegal attributes" loop shared by most xmlSchemaParse* functions: every
      # no-namespace attribute not in +allowed+ and every attribute in the XSD namespace is
      # reported with XML_SCHEMAP_S4S_ATTR_NOT_ALLOWED (in document order).
      def p_check_illegal_attrs(ctxt, node, allowed)
        attr = node.properties
        while attr
          if attr.ns.nil?
            p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr) unless allowed.include?(attr.name)
          elsif attr.ns.href == XML_SCHEMAS_NS
            p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
          end
          attr = attr.next
        end
      end

      # ------------------------------------------------------------------------------------
      # Utilities for parsing
      # ------------------------------------------------------------------------------------

      # xmlSchemaPValAttrNodeQNameValue
      # Returns [ret, uri, local]
      def p_val_attr_node_q_name_value(ctxt, schema, owner_item, attr, value)
        ret = Types.validate_q_name(value, 1)
        if ret > 0
          p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, owner_item, attr,
            Types.get_built_in_type(XML_SCHEMAS_QNAME), nil, value, nil, nil, nil)
          return [ctxt.err, nil, value]
        elsif ret < 0
          return [-1, nil, nil]
        end

        idx = value.index(":")
        if idx.nil?
          uri = nil
          ns = Tree.search_ns(attr.doc, attr.parent, nil)
          if ns && ns.href && !ns.href.empty?
            uri = ns.href
          elsif (schema.flags & XML_SCHEMAS_INCLUDING_CONVERT_NS) != 0
            # This one takes care of included schemas with no target namespace.
            uri = ctxt.target_namespace
          end
          return [0, uri, value]
        end
        # At this point xmlSplitQName3 has to return a local name.
        local = value[idx + 1..]
        pref = value[0, idx]
        ns = Tree.search_ns(attr.doc, attr.parent, pref)
        if ns.nil?
          p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, owner_item, attr,
            Types.get_built_in_type(XML_SCHEMAS_QNAME), nil, value,
            "The value '%s' of simple type 'xs:QName' has no " \
            "corresponding namespace declaration in scope", value, nil)
          return [ctxt.err, nil, local]
        end
        [0, ns.href, local]
      end

      # xmlSchemaPValAttrNodeQName
      # Returns [ret, uri, local]
      def p_val_attr_node_q_name(ctxt, schema, owner_item, attr)
        value = get_node_content(ctxt, attr)
        p_val_attr_node_q_name_value(ctxt, schema, owner_item, attr, value)
      end

      # xmlSchemaPValAttrQName
      # Returns [ret, uri, local]
      def p_val_attr_q_name(ctxt, schema, owner_item, owner_elem, name)
        attr = get_prop_node(owner_elem, name)
        return [0, nil, nil] if attr.nil?

        p_val_attr_node_q_name(ctxt, schema, owner_item, attr)
      end

      # xmlSchemaPValAttrNodeID
      def p_val_attr_node_id(ctxt, attr)
        return 0 if attr.nil?

        value = get_node_content_no_dict(attr)
        ret = value.nil? ? -1 : Types.validate_nc_name(value, 1)
        if ret == 0
          # NOTE: the IDness might have already be declared in the DTD
          if attr.atype != ATTRIBUTE_ID
            strip = Types.collapse_string(value)
            value = strip unless strip.nil?
            res = Tree.add_id(attr, value)
            if res == 0
              ret = ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE
              p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr,
                Types.get_built_in_type(XML_SCHEMAS_ID), nil, nil,
                "Duplicate value '%s' of simple type 'xs:ID'", value, nil)
            end
          end
        elsif ret > 0
          ret = ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE
          p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr,
            Types.get_built_in_type(XML_SCHEMAS_ID), nil, nil,
            "The value '%s' of simple type 'xs:ID' is not a valid 'xs:NCName'", value, nil)
        end
        ret
      end

      # xmlSchemaPValAttrID
      def p_val_attr_id(ctxt, owner_elem, name)
        attr = get_prop_node(owner_elem, name)
        return 0 if attr.nil?

        p_val_attr_node_id(ctxt, attr)
      end

      INT_MAX = 2_147_483_647

      # shared body of xmlGetMaxOccurs / xmlGetMinOccurs after the "unbounded" check
      def p_parse_occurs_value(ctxt, attr, val, min, max, defv, expected)
        n = val.bytesize
        i = 0
        i += 1 while i < n && (c = val.getbyte(i)) && (c == 0x20 || c == 0x9 || c == 0xA || c == 0xD)
        if i >= n
          p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr, nil,
            expected, val, nil, nil, nil)
          return defv
        end
        ret = 0
        while i < n && (c = val.getbyte(i)) >= 0x30 && c <= 0x39
          if ret > INT_MAX / 10
            ret = INT_MAX
          else
            digit = c - 0x30
            ret *= 10
            ret = ret > INT_MAX - digit ? INT_MAX : ret + digit
          end
          i += 1
        end
        i += 1 while i < n && (c = val.getbyte(i)) && (c == 0x20 || c == 0x9 || c == 0xA || c == 0xD)
        # TODO: Restrict the maximal value to Integer.
        if i < n || ret < min || (max != -1 && ret > max)
          p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr, nil,
            expected, val, nil, nil, nil)
          return defv
        end
        ret
      end

      # xmlGetMaxOccurs
      def get_max_occurs(ctxt, node, min, max, defv, expected)
        attr = get_prop_node(node, "maxOccurs")
        return defv if attr.nil?

        val = get_node_content(ctxt, attr)
        return defv if val.nil?

        if val == "unbounded"
          if max != UNBOUNDED
            p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr, nil,
              expected, val, nil, nil, nil)
            return defv
          else
            return UNBOUNDED # encoding it with -1 might be another option
          end
        end
        p_parse_occurs_value(ctxt, attr, val, min, max, defv, expected)
      end

      # xmlGetMinOccurs
      def get_min_occurs(ctxt, node, min, max, defv, expected)
        attr = get_prop_node(node, "minOccurs")
        return defv if attr.nil?

        val = get_node_content(ctxt, attr)
        return defv if val.nil?

        p_parse_occurs_value(ctxt, attr, val, min, max, defv, expected)
      end

      # xmlSchemaPGetBoolNodeValue
      def p_get_bool_node_value(ctxt, owner_item, node)
        value = Tree.node_get_content(node)
        # 3.2.2.1 Lexical representation: {true, false, 1, 0}
        case value
        when "true", "1" then 1
        when "false", "0" then 0
        else
          p_simple_type_err(ctxt, ErrCode::SCHEMAP_INVALID_BOOLEAN, owner_item, node,
            Types.get_built_in_type(XML_SCHEMAS_BOOLEAN), nil, value, nil, nil, nil)
          0
        end
      end

      # xmlGetBooleanProp
      def get_boolean_prop(ctxt, node, name, defv)
        val = get_prop(ctxt, node, name)
        return defv if val.nil?

        case val
        when "true", "1" then 1
        when "false", "0" then 0
        else
          p_simple_type_err(ctxt, ErrCode::SCHEMAP_INVALID_BOOLEAN, nil,
            get_prop_node(node, name), Types.get_built_in_type(XML_SCHEMAS_BOOLEAN),
            nil, val, nil, nil, nil)
          defv
        end
      end

      # ------------------------------------------------------------------------------------
      # Schema extraction from an Infoset
      # ------------------------------------------------------------------------------------

      # xmlSchemaPValAttrNodeValue
      def p_val_attr_node_value(pctxt, owner_item, attr, value, type)
        return -1 if pctxt.nil? || type.nil? || attr.nil?

        if type.type != XML_SCHEMA_TYPE_BASIC
          internal_err(pctxt, "xmlSchemaPValAttrNodeValue", "the given type is not a built-in type")
          return -1
        end
        case type.built_in_type
        when XML_SCHEMAS_NCNAME, XML_SCHEMAS_QNAME, XML_SCHEMAS_ANYURI, XML_SCHEMAS_TOKEN,
             XML_SCHEMAS_LANGUAGE
          ret, = Types.val_predef_type_node(type, value, false, attr)
        else
          internal_err(pctxt, "xmlSchemaPValAttrNodeValue",
            "validation using the given type is not supported while parsing a schema")
          return -1
        end
        # TODO: Should we use the S4S error codes instead?
        if ret < 0
          internal_err(pctxt, "xmlSchemaPValAttrNodeValue", "failed to validate a schema attribute value")
          return -1
        elsif ret > 0
          ret = if wxs_is_list(type)
            ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_2
          else
            ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_1
          end
          p_simple_type_err(pctxt, ret, owner_item, attr, type, nil, value, nil, nil, nil)
        end
        ret
      end

      # xmlSchemaPValAttrNode
      # Returns [ret, value]
      def p_val_attr_node(ctxt, owner_item, attr, type)
        return [-1, nil] if ctxt.nil? || type.nil? || attr.nil?

        val = get_node_content(ctxt, attr)
        [p_val_attr_node_value(ctxt, owner_item, attr, val, type), val]
      end

      # xmlSchemaPValAttr
      # Returns [ret, value]
      def p_val_attr(ctxt, owner_item, owner_elem, name, type)
        return [-1, nil] if ctxt.nil? || type.nil?

        if type.type != XML_SCHEMA_TYPE_BASIC
          p_err(ctxt, owner_elem, ErrCode::SCHEMAP_INTERNAL,
            "Internal error: xmlSchemaPValAttr, the given type '%s' is not a built-in type.\n",
            type.name, nil)
          return [-1, nil]
        end
        attr = get_prop_node(owner_elem, name)
        return [0, nil] if attr.nil?

        p_val_attr_node(ctxt, owner_item, attr, type)
      end

      # xmlSchemaCheckReference
      def check_reference(pctxt, _schema, node, attr, namespace_name)
        return 0 if pctxt.target_namespace == namespace_name
        return 0 if namespace_name == XML_SCHEMAS_NS

        # Check if the referenced namespace was <import>ed.
        rel = pctxt.constructor.bucket.relations
        while rel
          return 0 if wxs_is_bucket_impmain(rel.type) && namespace_name == rel.import_namespace

          rel = rel.next
        end
        # No matching <import>ed namespace found.
        n = attr.nil? ? node : attr
        if namespace_name.nil?
          custom_err(pctxt, ErrCode::SCHEMAP_SRC_RESOLVE, n, nil,
            "References from this schema to components in no " \
            "namespace are not allowed, since not indicated by an " \
            "import statement", nil, nil)
        else
          custom_err(pctxt, ErrCode::SCHEMAP_SRC_RESOLVE, n, nil,
            "References from this schema to components in the " \
            "namespace '%s' are not allowed, since not indicated by an " \
            "import statement", namespace_name, nil)
        end
        ErrCode::SCHEMAP_SRC_RESOLVE
      end

      # xmlSchemaParseLocalAttributes
      # +child+ and +list+ are in/out, +has_refs+ is an out-param that is only ever set to 1.
      # Returns [ret, child, list, has_refs]
      def parse_local_attributes(ctxt, schema, child, list, parent_type, has_refs)
        while is_schema(child, "attribute") || is_schema(child, "attributeGroup")
          if is_schema(child, "attribute")
            item = parse_local_attribute(ctxt, schema, child, list, parent_type)
          else
            item = parse_attribute_group_ref(ctxt, schema, child)
            has_refs = 1 if item
          end
          if item
            list ||= SchemaItemList.new
            list.items << item
          end
          child = child.next
        end
        [0, child, list, has_refs]
      end

      ANNOT_ALLOWED_ATTRS = ["id"].freeze

      # xmlSchemaParseAnnotation
      def parse_annotation(ctxt, node, needed)
        return nil if ctxt.nil? || node.nil?

        ret = needed != 0 ? new_annot(ctxt, node) : nil
        attr = node.properties
        while attr
          if (attr.ns.nil? && attr.name != "id") || (attr.ns && attr.ns.href == XML_SCHEMAS_NS)
            p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
          end
          attr = attr.next
        end
        p_val_attr_id(ctxt, node, "id")
        # And now for the children...
        barked = false
        child = node.children
        while child
          if is_schema(child, "appinfo")
            # TODO: make available the content of "appinfo".
            attr = child.properties
            while attr
              if (attr.ns.nil? && attr.name != "source") || (attr.ns && attr.ns.href == XML_SCHEMAS_NS)
                p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
              end
              attr = attr.next
            end
            p_val_attr(ctxt, nil, child, "source", Types.get_built_in_type(XML_SCHEMAS_ANYURI))
            child = child.next
          elsif is_schema(child, "documentation")
            # TODO: make available the content of "documentation".
            attr = child.properties
            while attr
              if attr.ns.nil?
                if attr.name != "source"
                  p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
                end
              elsif attr.ns.href == XML_SCHEMAS_NS ||
                  (attr.name == "lang" && attr.ns.href != XML_XML_NAMESPACE)
                p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
              end
              attr = attr.next
            end
            # Attribute "xml:lang".
            attr = get_prop_node_ns(child, XML_XML_NAMESPACE, "lang")
            p_val_attr_node(ctxt, nil, attr, Types.get_built_in_type(XML_SCHEMAS_LANGUAGE)) if attr
            child = child.next
          else
            unless barked
              p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
                "(appinfo | documentation)*")
            end
            barked = true
            child = child.next
          end
        end
        ret
      end

      FACET_TYPES_BY_NAME = {
        "minInclusive" => XML_SCHEMA_FACET_MININCLUSIVE,
        "minExclusive" => XML_SCHEMA_FACET_MINEXCLUSIVE,
        "maxInclusive" => XML_SCHEMA_FACET_MAXINCLUSIVE,
        "maxExclusive" => XML_SCHEMA_FACET_MAXEXCLUSIVE,
        "totalDigits" => XML_SCHEMA_FACET_TOTALDIGITS,
        "fractionDigits" => XML_SCHEMA_FACET_FRACTIONDIGITS,
        "pattern" => XML_SCHEMA_FACET_PATTERN,
        "enumeration" => XML_SCHEMA_FACET_ENUMERATION,
        "whiteSpace" => XML_SCHEMA_FACET_WHITESPACE,
        "length" => XML_SCHEMA_FACET_LENGTH,
        "maxLength" => XML_SCHEMA_FACET_MAXLENGTH,
        "minLength" => XML_SCHEMA_FACET_MINLENGTH,
      }.freeze

      # xmlSchemaParseFacet
      def parse_facet(ctxt, schema, node)
        return nil if ctxt.nil? || schema.nil? || node.nil?

        facet = SchemaFacet.new
        facet.node = node
        value = get_prop(ctxt, node, "value")
        if value.nil?
          p_err2(ctxt, node, nil, ErrCode::SCHEMAP_FACET_NO_VALUE,
            "Facet %s has no value\n", node.name, nil)
          return nil
        end
        ftype = node.ns && node.ns.href == XML_SCHEMAS_NS ? FACET_TYPES_BY_NAME[node.name] : nil
        if ftype.nil?
          p_err2(ctxt, node, nil, ErrCode::SCHEMAP_UNKNOWN_FACET_TYPE,
            "Unknown facet type %s\n", node.name, nil)
          return nil
        end
        facet.type = ftype
        p_val_attr_id(ctxt, node, "id")
        facet.value = value
        if facet.type != XML_SCHEMA_FACET_PATTERN && facet.type != XML_SCHEMA_FACET_ENUMERATION
          fixed = get_prop(ctxt, node, "fixed")
          facet.fixed = 1 if fixed && fixed == "true"
        end
        child = node.children
        if is_schema(child, "annotation")
          facet.annot = parse_annotation(ctxt, child, 1)
          child = child.next
        end
        if child
          p_err2(ctxt, node, child, ErrCode::SCHEMAP_UNKNOWN_FACET_CHILD,
            "Facet %s has unexpected child content\n", node.name, nil)
        end
        facet
      end

      # xmlSchemaParseWildcardNs
      def parse_wildcard_ns(ctxt, _schema, wildc, node)
        ret = 0
        pc = get_prop(ctxt, node, "processContents")
        if pc.nil? || pc == "strict"
          wildc.process_contents = XML_SCHEMAS_ANY_STRICT
        elsif pc == "skip"
          wildc.process_contents = XML_SCHEMAS_ANY_SKIP
        elsif pc == "lax"
          wildc.process_contents = XML_SCHEMAS_ANY_LAX
        else
          p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, node, nil,
            "(strict | skip | lax)", pc, nil, nil, nil)
          wildc.process_contents = XML_SCHEMAS_ANY_STRICT
          ret = ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE
        end
        # Build the namespace constraints.
        attr = get_prop_node(node, "namespace")
        # xmlSchemaGetNodeContent(ctxt, NULL) yields ""
        ns = attr.nil? ? "" : get_node_content(ctxt, attr)
        return -1 if ns.nil?

        if attr.nil? || ns == "##any"
          wildc.any = 1
        elsif ns == "##other"
          wildc.neg_ns_set = new_wildcard_ns_constraint(ctxt)
          return -1 if wildc.neg_ns_set.nil?

          wildc.neg_ns_set.value = ctxt.target_namespace
        else
          last_ns = nil
          ns.scan(BLANK_TOKEN_RE) do |ns_item|
            if ns_item == "##other" || ns_item == "##any"
              p_simple_type_err(ctxt, ErrCode::SCHEMAP_WILDCARD_INVALID_NS_MEMBER, nil, attr, nil,
                "((##any | ##other) | List of (xs:anyURI | (##targetNamespace | ##local)))",
                ns_item, nil, nil, nil)
              ret = ErrCode::SCHEMAP_WILDCARD_INVALID_NS_MEMBER
            else
              if ns_item == "##targetNamespace"
                dictns_item = ctxt.target_namespace
              elsif ns_item == "##local"
                dictns_item = nil
              else
                # Validate the item (anyURI).
                p_val_attr_node_value(ctxt, nil, attr, ns_item,
                  Types.get_built_in_type(XML_SCHEMAS_ANYURI))
                dictns_item = ns_item
              end
              # Avoid duplicate namespaces.
              tmp = wildc.ns_set
              while tmp
                break if dictns_item == tmp.value

                tmp = tmp.next
              end
              if tmp.nil?
                tmp = new_wildcard_ns_constraint(ctxt)
                return -1 if tmp.nil?

                tmp.value = dictns_item
                tmp.next = nil
                if wildc.ns_set.nil?
                  wildc.ns_set = tmp
                elsif last_ns
                  last_ns.next = tmp
                end
                last_ns = tmp
              end
            end
          end
        end
        ret
      end

      # xmlSchemaPCheckParticleCorrect_2
      def p_check_particle_correct_2(ctxt, _item, node, min_occurs, max_occurs)
        return 0 if max_occurs == 0 && min_occurs == 0

        if max_occurs != UNBOUNDED
          # 3.9.6 Schema Component Constraint: Particle Correct
          if max_occurs < 1
            # 2.2 {max occurs} must be greater than or equal to 1.
            p_custom_attr_err(ctxt, ErrCode::SCHEMAP_P_PROPS_CORRECT_2_2, nil, nil,
              get_prop_node(node, "maxOccurs"),
              "The value must be greater than or equal to 1")
            return ErrCode::SCHEMAP_P_PROPS_CORRECT_2_2
          elsif min_occurs > max_occurs
            # 2.1 {min occurs} must not be greater than {max occurs}.
            p_custom_attr_err(ctxt, ErrCode::SCHEMAP_P_PROPS_CORRECT_2_1, nil, nil,
              get_prop_node(node, "minOccurs"),
              "The value must not be greater than the value of 'maxOccurs'")
            return ErrCode::SCHEMAP_P_PROPS_CORRECT_2_1
          end
        end
        0
      end

      ANY_ALLOWED_ATTRS = %w[id minOccurs maxOccurs namespace processContents].freeze

      # xmlSchemaParseAny
      def parse_any(ctxt, schema, node)
        return nil if ctxt.nil? || schema.nil? || node.nil?

        # Check for illegal attributes.
        p_check_illegal_attrs(ctxt, node, ANY_ALLOWED_ATTRS)
        p_val_attr_id(ctxt, node, "id")
        # minOccurs/maxOccurs.
        max = get_max_occurs(ctxt, node, 0, UNBOUNDED, 1, "(xs:nonNegativeInteger | unbounded)")
        min = get_min_occurs(ctxt, node, 0, -1, 1, "xs:nonNegativeInteger")
        p_check_particle_correct_2(ctxt, nil, node, min, max)
        # Create & parse the wildcard.
        wild = add_wildcard(ctxt, schema, XML_SCHEMA_TYPE_ANY, node)
        return nil if wild.nil?

        parse_wildcard_ns(ctxt, schema, wild, node)
        # And now for the children...
        annot = nil
        child = node.children
        if is_schema(child, "annotation")
          annot = parse_annotation(ctxt, child, 1)
          child = child.next
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?)")
        end
        # No component if minOccurs==maxOccurs==0.
        return nil if min == 0 && max == 0

        # Create the particle.
        particle = add_particle(ctxt, node, min, max)
        return nil if particle.nil?

        particle.annot = annot
        particle.children = wild
        particle
      end

      # xmlSchemaParseNotation
      def parse_notation(ctxt, schema, node)
        return nil if ctxt.nil? || schema.nil? || node.nil?

        name = get_prop(ctxt, node, "name")
        if name.nil?
          p_err2(ctxt, node, nil, ErrCode::SCHEMAP_NOTATION_NO_NAME,
            "Notation has no name\n", nil, nil)
          return nil
        end
        ret = add_notation(ctxt, schema, name, ctxt.target_namespace, node)
        return nil if ret.nil?

        p_val_attr_id(ctxt, node, "id")
        child = node.children
        if is_schema(child, "annotation")
          ret.annot = parse_annotation(ctxt, child, 1)
          child = child.next
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?)")
        end
        ret
      end

      ANY_ATTRIBUTE_ALLOWED_ATTRS = %w[id namespace processContents].freeze

      # xmlSchemaParseAnyAttribute
      def parse_any_attribute(ctxt, schema, node)
        return nil if ctxt.nil? || schema.nil? || node.nil?

        ret = add_wildcard(ctxt, schema, XML_SCHEMA_TYPE_ANY_ATTRIBUTE, node)
        return nil if ret.nil?

        # Check for illegal attributes.
        p_check_illegal_attrs(ctxt, node, ANY_ATTRIBUTE_ALLOWED_ATTRS)
        p_val_attr_id(ctxt, node, "id")
        # Parse the namespace list.
        return nil if parse_wildcard_ns(ctxt, schema, ret, node) != 0

        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          ret.annot = parse_annotation(ctxt, child, 1)
          child = child.next
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?)")
        end
        ret
      end

      WXS_ATTR_DEF_VAL_DEFAULT = 1
      WXS_ATTR_DEF_VAL_FIXED = 2

      # xmlSchemaParseLocalAttribute
      def parse_local_attribute(pctxt, schema, node, uses, parent_type)
        return nil if pctxt.nil? || schema.nil? || node.nil?

        name = nil
        ns = nil
        use = nil
        tmp_ns = nil
        tmp_name = nil
        def_value = nil
        is_ref = false
        occurs = XML_SCHEMAS_ATTR_USE_OPTIONAL
        has_form = false
        def_value_type = 0

        # 3.2.3 Constraints on XML Representations of Attribute Declarations
        attr = get_prop_node(node, "ref")
        if attr
          r, tmp_ns, tmp_name = p_val_attr_node_q_name(pctxt, schema, nil, attr)
          return nil if r != 0
          return nil if check_reference(pctxt, schema, node, attr, tmp_ns) != 0

          is_ref = true
        end
        nberrors = pctxt.nberrors
        # Check for illegal attributes.
        attr = node.properties
        while attr
          handled = false
          if attr.ns.nil?
            aname = attr.name
            if is_ref
              if aname == "id"
                p_val_attr_node_id(pctxt, attr)
                handled = true
              elsif aname == "ref"
                handled = true
              end
            elsif aname == "name"
              handled = true
            elsif aname == "id"
              p_val_attr_node_id(pctxt, attr)
              handled = true
            elsif aname == "type"
              _, tmp_ns, tmp_name = p_val_attr_node_q_name(pctxt, schema, nil, attr)
              handled = true
            elsif aname == "form"
              # Evaluate the target namespace
              has_form = true
              attr_value = get_node_content(pctxt, attr)
              if attr_value == "qualified"
                ns = pctxt.target_namespace
              elsif attr_value != "unqualified"
                p_simple_type_err(pctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr, nil,
                  "(qualified | unqualified)", attr_value, nil, nil, nil)
              end
              handled = true
            end
            unless handled
              if aname == "use"
                attr_value = get_node_content(pctxt, attr)
                # TODO: Maybe we need to normalize the value beforehand.
                if attr_value == "optional"
                  occurs = XML_SCHEMAS_ATTR_USE_OPTIONAL
                elsif attr_value == "prohibited"
                  occurs = XML_SCHEMAS_ATTR_USE_PROHIBITED
                elsif attr_value == "required"
                  occurs = XML_SCHEMAS_ATTR_USE_REQUIRED
                else
                  p_simple_type_err(pctxt, ErrCode::SCHEMAP_INVALID_ATTR_USE, nil, attr, nil,
                    "(optional | prohibited | required)", attr_value, nil, nil, nil)
                end
                handled = true
              elsif aname == "default"
                # 3.2.3 : 1 default and fixed must not both be present.
                if def_value
                  p_mutual_excl_attr_err(pctxt, ErrCode::SCHEMAP_SRC_ATTRIBUTE_1, nil, attr,
                    "default", "fixed")
                else
                  def_value = get_node_content(pctxt, attr)
                  def_value_type = WXS_ATTR_DEF_VAL_DEFAULT
                end
                handled = true
              elsif aname == "fixed"
                # 3.2.3 : 1 default and fixed must not both be present.
                if def_value
                  p_mutual_excl_attr_err(pctxt, ErrCode::SCHEMAP_SRC_ATTRIBUTE_1, nil, attr,
                    "default", "fixed")
                else
                  def_value = get_node_content(pctxt, attr)
                  def_value_type = WXS_ATTR_DEF_VAL_FIXED
                end
                handled = true
              end
            end
          elsif attr.ns.href != XML_SCHEMAS_NS
            handled = true
          end
          p_illegal_attr_err(pctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr) unless handled
          attr = attr.next
        end
        # 3.2.3 : 2 If default and use are both present, use must have the actual value
        # optional.
        if def_value_type == WXS_ATTR_DEF_VAL_DEFAULT && occurs != XML_SCHEMAS_ATTR_USE_OPTIONAL
          p_simple_type_err(pctxt, ErrCode::SCHEMAP_SRC_ATTRIBUTE_2, nil, node, nil,
            "(optional | prohibited | required)", nil,
            "The value of the attribute 'use' must be 'optional' " \
            "if the attribute 'default' is present", nil, nil)
        end
        # We want correct attributes.
        return nil if nberrors != pctxt.nberrors

        if !is_ref
          # TODO: move XML_SCHEMAS_QUALIF_ATTR to the parser.
          ns = pctxt.target_namespace if !has_form && (schema.flags & XML_SCHEMAS_QUALIF_ATTR) != 0
          # 3.2.6 Schema Component Constraint: xsi: Not Allowed
          if ns == XML_SCHEMA_INSTANCE_NS
            custom_err(pctxt, ErrCode::SCHEMAP_NO_XSI, node, nil,
              "The target namespace must not match '%s'", XML_SCHEMA_INSTANCE_NS, nil)
          end
          attr = get_prop_node(node, "name")
          if attr.nil?
            p_missing_attr_err(pctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "name", nil)
            return nil
          end
          r, name = p_val_attr_node(pctxt, nil, attr, Types.get_built_in_type(XML_SCHEMAS_NCNAME))
          return nil if r != 0

          # 3.2.6 Schema Component Constraint: xmlns Not Allowed
          if name == "xmlns"
            p_simple_type_err(pctxt, ErrCode::SCHEMAP_NO_XMLNS, nil, attr,
              Types.get_built_in_type(XML_SCHEMAS_NCNAME), nil, nil,
              "The value of the attribute must not match 'xmlns'", nil, nil)
            return nil
          end
          if occurs != XML_SCHEMAS_ATTR_USE_PROHIBITED
            # Create the attribute use component.
            use = add_attribute_use(pctxt, node)
            return nil if use.nil?

            use.occurs = occurs
            # Create the attribute declaration.
            attr_decl = add_attribute(pctxt, schema, name, ns, node, 0)
            return nil if attr_decl.nil?

            if tmp_name
              attr_decl.type_name = tmp_name
              attr_decl.type_ns = tmp_ns
            end
            use.attr_decl = attr_decl
            # Value constraint.
            if def_value
              attr_decl.def_value = def_value
              attr_decl.flags |= XML_SCHEMAS_ATTR_FIXED if def_value_type == WXS_ATTR_DEF_VAL_FIXED
            end
          end
        elsif occurs != XML_SCHEMAS_ATTR_USE_PROHIBITED
          # Create the attribute use component.
          use = add_attribute_use(pctxt, node)
          return nil if use.nil?

          # We need to resolve the reference at later stage.
          wxs_add_pending(pctxt, use)
          use.occurs = occurs
          # Create a QName reference to the attribute declaration.
          ref = new_q_name_ref(pctxt, XML_SCHEMA_TYPE_ATTRIBUTE, tmp_name, tmp_ns)
          return nil if ref.nil?

          # Assign the reference. This will be substituted for the referenced attribute
          # declaration when the QName is resolved.
          use.attr_decl = ref
          # Value constraint.
          use.def_value = def_value if def_value
          use.flags |= XML_SCHEMA_ATTR_USE_FIXED if def_value_type == WXS_ATTR_DEF_VAL_FIXED
        end

        # check_children: And now for the children...
        child = node.children
        if occurs == XML_SCHEMAS_ATTR_USE_PROHIBITED
          if is_schema(child, "annotation")
            parse_annotation(pctxt, child, 0)
            child = child.next
          end
          if child
            p_content_err(pctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
              "(annotation?)")
          end
          # Check for pointlessness of attribute prohibitions.
          if parent_type == XML_SCHEMA_TYPE_ATTRIBUTEGROUP
            custom_warning(pctxt, ErrCode::SCHEMAP_WARN_ATTR_POINTLESS_PROH, node, nil,
              "Skipping attribute use prohibition, since it is " \
              "pointless inside an <attributeGroup>", nil, nil, nil)
            return nil
          elsif parent_type == XML_SCHEMA_TYPE_EXTENSION
            custom_warning(pctxt, ErrCode::SCHEMAP_WARN_ATTR_POINTLESS_PROH, node, nil,
              "Skipping attribute use prohibition, since it is " \
              "pointless when extending a type", nil, nil, nil)
            return nil
          end
          unless is_ref
            tmp_name = name
            tmp_ns = ns
          end
          # Check for duplicate attribute prohibitions.
          uses&.items&.each do |u|
            next unless u.type == XML_SCHEMA_EXTRA_ATTR_USE_PROHIB &&
              tmp_name == u.name && tmp_ns == u.target_namespace

            custom_warning(pctxt, ErrCode::SCHEMAP_WARN_ATTR_POINTLESS_PROH, node, nil,
              "Skipping duplicate attribute use prohibition '%s'",
              format_q_name(tmp_ns, tmp_name), nil, nil)
            return nil
          end
          # Create the attribute prohibition helper component.
          prohib = add_attribute_use_prohib(pctxt)
          return nil if prohib.nil?

          prohib.node = node
          prohib.name = tmp_name
          prohib.target_namespace = tmp_ns
          # We need at least to resolve to the attribute declaration.
          wxs_add_pending(pctxt, prohib) if is_ref
          return prohib
        else
          if is_schema(child, "annotation")
            # TODO: Should this go into the attr decl?
            use.annot = parse_annotation(pctxt, child, 1)
            child = child.next
          end
          if is_ref
            if child
              if is_schema(child, "simpleType")
                # 3.2.3 : 3.2 If ref is present, then all of <simpleType>, form and type
                # must be absent.
                p_content_err(pctxt, ErrCode::SCHEMAP_SRC_ATTRIBUTE_3_2, nil, node, child, nil,
                  "(annotation?)")
              else
                p_content_err(pctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
                  "(annotation?)")
              end
            end
          else
            if is_schema(child, "simpleType")
              if use.attr_decl.type_name
                # 3.2.3 : 4 type and <simpleType> must not both be present.
                p_content_err(pctxt, ErrCode::SCHEMAP_SRC_ATTRIBUTE_4, nil, node, child,
                  "The attribute 'type' and the <simpleType> child " \
                  "are mutually exclusive", nil)
              else
                use.attr_decl.subtypes = parse_simple_type(pctxt, schema, child, 0)
              end
              child = child.next
            end
            if child
              p_content_err(pctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
                "(annotation?, simpleType?)")
            end
          end
        end
        use
      end

      GLOBAL_ATTRIBUTE_ALLOWED_ATTRS = %w[id default fixed name type].freeze

      # xmlSchemaParseGlobalAttribute
      def parse_global_attribute(pctxt, schema, node)
        return nil if pctxt.nil? || schema.nil? || node.nil?

        # 3.2.3 : 3.1 One of ref or name must be present, but not both
        attr = get_prop_node(node, "name")
        if attr.nil?
          p_missing_attr_err(pctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "name", nil)
          return nil
        end
        r, attr_value = p_val_attr_node(pctxt, nil, attr, Types.get_built_in_type(XML_SCHEMAS_NCNAME))
        return nil if r != 0

        # 3.2.6 Schema Component Constraint: xmlns Not Allowed
        if attr_value == "xmlns"
          p_simple_type_err(pctxt, ErrCode::SCHEMAP_NO_XMLNS, nil, attr,
            Types.get_built_in_type(XML_SCHEMAS_NCNAME), nil, nil,
            "The value of the attribute must not match 'xmlns'", nil, nil)
          return nil
        end
        # 3.2.6 Schema Component Constraint: xsi: Not Allowed
        if pctxt.target_namespace == XML_SCHEMA_INSTANCE_NS
          custom_err(pctxt, ErrCode::SCHEMAP_NO_XSI, node, nil,
            "The target namespace must not match '%s'", XML_SCHEMA_INSTANCE_NS, nil)
        end
        ret = add_attribute(pctxt, schema, attr_value, pctxt.target_namespace, node, 1)
        return nil if ret.nil?

        ret.flags |= XML_SCHEMAS_ATTR_GLOBAL
        # Check for illegal attributes.
        p_check_illegal_attrs(pctxt, node, GLOBAL_ATTRIBUTE_ALLOWED_ATTRS)
        _, ret.type_ns, ret.type_name = p_val_attr_q_name(pctxt, schema, nil, node, "type")
        p_val_attr_id(pctxt, node, "id")
        # Attribute "fixed".
        ret.def_value = get_prop(pctxt, node, "fixed")
        ret.flags |= XML_SCHEMAS_ATTR_FIXED if ret.def_value
        # Attribute "default".
        attr = get_prop_node(node, "default")
        if attr
          # 3.2.3 : 1 default and fixed must not both be present.
          if (ret.flags & XML_SCHEMAS_ATTR_FIXED) != 0
            p_mutual_excl_attr_err(pctxt, ErrCode::SCHEMAP_SRC_ATTRIBUTE_1, ret, attr,
              "default", "fixed")
          else
            ret.def_value = get_node_content(pctxt, attr)
          end
        end
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          ret.annot = parse_annotation(pctxt, child, 1)
          child = child.next
        end
        if is_schema(child, "simpleType")
          if ret.type_name
            # 3.2.3 : 4 type and <simpleType> must not both be present.
            p_content_err(pctxt, ErrCode::SCHEMAP_SRC_ATTRIBUTE_4, nil, node, child,
              "The attribute 'type' and the <simpleType> child " \
              "are mutually exclusive", nil)
          else
            ret.subtypes = parse_simple_type(pctxt, schema, child, 0)
          end
          child = child.next
        end
        if child
          p_content_err(pctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?, simpleType?)")
        end
        ret
      end

      REF_ID_ALLOWED_ATTRS = %w[ref id].freeze

      # xmlSchemaParseAttributeGroupRef
      def parse_attribute_group_ref(pctxt, schema, node)
        return nil if pctxt.nil? || schema.nil? || node.nil?

        attr = get_prop_node(node, "ref")
        if attr.nil?
          p_missing_attr_err(pctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "ref", nil)
          return nil
        end
        _, ref_ns, ref = p_val_attr_node_q_name(pctxt, schema, nil, attr)
        return nil if check_reference(pctxt, schema, node, attr, ref_ns) != 0

        # Check for illegal attributes.
        p_check_illegal_attrs(pctxt, node, REF_ID_ALLOWED_ATTRS)
        # Attribute ID
        p_val_attr_id(pctxt, node, "id")
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          # TODO: We do not have a place to store the annotation, do we?
          parse_annotation(pctxt, child, 0)
          child = child.next
        end
        if child
          p_content_err(pctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?)")
        end
        # Handle attribute group redefinitions.
        if pctxt.is_redefine != 0 && pctxt.redef &&
            pctxt.redef.item.type == XML_SCHEMA_TYPE_ATTRIBUTEGROUP &&
            ref == pctxt.redef.ref_name && ref_ns == pctxt.redef.ref_target_ns
          # SPEC src-redefine (7.1) "... it must have exactly one such group."
          if pctxt.redef_counter != 0
            custom_err(pctxt, ErrCode::SCHEMAP_SRC_REDEFINE, node, nil,
              "The redefining attribute group definition " \
              "'%s' must not contain more than one " \
              "reference to the redefined definition",
              format_q_name(ref_ns, ref), nil)
            return nil
          end
          pctxt.redef_counter += 1
          # URGENT TODO: How to ensure that the reference will not be handled by the
          # normal component resolution mechanism?
          ret = new_q_name_ref(pctxt, XML_SCHEMA_TYPE_ATTRIBUTEGROUP, ref, ref_ns)
          return nil if ret.nil?

          ret.node = node
          pctxt.redef.reference = ret
        else
          # Create a QName-reference helper component. We will substitute this component for
          # the attribute uses of the referenced attribute group definition.
          ret = new_q_name_ref(pctxt, XML_SCHEMA_TYPE_ATTRIBUTEGROUP, ref, ref_ns)
          return nil if ret.nil?

          ret.node = node
          # Add to pending items, to be able to resolve the reference.
          wxs_add_pending(pctxt, ret)
        end
        ret
      end

      NAME_ID_ALLOWED_ATTRS = %w[name id].freeze

      # xmlSchemaParseAttributeGroupDefinition
      def parse_attribute_group_definition(pctxt, schema, node)
        return nil if pctxt.nil? || schema.nil? || node.nil?

        attr = get_prop_node(node, "name")
        if attr.nil?
          p_missing_attr_err(pctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "name", nil)
          return nil
        end
        # The name is crucial, exit if invalid.
        r, name = p_val_attr_node(pctxt, nil, attr, Types.get_built_in_type(XML_SCHEMAS_NCNAME))
        return nil if r != 0

        ret = add_attribute_group_definition(pctxt, schema, name, pctxt.target_namespace, node)
        return nil if ret.nil?

        # Check for illegal attributes.
        p_check_illegal_attrs(pctxt, node, NAME_ID_ALLOWED_ATTRS)
        # Attribute ID
        p_val_attr_id(pctxt, node, "id")
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          ret.annot = parse_annotation(pctxt, child, 1)
          child = child.next
        end
        # Parse contained attribute decls/refs.
        r, child, ret.attr_uses, has_refs = parse_local_attributes(pctxt, schema, child,
          ret.attr_uses, XML_SCHEMA_TYPE_ATTRIBUTEGROUP, 0)
        return nil if r == -1

        ret.flags |= XML_SCHEMAS_ATTRGROUP_HAS_REFS if has_refs != 0
        # Parse the attribute wildcard.
        if is_schema(child, "anyAttribute")
          ret.attribute_wildcard = parse_any_attribute(pctxt, schema, child)
          child = child.next
        end
        if child
          p_content_err(pctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?, ((attribute | attributeGroup)*, anyAttribute?))")
        end
        ret
      end

      # xmlSchemaPValAttrFormDefault
      # Returns [ret, flags]
      def p_val_attr_form_default(value, flags, flag_qualified)
        if value == "qualified"
          flags |= flag_qualified if (flags & flag_qualified) == 0
        elsif value != "unqualified"
          return [1, flags]
        end
        [0, flags]
      end

      # xmlSchemaPValAttrBlockFinal
      # Returns [ret, flags]
      def p_val_attr_block_final(value, flags, flag_all, flag_extension, flag_restriction,
                                 flag_substitution, flag_list, flag_union)
        ret = 0
        # TODO: This does not check for duplicate entries.
        return [-1, flags] if flags.nil? || value.nil?
        return [0, flags] if value.empty?

        if value == "#all"
          if flag_all != -1
            flags |= flag_all
          else
            flags |= flag_extension if flag_extension != -1
            flags |= flag_restriction if flag_restriction != -1
            flags |= flag_substitution if flag_substitution != -1
            flags |= flag_list if flag_list != -1
            flags |= flag_union if flag_union != -1
          end
        else
          value.scan(BLANK_TOKEN_RE) do |item|
            flag = case item
            when "extension" then flag_extension
            when "restriction" then flag_restriction
            when "substitution" then flag_substitution
            when "list" then flag_list
            when "union" then flag_union
            else -1
            end
            if flag != -1
              flags |= flag if (flags & flag) == 0
            else
              ret = 1
            end
            break if ret != 0
          end
        end
        [ret, flags]
      end

      # xmlSchemaCheckCSelectorXPath
      def check_c_selector_x_path(ctxt, idc, selector, attr, is_field)
        # c-selector-xpath: Schema Component Constraint: Selector Value OK
        if selector.nil?
          p_err(ctxt, idc.node, ErrCode::SCHEMAP_INTERNAL,
            "Internal error: xmlSchemaCheckCSelectorXPath, " \
            "the selector is not specified.\n", nil, nil)
          return -1
        end
        node = attr.nil? ? idc.node : attr
        if selector.xpath.nil?
          p_custom_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, node,
            "The XPath expression of the selector is not valid", nil)
          return ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE
        else
          ns_array = nil
          # Compile the XPath expression.
          ns_list = attr.nil? ? nil : Tree.get_ns_list(attr.doc, attr.parent)
          # Build an array of prefixes and namespaces.
          if ns_list
            ns_array = []
            ns_list.each do |ns|
              ns_array << ns.href << ns.prefix
            end
          end
          # TODO: Differentiate between "selector" and "field".
          flags = is_field != 0 ? XML_PATTERN_XSFIELD : XML_PATTERN_XSSEL
          selector.xpath_comp = Pattern.pattern_compile(selector.xpath, nil, flags, ns_array)
          if selector.xpath_comp.nil?
            p_custom_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, node,
              "The XPath expression '%s' could not be compiled", selector.xpath)
            return ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE
          end
        end
        0
      end

      ANNOTATED_ITEM_TYPES = [
        XML_SCHEMA_TYPE_ELEMENT, XML_SCHEMA_TYPE_ATTRIBUTE, XML_SCHEMA_TYPE_ANY_ATTRIBUTE,
        XML_SCHEMA_TYPE_ANY, XML_SCHEMA_TYPE_PARTICLE, XML_SCHEMA_TYPE_IDC_KEY,
        XML_SCHEMA_TYPE_IDC_KEYREF, XML_SCHEMA_TYPE_IDC_UNIQUE, XML_SCHEMA_TYPE_ATTRIBUTEGROUP,
        XML_SCHEMA_TYPE_NOTATION, XML_SCHEMA_FACET_MININCLUSIVE, XML_SCHEMA_FACET_MINEXCLUSIVE,
        XML_SCHEMA_FACET_MAXINCLUSIVE, XML_SCHEMA_FACET_MAXEXCLUSIVE,
        XML_SCHEMA_FACET_TOTALDIGITS, XML_SCHEMA_FACET_FRACTIONDIGITS, XML_SCHEMA_FACET_PATTERN,
        XML_SCHEMA_FACET_ENUMERATION, XML_SCHEMA_FACET_WHITESPACE, XML_SCHEMA_FACET_LENGTH,
        XML_SCHEMA_FACET_MAXLENGTH, XML_SCHEMA_FACET_MINLENGTH, XML_SCHEMA_TYPE_SIMPLE,
        XML_SCHEMA_TYPE_COMPLEX, XML_SCHEMA_TYPE_GROUP, XML_SCHEMA_TYPE_SEQUENCE,
        XML_SCHEMA_TYPE_CHOICE, XML_SCHEMA_TYPE_ALL,
      ].freeze

      # xmlSchemaAddAnnotation
      def add_annotation(ann_item, annot)
        return nil if ann_item.nil? || annot.nil?

        if ANNOTATED_ITEM_TYPES.include?(ann_item.type)
          # ADD_ANNOTATION(annot)
          if ann_item.annot.nil?
            ann_item.annot = annot
            return annot
          end
          cur = ann_item.annot
          cur = cur.next while cur.next
          cur.next = annot
        else
          p_custom_err(nil, ErrCode::SCHEMAP_INTERNAL, nil, nil,
            "Internal error: xmlSchemaAddAnnotation, " \
            "The item is not a annotated schema component", nil)
        end
        annot
      end

      IDC_SELECTOR_ALLOWED_ATTRS = %w[id xpath].freeze

      # xmlSchemaParseIDCSelectorAndField
      def parse_idc_selector_and_field(ctxt, idc, node, is_field)
        # Check for illegal attributes.
        p_check_illegal_attrs(ctxt, node, IDC_SELECTOR_ALLOWED_ATTRS)
        # Create the item.
        item = SchemaIDCSelect.new
        # Attribute "xpath" (mandatory).
        attr = get_prop_node(node, "xpath")
        if attr.nil?
          p_missing_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "name", nil)
        else
          item.xpath = get_node_content(ctxt, attr)
          # URGENT TODO: "field"s have an other syntax than "selector"s.
          if check_c_selector_x_path(ctxt, idc, item, attr, is_field) == -1
            p_err(ctxt, attr, ErrCode::SCHEMAP_INTERNAL,
              "Internal error: xmlSchemaParseIDCSelectorAndField, " \
              "validating the XPath expression of a IDC selector.\n", nil, nil)
          end
        end
        p_val_attr_id(ctxt, node, "id")
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          # Add the annotation to the parent IDC.
          add_annotation(idc, parse_annotation(ctxt, child, 1))
          child = child.next
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?)")
        end
        item
      end

      # xmlSchemaParseIDC
      def parse_idc(ctxt, schema, node, idc_category, target_namespace)
        # Check for illegal attributes.
        attr = node.properties
        while attr
          if attr.ns.nil?
            if attr.name != "id" && attr.name != "name" &&
                (idc_category != XML_SCHEMA_TYPE_IDC_KEYREF || attr.name != "refer")
              p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
            end
          elsif attr.ns.href == XML_SCHEMAS_NS
            p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
          end
          attr = attr.next
        end
        # Attribute "name" (mandatory).
        attr = get_prop_node(node, "name")
        if attr.nil?
          p_missing_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "name", nil)
          return nil
        end
        r, name = p_val_attr_node(ctxt, nil, attr, Types.get_built_in_type(XML_SCHEMAS_NCNAME))
        return nil if r != 0

        # Create the component.
        item = add_idc(ctxt, schema, name, target_namespace, idc_category, node)
        return nil if item.nil?

        p_val_attr_id(ctxt, node, "id")
        if idc_category == XML_SCHEMA_TYPE_IDC_KEYREF
          # Attribute "refer" (mandatory).
          attr = get_prop_node(node, "refer")
          if attr.nil?
            p_missing_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "refer", nil)
          else
            # Create a reference item.
            item.ref = new_q_name_ref(ctxt, XML_SCHEMA_TYPE_IDC_KEY, nil, nil)
            return nil if item.ref.nil?

            _, item.ref.target_namespace, item.ref.name =
              p_val_attr_node_q_name(ctxt, schema, nil, attr)
            check_reference(ctxt, schema, node, attr, item.ref.target_namespace)
          end
        end
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          item.annot = parse_annotation(ctxt, child, 1)
          child = child.next
        end
        if child.nil?
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_MISSING, nil, node, child,
            "A child element is missing", "(annotation?, (selector, field+))")
        end
        # Child element <selector>.
        if is_schema(child, "selector")
          item.selector = parse_idc_selector_and_field(ctxt, item, child, 0)
          child = child.next
          # Child elements <field>.
          if is_schema(child, "field")
            last_field = nil
            loop do
              field = parse_idc_selector_and_field(ctxt, item, child, 1)
              if field
                field.index = item.nb_fields
                item.nb_fields += 1
                if last_field
                  last_field.next = field
                else
                  item.fields = field
                end
                last_field = field
              end
              child = child.next
              break unless is_schema(child, "field")
            end
          else
            p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
              "(annotation?, (selector, field+))")
          end
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?, (selector, field+))")
        end
        item
      end

      ELEMENT_REF_ALLOWED_ATTRS = %w[ref name id maxOccurs minOccurs].freeze
      ELEMENT_DECL_ALLOWED_ATTRS = %w[name type id default fixed block nillable].freeze
      ELEMENT_LOCAL_EXTRA_ATTRS = %w[maxOccurs minOccurs form].freeze
      ELEMENT_GLOBAL_EXTRA_ATTRS = %w[final abstract substitutionGroup].freeze

      # xmlSchemaParseElement
      # Returns [element declaration or particle (or nil), is_elem_ref]
      def parse_element(ctxt, schema, node, top_level)
        return [nil, 0] if ctxt.nil? || schema.nil? || node.nil?

        decl = nil
        particle = nil
        annot = nil
        is_elem_ref = 0
        is_ref = false

        # If we get a "ref" attribute on a local <element> we will assume it's a reference -
        # even if there's a "name" attribute; this seems to be more robust.
        name_attr = get_prop_node(node, "name")
        attr = get_prop_node(node, "ref")
        if top_level != 0 || attr.nil?
          if name_attr.nil?
            p_missing_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "name", nil)
            return [nil, is_elem_ref]
          end
        else
          is_ref = true
        end

        p_val_attr_id(ctxt, node, "id")
        child = node.children
        if is_schema(child, "annotation")
          annot = parse_annotation(ctxt, child, 1)
          child = child.next
        end
        # Skip particle part if a global declaration.
        if top_level == 0
          # The particle part ==============================================
          min = get_min_occurs(ctxt, node, 0, -1, 1, "xs:nonNegativeInteger")
          max = get_max_occurs(ctxt, node, 0, UNBOUNDED, 1, "(xs:nonNegativeInteger | unbounded)")
          p_check_particle_correct_2(ctxt, nil, node, min, max)
          particle = add_particle(ctxt, node, min, max)
          return [nil, is_elem_ref] if particle.nil?

          if is_ref
            # The reference part =========================================
            is_elem_ref = 1
            _, ref_ns, ref = p_val_attr_node_q_name(ctxt, schema, nil, attr)
            check_reference(ctxt, schema, node, attr, ref_ns)
            # SPEC (3.3.3 : 2.1) "One of ref or name must be present, but not both"
            if name_attr
              p_mutual_excl_attr_err(ctxt, ErrCode::SCHEMAP_SRC_ELEMENT_2_1, nil, name_attr,
                "ref", "name")
            end
            # Check for illegal attributes.
            attr = node.properties
            while attr
              if attr.ns.nil?
                if ELEMENT_REF_ALLOWED_ATTRS.include?(attr.name)
                  attr = attr.next
                  next
                else
                  # SPEC (3.3.3 : 2.2)
                  p_custom_attr_err(ctxt, ErrCode::SCHEMAP_SRC_ELEMENT_2_2, nil, nil, attr,
                    "Only the attributes 'minOccurs', 'maxOccurs' and " \
                    "'id' are allowed in addition to 'ref'")
                  break
                end
              elsif attr.ns.href == XML_SCHEMAS_NS
                p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
              end
              attr = attr.next
            end
            # No children except <annotation> expected.
            if child
              p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
                "(annotation?)")
            end
            return [nil, is_elem_ref] if min == 0 && max == 0

            # Create the reference item and attach it to the particle.
            refer = new_q_name_ref(ctxt, XML_SCHEMA_TYPE_ELEMENT, ref, ref_ns)
            return [nil, is_elem_ref] if refer.nil?

            particle.children = refer
            particle.annot = annot
            # Add the particle to pending components, since the reference need to be
            # resolved.
            wxs_add_pending(ctxt, particle)
            return [particle, is_elem_ref]
          end
        end

        # The declaration part ===============================================
        ns = nil
        r, name = p_val_attr_node(ctxt, nil, name_attr, Types.get_built_in_type(XML_SCHEMAS_NCNAME))
        return [nil, is_elem_ref] if r != 0

        # Evaluate the target namespace.
        if top_level != 0
          ns = ctxt.target_namespace
        else
          attr = get_prop_node(node, "form")
          if attr
            attr_value = get_node_content(ctxt, attr)
            if attr_value == "qualified"
              ns = ctxt.target_namespace
            elsif attr_value != "unqualified"
              p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr, nil,
                "(qualified | unqualified)", attr_value, nil, nil, nil)
            end
          elsif (schema.flags & XML_SCHEMAS_QUALIF_ELEM) != 0
            ns = ctxt.target_namespace
          end
        end
        decl = add_element(ctxt, name, ns, node, top_level)
        return [nil, is_elem_ref] if decl.nil?

        # Check for illegal attributes.
        attr = node.properties
        while attr
          if attr.ns.nil?
            unless ELEMENT_DECL_ALLOWED_ATTRS.include?(attr.name)
              if top_level == 0
                unless ELEMENT_LOCAL_EXTRA_ATTRS.include?(attr.name)
                  p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
                end
              elsif !ELEMENT_GLOBAL_EXTRA_ATTRS.include?(attr.name)
                p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
              end
            end
          elsif attr.ns.href == XML_SCHEMAS_NS
            p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
          end
          attr = attr.next
        end
        # Extract/validate attributes.
        if top_level != 0
          # Process top attributes of global element declarations here.
          decl.flags |= XML_SCHEMAS_ELEM_GLOBAL
          decl.flags |= XML_SCHEMAS_ELEM_TOPLEVEL
          _, decl.subst_group_ns, decl.subst_group =
            p_val_attr_q_name(ctxt, schema, nil, node, "substitutionGroup")
          decl.flags |= XML_SCHEMAS_ELEM_ABSTRACT if get_boolean_prop(ctxt, node, "abstract", 0) != 0
          # Attribute "final".
          attr = get_prop_node(node, "final")
          if attr.nil?
            if (schema.flags & XML_SCHEMAS_FINAL_DEFAULT_EXTENSION) != 0
              decl.flags |= XML_SCHEMAS_ELEM_FINAL_EXTENSION
            end
            if (schema.flags & XML_SCHEMAS_FINAL_DEFAULT_RESTRICTION) != 0
              decl.flags |= XML_SCHEMAS_ELEM_FINAL_RESTRICTION
            end
          else
            attr_value = get_node_content(ctxt, attr)
            r, decl.flags = p_val_attr_block_final(attr_value, decl.flags, -1,
              XML_SCHEMAS_ELEM_FINAL_EXTENSION, XML_SCHEMAS_ELEM_FINAL_RESTRICTION, -1, -1, -1)
            if r != 0
              p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr, nil,
                "(#all | List of (extension | restriction))", attr_value, nil, nil, nil)
            end
          end
        end
        # Attribute "block".
        attr = get_prop_node(node, "block")
        if attr.nil?
          # Apply default "block" values.
          if (schema.flags & XML_SCHEMAS_BLOCK_DEFAULT_RESTRICTION) != 0
            decl.flags |= XML_SCHEMAS_ELEM_BLOCK_RESTRICTION
          end
          if (schema.flags & XML_SCHEMAS_BLOCK_DEFAULT_EXTENSION) != 0
            decl.flags |= XML_SCHEMAS_ELEM_BLOCK_EXTENSION
          end
          if (schema.flags & XML_SCHEMAS_BLOCK_DEFAULT_SUBSTITUTION) != 0
            decl.flags |= XML_SCHEMAS_ELEM_BLOCK_SUBSTITUTION
          end
        else
          attr_value = get_node_content(ctxt, attr)
          r, decl.flags = p_val_attr_block_final(attr_value, decl.flags, -1,
            XML_SCHEMAS_ELEM_BLOCK_EXTENSION, XML_SCHEMAS_ELEM_BLOCK_RESTRICTION,
            XML_SCHEMAS_ELEM_BLOCK_SUBSTITUTION, -1, -1)
          if r != 0
            p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr, nil,
              "(#all | List of (extension | restriction | substitution))", attr_value,
              nil, nil, nil)
          end
        end
        decl.flags |= XML_SCHEMAS_ELEM_NILLABLE if get_boolean_prop(ctxt, node, "nillable", 0) != 0

        attr = get_prop_node(node, "type")
        if attr
          _, decl.named_type_ns, decl.named_type = p_val_attr_node_q_name(ctxt, schema, nil, attr)
          check_reference(ctxt, schema, node, attr, decl.named_type_ns)
        end
        decl.value = get_prop(ctxt, node, "default")
        attr = get_prop_node(node, "fixed")
        if attr
          fixed = get_node_content(ctxt, attr)
          if decl.value
            # 3.3.3 : 1 default and fixed must not both be present.
            p_mutual_excl_attr_err(ctxt, ErrCode::SCHEMAP_SRC_ELEMENT_1, nil, attr, "default", "fixed")
          else
            decl.flags |= XML_SCHEMAS_ELEM_FIXED
            decl.value = fixed
          end
        end
        # And now for the children...
        if is_schema(child, "complexType")
          # 3.3.3 : 3 "type" and either <simpleType> or <complexType> are mutually exclusive
          if decl.named_type
            p_content_err(ctxt, ErrCode::SCHEMAP_SRC_ELEMENT_3, nil, node, child,
              "The attribute 'type' and the <complexType> child are " \
              "mutually exclusive", nil)
          else
            decl.subtypes = parse_complex_type(ctxt, schema, child, 0)
          end
          child = child.next
        elsif is_schema(child, "simpleType")
          # 3.3.3 : 3 "type" and either <simpleType> or <complexType> are mutually exclusive
          if decl.named_type
            p_content_err(ctxt, ErrCode::SCHEMAP_SRC_ELEMENT_3, nil, node, child,
              "The attribute 'type' and the <simpleType> child are " \
              "mutually exclusive", nil)
          else
            decl.subtypes = parse_simple_type(ctxt, schema, child, 0)
          end
          child = child.next
        end
        last_idc = nil
        while is_schema(child, "unique") || is_schema(child, "key") || is_schema(child, "keyref")
          cur_idc = nil
          if is_schema(child, "unique")
            cur_idc = parse_idc(ctxt, schema, child, XML_SCHEMA_TYPE_IDC_UNIQUE, decl.target_namespace)
          elsif is_schema(child, "key")
            cur_idc = parse_idc(ctxt, schema, child, XML_SCHEMA_TYPE_IDC_KEY, decl.target_namespace)
          elsif is_schema(child, "keyref")
            cur_idc = parse_idc(ctxt, schema, child, XML_SCHEMA_TYPE_IDC_KEYREF, decl.target_namespace)
          end
          # (sic) a NULL IDC resets the list tail, exactly as in C
          if last_idc
            last_idc.next = cur_idc
          else
            decl.idcs = cur_idc
          end
          last_idc = cur_idc
          child = child.next
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?, ((simpleType | complexType)?, (unique | key | keyref)*))")
        end
        decl.annot = annot
        # NOTE: Element Declaration Representation OK 4. will be checked at a different layer.
        return [decl, is_elem_ref] if top_level != 0

        particle.children = decl
        [particle, is_elem_ref]
      end

      UNION_ALLOWED_ATTRS = %w[id memberTypes].freeze

      # xmlSchemaParseUnion
      def parse_union(ctxt, schema, node)
        return -1 if ctxt.nil? || schema.nil? || node.nil?

        # Not a component, don't create it.
        type = ctxt.ctxt_type
        # Mark the simple type as being of variety "union".
        type.flags |= XML_SCHEMAS_TYPE_VARIETY_UNION
        # SPEC (Base type) (2) "If the <list> or <union> alternative is chosen, then the
        # `simple ur-type definition`."
        type.base_type = Types.get_built_in_type(XML_SCHEMAS_ANYSIMPLETYPE)
        # Check for illegal attributes.
        p_check_illegal_attrs(ctxt, node, UNION_ALLOWED_ATTRS)
        p_val_attr_id(ctxt, node, "id")
        # Attribute "memberTypes". This is a list of QNames.
        attr = get_prop_node(node, "memberTypes")
        if attr
          last_link = nil
          cur = get_node_content(ctxt, attr)
          return -1 if cur.nil?

          type.base = cur
          cur.scan(BLANK_TOKEN_RE) do |tmp|
            r, ns_name, local_name = p_val_attr_node_q_name_value(ctxt, schema, nil, attr, tmp)
            next unless r == 0

            # Create the member type link.
            link = SchemaTypeLink.new
            if last_link.nil?
              type.member_types = link
            else
              last_link.next = link
            end
            last_link = link
            # Create a reference item.
            ref = new_q_name_ref(ctxt, XML_SCHEMA_TYPE_SIMPLE, local_name, ns_name)
            return -1 if ref.nil?

            # Assign the reference to the link, it will be resolved later during fixup of
            # the union simple type.
            link.type = ref
          end
        end
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          # Add the annotation to the simple type ancestor.
          add_annotation(type, parse_annotation(ctxt, child, 1))
          child = child.next
        end
        if is_schema(child, "simpleType")
          last = nil
          # Anchor the member types in the "subtypes" field of the simple type.
          while is_schema(child, "simpleType")
            subtype = parse_simple_type(ctxt, schema, child, 0)
            if subtype
              if last.nil?
                type.subtypes = subtype
              else
                last.next = subtype
              end
              last = subtype
              last.next = nil
            end
            child = child.next
          end
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?, simpleType*)")
        end
        if attr.nil? && type.subtypes.nil?
          # src-union-memberTypes-or-simpleTypes
          p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_UNION_MEMBERTYPES_OR_SIMPLETYPES, nil, node,
            "Either the attribute 'memberTypes' or " \
            "at least one <simpleType> child must be present", nil)
        end
        0
      end

      LIST_ALLOWED_ATTRS = %w[id itemType].freeze

      # xmlSchemaParseList
      def parse_list(ctxt, schema, node)
        return nil if ctxt.nil? || schema.nil? || node.nil?

        # Not a component, don't create it.
        type = ctxt.ctxt_type
        # Mark the type as being of variety "list".
        type.flags |= XML_SCHEMAS_TYPE_VARIETY_LIST
        # SPEC (Base type) (2)
        type.base_type = Types.get_built_in_type(XML_SCHEMAS_ANYSIMPLETYPE)
        # Check for illegal attributes.
        p_check_illegal_attrs(ctxt, node, LIST_ALLOWED_ATTRS)
        p_val_attr_id(ctxt, node, "id")
        # Attribute "itemType". NOTE that we will use the "ref" and "refNs" fields for
        # holding the reference to the itemType.
        _, type.base_ns, type.base = p_val_attr_q_name(ctxt, schema, nil, node, "itemType")
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          add_annotation(type, parse_annotation(ctxt, child, 1))
          child = child.next
        end
        if is_schema(child, "simpleType")
          # src-list-itemType-or-simpleType
          if type.base
            p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_SIMPLE_TYPE_1, nil, node,
              "The attribute 'itemType' and the <simpleType> child " \
              "are mutually exclusive", nil)
          else
            type.subtypes = parse_simple_type(ctxt, schema, child, 0)
          end
          child = child.next
        elsif type.base.nil?
          p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_SIMPLE_TYPE_1, nil, node,
            "Either the attribute 'itemType' or the <simpleType> child " \
            "must be present", nil)
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?, simpleType?)")
        end
        if type.base.nil? && type.subtypes.nil? && get_prop_node(node, "itemType").nil?
          p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_SIMPLE_TYPE_1, nil, node,
            "Either the attribute 'itemType' or the <simpleType> child " \
            "must be present", nil)
        end
        nil
      end

      SIMPLE_TYPE_LOCAL_ALLOWED_ATTRS = %w[id].freeze
      SIMPLE_TYPE_GLOBAL_ALLOWED_ATTRS = %w[id name final].freeze

      # xmlSchemaParseSimpleType
      def parse_simple_type(ctxt, schema, node, top_level)
        return nil if ctxt.nil? || schema.nil? || node.nil?

        attr_value = nil
        has_restriction = false
        if top_level != 0
          attr = get_prop_node(node, "name")
          if attr.nil?
            p_missing_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "name", nil)
            return nil
          end
          r, attr_value = p_val_attr_node(ctxt, nil, attr, Types.get_built_in_type(XML_SCHEMAS_NCNAME))
          return nil if r != 0

          # Skip built-in types.
          if ctxt.is_s4s != 0
            if ctxt.is_redefine != 0
              # REDEFINE: Disallow redefinition of built-in-types.
              p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_REDEFINE, nil, node,
                "Redefinition of built-in simple types is not supported", nil)
              return nil
            end
            bi_type = Types.get_predefined_type(attr_value, XML_SCHEMAS_NS)
            return bi_type if bi_type
          end
        end
        # TargetNamespace: SPEC "The `actual value` of the targetNamespace [attribute] of the
        # <schema> ancestor element information item if present, otherwise `absent`.
        if top_level == 0
          # Parse as local simple type definition.
          type = add_type(ctxt, schema, XML_SCHEMA_TYPE_SIMPLE, nil, ctxt.target_namespace, node, 0)
          return nil if type.nil?

          type.type = XML_SCHEMA_TYPE_SIMPLE
          type.content_type = XML_SCHEMA_CONTENT_SIMPLE
          # Check for illegal attributes.
          p_check_illegal_attrs(ctxt, node, SIMPLE_TYPE_LOCAL_ALLOWED_ATTRS)
        else
          # Parse as global simple type definition.
          # Note that attrValue is the value of the attribute "name" here.
          type = add_type(ctxt, schema, XML_SCHEMA_TYPE_SIMPLE, attr_value, ctxt.target_namespace,
            node, 1)
          return nil if type.nil?

          type.type = XML_SCHEMA_TYPE_SIMPLE
          type.content_type = XML_SCHEMA_CONTENT_SIMPLE
          type.flags |= XML_SCHEMAS_TYPE_GLOBAL
          # Check for illegal attributes.
          p_check_illegal_attrs(ctxt, node, SIMPLE_TYPE_GLOBAL_ALLOWED_ATTRS)
          # Attribute "final".
          attr = get_prop_node(node, "final")
          if attr.nil?
            if (schema.flags & XML_SCHEMAS_FINAL_DEFAULT_RESTRICTION) != 0
              type.flags |= XML_SCHEMAS_TYPE_FINAL_RESTRICTION
            end
            type.flags |= XML_SCHEMAS_TYPE_FINAL_LIST if (schema.flags & XML_SCHEMAS_FINAL_DEFAULT_LIST) != 0
            type.flags |= XML_SCHEMAS_TYPE_FINAL_UNION if (schema.flags & XML_SCHEMAS_FINAL_DEFAULT_UNION) != 0
          else
            attr_value = get_prop(ctxt, node, "final")
            r, type.flags = p_val_attr_block_final(attr_value, type.flags, -1, -1,
              XML_SCHEMAS_TYPE_FINAL_RESTRICTION, -1, XML_SCHEMAS_TYPE_FINAL_LIST,
              XML_SCHEMAS_TYPE_FINAL_UNION)
            if r != 0
              p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, type, attr, nil,
                "(#all | List of (list | union | restriction)", attr_value, nil, nil, nil)
            end
          end
        end
        type.target_namespace = ctxt.target_namespace
        p_val_attr_id(ctxt, node, "id")
        # And now for the children...
        old_ctxt_type = ctxt.ctxt_type
        ctxt.ctxt_type = type

        child = node.children
        if is_schema(child, "annotation")
          type.annot = parse_annotation(ctxt, child, 1)
          child = child.next
        end
        if child.nil?
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_MISSING, nil, node, child, nil,
            "(annotation?, (restriction | list | union))")
        elsif is_schema(child, "restriction")
          parse_restriction(ctxt, schema, child, XML_SCHEMA_TYPE_SIMPLE)
          has_restriction = true
          child = child.next
        elsif is_schema(child, "list")
          parse_list(ctxt, schema, child)
          child = child.next
        elsif is_schema(child, "union")
          parse_union(ctxt, schema, child)
          child = child.next
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?, (restriction | list | union))")
        end
        # REDEFINE: SPEC src-redefine (5) "Within the [children], each <simpleType> must have
        # a <restriction> among its [children] ..."
        if top_level != 0 && ctxt.is_redefine != 0 && !has_restriction
          p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_REDEFINE, nil, node,
            "This is a redefinition, thus the <simpleType> must have a <restriction> child", nil)
        end

        ctxt.ctxt_type = old_ctxt_type
        type
      end

      GROUP_REF_ALLOWED_ATTRS = %w[ref id minOccurs maxOccurs].freeze

      # xmlSchemaParseModelGroupDefRef
      def parse_model_group_def_ref(ctxt, schema, node)
        return nil if ctxt.nil? || schema.nil? || node.nil?

        attr = get_prop_node(node, "ref")
        if attr.nil?
          p_missing_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "ref", nil)
          return nil
        end
        r, ref_ns, ref = p_val_attr_node_q_name(ctxt, schema, nil, attr)
        return nil if r != 0

        check_reference(ctxt, schema, node, attr, ref_ns)
        min = get_min_occurs(ctxt, node, 0, -1, 1, "xs:nonNegativeInteger")
        max = get_max_occurs(ctxt, node, 0, UNBOUNDED, 1, "(xs:nonNegativeInteger | unbounded)")
        # Check for illegal attributes.
        p_check_illegal_attrs(ctxt, node, GROUP_REF_ALLOWED_ATTRS)
        p_val_attr_id(ctxt, node, "id")
        item = add_particle(ctxt, node, min, max)
        return nil if item.nil?

        # Create a qname-reference and set as the term; it will be substituted for the model
        # group after the reference has been resolved.
        item.children = new_q_name_ref(ctxt, XML_SCHEMA_TYPE_GROUP, ref, ref_ns)
        p_check_particle_correct_2(ctxt, item, node, min, max)
        # And now for the children...
        child = node.children
        # TODO: Is annotation even allowed for a model group reference?
        if is_schema(child, "annotation")
          # TODO: What to do exactly with the annotation?
          item.annot = parse_annotation(ctxt, child, 1)
          child = child.next
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?)")
        end
        # Corresponds to no component at all if minOccurs==maxOccurs==0.
        return nil if min == 0 && max == 0

        item
      end

      # xmlSchemaParseModelGroupDefinition
      def parse_model_group_definition(ctxt, schema, node)
        return nil if ctxt.nil? || schema.nil? || node.nil?

        attr = get_prop_node(node, "name")
        if attr.nil?
          p_missing_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "name", nil)
          return nil
        end
        r, name = p_val_attr_node(ctxt, nil, attr, Types.get_built_in_type(XML_SCHEMAS_NCNAME))
        return nil if r != 0

        item = add_model_group_definition(ctxt, schema, name, ctxt.target_namespace, node)
        return nil if item.nil?

        # Check for illegal attributes.
        p_check_illegal_attrs(ctxt, node, NAME_ID_ALLOWED_ATTRS)
        p_val_attr_id(ctxt, node, "id")
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          item.annot = parse_annotation(ctxt, child, 1)
          child = child.next
        end
        if is_schema(child, "all")
          item.children = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_ALL, 0)
          child = child.next
        elsif is_schema(child, "choice")
          item.children = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_CHOICE, 0)
          child = child.next
        elsif is_schema(child, "sequence")
          item.children = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_SEQUENCE, 0)
          child = child.next
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?, (all | choice | sequence)?)")
        end
        item
      end

      MODEL_GROUP_PARTICLE_ALLOWED_ATTRS = %w[id maxOccurs minOccurs].freeze
      ID_ALLOWED_ATTRS = %w[id].freeze

      # xmlSchemaParseModelGroup
      def parse_model_group(ctxt, schema, node, type, with_particle)
        return nil if ctxt.nil? || schema.nil? || node.nil?

        particle = nil
        min = 1
        max = 1
        has_refs = 0
        # Create a model group with the given compositor.
        item = add_model_group(ctxt, schema, type, node)
        return nil if item.nil?

        if with_particle != 0
          if type == XML_SCHEMA_TYPE_ALL
            min = get_min_occurs(ctxt, node, 0, 1, 1, "(0 | 1)")
            max = get_max_occurs(ctxt, node, 1, 1, 1, "1")
          else
            # choice + sequence
            min = get_min_occurs(ctxt, node, 0, -1, 1, "xs:nonNegativeInteger")
            max = get_max_occurs(ctxt, node, 0, UNBOUNDED, 1, "(xs:nonNegativeInteger | unbounded)")
          end
          p_check_particle_correct_2(ctxt, nil, node, min, max)
          # Create a particle
          particle = add_particle(ctxt, node, min, max)
          return nil if particle.nil?

          particle.children = item
          # Check for illegal attributes.
          p_check_illegal_attrs(ctxt, node, MODEL_GROUP_PARTICLE_ALLOWED_ATTRS)
        else
          # Check for illegal attributes.
          p_check_illegal_attrs(ctxt, node, ID_ALLOWED_ATTRS)
        end

        # Extract and validate attributes.
        p_val_attr_id(ctxt, node, "id")
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          item.annot = parse_annotation(ctxt, child, 1)
          child = child.next
        end
        if type == XML_SCHEMA_TYPE_ALL
          last = nil
          while is_schema(child, "element")
            part, is_elem_ref = parse_element(ctxt, schema, child, 0)
            # SPEC cos-all-limited (2) "The {max occurs} of all the particles in the
            # {particles} of the ('all') group must be 0 or 1.
            if part
              has_refs += 1 if is_elem_ref != 0
              if part.min_occurs > 1
                p_custom_err(ctxt, ErrCode::SCHEMAP_COS_ALL_LIMITED, nil, child,
                  "Invalid value for minOccurs (must be 0 or 1)", nil)
                # Reset to 1.
                part.min_occurs = 1
              end
              if part.max_occurs > 1
                p_custom_err(ctxt, ErrCode::SCHEMAP_COS_ALL_LIMITED, nil, child,
                  "Invalid value for maxOccurs (must be 0 or 1)", nil)
                # Reset to 1.
                part.max_occurs = 1
              end
              if last.nil?
                item.children = part
              else
                last.next = part
              end
              last = part
            end
            child = child.next
          end
          if child
            p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
              "(annotation?, (annotation?, element*)")
          end
        else
          # choice + sequence
          part = nil
          last = nil
          while is_schema(child, "element") || is_schema(child, "group") ||
              is_schema(child, "any") || is_schema(child, "choice") || is_schema(child, "sequence")
            if is_schema(child, "element")
              part, is_elem_ref = parse_element(ctxt, schema, child, 0)
              has_refs += 1 if part && is_elem_ref != 0
            elsif is_schema(child, "group")
              part = parse_model_group_def_ref(ctxt, schema, child)
              has_refs += 1 if part
              # Handle redefinitions.
              if ctxt.is_redefine != 0 && ctxt.redef &&
                  ctxt.redef.item.type == XML_SCHEMA_TYPE_GROUP && part && part.children
                if get_q_name_ref_name(part.children) == ctxt.redef.ref_name &&
                    get_q_name_ref_target_ns(part.children) == ctxt.redef.ref_target_ns
                  # SPEC src-redefine: (6.1.1) "It must have exactly one such group."
                  if ctxt.redef_counter != 0
                    custom_err(ctxt, ErrCode::SCHEMAP_SRC_REDEFINE, child, nil,
                      "The redefining model group definition " \
                      "'%s' must not contain more than one " \
                      "reference to the redefined definition",
                      format_q_name(ctxt.redef.ref_target_ns, ctxt.redef.ref_name), nil)
                    part = nil
                  elsif part.min_occurs != 1 || part.max_occurs != 1
                    # SPEC src-redefine: (6.1.2) "The `actual value` of both that group's
                    # minOccurs and maxOccurs [attribute] must be 1 (or `absent`).
                    custom_err(ctxt, ErrCode::SCHEMAP_SRC_REDEFINE, child, nil,
                      "The redefining model group definition " \
                      "'%s' must not contain a reference to the " \
                      "redefined definition with a " \
                      "maxOccurs/minOccurs other than 1",
                      format_q_name(ctxt.redef.ref_target_ns, ctxt.redef.ref_name), nil)
                    part = nil
                  end
                  ctxt.redef.reference = part
                  ctxt.redef_counter += 1
                end
              end
            elsif is_schema(child, "any")
              part = parse_any(ctxt, schema, child)
            elsif is_schema(child, "choice")
              part = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_CHOICE, 1)
            elsif is_schema(child, "sequence")
              part = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_SEQUENCE, 1)
            end
            if part
              if last.nil?
                item.children = part
              else
                last.next = part
              end
              last = part
            end
            child = child.next
          end
          if child
            p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
              "(annotation?, (element | group | choice | sequence | any)*)")
          end
        end
        return nil if max == 0 && min == 0

        # We need to resolve references.
        wxs_add_pending(ctxt, item) if has_refs != 0
        with_particle != 0 ? particle : item
      end

      RESTRICTION_ALLOWED_ATTRS = %w[id base].freeze

      FACET_ELEMENT_NAMES = %w[minInclusive minExclusive maxInclusive maxExclusive totalDigits
        fractionDigits pattern enumeration whiteSpace length maxLength minLength].freeze

      # true if +child+ is one of the xs: facet elements accepted by <restriction>
      def p_is_facet_elem(child)
        !child.nil? && !child.ns.nil? && child.ns.href == XML_SCHEMAS_NS &&
          FACET_ELEMENT_NAMES.include?(child.name)
      end

      # xmlSchemaParseRestriction
      def parse_restriction(ctxt, schema, node, parent_type)
        return nil if ctxt.nil? || schema.nil? || node.nil?

        # Not a component, don't create it.
        type = ctxt.ctxt_type
        type.flags |= XML_SCHEMAS_TYPE_DERIVATION_METHOD_RESTRICTION
        # Check for illegal attributes.
        p_check_illegal_attrs(ctxt, node, RESTRICTION_ALLOWED_ATTRS)
        # Extract and validate attributes.
        p_val_attr_id(ctxt, node, "id")
        # Extract the base type. The "base" attribute is mandatory if inside a complex type
        # or if redefining.
        r, type.base_ns, type.base = p_val_attr_q_name(ctxt, schema, nil, node, "base")
        if r == 0
          if type.base.nil? && type.type == XML_SCHEMA_TYPE_COMPLEX
            p_missing_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "base", nil)
          elsif ctxt.is_redefine != 0 && (type.flags & XML_SCHEMAS_TYPE_GLOBAL) != 0
            if type.base.nil?
              p_missing_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "base", nil)
            elsif type.base != type.name || type.base_ns != type.target_namespace
              # REDEFINE: SPEC src-redefine (5)
              p_custom_err_ext(ctxt, ErrCode::SCHEMAP_SRC_REDEFINE, nil, node,
                "This is a redefinition, but the QName " \
                "value '%s' of the 'base' attribute does not match the " \
                "type's designation '%s'",
                format_q_name(type.base_ns, type.base),
                format_q_name(type.target_namespace, type.name), nil)
              # Avoid confusion and erase the values.
              type.base = nil
              type.base_ns = nil
            end
          end
        end
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          # Add the annotation to the simple type ancestor.
          add_annotation(type, parse_annotation(ctxt, child, 1))
          child = child.next
        end
        if parent_type == XML_SCHEMA_TYPE_SIMPLE
          # Corresponds to <simpleType><restriction><simpleType>.
          if is_schema(child, "simpleType")
            if type.base
              # src-restriction-base-or-simpleType
              p_content_err(ctxt, ErrCode::SCHEMAP_SRC_RESTRICTION_BASE_OR_SIMPLETYPE, nil, node,
                child, "The attribute 'base' and the <simpleType> child are " \
                "mutually exclusive", nil)
            else
              type.base_type = parse_simple_type(ctxt, schema, child, 0)
            end
            child = child.next
          elsif type.base.nil?
            p_content_err(ctxt, ErrCode::SCHEMAP_SRC_RESTRICTION_BASE_OR_SIMPLETYPE, nil, node,
              child, "Either the attribute 'base' or a <simpleType> child " \
              "must be present", nil)
          end
        elsif parent_type == XML_SCHEMA_TYPE_COMPLEX_CONTENT
          # Corresponds to <complexType><complexContent><restriction>... followed by:
          # Model groups <all>, <choice> and <sequence>.
          if is_schema(child, "all")
            type.subtypes = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_ALL, 1)
            child = child.next
          elsif is_schema(child, "choice")
            type.subtypes = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_CHOICE, 1)
            child = child.next
          elsif is_schema(child, "sequence")
            type.subtypes = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_SEQUENCE, 1)
            child = child.next
          elsif is_schema(child, "group")
            # Model group reference <group>.
            type.subtypes = parse_model_group_def_ref(ctxt, schema, child)
            # Note that the reference will be resolved in xmlSchemaResolveTypeReferences();
            child = child.next
          end
        elsif parent_type == XML_SCHEMA_TYPE_SIMPLE_CONTENT
          # Corresponds to <complexType><simpleContent><restriction>...
          # "1.1 the simple type definition corresponding to the <simpleType> among the
          # [children] of <restriction> if there is one;"
          if is_schema(child, "simpleType")
            # We will store the to-be-restricted simple type in type->contentTypeDef
            # *temporarily*.
            type.content_type_def = parse_simple_type(ctxt, schema, child, 0)
            return nil if type.content_type_def.nil?

            child = child.next
          end
        end

        if parent_type == XML_SCHEMA_TYPE_SIMPLE || parent_type == XML_SCHEMA_TYPE_SIMPLE_CONTENT
          lastfacet = nil
          # Add the facets to the simple type ancestor.
          while p_is_facet_elem(child)
            facet = parse_facet(ctxt, schema, child)
            if facet
              if lastfacet.nil?
                type.facets = facet
              else
                lastfacet.next = facet
              end
              lastfacet = facet
              lastfacet.next = nil
            end
            child = child.next
          end
          # Create links for derivation and validation.
          if type.facets
            last_facet_link = nil
            facet = type.facets
            loop do
              facet_link = SchemaFacetLink.new(facet: facet)
              if last_facet_link.nil?
                type.facet_set = facet_link
              else
                last_facet_link.next = facet_link
              end
              last_facet_link = facet_link
              facet = facet.next
              break if facet.nil?
            end
          end
        end
        if type.type == XML_SCHEMA_TYPE_COMPLEX
          # Attribute uses/declarations.
          r, child, type.attr_uses, = parse_local_attributes(ctxt, schema, child, type.attr_uses,
            XML_SCHEMA_TYPE_RESTRICTION, nil)
          return nil if r == -1

          # Attribute wildcard.
          if is_schema(child, "anyAttribute")
            type.attribute_wildcard = parse_any_attribute(ctxt, schema, child)
            child = child.next
          end
        end
        if child
          if parent_type == XML_SCHEMA_TYPE_COMPLEX_CONTENT
            p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
              "annotation?, (group | all | choice | sequence)?, " \
              "((attribute | attributeGroup)*, anyAttribute?))")
          elsif parent_type == XML_SCHEMA_TYPE_SIMPLE_CONTENT
            p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
              "(annotation?, (simpleType?, (minExclusive | minInclusive | " \
              "maxExclusive | maxInclusive | totalDigits | fractionDigits | " \
              "length | minLength | maxLength | enumeration | whiteSpace | " \
              "pattern)*)?, ((attribute | attributeGroup)*, anyAttribute?))")
          else
            # Simple type
            p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
              "(annotation?, (simpleType?, (minExclusive | minInclusive | " \
              "maxExclusive | maxInclusive | totalDigits | fractionDigits | " \
              "length | minLength | maxLength | enumeration | whiteSpace | " \
              "pattern)*))")
          end
        end
        nil
      end

      # xmlSchemaParseExtension
      def parse_extension(ctxt, schema, node, parent_type)
        return nil if ctxt.nil? || schema.nil? || node.nil?

        # Not a component, don't create it.
        type = ctxt.ctxt_type
        type.flags |= XML_SCHEMAS_TYPE_DERIVATION_METHOD_EXTENSION
        # Check for illegal attributes.
        p_check_illegal_attrs(ctxt, node, RESTRICTION_ALLOWED_ATTRS)
        p_val_attr_id(ctxt, node, "id")
        # Attribute "base" - mandatory.
        r, type.base_ns, type.base = p_val_attr_q_name(ctxt, schema, nil, node, "base")
        if r == 0 && type.base.nil?
          p_missing_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "base", nil)
        end
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          # Add the annotation to the type ancestor.
          add_annotation(type, parse_annotation(ctxt, child, 1))
          child = child.next
        end
        if parent_type == XML_SCHEMA_TYPE_COMPLEX_CONTENT
          # Corresponds to <complexType><complexContent><extension>... and:
          # Model groups <all>, <choice>, <sequence> and <group>.
          if is_schema(child, "all")
            type.subtypes = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_ALL, 1)
            child = child.next
          elsif is_schema(child, "choice")
            type.subtypes = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_CHOICE, 1)
            child = child.next
          elsif is_schema(child, "sequence")
            type.subtypes = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_SEQUENCE, 1)
            child = child.next
          elsif is_schema(child, "group")
            type.subtypes = parse_model_group_def_ref(ctxt, schema, child)
            # Note that the reference will be resolved in xmlSchemaResolveTypeReferences();
            child = child.next
          end
        end
        if child
          # Attribute uses/declarations.
          r, child, type.attr_uses, = parse_local_attributes(ctxt, schema, child, type.attr_uses,
            XML_SCHEMA_TYPE_EXTENSION, nil)
          return nil if r == -1

          # Attribute wildcard.
          if is_schema(child, "anyAttribute")
            ctxt.ctxt_type.attribute_wildcard = parse_any_attribute(ctxt, schema, child)
            child = child.next
          end
        end
        if child
          if parent_type == XML_SCHEMA_TYPE_COMPLEX_CONTENT
            # Complex content extension.
            p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
              "(annotation?, ((group | all | choice | sequence)?, " \
              "((attribute | attributeGroup)*, anyAttribute?)))")
          else
            # Simple content extension.
            p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
              "(annotation?, ((attribute | attributeGroup)*, anyAttribute?))")
          end
        end
        nil
      end

      # xmlSchemaParseSimpleContent
      # Returns [ret, has_restriction_or_extension]
      def parse_simple_content(ctxt, schema, node)
        return [-1, 0] if ctxt.nil? || schema.nil? || node.nil?

        has_restriction_or_extension = 0
        # Not a component, don't create it.
        type = ctxt.ctxt_type
        type.content_type = XML_SCHEMA_CONTENT_SIMPLE
        # Check for illegal attributes.
        p_check_illegal_attrs(ctxt, node, ID_ALLOWED_ATTRS)
        p_val_attr_id(ctxt, node, "id")
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          # Add the annotation to the complex type ancestor.
          add_annotation(type, parse_annotation(ctxt, child, 1))
          child = child.next
        end
        if child.nil?
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_MISSING, nil, node, nil, nil,
            "(annotation?, (restriction | extension))")
        end
        # (sic) reported twice, as in C
        if child.nil?
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_MISSING, nil, node, nil, nil,
            "(annotation?, (restriction | extension))")
        end
        if is_schema(child, "restriction")
          parse_restriction(ctxt, schema, child, XML_SCHEMA_TYPE_SIMPLE_CONTENT)
          has_restriction_or_extension = 1
          child = child.next
        elsif is_schema(child, "extension")
          parse_extension(ctxt, schema, child, XML_SCHEMA_TYPE_SIMPLE_CONTENT)
          has_restriction_or_extension = 1
          child = child.next
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?, (restriction | extension))")
        end
        [0, has_restriction_or_extension]
      end

      COMPLEX_CONTENT_ALLOWED_ATTRS = %w[id mixed].freeze

      # xmlSchemaParseComplexContent
      # Returns [ret, has_restriction_or_extension]
      def parse_complex_content(ctxt, schema, node)
        return [-1, 0] if ctxt.nil? || schema.nil? || node.nil?

        has_restriction_or_extension = 0
        # Not a component, don't create it.
        type = ctxt.ctxt_type
        # Check for illegal attributes.
        p_check_illegal_attrs(ctxt, node, COMPLEX_CONTENT_ALLOWED_ATTRS)
        p_val_attr_id(ctxt, node, "id")
        # Set the 'mixed' on the complex type ancestor.
        if get_boolean_prop(ctxt, node, "mixed", 0) != 0
          type.flags |= XML_SCHEMAS_TYPE_MIXED if (type.flags & XML_SCHEMAS_TYPE_MIXED) == 0
        end
        child = node.children
        if is_schema(child, "annotation")
          # Add the annotation to the complex type ancestor.
          add_annotation(type, parse_annotation(ctxt, child, 1))
          child = child.next
        end
        if child.nil?
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_MISSING, nil, node, nil, nil,
            "(annotation?, (restriction | extension))")
        end
        # (sic) reported twice, as in C
        if child.nil?
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_MISSING, nil, node, nil, nil,
            "(annotation?, (restriction | extension))")
        end
        if is_schema(child, "restriction")
          parse_restriction(ctxt, schema, child, XML_SCHEMA_TYPE_COMPLEX_CONTENT)
          has_restriction_or_extension = 1
          child = child.next
        elsif is_schema(child, "extension")
          parse_extension(ctxt, schema, child, XML_SCHEMA_TYPE_COMPLEX_CONTENT)
          has_restriction_or_extension = 1
          child = child.next
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?, (restriction | extension))")
        end
        [0, has_restriction_or_extension]
      end

      # xmlSchemaParseComplexType
      def parse_complex_type(ctxt, schema, node, top_level)
        return nil if ctxt.nil? || schema.nil? || node.nil?

        name = nil
        final = false
        block = false
        has_restriction_or_extension = 0
        ctxt_type = ctxt.ctxt_type

        if top_level != 0
          attr = get_prop_node(node, "name")
          if attr.nil?
            p_missing_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "name", nil)
            return nil
          end
          r, name = p_val_attr_node(ctxt, nil, attr, Types.get_built_in_type(XML_SCHEMAS_NCNAME))
          return nil if r != 0
        end

        if top_level == 0
          # Parse as local complex type definition.
          type = add_type(ctxt, schema, XML_SCHEMA_TYPE_COMPLEX, nil, ctxt.target_namespace, node, 0)
          return nil if type.nil?

          name = type.name
          type.node = node
          type.type = XML_SCHEMA_TYPE_COMPLEX
          # TODO: We need the target namespace.
        else
          # Parse as global complex type definition.
          type = add_type(ctxt, schema, XML_SCHEMA_TYPE_COMPLEX, name, ctxt.target_namespace, node, 1)
          return nil if type.nil?

          type.node = node
          type.type = XML_SCHEMA_TYPE_COMPLEX
          type.flags |= XML_SCHEMAS_TYPE_GLOBAL
        end
        type.target_namespace = ctxt.target_namespace
        # Handle attributes.
        attr = node.properties
        while attr
          if attr.ns.nil?
            aname = attr.name
            if aname == "id"
              # Attribute "id".
              p_val_attr_id(ctxt, node, "id")
            elsif aname == "mixed"
              # Attribute "mixed".
              type.flags |= XML_SCHEMAS_TYPE_MIXED if p_get_bool_node_value(ctxt, nil, attr) != 0
            elsif top_level != 0
              # Attributes of global complex type definitions.
              if aname == "name"
                # Pass.
              elsif aname == "abstract"
                # Attribute "abstract".
                type.flags |= XML_SCHEMAS_TYPE_ABSTRACT if p_get_bool_node_value(ctxt, nil, attr) != 0
              elsif aname == "final"
                # Attribute "final".
                attr_value = get_node_content(ctxt, attr)
                r, type.flags = p_val_attr_block_final(attr_value, type.flags, -1,
                  XML_SCHEMAS_TYPE_FINAL_EXTENSION, XML_SCHEMAS_TYPE_FINAL_RESTRICTION, -1, -1, -1)
                if r != 0
                  p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr, nil,
                    "(#all | List of (extension | restriction))", attr_value, nil, nil, nil)
                else
                  final = true
                end
              elsif aname == "block"
                # Attribute "block".
                attr_value = get_node_content(ctxt, attr)
                r, type.flags = p_val_attr_block_final(attr_value, type.flags, -1,
                  XML_SCHEMAS_TYPE_BLOCK_EXTENSION, XML_SCHEMAS_TYPE_BLOCK_RESTRICTION, -1, -1, -1)
                if r != 0
                  p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr, nil,
                    "(#all | List of (extension | restriction)) ", attr_value, nil, nil, nil)
                else
                  block = true
                end
              else
                p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
              end
            else
              p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
            end
          elsif attr.ns.href == XML_SCHEMAS_NS
            p_illegal_attr_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_NOT_ALLOWED, nil, attr)
          end
          attr = attr.next
        end
        unless block
          # Apply default "block" values.
          if (schema.flags & XML_SCHEMAS_BLOCK_DEFAULT_RESTRICTION) != 0
            type.flags |= XML_SCHEMAS_TYPE_BLOCK_RESTRICTION
          end
          if (schema.flags & XML_SCHEMAS_BLOCK_DEFAULT_EXTENSION) != 0
            type.flags |= XML_SCHEMAS_TYPE_BLOCK_EXTENSION
          end
        end
        unless final
          # Apply default "block" values.
          if (schema.flags & XML_SCHEMAS_FINAL_DEFAULT_RESTRICTION) != 0
            type.flags |= XML_SCHEMAS_TYPE_FINAL_RESTRICTION
          end
          if (schema.flags & XML_SCHEMAS_FINAL_DEFAULT_EXTENSION) != 0
            type.flags |= XML_SCHEMAS_TYPE_FINAL_EXTENSION
          end
        end
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          type.annot = parse_annotation(ctxt, child, 1)
          child = child.next
        end
        ctxt.ctxt_type = type
        if is_schema(child, "simpleContent")
          # <complexType><simpleContent>... 3.4.3 : 2.2 Specifying mixed='true' when the
          # <simpleContent> alternative is chosen has no effect
          type.flags ^= XML_SCHEMAS_TYPE_MIXED if (type.flags & XML_SCHEMAS_TYPE_MIXED) != 0
          _, has_restriction_or_extension = parse_simple_content(ctxt, schema, child)
          child = child.next
        elsif is_schema(child, "complexContent")
          # <complexType><complexContent>...
          type.content_type = XML_SCHEMA_CONTENT_EMPTY
          _, has_restriction_or_extension = parse_complex_content(ctxt, schema, child)
          child = child.next
        else
          # E.g <complexType><sequence>... or <complexType><attribute>... etc.
          # SPEC "...the third alternative (neither <simpleContent> nor <complexContent>) is
          # chosen. This case is understood as shorthand for complex content restricting the
          # `ur-type definition`, and the details of the mappings should be modified as
          # necessary.
          type.base_type = Types.get_built_in_type(XML_SCHEMAS_ANYTYPE)
          type.flags |= XML_SCHEMAS_TYPE_DERIVATION_METHOD_RESTRICTION
          # Parse model groups.
          if is_schema(child, "all")
            type.subtypes = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_ALL, 1)
            child = child.next
          elsif is_schema(child, "choice")
            type.subtypes = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_CHOICE, 1)
            child = child.next
          elsif is_schema(child, "sequence")
            type.subtypes = parse_model_group(ctxt, schema, child, XML_SCHEMA_TYPE_SEQUENCE, 1)
            child = child.next
          elsif is_schema(child, "group")
            type.subtypes = parse_model_group_def_ref(ctxt, schema, child)
            # Note that the reference will be resolved in xmlSchemaResolveTypeReferences();
            child = child.next
          end
          # Parse attribute decls/refs.
          r, child, type.attr_uses, = parse_local_attributes(ctxt, schema, child, type.attr_uses,
            XML_SCHEMA_TYPE_RESTRICTION, nil)
          return nil if r == -1

          # Parse attribute wildcard.
          if is_schema(child, "anyAttribute")
            type.attribute_wildcard = parse_any_attribute(ctxt, schema, child)
            child = child.next
          end
        end
        if child
          p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?, (simpleContent | complexContent | " \
            "((group | all | choice | sequence)?, ((attribute | " \
            "attributeGroup)*, anyAttribute?))))")
        end
        # REDEFINE: SPEC src-redefine (5)
        if top_level != 0 && ctxt.is_redefine != 0 && has_restriction_or_extension == 0
          p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_REDEFINE, nil, node,
            "This is a redefinition, thus the " \
            "<complexType> must have a <restriction> or <extension> " \
            "grand-child", nil)
        end
        ctxt.ctxt_type = ctxt_type
        type
      end
    end
  end
end
