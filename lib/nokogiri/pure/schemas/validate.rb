# frozen_string_literal: true

require_relative "macros"
require_relative "validate_idc"

# Instance validation of libxml2 2.13.9 xmlschemas.c (lines ~21520-28853): XSI schema assembly,
# simple type validation (cvc-simple-type), attribute/element validation, content models,
# the DOM walker and the SAX-driven (streaming) validator used by xmlSchemaValidateFile.
module Nokogiri
  module Pure
    module Schemas
      XML_SCHEMA_PUSH_TEXT_PERSIST = 1
      XML_SCHEMA_PUSH_TEXT_CREATED = 2
      XML_SCHEMA_PUSH_TEXT_VOLATILE = 3

      # VERROR(err, type, msg)
      def verror(vctxt, err, type, msg)
        custom_err(vctxt, err, nil, type, msg, nil, nil)
      end

      # xmlSchemaAssembleByLocation
      def assemble_by_location(vctxt, schema, node, ns_name, location)
        return -1 if vctxt.nil? || schema.nil?

        if vctxt.pctxt.nil?
          internal_err(vctxt, "xmlSchemaAssembleByLocation", "no parser context available")
          return -1
        end
        pctxt = vctxt.pctxt
        if pctxt.constructor.nil?
          internal_err(pctxt, "xmlSchemaAssembleByLocation", "no constructor")
          return -1
        end
        location = build_absolute_uri(pctxt.dict, location, node)
        ret, bucket = add_schema_doc(pctxt, XML_SCHEMA_SCHEMA_IMPORT, location, nil, nil, 0, node, nil, ns_name)
        return ret if ret != 0

        if bucket.nil?
          custom_warning(vctxt, ErrCode::SCHEMAV_MISC, node, nil,
            "The document at location '%s' could not be acquired", location, nil, nil)
          return ret
        end
        pctxt.constructor.bucket = bucket if pctxt.constructor.bucket.nil?
        return 0 if bucket.nil? || !can_parse_schema(bucket)

        pctxt.nberrors = 0
        pctxt.err = 0
        pctxt.doc = bucket.doc
        ret = parse_new_doc_with_context(pctxt, schema, bucket)
        if ret == -1
          pctxt.doc = nil
          return -1
        end
        ret = pctxt.err if ret == 0 && pctxt.nberrors != 0
        if pctxt.nberrors == 0
          fixup_components(pctxt, bucket)
          ret = pctxt.err
          vctxt.err = ret if ret != 0 && vctxt.err == 0
          vctxt.nberrors += pctxt.nberrors
        else
          vctxt.nberrors += pctxt.nberrors
        end
        pctxt.doc = nil
        ret
      end

      # xmlSchemaGetMetaAttrInfo
      def get_meta_attr_info(vctxt, meta_type)
        n = vctxt.nb_attr_infos
        return nil if n == 0

        infos = vctxt.attr_infos
        i = 0
        while i < n
          iattr = infos[i]
          return iattr if iattr.meta_type == meta_type

          i += 1
        end
        nil
      end

      def blank_byte?(c) = c == 0x20 || c == 0x9 || c == 0xA || c == 0xD

      # xmlSchemaAssembleByXSI
      def assemble_by_xsi(vctxt)
        iattr = get_meta_attr_info(vctxt, XML_SCHEMA_ATTR_INFO_META_XSI_SCHEMA_LOC)
        iattr ||= get_meta_attr_info(vctxt, XML_SCHEMA_ATTR_INFO_META_XSI_NO_NS_SCHEMA_LOC)
        return 0 if iattr.nil?

        ret = 0
        nsname = nil
        s = iattr.value.to_s.b
        cur = 0
        n = s.bytesize
        loop do
          if iattr.meta_type == XML_SCHEMA_ATTR_INFO_META_XSI_SCHEMA_LOC
            cur += 1 while cur < n && blank_byte?(s.getbyte(cur))
            e = cur
            e += 1 while e < n && !blank_byte?(s.getbyte(e))
            break if e == cur

            nsname = s.byteslice(cur, e - cur).force_encoding(Encoding::UTF_8)
            cur = e
          end
          cur += 1 while cur < n && blank_byte?(s.getbyte(cur))
          e = cur
          e += 1 while e < n && !blank_byte?(s.getbyte(e))
          if e == cur
            if iattr.meta_type == XML_SCHEMA_ATTR_INFO_META_XSI_SCHEMA_LOC
              custom_warning(vctxt, ErrCode::SCHEMAV_MISC, iattr.node, nil,
                "The value must consist of tuples: the target namespace name and the document's URI",
                nil, nil, nil)
            end
            break
          end
          location = s.byteslice(cur, e - cur).force_encoding(Encoding::UTF_8)
          cur = e
          ret = assemble_by_location(vctxt, vctxt.schema, iattr.node, nsname, location)
          if ret == -1
            internal_err(vctxt, "xmlSchemaAssembleByXSI", "assembling schemata")
            return -1
          end
          break if cur >= n
        end
        ret
      end

      # xmlSchemaLookupNamespace
      def lookup_namespace(vctxt, prefix)
        if vctxt.sax
          i = vctxt.depth
          while i >= 0
            inode = vctxt.elem_infos[i]
            if inode.nb_ns_bindings != 0
              b = inode.ns_bindings
              j = 0
              while j < inode.nb_ns_bindings * 2
                return b[j + 1] if (prefix.nil? && b[j].nil?) || (!prefix.nil? && prefix == b[j])

                j += 2
              end
            end
            i -= 1
          end
          nil
        else
          node = vctxt.inode.node
          if node.nil? || node.doc.nil?
            internal_err(vctxt, "xmlSchemaLookupNamespace", "no node or node's doc available")
            return nil
          end
          ns = Tree.search_ns(node.doc, node, prefix)
          ns&.href
        end
      end

      # xmlSchemaValidateNotation(vctxt, schema, node, value, &val, valNeeded) -> [ret, val]
      def validate_notation(vctxt, schema, node, value, val_needed)
        if vctxt && vctxt.schema.nil?
          internal_err(vctxt, "xmlSchemaValidateNotation", "a schema is needed on the validation context")
          return [-1, nil]
        end
        ret = Types.validate_q_name(value, 1)
        return [ret, nil] if ret != 0

        val = nil
        local_name, prefix = Tree.split_qname2(value)
        if prefix
          ns_name = nil
          if vctxt
            ns_name = lookup_namespace(vctxt, prefix)
          elsif node
            ns = Tree.search_ns(node.doc, node, prefix)
            ns_name = ns.href if ns
          else
            return [1, nil]
          end
          return [1, nil] if ns_name.nil?

          if get_notation(schema, local_name, ns_name)
            val = Types.new_notation_value(local_name, ns_name) if val_needed
          else
            ret = 1
          end
        else
          if get_notation(schema, value, nil)
            val = Types.new_notation_value(value, nil) if val_needed
          else
            return [1, nil]
          end
        end
        [ret, val]
      end

      # xmlSchemaGetFreshAttrInfo
      def get_fresh_attr_info(vctxt)
        vctxt.attr_infos ||= []
        iattr = SchemaAttrInfo.new(node_type: ATTRIBUTE_NODE)
        vctxt.attr_infos[vctxt.nb_attr_infos] = iattr
        vctxt.nb_attr_infos += 1
        iattr
      end

      # xmlSchemaValidatorPushAttribute
      def validator_push_attribute(vctxt, attr_node, node_line, local_name, ns_name, owned_names, value, owned_value)
        attr = get_fresh_attr_info(vctxt)
        attr.node = attr_node
        attr.node_line = node_line
        attr.state = XML_SCHEMAS_ATTR_UNKNOWN
        attr.local_name = local_name
        attr.ns_name = ns_name
        attr.flags |= XML_SCHEMA_NODE_INFO_FLAG_OWNED_NAMES if owned_names != 0
        if ns_name
          if local_name == "nil"
            attr.meta_type = XML_SCHEMA_ATTR_INFO_META_XSI_NIL if ns_name == XML_SCHEMA_INSTANCE_NS
          elsif local_name == "type"
            attr.meta_type = XML_SCHEMA_ATTR_INFO_META_XSI_TYPE if ns_name == XML_SCHEMA_INSTANCE_NS
          elsif local_name == "schemaLocation"
            attr.meta_type = XML_SCHEMA_ATTR_INFO_META_XSI_SCHEMA_LOC if ns_name == XML_SCHEMA_INSTANCE_NS
          elsif local_name == "noNamespaceSchemaLocation"
            attr.meta_type = XML_SCHEMA_ATTR_INFO_META_XSI_NO_NS_SCHEMA_LOC if ns_name == XML_SCHEMA_INSTANCE_NS
          elsif ns_name == XML_NAMESPACE_NS
            attr.meta_type = XML_SCHEMA_ATTR_INFO_META_XMLNS
          end
        end
        attr.value = value
        attr.flags |= XML_SCHEMA_NODE_INFO_FLAG_OWNED_VALUES if owned_value != 0
        attr.state = XML_SCHEMAS_ATTR_META if attr.meta_type != 0
        0
      end

      # xmlSchemaClearElemInfo
      def clear_elem_info(vctxt, ielem)
        ielem.has_keyrefs = 0
        ielem.applied_xpath = 0
        ielem.local_name = nil
        ielem.ns_name = nil
        ielem.value = nil
        ielem.val = nil
        if ielem.idc_matchers
          idc_release_matcher_list(vctxt, ielem.idc_matchers)
          ielem.idc_matchers = nil
        end
        ielem.idc_table = nil
        ielem.regex_ctxt = nil
        if ielem.ns_bindings
          ielem.ns_bindings = nil
          ielem.nb_ns_bindings = 0
          ielem.size_ns_bindings = 0
        end
      end

      # xmlSchemaGetFreshElemInfo
      def get_fresh_elem_info(vctxt)
        vctxt.elem_infos ||= []
        info = SchemaNodeInfo.new(node_type: ELEMENT_NODE, depth: vctxt.depth)
        vctxt.elem_infos[vctxt.depth] = info
        info
      end

      # xmlSchemaValidateFacets
      def validate_facets(actxt, node, type, val_type, value, val, length, fire_errors)
        return 0 if type.type == XML_SCHEMA_TYPE_BASIC

        error = 0
        ret = 0
        len = 0
        catch(:pattern_and_enum) do
          throw :pattern_and_enum if type.facet_set.nil?

          if wxs_is_atomic(type)
            tmp_type = get_primitive_type(type)
            ws = if tmp_type.built_in_type == XML_SCHEMAS_STRING || wxs_is_any_simple_type(tmp_type)
              get_white_space_facet_value(type)
            else
              XML_SCHEMA_WHITESPACE_COLLAPSE
            end
            val_type = Types.get_val_type(val) if val
            ret = 0
            facet_link = type.facet_set
            while facet_link
              ft = facet_link.facet.type
              if ft == XML_SCHEMA_FACET_WHITESPACE || ft == XML_SCHEMA_FACET_PATTERN || ft == XML_SCHEMA_FACET_ENUMERATION
                facet_link = facet_link.next
                next
              end
              if ft == XML_SCHEMA_FACET_LENGTH || ft == XML_SCHEMA_FACET_MINLENGTH || ft == XML_SCHEMA_FACET_MAXLENGTH
                ret, len = Types.validate_length_facet_whtsp(facet_link.facet, val_type, value, val, ws)
                len ||= 0
              else
                ret = Types.validate_facet_whtsp(facet_link.facet, ws, val_type, value, val, ws)
              end
              if ret < 0
                internal_err(actxt, "xmlSchemaValidateFacets", "validating against a atomic type facet")
                return -1
              elsif ret > 0
                return ret unless fire_errors

                facet_err(actxt, ret, node, value, len, type, facet_link.facet, nil, nil, nil)
                error = ret if error == 0
              end
              ret = 0
              facet_link = facet_link.next
            end
          elsif !wxs_is_list(type)
            throw :pattern_and_enum
          end

          # WXS_IS_LIST:
          throw :pattern_and_enum unless wxs_is_list(type)

          ret = 0
          facet_link = type.facet_set
          while facet_link
            ft = facet_link.facet.type
            if ft == XML_SCHEMA_FACET_LENGTH || ft == XML_SCHEMA_FACET_MINLENGTH || ft == XML_SCHEMA_FACET_MAXLENGTH
              ret, = Types.validate_list_simple_type_facet(facet_link.facet, value, length)
              if ret < 0
                internal_err(actxt, "xmlSchemaValidateFacets", "validating against a list type facet")
                return -1
              elsif ret > 0
                return ret unless fire_errors

                facet_err(actxt, ret, node, value, length, type, facet_link.facet, nil, nil, nil)
                error = ret if error == 0
              end
              ret = 0
            end
            facet_link = facet_link.next
          end
        end

        # pattern_and_enum:
        found = false
        ret = 0
        tmp_type = type
        loop do
          facet = tmp_type.facets
          while facet
            if facet.type == XML_SCHEMA_FACET_ENUMERATION
              found = true
              ret = are_values_equal(facet.val, val)
              break if ret == 1

              if ret < 0
                internal_err(actxt, "xmlSchemaValidateFacets", "validating against an enumeration facet")
                return -1
              end
            end
            facet = facet.next
          end
          break if ret != 0
          break if found

          tmp_type = tmp_type.base_type
          break if tmp_type.nil? || tmp_type.type == XML_SCHEMA_TYPE_BASIC
        end
        if found && ret == 0
          ret = ErrCode::SCHEMAV_CVC_ENUMERATION_VALID
          return ret unless fire_errors

          facet_err(actxt, ret, node, value, 0, type, nil, nil, nil, nil)
          error = ret if error == 0
        end

        tmp_type = type
        facet = nil
        loop do
          found = false
          facet_link = tmp_type.facet_set
          while facet_link
            if facet_link.facet.type == XML_SCHEMA_FACET_PATTERN
              found = true
              ret = XmlRegexp.regexp_exec(facet_link.facet.regexp, value)
              break if ret == 1

              if ret < 0
                internal_err(actxt, "xmlSchemaValidateFacets", "validating against a pattern facet")
                return -1
              else
                facet = facet_link.facet
              end
            end
            facet_link = facet_link.next
          end
          if found && ret != 1
            ret = ErrCode::SCHEMAV_CVC_PATTERN_VALID
            return ret unless fire_errors

            facet_err(actxt, ret, node, value, 0, type, facet, nil, nil, nil)
            error = ret if error == 0
            break
          end
          tmp_type = tmp_type.base_type
          break if tmp_type.nil? || tmp_type.type == XML_SCHEMA_TYPE_BASIC
        end
        error
      end

      # xmlSchemaNormalizeValue
      def normalize_value(type, value)
        case get_white_space_facet_value(type)
        when XML_SCHEMA_WHITESPACE_COLLAPSE
          Types.collapse_string(value)
        when XML_SCHEMA_WHITESPACE_REPLACE
          Types.white_space_replace(value)
        end
      end

      # xmlSchemaValidateQName(vctxt, value, &val, valNeeded) -> [ret, val]
      def validate_q_name(vctxt, value, val_needed)
        ret = Types.validate_q_name(value, 1)
        if ret != 0
          if ret == -1
            internal_err(vctxt, "xmlSchemaValidateQName", "calling xmlValidateQName()")
            return [-1, nil]
          end
          return [ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_1, nil]
        end
        stripped = Types.collapse_string(value)
        local, prefix = Tree.split_qname2(stripped || value)
        local ||= value.dup
        ns_name = lookup_namespace(vctxt, prefix)
        if prefix && ns_name.nil?
          ret = ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_1
          custom_err(vctxt, ret, nil, Types.get_built_in_type(XML_SCHEMAS_QNAME),
            "The QName value '%s' has no corresponding namespace declaration in scope", value, nil)
          return [ret, nil]
        end
        val = nil
        val = Types.new_q_name_value(ns_name, local) if val_needed
        [0, val]
      end

      # xmlSchemaVCheckCVCSimpleType(actxt, node, type, value, &retVal, fireErrors, normalize,
      # isNormalized) -> [ret, val]; want_val corresponds to retVal != NULL
      def v_check_cvc_simple_type(actxt, node, type, value, want_val, fire_errors, normalize, is_normalized)
        fire_errors = fire_errors == true || fire_errors == 1
        normalize = normalize == true || normalize == 1
        is_normalized = is_normalized == true || is_normalized == 1
        ret = 0
        val_needed = want_val ? true : false
        val = nil
        val_needed = true if !val_needed && (type.flags & XML_SCHEMAS_TYPE_FACETSNEEDVALUE) != 0
        value = "" if value.nil?

        # NORMALIZE(atype)
        do_normalize = lambda do |atype|
          if !is_normalized && (normalize || (type.flags & XML_SCHEMAS_TYPE_NORMVALUENEEDED) != 0)
            norm = normalize_value(atype, value)
            value = norm unless norm.nil?
            is_normalized = true
          end
        end

        if wxs_is_any_simple_type(type) || wxs_is_atomic(type)
          do_normalize.call(type)
          if type.type != XML_SCHEMA_TYPE_BASIC
            bi_type = type.base_type
            bi_type = bi_type.base_type while bi_type && bi_type.type != XML_SCHEMA_TYPE_BASIC
            if bi_type.nil?
              internal_err(actxt, "xmlSchemaVCheckCVCSimpleType", "could not get the built-in type")
              return [-1, nil]
            end
          else
            bi_type = type
          end
          if actxt.type == XML_SCHEMA_CTXT_VALIDATOR
            case bi_type.built_in_type
            when XML_SCHEMAS_NOTATION
              ret, val = validate_notation(actxt, actxt.schema, nil, value, val_needed)
            when XML_SCHEMAS_QNAME
              ret, val = validate_q_name(actxt, value, val_needed)
            else
              ret, val = Types.val_predef_type_node_no_norm(bi_type, value, val_needed, node)
            end
          elsif actxt.type == XML_SCHEMA_CTXT_PARSER
            if bi_type.built_in_type == XML_SCHEMAS_NOTATION
              ret, val = validate_notation(nil, actxt.schema, node, value, val_needed)
            else
              ret, val = Types.val_predef_type_node_no_norm(bi_type, value, val_needed, node)
            end
          else
            return [-1, nil]
          end
          if ret != 0
            if ret < 0
              internal_err(actxt, "xmlSchemaVCheckCVCSimpleType", "validating against a built-in type")
              return [-1, nil]
            end
            ret = wxs_is_list(type) ? ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_2 : ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_1
          end
          if ret == 0 && (type.flags & XML_SCHEMAS_TYPE_HAS_FACETS) != 0
            ret = validate_facets(actxt, node, type, bi_type.built_in_type, value, val, 0, fire_errors)
            if ret != 0
              if ret < 0
                internal_err(actxt, "xmlSchemaVCheckCVCSimpleType", "validating facets of atomic simple type")
                return [-1, nil]
              end
              ret = wxs_is_list(type) ? ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_2 : ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_1
            end
          elsif fire_errors && ret > 0
            simple_type_err(actxt, ret, node, value, type, 1)
          end
        elsif wxs_is_list(type)
          do_normalize.call(type)
          item_type = type.subtypes
          len = 0
          prev_val = nil
          s = value.b
          n = s.bytesize
          cur = 0
          loop do
            cur += 1 while cur < n && blank_byte?(s.getbyte(cur))
            e = cur
            e += 1 while e < n && !blank_byte?(s.getbyte(e))
            break if e == cur

            tmp_value = s.byteslice(cur, e - cur).force_encoding(Encoding::UTF_8)
            len += 1
            ret, cur_val = v_check_cvc_simple_type(actxt, node, item_type, tmp_value, val_needed, fire_errors, false, true)
            if cur_val
              if val.nil?
                val = cur_val
              else
                Types.value_append(prev_val, cur_val)
              end
              prev_val = cur_val
            end
            if ret != 0
              if ret < 0
                internal_err(actxt, "xmlSchemaVCheckCVCSimpleType", "validating an item of list simple type")
                return [-1, nil]
              end
              ret = ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_2
              break
            end
            cur = e
            break if cur >= n
          end
          if ret == 0 && (type.flags & XML_SCHEMAS_TYPE_HAS_FACETS) != 0
            ret = validate_facets(actxt, node, type, XML_SCHEMAS_UNKNOWN, value, val, len, fire_errors)
            if ret != 0
              if ret < 0
                internal_err(actxt, "xmlSchemaVCheckCVCSimpleType", "validating facets of list simple type")
                return [-1, nil]
              end
              ret = ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_2
            end
          end
          if fire_errors && ret > 0
            normalize = true
            do_normalize.call(type)
            simple_type_err(actxt, ret, node, value, type, 1)
          end
        elsif wxs_is_union(type)
          member_link = get_union_simple_type_member_types(type)
          if member_link.nil?
            internal_err(actxt, "xmlSchemaVCheckCVCSimpleType", "union simple type has no member types")
            return [-1, nil]
          end
          while member_link
            ret, val = v_check_cvc_simple_type(actxt, node, member_link.type, value, val_needed, false, true, false)
            break if ret <= 0

            member_link = member_link.next
          end
          if ret != 0
            if ret < 0
              internal_err(actxt, "xmlSchemaVCheckCVCSimpleType", "validating members of union simple type")
              return [-1, nil]
            end
            ret = ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_3
          end
          if ret == 0 && (type.flags & XML_SCHEMAS_TYPE_HAS_FACETS) != 0
            do_normalize.call(member_link.type)
            ret = validate_facets(actxt, node, type, XML_SCHEMAS_UNKNOWN, value, val, 0, fire_errors)
            if ret != 0
              if ret < 0
                internal_err(actxt, "xmlSchemaVCheckCVCSimpleType", "validating facets of union simple type")
                return [-1, nil]
              end
              ret = ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_3
            end
          end
          simple_type_err(actxt, ret, node, value, type, 1) if fire_errors && ret > 0
        end

        if ret == 0
          [ret, want_val ? val : nil]
        else
          [ret, nil]
        end
      end

      # xmlSchemaVExpandQName(vctxt, value, &nsName, &localName) -> [ret, ns_name, local_name]
      def v_expand_q_name(vctxt, value)
        ret = Types.validate_q_name(value, 1)
        return [-1, nil, nil] if ret == -1

        if ret > 0
          simple_type_err(vctxt, ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_1, nil, value,
            Types.get_built_in_type(XML_SCHEMAS_QNAME), 1)
          return [1, nil, nil]
        end
        local, prefix = Tree.split_qname2(value)
        local_name = local.nil? ? value : local
        ns_name = lookup_namespace(vctxt, prefix)
        if prefix && ns_name.nil?
          custom_err(vctxt, ErrCode::SCHEMAV_CVC_DATATYPE_VALID_1_2_1, nil,
            Types.get_built_in_type(XML_SCHEMAS_QNAME),
            "The QName value '%s' has no corresponding namespace declaration in scope", value, nil)
          return [2, ns_name, local_name]
        end
        [0, ns_name, local_name]
      end

      # xmlSchemaProcessXSIType(vctxt, iattr, &localType, elemDecl) -> [ret, local_type]
      def process_xsi_type(vctxt, iattr, elem_decl)
        ret = 0
        local_type = nil
        return [0, nil] if iattr.nil?

        vctxt.inode = iattr
        begin
          ret, ns_name, local = v_expand_q_name(vctxt, iattr.value)
          if ret != 0
            if ret < 0
              internal_err(vctxt, "xmlSchemaValidateElementByDeclaration",
                "calling xmlSchemaQNameExpand() to validate the attribute 'xsi:type'")
              return [-1, nil]
            end
            return [ret, nil]
          end
          local_type = get_type(vctxt.schema, local, ns_name)
          if local_type.nil?
            custom_err(vctxt, ErrCode::SCHEMAV_CVC_ELT_4_2, nil,
              Types.get_built_in_type(XML_SCHEMAS_QNAME),
              "The QName value '%s' of the xsi:type attribute does not resolve to a type definition",
              format_qname(ns_name, local), nil)
            return [vctxt.err, nil]
          end
          if elem_decl
            set = 0
            if (elem_decl.flags & XML_SCHEMAS_ELEM_BLOCK_EXTENSION) != 0 ||
                (elem_decl.subtypes.flags & XML_SCHEMAS_TYPE_BLOCK_EXTENSION) != 0
              set |= SUBSET_EXTENSION
            end
            if (elem_decl.flags & XML_SCHEMAS_ELEM_BLOCK_RESTRICTION) != 0 ||
                (elem_decl.subtypes.flags & XML_SCHEMAS_TYPE_BLOCK_RESTRICTION) != 0
              set |= SUBSET_RESTRICTION
            end
            if check_cos_derived_ok(vctxt, local_type, elem_decl.subtypes, set) != 0
              custom_err(vctxt, ErrCode::SCHEMAV_CVC_ELT_4_3, nil, nil,
                "The type definition '%s', specified by xsi:type, is blocked or not validly derived " \
                "from the type definition of the element declaration",
                format_qname(local_type.target_namespace, local_type.name), nil)
              ret = vctxt.err
              local_type = nil
            end
          end
          [ret, local_type]
        ensure
          vctxt.inode = vctxt.elem_infos[vctxt.depth] # ACTIVATE_ELEM
        end
      end

      # xmlSchemaValidateElemDecl
      def validate_elem_decl(vctxt)
        elem_decl = vctxt.inode.decl
        if elem_decl.nil?
          verror(vctxt, ErrCode::SCHEMAV_CVC_ELT_1, nil, "No matching declaration available")
          return vctxt.err
        end
        actual_type = elem_decl.subtypes
        if (elem_decl.flags & XML_SCHEMAS_ELEM_ABSTRACT) != 0
          verror(vctxt, ErrCode::SCHEMAV_CVC_ELT_2, nil, "The element declaration is abstract")
          return vctxt.err
        end
        if actual_type.nil?
          verror(vctxt, ErrCode::SCHEMAV_CVC_TYPE_1, nil, "The type definition is absent")
          return ErrCode::SCHEMAV_CVC_TYPE_1
        end
        if vctxt.nb_attr_infos != 0
          iattr = get_meta_attr_info(vctxt, XML_SCHEMA_ATTR_INFO_META_XSI_NIL)
          if iattr
            vctxt.inode = iattr
            ret, iattr.val = v_check_cvc_simple_type(vctxt, nil, Types.get_built_in_type(XML_SCHEMAS_BOOLEAN),
              iattr.value, true, true, false, false)
            vctxt.inode = vctxt.elem_infos[vctxt.depth]
            if ret < 0
              internal_err(vctxt, "xmlSchemaValidateElemDecl",
                "calling xmlSchemaVCheckCVCSimpleType() to validate the attribute 'xsi:nil'")
              return -1
            end
            if ret == 0
              if (elem_decl.flags & XML_SCHEMAS_ELEM_NILLABLE) == 0
                verror(vctxt, ErrCode::SCHEMAV_CVC_ELT_3_1, nil, "The element is not 'nillable'")
              elsif (b = Types.value_get_as_boolean(iattr.val)) && b != 0
                if (elem_decl.flags & XML_SCHEMAS_ELEM_FIXED) != 0 && !elem_decl.value.nil?
                  verror(vctxt, ErrCode::SCHEMAV_CVC_ELT_3_2_2, nil,
                    "The element cannot be 'nilled' because there is a fixed value constraint defined for it")
                else
                  vctxt.inode.flags |= XML_SCHEMA_ELEM_INFO_NILLED
                end
              end
            end
          end
          iattr = get_meta_attr_info(vctxt, XML_SCHEMA_ATTR_INFO_META_XSI_TYPE)
          if iattr
            ret, local_type = process_xsi_type(vctxt, iattr, elem_decl)
            if ret != 0 && ret == -1
              internal_err(vctxt, "xmlSchemaValidateElemDecl",
                "calling xmlSchemaProcessXSIType() to process the attribute 'xsi:type'")
              return -1
            end
            if local_type
              vctxt.inode.flags |= XML_SCHEMA_ELEM_INFO_LOCAL_TYPE
              actual_type = local_type
            end
          end
        end
        return -1 if elem_decl.idcs && idc_register_matchers(vctxt, elem_decl) == -1

        if actual_type.nil?
          verror(vctxt, ErrCode::SCHEMAV_CVC_TYPE_1, nil, "The type definition is absent")
          return ErrCode::SCHEMAV_CVC_TYPE_1
        end
        vctxt.inode.type_def = actual_type
        0
      end

      # xmlSchemaVAttributesSimple
      def v_attributes_simple(vctxt)
        return 0 if vctxt.nb_attr_infos == 0

        ret = 0
        vctxt.nb_attr_infos.times do |i|
          iattr = vctxt.attr_infos[i]
          next if iattr.meta_type != 0

          vctxt.inode = iattr
          illegal_attr_err(vctxt, ErrCode::SCHEMAV_CVC_TYPE_3_1_1, iattr, nil)
          ret = ErrCode::SCHEMAV_CVC_TYPE_3_1_1
        end
        vctxt.inode = vctxt.elem_infos[vctxt.depth]
        ret
      end

      # xmlSchemaClearAttrInfos
      def clear_attr_infos(vctxt)
        return if vctxt.nb_attr_infos == 0

        vctxt.attr_infos.clear
        vctxt.nb_attr_infos = 0
      end

      # xmlSchemaVAttributesComplex
      def v_attributes_complex(vctxt)
        type = vctxt.inode.type_def
        attr_use_list = type.attr_uses
        nb_attrs = vctxt.nb_attr_infos
        nb_uses = attr_use_list ? attr_use_list.nb_items : 0
        wild_ids = 0
        def_attr_owner_elem = nil
        infos = vctxt.attr_infos

        nb_uses.times do |i|
          found = false
          attr_use = attr_use_list.items[i]
          attr_decl = attr_use.attr_decl
          j = 0
          while j < nb_attrs
            iattr = infos[j]
            j += 1
            next if iattr.meta_type != 0
            next if iattr.local_name != attr_decl.name
            next if iattr.ns_name != attr_decl.target_namespace

            found = true
            iattr.state = XML_SCHEMAS_ATTR_ASSESSED
            iattr.use = attr_use
            iattr.decl = attr_decl
            iattr.type_def = attr_decl.subtypes
            break
          end
          next if found

          if attr_use.occurs == XML_SCHEMAS_ATTR_USE_REQUIRED
            tmpiattr = get_fresh_attr_info(vctxt)
            infos = vctxt.attr_infos
            tmpiattr.state = XML_SCHEMAS_ATTR_ERR_MISSING
            tmpiattr.use = attr_use
            tmpiattr.decl = attr_decl
          elsif attr_use.occurs == XML_SCHEMAS_ATTR_USE_OPTIONAL &&
              (!attr_use.def_value.nil? || !attr_decl.def_value.nil?)
            tmpiattr = get_fresh_attr_info(vctxt)
            infos = vctxt.attr_infos
            tmpiattr.state = XML_SCHEMAS_ATTR_DEFAULT
            tmpiattr.use = attr_use
            tmpiattr.decl = attr_decl
            tmpiattr.type_def = attr_decl.subtypes
            tmpiattr.local_name = attr_decl.name
            tmpiattr.ns_name = attr_decl.target_namespace
          end
        end

        return 0 if vctxt.nb_attr_infos == 0

        if type.attribute_wildcard
          nb_attrs.times do |i|
            iattr = infos[i]
            next if iattr.state != XML_SCHEMAS_ATTR_UNKNOWN
            next unless check_cvc_wildcard_namespace(type.attribute_wildcard, iattr.ns_name) == 0

            if type.attribute_wildcard.process_contents == XML_SCHEMAS_ANY_SKIP
              iattr.state = XML_SCHEMAS_ATTR_WILD_SKIP
              next
            end
            iattr.decl = get_attribute_decl(vctxt.schema, iattr.local_name, iattr.ns_name)
            if iattr.decl
              iattr.state = XML_SCHEMAS_ATTR_ASSESSED
              iattr.type_def = iattr.decl.subtypes
              if is_derived_from_built_in_type(iattr.type_def, XML_SCHEMAS_ID) != 0
                if wild_ids != 0
                  iattr.state = XML_SCHEMAS_ATTR_ERR_WILD_DUPLICATE_ID
                  next
                end
                wild_ids += 1
                if attr_use_list
                  attr_use_list.items.each do |au|
                    if is_derived_from_built_in_type(au.attr_decl.subtypes, XML_SCHEMAS_ID) != 0
                      iattr.state = XML_SCHEMAS_ATTR_ERR_WILD_AND_USE_ID
                      break
                    end
                  end
                end
              end
            elsif type.attribute_wildcard.process_contents == XML_SCHEMAS_ANY_LAX
              iattr.state = XML_SCHEMAS_ATTR_WILD_LAX_NO_DECL
            else
              iattr.state = XML_SCHEMAS_ATTR_ERR_WILD_STRICT_NO_DECL
            end
          end
        end

        return 0 if vctxt.nb_attr_infos == 0

        if (vctxt.options & XML_SCHEMA_VAL_VC_I_CREATE) != 0
          ielem = vctxt.elem_infos[vctxt.depth]
          def_attr_owner_elem = ielem.node if ielem&.node&.doc
        end

        i = 0
        while i < vctxt.nb_attr_infos
          iattr = infos[i]
          i += 1
          next if iattr.state != XML_SCHEMAS_ATTR_ASSESSED && iattr.state != XML_SCHEMAS_ATTR_DEFAULT

          if iattr.type_def.nil?
            iattr.state = XML_SCHEMAS_ATTR_ERR_NO_TYPE
            next
          end
          vctxt.inode = iattr
          fixed = false
          xpath_res = 0
          if vctxt.xpath_states
            xpath_res = x_path_evaluate(vctxt, ATTRIBUTE_NODE)
            if xpath_res == -1
              internal_err(vctxt, "xmlSchemaVAttributesComplex", "calling xmlSchemaXPathEvaluate()")
              vctxt.inode = vctxt.elem_infos[vctxt.depth]
              return -1
            end
          end

          catch(:eval_idcs) do
            if iattr.state == XML_SCHEMAS_ATTR_DEFAULT
              if xpath_res != 0 || def_attr_owner_elem
                if iattr.use.def_value
                  iattr.value = iattr.use.def_value
                  iattr.val = iattr.use.def_val
                else
                  iattr.value = iattr.decl.def_value
                  iattr.val = iattr.decl.def_val
                end
                if iattr.val.nil?
                  internal_err(vctxt, "xmlSchemaVAttributesComplex",
                    "default/fixed value on an attribute use was not precomputed")
                  vctxt.inode = vctxt.elem_infos[vctxt.depth]
                  return -1
                end
                iattr.val = Types.copy_value(iattr.val)
              end
              if def_attr_owner_elem
                value = iattr.value
                norm = normalize_value(iattr.type_def, iattr.value)
                value = norm if norm
                if iattr.ns_name.nil?
                  Tree.new_prop(def_attr_owner_elem, iattr.local_name, value)
                else
                  ns = Tree.search_ns_by_href(def_attr_owner_elem.doc, def_attr_owner_elem, iattr.ns_name)
                  if ns.nil?
                    counter = 0
                    prefix = nil
                    loop do
                      prefix = "p#{counter}"
                      counter += 1
                      ns = Tree.search_ns(def_attr_owner_elem.doc, def_attr_owner_elem, prefix)
                      break if ns.nil?
                    end
                    ns = Tree.new_ns(vctxt.validation_root, iattr.ns_name, prefix)
                  end
                  Tree.new_ns_prop(def_attr_owner_elem, ns, iattr.local_name, value)
                end
              end
              throw :eval_idcs
            end
            vctxt.value = nil
            fixed = (iattr.decl.flags & XML_SCHEMAS_ATTR_FIXED) != 0 ||
              (!iattr.use.nil? && (iattr.use.flags & XML_SCHEMAS_ATTR_FIXED) != 0)
            if xpath_res != 0 || fixed
              iattr.flags |= XML_SCHEMA_NODE_INFO_VALUE_NEEDED
              res, iattr.val = v_check_cvc_simple_type(vctxt, iattr.node, iattr.type_def, iattr.value,
                true, true, true, false)
            else
              res, = v_check_cvc_simple_type(vctxt, iattr.node, iattr.type_def, iattr.value,
                false, true, false, false)
            end
            if res != 0
              if res == -1
                internal_err(vctxt, "xmlSchemaVAttributesComplex",
                  "calling xmlSchemaStreamValidateSimpleTypeValue()")
                vctxt.inode = vctxt.elem_infos[vctxt.depth]
                return -1
              end
              iattr.state = XML_SCHEMAS_ATTR_INVALID_VALUE
              throw :eval_idcs
            end
            if fixed
              throw :eval_idcs if iattr.val.nil?

              if iattr.use && iattr.use.def_value
                throw :eval_idcs if iattr.use.def_val.nil?

                iattr.vc_value = iattr.use.def_value
                iattr.state = XML_SCHEMAS_ATTR_ERR_FIXED_VALUE if are_values_equal(iattr.val, iattr.use.def_val) == 0
              else
                throw :eval_idcs if iattr.decl.def_val.nil?

                iattr.vc_value = iattr.decl.def_value
                iattr.state = XML_SCHEMAS_ATTR_ERR_FIXED_VALUE if are_values_equal(iattr.val, iattr.decl.def_val) == 0
              end
            end
          end
          # eval_idcs:
          if xpath_res != 0
            if x_path_process_history(vctxt, vctxt.depth + 1) == -1
              internal_err(vctxt, "xmlSchemaVAttributesComplex", "calling xmlSchemaXPathEvaluate()")
              vctxt.inode = vctxt.elem_infos[vctxt.depth]
              return -1
            end
          elsif vctxt.xpath_states
            x_path_pop(vctxt)
          end
        end

        vctxt.nb_attr_infos.times do |k|
          iattr = infos[k]
          st = iattr.state
          next if st == XML_SCHEMAS_ATTR_META || st == XML_SCHEMAS_ATTR_ASSESSED ||
            st == XML_SCHEMAS_ATTR_WILD_SKIP || st == XML_SCHEMAS_ATTR_WILD_LAX_NO_DECL

          vctxt.inode = iattr
          case st
          when XML_SCHEMAS_ATTR_ERR_MISSING
            vctxt.inode = vctxt.elem_infos[vctxt.depth]
            custom_err(vctxt, ErrCode::SCHEMAV_CVC_COMPLEX_TYPE_4, nil, nil,
              "The attribute '%s' is required but missing",
              format_qname(iattr.decl.target_namespace, iattr.decl.name), nil)
          when XML_SCHEMAS_ATTR_ERR_NO_TYPE
            verror(vctxt, ErrCode::SCHEMAV_CVC_ATTRIBUTE_2, nil, "The type definition is absent")
          when XML_SCHEMAS_ATTR_ERR_FIXED_VALUE
            custom_err(vctxt, ErrCode::SCHEMAV_CVC_AU, nil, nil,
              "The value '%s' does not match the fixed value constraint '%s'",
              iattr.value, iattr.vc_value)
          when XML_SCHEMAS_ATTR_ERR_WILD_STRICT_NO_DECL
            verror(vctxt, ErrCode::SCHEMAV_CVC_WILDCARD, nil,
              "No matching global attribute declaration available, but demanded by the strict wildcard")
          when XML_SCHEMAS_ATTR_UNKNOWN
            next if iattr.meta_type != 0

            if type.attribute_wildcard.nil?
              illegal_attr_err(vctxt, ErrCode::SCHEMAV_CVC_COMPLEX_TYPE_3_2_1, iattr, nil)
            else
              illegal_attr_err(vctxt, ErrCode::SCHEMAV_CVC_COMPLEX_TYPE_3_2_2, iattr, nil)
            end
          end
        end
        vctxt.inode = vctxt.elem_infos[vctxt.depth]
        0
      end

      # xmlSchemaValidateElemWildcard(vctxt, &skip) -> [ret, skip]
      def validate_elem_wildcard(vctxt)
        wild = vctxt.inode.decl
        if wild.nil? || wild.type != XML_SCHEMA_TYPE_ANY
          internal_err(vctxt, "xmlSchemaValidateElemWildcard", "bad arguments")
          return [-1, 0]
        end
        return [0, 1] if wild.process_contents == XML_SCHEMAS_ANY_SKIP

        decl = get_elem(vctxt.schema, vctxt.inode.local_name, vctxt.inode.ns_name)
        if decl
          vctxt.inode.decl = decl
          return [0, 0]
        end
        if wild.process_contents == XML_SCHEMAS_ANY_STRICT
          verror(vctxt, ErrCode::SCHEMAV_CVC_ELT_1, nil,
            "No matching global element declaration available, but demanded by the strict wildcard")
          return [vctxt.err, 0]
        end
        if vctxt.nb_attr_infos != 0
          iattr = get_meta_attr_info(vctxt, XML_SCHEMA_ATTR_INFO_META_XSI_TYPE)
          if iattr
            ret, vctxt.inode.type_def = process_xsi_type(vctxt, iattr, nil)
            if ret == -1
              internal_err(vctxt, "xmlSchemaValidateElemWildcard",
                "calling xmlSchemaProcessXSIType() to process the attribute 'xsi:nil'")
              return [-1, 0]
            end
            return [0, 0]
          end
        end
        vctxt.inode.type_def = Types.get_built_in_type(XML_SCHEMAS_ANYTYPE)
        [0, 0]
      end

      # xmlSchemaCheckCOSValidDefault(vctxt, value, &val) -> [ret, val]
      def check_cos_valid_default(vctxt, value)
        ret = 0
        val = nil
        inode = vctxt.inode
        if wxs_is_complex(inode.type_def)
          if !wxs_has_simple_content(inode.type_def) &&
              (!wxs_has_mixed_content(inode.type_def) || !wxs_emptiable(inode.type_def))
            ret = ErrCode::SCHEMAP_COS_VALID_DEFAULT_2_1
            verror(vctxt, ret, nil,
              "For a string to be a valid default, the type definition must be a simple type or a " \
              "complex type with simple content or mixed content and a particle emptiable")
            return [ret, nil]
          end
        end
        if wxs_is_simple(inode.type_def)
          ret, val = v_check_cvc_simple_type(vctxt, nil, inode.type_def, value, true, true, true, false)
        elsif wxs_has_simple_content(inode.type_def)
          ret, val = v_check_cvc_simple_type(vctxt, nil, inode.type_def.content_type_def, value, true, true, true, false)
        end
        internal_err(vctxt, "xmlSchemaCheckCOSValidDefault", "calling xmlSchemaVCheckCVCSimpleType()") if ret < 0
        [ret, val]
      end

      # xmlSchemaVContentModelCallback
      CONTENT_MODEL_CALLBACK = ->(_exec, _name, transdata, inputdata) { inputdata.decl = transdata }

      def v_content_model_callback = CONTENT_MODEL_CALLBACK

      # xmlSchemaValidatorPushElem
      def validator_push_elem(vctxt)
        vctxt.inode = get_fresh_elem_info(vctxt)
        vctxt.nb_attr_infos = 0
        0
      end

      # xmlSchemaVCheckINodeDataType
      def v_check_i_node_data_type(vctxt, inode, type, value)
        if (inode.flags & XML_SCHEMA_NODE_INFO_VALUE_NEEDED) != 0
          ret, inode.val = v_check_cvc_simple_type(vctxt, nil, type, value, true, true, true, false)
          ret
        else
          ret, = v_check_cvc_simple_type(vctxt, nil, type, value, false, true, false, false)
          ret
        end
      end

      # xmlSchemaValidatorPopElem
      def validator_pop_elem(vctxt)
        ret = 0
        inode = vctxt.inode
        clear_attr_infos(vctxt) if vctxt.nb_attr_infos != 0
        catch(:end_elem) do
          if (inode.flags & XML_SCHEMA_NODE_INFO_ERR_NOT_EXPECTED) != 0
            vctxt.skip_depth = vctxt.depth - 1
            throw :end_elem
          end
          throw :end_elem if inode.type_def.nil? || (inode.flags & XML_SCHEMA_NODE_INFO_ERR_BAD_TYPE) != 0

          td = inode.type_def
          character_content = false
          if td.content_type == XML_SCHEMA_CONTENT_MIXED || td.content_type == XML_SCHEMA_CONTENT_ELEMENTS
            if td.built_in_type == XML_SCHEMAS_ANYTYPE
              character_content = true
            elsif (inode.flags & XML_SCHEMA_ELEM_INFO_ERR_BAD_CONTENT) == 0
              if inode.regex_ctxt.nil?
                inode.regex_ctxt = XmlRegexp.reg_new_exec_ctxt(td.cont_model, CONTENT_MODEL_CALLBACK, vctxt)
                if inode.regex_ctxt.nil?
                  internal_err(vctxt, "xmlSchemaValidatorPopElem", "failed to create a regex context")
                  vctxt.err = -1
                  return -1
                end
              end
              if inode_nilled(inode)
                ret = 0
              else
                _r, nbval, nbneg, values, _terminal = XmlRegexp.reg_exec_next_values(inode.regex_ctxt, 10)
                ret = XmlRegexp.reg_exec_push_string(inode.regex_ctxt, nil, nil)
                if ret < 0 || (ret == 0 && !inode_nilled(inode))
                  ret = 1
                  inode.flags |= XML_SCHEMA_ELEM_INFO_ERR_BAD_CONTENT
                  complex_type_err(vctxt, ErrCode::SCHEMAV_ELEMENT_CONTENT, nil, nil,
                    "Missing child element(s)", nbval || 0, nbneg || 0, values || [])
                else
                  ret = 0
                end
              end
            end
          end

          # skip_nilled:
          throw :end_elem if !character_content && td.content_type == XML_SCHEMA_CONTENT_ELEMENTS

          # character_content:
          vctxt.value = nil
          if inode.decl.nil?
            if wxs_is_simple(td)
              ret = v_check_i_node_data_type(vctxt, inode, td, inode.value)
            elsif wxs_has_simple_content(td)
              ret = v_check_i_node_data_type(vctxt, inode, td.content_type_def, inode.value)
            end
            if ret < 0
              internal_err(vctxt, "xmlSchemaValidatorPopElem", "calling xmlSchemaVCheckCVCSimpleType()")
              vctxt.err = -1
              return -1
            end
            throw :end_elem
          end
          decl = inode.decl
          if !decl.value.nil? && (inode.flags & XML_SCHEMA_ELEM_INFO_EMPTY) != 0 && !inode_nilled(inode)
            if (inode.flags & XML_SCHEMA_ELEM_INFO_LOCAL_TYPE) != 0
              ret, inode.val = check_cos_valid_default(vctxt, decl.value)
              if ret != 0
                if ret < 0
                  internal_err(vctxt, "xmlSchemaValidatorPopElem", "calling xmlSchemaCheckCOSValidDefault()")
                  vctxt.err = -1
                  return -1
                end
                throw :end_elem
              end
            else
              if wxs_is_simple(td)
                ret = v_check_i_node_data_type(vctxt, inode, td, decl.value)
              elsif wxs_has_simple_content(td)
                ret = v_check_i_node_data_type(vctxt, inode, td.content_type_def, decl.value)
              end
              if ret != 0
                if ret < 0
                  internal_err(vctxt, "xmlSchemaValidatorPopElem", "calling xmlSchemaVCheckCVCSimpleType()")
                  vctxt.err = -1
                  return -1
                end
                throw :end_elem
              end
            end
            # default_psvi:
            if (vctxt.options & XML_SCHEMA_VAL_VC_I_CREATE) != 0 && inode.node
              norm = normalize_value(td, decl.value)
              text_child = Tree.new_doc_text(inode.node.doc, norm || decl.value)
              Tree.add_child(inode.node, text_child)
            end
          elsif !inode_nilled(inode)
            if wxs_is_simple(td)
              ret = v_check_i_node_data_type(vctxt, inode, td, inode.value)
            elsif wxs_has_simple_content(td)
              ret = v_check_i_node_data_type(vctxt, inode, td.content_type_def, inode.value)
            end
            if ret != 0
              if ret < 0
                internal_err(vctxt, "xmlSchemaValidatorPopElem", "calling xmlSchemaVCheckCVCSimpleType()")
                vctxt.err = -1
                return -1
              end
              throw :end_elem
            end
            if !decl.value.nil? && (decl.flags & XML_SCHEMAS_ELEM_FIXED) != 0
              if (inode.flags & XML_SCHEMA_ELEM_INFO_HAS_ELEM_CONTENT) != 0
                ret = ErrCode::SCHEMAV_CVC_ELT_5_2_2_1
                verror(vctxt, ret, nil,
                  "The content must not contain element nodes since there is a fixed value constraint")
                throw :end_elem
              elsif wxs_has_mixed_content(td)
                if inode.value != decl.value
                  ret = ErrCode::SCHEMAV_CVC_ELT_5_2_2_2_1
                  custom_err(vctxt, ret, nil, nil,
                    "The initial value '%s' does not match the fixed value constraint '%s'",
                    inode.value, decl.value)
                  throw :end_elem
                end
              elsif wxs_has_simple_content(td)
                if inode.value != decl.value
                  ret = ErrCode::SCHEMAV_CVC_ELT_5_2_2_2_2
                  custom_err(vctxt, ret, nil, nil,
                    "The actual value '%s' does not match the fixed value constraint '%s'",
                    inode.value, decl.value)
                  throw :end_elem
                end
              end
            end
          end
        end

        # end_elem:
        return 0 if vctxt.depth < 0

        vctxt.skip_depth = -1 if vctxt.depth == vctxt.skip_depth
        if inode.applied_xpath != 0 && x_path_process_history(vctxt, vctxt.depth) == -1
          vctxt.err = -1
          return -1
        end
        if inode.idc_matchers && (vctxt.has_keyrefs != 0 || vctxt.create_idc_node_tables != 0)
          if idc_fill_node_tables(vctxt, inode) == -1
            vctxt.err = -1
            return -1
          end
        end
        if vctxt.inode.has_keyrefs != 0 && check_cvcidc_key_ref(vctxt) == -1
          vctxt.err = -1
          return -1
        end
        if inode.idc_table && vctxt.depth > 0 && (vctxt.has_keyrefs != 0 || vctxt.create_idc_node_tables != 0)
          if bubble_idc_node_tables(vctxt) == -1
            vctxt.err = -1
            return -1
          end
        end
        clear_elem_info(vctxt, inode)
        if vctxt.depth == 0
          vctxt.depth -= 1
          vctxt.inode = nil
          return 0
        end
        aidc = vctxt.aidcs
        while aidc
          aidc.keyref_depth = -1 if aidc.keyref_depth == vctxt.depth
          aidc = aidc.next
        end
        vctxt.depth -= 1
        vctxt.inode = vctxt.elem_infos[vctxt.depth]
        ret
      end

      # xmlSchemaValidateChildElem
      def validate_child_elem(vctxt)
        ret = 0
        if vctxt.depth <= 0
          internal_err(vctxt, "xmlSchemaValidateChildElem", "not intended for the validation root")
          return -1
        end
        pielem = vctxt.elem_infos[vctxt.depth - 1]
        pielem.flags ^= XML_SCHEMA_ELEM_INFO_EMPTY if (pielem.flags & XML_SCHEMA_ELEM_INFO_EMPTY) != 0
        catch(:unexpected_elem) do
          if inode_nilled(pielem)
            vctxt.inode = pielem
            ret = ErrCode::SCHEMAV_CVC_ELT_3_2_1
            verror(vctxt, ret, nil,
              "Neither character nor element content is allowed, because the element was 'nilled'")
            vctxt.inode = vctxt.elem_infos[vctxt.depth]
            throw :unexpected_elem
          end
          ptype = pielem.type_def
          if ptype.built_in_type == XML_SCHEMAS_ANYTYPE
            vctxt.inode.decl = get_elem(vctxt.schema, vctxt.inode.local_name, vctxt.inode.ns_name)
            if vctxt.inode.decl.nil?
              iattr = get_meta_attr_info(vctxt, XML_SCHEMA_ATTR_INFO_META_XSI_TYPE)
              if iattr
                ret, vctxt.inode.type_def = process_xsi_type(vctxt, iattr, nil)
                if ret != 0
                  if ret == -1
                    internal_err(vctxt, "xmlSchemaValidateChildElem",
                      "calling xmlSchemaProcessXSIType() to process the attribute 'xsi:nil'")
                    return -1
                  end
                  return ret
                end
              else
                vctxt.inode.type_def = Types.get_built_in_type(XML_SCHEMAS_ANYTYPE)
              end
            end
            return 0
          end

          case ptype.content_type
          when XML_SCHEMA_CONTENT_EMPTY
            vctxt.inode = pielem
            ret = ErrCode::SCHEMAV_CVC_COMPLEX_TYPE_2_1
            verror(vctxt, ret, nil, "Element content is not allowed, because the content type is empty")
            vctxt.inode = vctxt.elem_infos[vctxt.depth]
            throw :unexpected_elem
          when XML_SCHEMA_CONTENT_MIXED, XML_SCHEMA_CONTENT_ELEMENTS
            if ptype.cont_model.nil?
              internal_err(vctxt, "xmlSchemaValidateChildElem", "type has elem content but no content model")
              return -1
            end
            if (pielem.flags & XML_SCHEMA_ELEM_INFO_ERR_BAD_CONTENT) != 0
              internal_err(vctxt, "xmlSchemaValidateChildElem",
                "validating elem, but elem content is already invalid")
              return -1
            end
            regex_ctxt = pielem.regex_ctxt
            if regex_ctxt.nil?
              regex_ctxt = XmlRegexp.reg_new_exec_ctxt(ptype.cont_model, CONTENT_MODEL_CALLBACK, vctxt)
              if regex_ctxt.nil?
                internal_err(vctxt, "xmlSchemaValidateChildElem", "failed to create a regex context")
                return -1
              end
              pielem.regex_ctxt = regex_ctxt
            end
            ret = XmlRegexp.reg_exec_push_string2(regex_ctxt, vctxt.inode.local_name, vctxt.inode.ns_name,
              vctxt.inode)
            if vctxt.err == ErrCode::SCHEMAV_INTERNAL
              internal_err(vctxt, "xmlSchemaValidateChildElem", "calling xmlRegExecPushString2()")
              return -1
            end
            if ret < 0
              _r, _s, nbval, nbneg, values, _t = XmlRegexp.reg_exec_err_info(regex_ctxt, 10)
              complex_type_err(vctxt, ErrCode::SCHEMAV_ELEMENT_CONTENT, nil, nil,
                "This element is not expected", nbval || 0, nbneg || 0, values || [])
              ret = vctxt.err
              throw :unexpected_elem
            else
              ret = 0
            end
          when XML_SCHEMA_CONTENT_SIMPLE, XML_SCHEMA_CONTENT_BASIC
            vctxt.inode = pielem
            if wxs_is_complex(ptype)
              ret = ErrCode::SCHEMAV_CVC_COMPLEX_TYPE_2_2
              verror(vctxt, ret, nil,
                "Element content is not allowed, because the content type is a simple type definition")
            else
              ret = ErrCode::SCHEMAV_CVC_TYPE_3_1_2
              verror(vctxt, ret, nil, "Element content is not allowed, because the type definition is simple")
            end
            vctxt.inode = vctxt.elem_infos[vctxt.depth]
            ret = vctxt.err
            throw :unexpected_elem
          end
          return ret
        end
        # unexpected_elem:
        vctxt.skip_depth = vctxt.depth
        vctxt.inode.flags |= XML_SCHEMA_NODE_INFO_ERR_NOT_EXPECTED
        pielem.flags |= XML_SCHEMA_ELEM_INFO_ERR_BAD_CONTENT
        ret
      end

      # xmlSchemaVPushText(vctxt, nodeType, value, len, mode, &consumed) -> ret (consumed unused)
      def v_push_text(vctxt, node_type, value, len, mode)
        inode = vctxt.inode
        if inode_nilled(inode)
          verror(vctxt, ErrCode::SCHEMAV_CVC_ELT_3_2_1, nil,
            "Neither character nor element content is allowed because the element is 'nilled'")
          return vctxt.err
        end
        ct = inode.type_def.content_type
        if ct == XML_SCHEMA_CONTENT_EMPTY
          verror(vctxt, ErrCode::SCHEMAV_CVC_COMPLEX_TYPE_2_1, nil,
            "Character content is not allowed, because the content type is empty")
          return vctxt.err
        end
        if ct == XML_SCHEMA_CONTENT_ELEMENTS
          if node_type != TEXT_NODE || is_blank(value, len) == 0
            verror(vctxt, ErrCode::SCHEMAV_CVC_COMPLEX_TYPE_2_3, nil,
              "Character content other than whitespace is not allowed because the content type is 'element-only'")
            return vctxt.err
          end
          return 0
        end
        return 0 if value.nil? || value.empty?
        return 0 if ct == XML_SCHEMA_CONTENT_MIXED && (inode.decl.nil? || inode.decl.value.nil?)

        value = value.byteslice(0, len) if len && len >= 0 && len < value.bytesize
        if inode.value.nil?
          inode.value = mode == XML_SCHEMA_PUSH_TEXT_PERSIST ? value : value.dup
          inode.flags |= XML_SCHEMA_NODE_INFO_FLAG_OWNED_VALUES if mode != XML_SCHEMA_PUSH_TEXT_PERSIST
        else
          if (inode.flags & XML_SCHEMA_NODE_INFO_FLAG_OWNED_VALUES) != 0 && !inode.value.frozen?
            inode.value << value
          else
            inode.value = inode.value + value
            inode.flags |= XML_SCHEMA_NODE_INFO_FLAG_OWNED_VALUES
          end
        end
        0
      end

      # xmlSchemaValidateElem
      def validate_elem(vctxt)
        ret = 0
        if vctxt.skip_depth != -1 && vctxt.depth >= vctxt.skip_depth
          internal_err(vctxt, "xmlSchemaValidateElem", "in skip-state")
          return -1
        end
        if vctxt.xsi_assemble != 0
          ret = assemble_by_xsi(vctxt)
          if ret != 0
            return -1 if ret == -1

            vctxt.skip_depth = 0
            return ret
          end
          vctxt.schema.schemas_imports&.each_value { |imp| augment_imported_idc(imp, vctxt) }
        end
        catch(:exit) do
          if vctxt.depth > 0
            ret = validate_child_elem(vctxt)
            if ret != 0
              if ret < 0
                internal_err(vctxt, "xmlSchemaValidateElem", "calling xmlSchemaStreamValidateChildElement()")
                return -1
              end
              throw :exit
            end
            throw :exit if vctxt.depth == vctxt.skip_depth
            if vctxt.inode.decl.nil? && vctxt.inode.type_def.nil?
              internal_err(vctxt, "xmlSchemaValidateElem",
                "the child element was valid but neither the declaration nor the type was set")
              return -1
            end
          else
            vctxt.inode.decl = get_elem(vctxt.schema, vctxt.inode.local_name, vctxt.inode.ns_name)
            if vctxt.inode.decl.nil?
              ret = ErrCode::SCHEMAV_CVC_ELT_1
              verror(vctxt, ret, nil, "No matching global declaration available for the validation root")
              throw :exit
            end
          end

          unless vctxt.inode.decl.nil?
            skip_to_type = false
            if vctxt.inode.decl.type == XML_SCHEMA_TYPE_ANY
              ret, skip = validate_elem_wildcard(vctxt)
              if ret != 0
                if ret < 0
                  internal_err(vctxt, "xmlSchemaValidateElem", "calling xmlSchemaValidateElemWildcard()")
                  return -1
                end
                throw :exit
              end
              if skip != 0
                vctxt.skip_depth = vctxt.depth
                throw :exit
              end
              if vctxt.inode.decl.type != XML_SCHEMA_TYPE_ELEMENT
                vctxt.inode.decl = nil
                skip_to_type = true
              end
            end
            unless skip_to_type
              ret = validate_elem_decl(vctxt)
              if ret != 0
                if ret < 0
                  internal_err(vctxt, "xmlSchemaValidateElem", "calling xmlSchemaValidateElemDecl()")
                  return -1
                end
                throw :exit
              end
            end
          end

          # type_validation:
          if vctxt.inode.type_def.nil?
            vctxt.inode.flags |= XML_SCHEMA_NODE_INFO_ERR_BAD_TYPE
            ret = ErrCode::SCHEMAV_CVC_TYPE_1
            verror(vctxt, ret, nil, "The type definition is absent")
            throw :exit
          end
          if (vctxt.inode.type_def.flags & XML_SCHEMAS_TYPE_ABSTRACT) != 0
            vctxt.inode.flags |= XML_SCHEMA_NODE_INFO_ERR_BAD_TYPE
            ret = ErrCode::SCHEMAV_CVC_TYPE_2
            verror(vctxt, ret, nil, "The type definition is abstract")
            throw :exit
          end
          if vctxt.xpath_states
            ret = x_path_evaluate(vctxt, ELEMENT_NODE)
            vctxt.inode.applied_xpath = 1
            if ret == -1
              internal_err(vctxt, "xmlSchemaValidateElem", "calling xmlSchemaXPathEvaluate()")
              return -1
            end
          end
          if wxs_is_complex(vctxt.inode.type_def)
            if vctxt.nb_attr_infos != 0 || !vctxt.inode.type_def.attr_uses.nil?
              ret = v_attributes_complex(vctxt)
            end
          elsif vctxt.nb_attr_infos != 0
            ret = v_attributes_simple(vctxt)
          end
          clear_attr_infos(vctxt) if vctxt.nb_attr_infos != 0
          if ret == -1
            internal_err(vctxt, "xmlSchemaValidateElem", "calling attributes validation")
            return -1
          end
          ret = 0
        end
        # exit:
        vctxt.skip_depth = vctxt.depth if ret != 0
        ret
      end

      # ---- SAX (streaming) handlers ------------------------------------------------------

      # xmlSchemaSAXHandleText
      def sax_handle_text(vctxt, ch, len)
        return if vctxt.depth < 0
        return if vctxt.skip_depth != -1 && vctxt.depth >= vctxt.skip_depth

        vctxt.inode.flags ^= XML_SCHEMA_ELEM_INFO_EMPTY if (vctxt.inode.flags & XML_SCHEMA_ELEM_INFO_EMPTY) != 0
        if v_push_text(vctxt, TEXT_NODE, ch, len, XML_SCHEMA_PUSH_TEXT_VOLATILE) == -1
          internal_err(vctxt, "xmlSchemaSAXHandleCDataSection", "calling xmlSchemaVPushText()")
          vctxt.err = -1
          vctxt.parser_ctxt&.stop_parser
        end
      end

      # xmlSchemaSAXHandleCDataSection
      def sax_handle_c_data_section(vctxt, ch, len)
        return if vctxt.depth < 0
        return if vctxt.skip_depth != -1 && vctxt.depth >= vctxt.skip_depth

        vctxt.inode.flags ^= XML_SCHEMA_ELEM_INFO_EMPTY if (vctxt.inode.flags & XML_SCHEMA_ELEM_INFO_EMPTY) != 0
        if v_push_text(vctxt, CDATA_SECTION_NODE, ch, len, XML_SCHEMA_PUSH_TEXT_VOLATILE) == -1
          internal_err(vctxt, "xmlSchemaSAXHandleCDataSection", "calling xmlSchemaVPushText()")
          vctxt.err = -1
          vctxt.parser_ctxt&.stop_parser
        end
      end

      # xmlSchemaSAXHandleReference
      def sax_handle_reference(_vctxt, _name) = nil

      # xmlSchemaSAXHandleStartElementNs. +namespaces+ is a flat Array [prefix, uri, ...] and
      # +attributes+ an Array of [localname, prefix, uri, value] (value already unescaped).
      def sax_handle_start_element_ns(vctxt, localname, _prefix, uri, namespaces, attributes, node_line)
        vctxt.depth += 1
        return if vctxt.skip_depth != -1 && vctxt.depth >= vctxt.skip_depth

        validator_push_elem(vctxt)
        ielem = vctxt.inode
        ielem.node_line = node_line
        ielem.local_name = localname
        ielem.ns_name = uri
        ielem.flags |= XML_SCHEMA_ELEM_INFO_EMPTY
        if namespaces && !namespaces.empty?
          ielem.ns_bindings = []
          ielem.nb_ns_bindings = 0
          j = 0
          while j < namespaces.size
            ielem.ns_bindings << namespaces[j]
            u = namespaces[j + 1]
            ielem.ns_bindings << (u.nil? || u.empty? ? nil : u)
            ielem.nb_ns_bindings += 1
            j += 2
          end
        end
        attributes&.each do |(alocal, _aprefix, auri, avalue)|
          validator_push_attribute(vctxt, nil, ielem.node_line, alocal, auri, 0, avalue, 1)
        end
        ret = validate_elem(vctxt)
        if ret == -1
          internal_err(vctxt, "xmlSchemaSAXHandleStartElementNs", "calling xmlSchemaValidateElem()")
          vctxt.err = -1
          vctxt.parser_ctxt&.stop_parser
        end
      end

      # xmlSchemaSAXHandleEndElementNs
      def sax_handle_end_element_ns(vctxt, localname, _prefix, uri)
        if vctxt.skip_depth != -1
          if vctxt.depth > vctxt.skip_depth
            vctxt.depth -= 1
            return
          else
            vctxt.skip_depth = -1
          end
        end
        if vctxt.inode.local_name != localname || vctxt.inode.ns_name != uri
          internal_err(vctxt, "xmlSchemaSAXHandleEndElementNs", "elem pop mismatch")
        end
        res = validator_pop_elem(vctxt)
        if res < 0
          internal_err(vctxt, "xmlSchemaSAXHandleEndElementNs", "calling xmlSchemaValidatorPopElem()")
          vctxt.err = -1
          vctxt.parser_ctxt&.stop_parser
        end
      end

      # ---- context & drivers --------------------------------------------------------------

      # xmlSchemaNewValidCtxt
      def new_valid_ctxt(schema)
        ret = SchemaValidCtxt.new
        ret.type = XML_SCHEMA_CTXT_VALIDATOR
        ret.node_qnames = SchemaItemList.new
        ret.schema = schema
        ret.attr_infos = []
        ret
      end

      # xmlSchemaClearValidCtxt
      def clear_valid_ctxt(vctxt)
        return if vctxt.nil?

        vctxt.flags = 0
        vctxt.validation_root = nil
        vctxt.doc = nil
        vctxt.reader = nil
        vctxt.has_keyrefs = 0
        vctxt.value = nil
        vctxt.aidcs = nil
        vctxt.idc_nodes = nil
        vctxt.idc_keys = nil
        vctxt.xpath_states = nil
        clear_attr_infos(vctxt) if vctxt.nb_attr_infos != 0
        vctxt.elem_infos&.each { |ei| clear_elem_info(vctxt, ei) if ei }
        vctxt.node_qnames = SchemaItemList.new
        vctxt.filename = nil
      end

      def free_valid_ctxt(_ctxt) = nil

      # xmlSchemaIsValid
      def is_valid(ctxt) = ctxt.nil? ? -1 : (ctxt.err == 0 ? 1 : 0)

      # xmlSchemaSetValidStructuredErrors
      def set_valid_structured_errors(ctxt, serror, ctx = nil)
        return if ctxt.nil?

        ctxt.serror = serror
        ctxt.error = nil
        ctxt.warning = nil
        ctxt.err_ctxt = ctx
        set_parser_structured_errors(ctxt.pctxt, serror, ctx) if ctxt.pctxt
      end

      # xmlSchemaSetValidOptions
      def set_valid_options(ctxt, options)
        return -1 if ctxt.nil?
        return -1 if (options & ~1) != 0

        ctxt.options = options
        0
      end

      def valid_ctxt_get_options(ctxt) = ctxt.nil? ? -1 : ctxt.options

      # xmlSchemaVDocWalk
      def v_doc_walk(vctxt)
        ret = 0
        ielem = nil
        val_root = vctxt.validation_root || Tree.doc_get_root_element(vctxt.doc)
        if val_root.nil?
          verror(vctxt, 1, nil, "The document has no document element")
          return 1
        end
        vctxt.depth = -1
        vctxt.validation_root = val_root
        node = val_root
        while node
          leave = false
          if vctxt.skip_depth != -1 && vctxt.depth >= vctxt.skip_depth
            # goto next_sibling
          else
            descend = false
            case node.type
            when ELEMENT_NODE
              vctxt.depth += 1
              validator_push_elem(vctxt)
              ielem = vctxt.inode
              ielem.node = node
              ielem.node_line = node.line
              ielem.local_name = node.name
              ielem.ns_name = node.ns.href if node.ns
              ielem.flags |= XML_SCHEMA_ELEM_INFO_EMPTY
              vctxt.nb_attr_infos = 0
              attr = node.properties
              while attr
                ns_name = attr.ns ? attr.ns.href : nil
                validator_push_attribute(vctxt, attr, ielem.node_line, attr.name, ns_name, 0,
                  Tree.node_list_get_string(attr.doc, attr.children, 1), 1)
                attr = attr.next
              end
              ret = validate_elem(vctxt)
              if ret != 0
                if ret == -1
                  internal_err(vctxt, "xmlSchemaDocWalk", "calling xmlSchemaValidateElem()")
                  return -1
                end
                leave = true
              elsif vctxt.skip_depth != -1 && vctxt.depth >= vctxt.skip_depth
                leave = true
              else
                descend = true
              end
            when TEXT_NODE, CDATA_SECTION_NODE
              ielem.flags ^= XML_SCHEMA_ELEM_INFO_EMPTY if ielem && (ielem.flags & XML_SCHEMA_ELEM_INFO_EMPTY) != 0
              ret = v_push_text(vctxt, node.type, node.content, -1, XML_SCHEMA_PUSH_TEXT_PERSIST)
              if ret < 0
                internal_err(vctxt, "xmlSchemaVDocWalk", "calling xmlSchemaVPushText()")
                return -1
              end
              descend = true
            when ENTITY_NODE, ENTITY_REF_NODE
              internal_err(vctxt, "xmlSchemaVDocWalk",
                "there is at least one entity reference in the node-tree currently being validated. " \
                "Processing of entities with this XML Schema processor is not supported (yet). Please " \
                "substitute entities before validation.")
              return -1
            else
              leave = true
            end
            if descend && node.children
              node = node.children
              next
            end
            leave = true
          end

          # leave_node / next_sibling loop
          loop do
            if leave && node.type == ELEMENT_NODE
              unless node.equal?(vctxt.inode&.node)
                internal_err(vctxt, "xmlSchemaVDocWalk", "element position mismatch")
                return -1
              end
              ret = validator_pop_elem(vctxt)
              if ret != 0 && ret < 0
                internal_err(vctxt, "xmlSchemaVDocWalk", "calling xmlSchemaValidatorPopElem()")
                return -1
              end
              return ret if node.equal?(val_root)
            end
            # next_sibling:
            if node.next
              node = node.next
              break
            else
              node = node.parent
              leave = true
            end
          end
        end
        ret
      end

      # xmlSchemaPreRun
      def pre_run(vctxt)
        vctxt.err = 0
        vctxt.nberrors = 0
        vctxt.depth = -1
        vctxt.skip_depth = -1
        vctxt.has_keyrefs = 0
        vctxt.create_idc_node_tables = 0
        if vctxt.schema.nil?
          vctxt.xsi_assemble = 1
          return -1 if vctxt.pctxt.nil? && create_p_ctxt_on_v_ctxt(vctxt) == -1

          pctxt = vctxt.pctxt
          pctxt.xsi_assemble = 1
          vctxt.schema = new_schema(pctxt)
          return -1 if vctxt.schema.nil?

          pctxt.constructor = construction_ctxt_create(pctxt.dict)
          return -1 if pctxt.constructor.nil?

          pctxt.constructor.main_schema = vctxt.schema
          pctxt.owns_constructor = 1
        end
        vctxt.schema.schemas_imports&.each_value { |imp| augment_imported_idc(imp, vctxt) }
        0
      end

      # xmlSchemaPostRun
      def post_run(vctxt)
        vctxt.schema = nil if vctxt.xsi_assemble != 0
        clear_valid_ctxt(vctxt)
      end

      # xmlSchemaVStart. For streaming validation the caller passes a block that runs the parser.
      def v_start(vctxt)
        return -1 if pre_run(vctxt) < 0

        ret = if vctxt.doc
          v_doc_walk(vctxt)
        elsif block_given?
          yield
        else
          internal_err(vctxt, "xmlSchemaVStart", "no instance to validate")
          -1
        end
        post_run(vctxt)
        ret = vctxt.err if ret == 0
        ret
      end

      # xmlSchemaValidateOneElement
      def validate_one_element(ctxt, elem)
        return -1 if ctxt.nil? || elem.nil? || elem.type != ELEMENT_NODE
        return -1 if ctxt.schema.nil?

        ctxt.doc = elem.doc
        ctxt.node = elem
        ctxt.validation_root = elem
        v_start(ctxt)
      end

      # xmlSchemaValidateDoc
      def validate_doc(ctxt, doc)
        return -1 if ctxt.nil? || doc.nil?

        ctxt.doc = doc
        ctxt.node = Tree.doc_get_root_element(doc)
        if ctxt.node.nil?
          custom_err(ctxt, ErrCode::SCHEMAV_DOCUMENT_ELEMENT_MISSING, doc, nil,
            "The document has no document element", nil, nil)
          return ctxt.err
        end
        ctxt.validation_root = ctxt.node
        v_start(ctxt)
      end
    end
  end
end
