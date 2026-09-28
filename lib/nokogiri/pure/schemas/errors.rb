# frozen_string_literal: true

require_relative "structs"
require_relative "common"
require_relative "macros"

# Port of xmlschemas.c (libxml2 2.13.9) lines ~1120-3310: component description / message
# formatting helpers and all error reporting functions.
#
# String-buffer helpers (`const xmlChar *f(xmlChar **buf, ...)`) take no buffer and return the
# resulting String (or nil where the C buffer would be NULL). Messages are built exactly like
# the C code builds them (xmlStrcat sequences, xmlEscapeFormatString calls) and are then used
# as printf *formats* via Schemas.c_format with the same str1..str4 arguments.
module Nokogiri
  module Pure
    module Schemas
      extend self

      MAX_ERR_MSG_SIZE = 64000

      # xmlStrcat semantics: nil + x -> copy of x; a + nil -> a. +a+ must be a buffer owned
      # by the caller (it is appended to in place unless frozen).
      def str_cat(a, b)
        return a if b.nil?
        return +b.dup if a.nil?

        a = +a if a.frozen?
        a << b
      end

      # xmlStrVASPrintf(&tmp, MAX_ERR_MSG_SIZE, fmt, ap) as used by xmlVSetError
      def schema_vformat(fmt, args)
        return +"No error message provided" if fmt.nil?

        s = c_format(fmt, *args)
        if s.bytesize >= MAX_ERR_MSG_SIZE
          buf = s.b
          i = MAX_ERR_MSG_SIZE - 1
          while i > 0
            break if buf.getbyte(i - 1) < 0x80

            i -= 1
            break if buf.getbyte(i) >= 0xc0
          end
          s = buf.byteslice(0, i).force_encoding(Encoding::UTF_8)
        end
        s
      end

      # ------------------------------------------------------------------------------------
      # Helper functions
      # ------------------------------------------------------------------------------------

      # xmlSchemaItemTypeToStr
      def item_type_to_str(type)
        case type
        when XML_SCHEMA_TYPE_BASIC then "simple type definition"
        when XML_SCHEMA_TYPE_SIMPLE then "simple type definition"
        when XML_SCHEMA_TYPE_COMPLEX then "complex type definition"
        when XML_SCHEMA_TYPE_ELEMENT then "element declaration"
        when XML_SCHEMA_TYPE_ATTRIBUTE_USE then "attribute use"
        when XML_SCHEMA_TYPE_ATTRIBUTE then "attribute declaration"
        when XML_SCHEMA_TYPE_GROUP then "model group definition"
        when XML_SCHEMA_TYPE_ATTRIBUTEGROUP then "attribute group definition"
        when XML_SCHEMA_TYPE_NOTATION then "notation declaration"
        when XML_SCHEMA_TYPE_SEQUENCE then "model group (sequence)"
        when XML_SCHEMA_TYPE_CHOICE then "model group (choice)"
        when XML_SCHEMA_TYPE_ALL then "model group (all)"
        when XML_SCHEMA_TYPE_PARTICLE then "particle"
        when XML_SCHEMA_TYPE_IDC_UNIQUE then "unique identity-constraint"
        when XML_SCHEMA_TYPE_IDC_KEY then "key identity-constraint"
        when XML_SCHEMA_TYPE_IDC_KEYREF then "keyref identity-constraint"
        when XML_SCHEMA_TYPE_ANY then "wildcard (any)"
        when XML_SCHEMA_EXTRA_QNAMEREF then "[helper component] QName reference"
        when XML_SCHEMA_EXTRA_ATTR_USE_PROHIB then "[helper component] attribute use prohibition"
        else "Not a schema component"
        end
      end

      # xmlSchemaGetComponentTypeStr
      def get_component_type_str(item)
        if item.type == XML_SCHEMA_TYPE_BASIC
          wxs_is_complex(item) ? "complex type definition" : "simple type definition"
        else
          item_type_to_str(item.type)
        end
      end

      # xmlSchemaGetComponentNode
      def get_component_node(item)
        case item.type
        when XML_SCHEMA_TYPE_ELEMENT, XML_SCHEMA_TYPE_ATTRIBUTE, XML_SCHEMA_TYPE_COMPLEX,
             XML_SCHEMA_TYPE_SIMPLE, XML_SCHEMA_TYPE_ANY, XML_SCHEMA_TYPE_ANY_ATTRIBUTE,
             XML_SCHEMA_TYPE_PARTICLE, XML_SCHEMA_TYPE_SEQUENCE, XML_SCHEMA_TYPE_CHOICE,
             XML_SCHEMA_TYPE_ALL, XML_SCHEMA_TYPE_GROUP, XML_SCHEMA_TYPE_ATTRIBUTEGROUP,
             XML_SCHEMA_TYPE_IDC_UNIQUE, XML_SCHEMA_TYPE_IDC_KEY, XML_SCHEMA_TYPE_IDC_KEYREF,
             XML_SCHEMA_EXTRA_QNAMEREF, XML_SCHEMA_TYPE_ATTRIBUTE_USE
          item.node
        end
      end

      # xmlSchemaGetNextComponent (#if 0 in C; kept for completeness)
      def get_next_component(item)
        case item.type
        when XML_SCHEMA_TYPE_ELEMENT, XML_SCHEMA_TYPE_ATTRIBUTE, XML_SCHEMA_TYPE_COMPLEX,
             XML_SCHEMA_TYPE_SIMPLE, XML_SCHEMA_TYPE_PARTICLE, XML_SCHEMA_TYPE_ATTRIBUTEGROUP,
             XML_SCHEMA_TYPE_IDC_UNIQUE, XML_SCHEMA_TYPE_IDC_KEY, XML_SCHEMA_TYPE_IDC_KEYREF
          item.next
        end
      end

      # xmlSchemaFormatQName: "{ns}local", or local itself if ns is nil
      def format_q_name(namespace_name, local_name)
        buf = nil
        buf = +"{" << namespace_name << "}" if namespace_name
        if local_name
          return local_name if namespace_name.nil?

          buf << local_name
        else
          buf = str_cat(buf, "(NULL)")
        end
        buf
      end
      alias_method :format_qname, :format_q_name

      # xmlSchemaFormatQNameNs
      def format_q_name_ns(ns, local_name)
        format_q_name(ns&.href, local_name)
      end
      alias_method :format_qname_ns, :format_q_name_ns

      # xmlSchemaGetComponentName
      def get_component_name(item)
        return nil if item.nil?

        case item.type
        when XML_SCHEMA_TYPE_ELEMENT, XML_SCHEMA_TYPE_ATTRIBUTE, XML_SCHEMA_TYPE_ATTRIBUTEGROUP,
             XML_SCHEMA_TYPE_BASIC, XML_SCHEMA_TYPE_SIMPLE, XML_SCHEMA_TYPE_COMPLEX,
             XML_SCHEMA_TYPE_GROUP, XML_SCHEMA_TYPE_IDC_KEY, XML_SCHEMA_TYPE_IDC_UNIQUE,
             XML_SCHEMA_TYPE_IDC_KEYREF, XML_SCHEMA_EXTRA_QNAMEREF, XML_SCHEMA_TYPE_NOTATION
          item.name
        when XML_SCHEMA_TYPE_ATTRIBUTE_USE
          item.attr_decl.nil? ? nil : get_component_name(item.attr_decl)
        end
      end

      # xmlSchemaGetQNameRefName (macro)
      def get_q_name_ref_name(r) = r.name
      # xmlSchemaGetQNameRefTargetNs (macro)
      def get_q_name_ref_target_ns(r) = r.target_namespace

      # xmlSchemaGetComponentTargetNs
      def get_component_target_ns(item)
        return nil if item.nil?

        case item.type
        when XML_SCHEMA_TYPE_ELEMENT, XML_SCHEMA_TYPE_ATTRIBUTE, XML_SCHEMA_TYPE_ATTRIBUTEGROUP,
             XML_SCHEMA_TYPE_SIMPLE, XML_SCHEMA_TYPE_COMPLEX, XML_SCHEMA_TYPE_GROUP,
             XML_SCHEMA_TYPE_IDC_KEY, XML_SCHEMA_TYPE_IDC_UNIQUE, XML_SCHEMA_TYPE_IDC_KEYREF,
             XML_SCHEMA_EXTRA_QNAMEREF, XML_SCHEMA_TYPE_NOTATION
          item.target_namespace
        when XML_SCHEMA_TYPE_BASIC
          XML_SCHEMAS_NS
        when XML_SCHEMA_TYPE_ATTRIBUTE_USE
          item.attr_decl.nil? ? nil : get_component_target_ns(item.attr_decl)
        end
      end

      # xmlSchemaGetComponentQName
      def get_component_q_name(item)
        format_q_name(get_component_target_ns(item), get_component_name(item))
      end
      alias_method :get_component_qname, :get_component_q_name

      # xmlSchemaGetComponentDesignation: "<component type> '<qname>'"
      # (C appends to *buf, which every caller passes as NULL.)
      def get_component_designation(item)
        buf = str_cat(nil, get_component_type_str(item))
        buf = str_cat(buf, " '")
        buf = str_cat(buf, get_component_q_name(item))
        str_cat(buf, "'")
      end

      # xmlSchemaGetIDCDesignation
      def get_idc_designation(idc)
        get_component_designation(idc)
      end

      # xmlSchemaWildcardPCToString
      def wildcard_pc_to_string(pc)
        case pc
        when XML_SCHEMAS_ANY_SKIP then "skip"
        when XML_SCHEMAS_ANY_LAX then "lax"
        when XML_SCHEMAS_ANY_STRICT then "strict"
        else "invalid process contents"
        end
      end

      # xmlSchemaGetCanonValueWhtspExt_1 -> [ret, str]
      def get_canon_value_whtsp_ext_1(val, ws, for_hash)
        return [-1, nil] if val.nil?

        list = Types.value_get_next(val) ? true : false
        ret_value = nil
        loop do
          value = nil
          value2 = nil
          val_type = Types.get_val_type(val)
          case val_type
          when XML_SCHEMAS_STRING, XML_SCHEMAS_NORMSTRING, XML_SCHEMAS_ANYSIMPLETYPE
            value = Types.value_get_as_string(val)
            if value
              if ws == XML_SCHEMA_WHITESPACE_COLLAPSE
                value2 = Types.collapse_string(value)
              elsif ws == XML_SCHEMA_WHITESPACE_REPLACE
                value2 = Types.white_space_replace(value)
              end
              value = value2 if value2
            end
          else
            res, value2 = Types.get_canon_value(val)
            return [-1, nil] if res == -1

            if for_hash != 0 && for_hash != false && val_type == XML_SCHEMAS_DECIMAL && value2
              len = value2.bytesize
              if len > 2 && value2.getbyte(len - 1) == 48 && value2.getbyte(len - 2) == 46
                value2 = value2.byteslice(0, len - 2)
              end
            end
            value = value2
          end
          if ret_value.nil?
            if value.nil?
              ret_value = +"" unless list
            else
              ret_value = value.dup
            end
          elsif value
            # List.
            ret_value << " " << value
          end
          val = Types.value_get_next(val)
          break if val.nil?
        end
        [0, ret_value]
      end

      # xmlSchemaGetCanonValueWhtspExt -> [ret, str]
      def get_canon_value_whtsp_ext(val, ws)
        get_canon_value_whtsp_ext_1(val, ws, 0)
      end

      # xmlSchemaGetCanonValueHash -> [ret, str]
      def get_canon_value_hash(val)
        get_canon_value_whtsp_ext_1(val, XML_SCHEMA_WHITESPACE_COLLAPSE, 1)
      end

      # xmlSchemaFormatItemForReport: returns the (format-escaped) designation or nil
      def format_item_for_report(item_des, item, item_node)
        buf = nil
        named = true

        if item_des
          buf = +item_des.dup
        elsif item
          case item.type
          when XML_SCHEMA_TYPE_BASIC
            buf = if wxs_is_atomic(item)
              +"atomic type 'xs:"
            elsif wxs_is_list(item)
              +"list type 'xs:"
            elsif wxs_is_union(item)
              +"union type 'xs:"
            else
              +"simple type 'xs:"
            end
            buf = str_cat(buf, item.name)
            buf << "'"
          when XML_SCHEMA_TYPE_SIMPLE
            global = (item.flags & XML_SCHEMAS_TYPE_GLOBAL) != 0
            buf = global ? +"" : +"local "
            buf << if wxs_is_atomic(item)
              "atomic type"
            elsif wxs_is_list(item)
              "list type"
            elsif wxs_is_union(item)
              "union type"
            else
              "simple type"
            end
            if global
              buf << " '"
              buf = str_cat(buf, item.name)
              buf << "'"
            end
          when XML_SCHEMA_TYPE_COMPLEX
            global = (item.flags & XML_SCHEMAS_TYPE_GLOBAL) != 0
            buf = global ? +"" : +"local "
            buf << "complex type"
            if global
              buf << " '"
              buf = str_cat(buf, item.name)
              buf << "'"
            end
          when XML_SCHEMA_TYPE_ATTRIBUTE_USE
            buf = +"attribute use "
            if item.attr_decl
              buf << "'"
              buf = str_cat(buf, get_component_q_name(item.attr_decl))
              buf << "'"
            else
              buf << "(unknown)"
            end
          when XML_SCHEMA_TYPE_ATTRIBUTE
            buf = +"attribute decl. '"
            buf = str_cat(buf, format_q_name(item.target_namespace, item.name))
            buf << "'"
          when XML_SCHEMA_TYPE_ATTRIBUTEGROUP
            buf = get_component_designation(item)
          when XML_SCHEMA_TYPE_ELEMENT
            buf = +"element decl. '"
            buf = str_cat(buf, format_q_name(item.target_namespace, item.name))
            buf << "'"
          when XML_SCHEMA_TYPE_IDC_UNIQUE, XML_SCHEMA_TYPE_IDC_KEY, XML_SCHEMA_TYPE_IDC_KEYREF
            buf = if item.type == XML_SCHEMA_TYPE_IDC_UNIQUE
              +"unique '"
            elsif item.type == XML_SCHEMA_TYPE_IDC_KEY
              +"key '"
            else
              +"keyRef '"
            end
            buf = str_cat(buf, item.name)
            buf << "'"
          when XML_SCHEMA_TYPE_ANY, XML_SCHEMA_TYPE_ANY_ATTRIBUTE
            buf = +wildcard_pc_to_string(item.process_contents).dup
            buf << " wildcard"
          when XML_SCHEMA_FACET_MININCLUSIVE, XML_SCHEMA_FACET_MINEXCLUSIVE,
               XML_SCHEMA_FACET_MAXINCLUSIVE, XML_SCHEMA_FACET_MAXEXCLUSIVE,
               XML_SCHEMA_FACET_TOTALDIGITS, XML_SCHEMA_FACET_FRACTIONDIGITS,
               XML_SCHEMA_FACET_PATTERN, XML_SCHEMA_FACET_ENUMERATION,
               XML_SCHEMA_FACET_WHITESPACE, XML_SCHEMA_FACET_LENGTH,
               XML_SCHEMA_FACET_MAXLENGTH, XML_SCHEMA_FACET_MINLENGTH
            buf = +"facet '"
            buf = str_cat(buf, facet_type_to_string(item.type))
            buf << "'"
          when XML_SCHEMA_TYPE_GROUP
            buf = +"model group def. '"
            buf = str_cat(buf, get_component_q_name(item))
            buf << "'"
          when XML_SCHEMA_TYPE_SEQUENCE, XML_SCHEMA_TYPE_CHOICE, XML_SCHEMA_TYPE_ALL,
               XML_SCHEMA_TYPE_PARTICLE
            buf = +get_component_type_str(item).dup
          when XML_SCHEMA_TYPE_NOTATION
            buf = +get_component_type_str(item).dup
            buf << " '"
            buf = str_cat(buf, get_component_q_name(item))
            buf << "'"
            # Falls through to default.
            named = false
          else
            named = false
          end
        else
          named = false
        end

        if !named && item_node
          elem = item_node.type == ATTRIBUTE_NODE ? item_node.parent : item_node
          buf = +"Element '"
          buf = if elem.ns
            str_cat(buf, format_q_name(elem.ns.href, elem.name))
          else
            str_cat(buf, elem.name)
          end
          buf << "'"
        end
        if item_node && item_node.type == ATTRIBUTE_NODE
          buf = str_cat(buf, ", attribute '")
          buf = if item_node.ns
            str_cat(buf, format_q_name(item_node.ns.href, item_node.name))
          else
            str_cat(buf, item_node.name)
          end
          buf = str_cat(buf, "'")
        end
        escape_format_string(buf)
      end

      # xmlSchemaFormatFacetEnumSet: "'a', 'b', 'c'" or nil
      def format_facet_enum_set(actxt, type)
        buf = nil
        found = false
        loop do
          # Use the whitespace type of the base type.
          ws = get_white_space_facet_value(type.base_type)
          facet = type.facets
          while facet
            if facet.type != XML_SCHEMA_FACET_ENUMERATION
              facet = facet.next
              next
            end
            found = true
            res, value = get_canon_value_whtsp_ext(facet.val, ws)
            if res == -1
              internal_err(actxt, "xmlSchemaFormatFacetEnumSet",
                "compute the canonical lexical representation")
              return nil
            end
            buf = buf.nil? ? +"'" : (buf << ", '")
            buf = str_cat(buf, value)
            buf << "'"
            facet = facet.next
          end
          # The enumeration facet of a type restricts the enumeration facet of the ancestor
          # type; thus we break on the first found enumeration.
          break if found

          type = type.base_type
          break unless type && type.type != XML_SCHEMA_TYPE_BASIC
        end
        buf
      end

      # ------------------------------------------------------------------------------------
      # Error functions
      # ------------------------------------------------------------------------------------

      # xmlSchemaPErrMemory
      def p_err_memory(ctxt)
        if ctxt
          ctxt.nberrors += 1
          ctxt.err = ErrCode::ERR_NO_MEMORY if defined?(ErrCode::ERR_NO_MEMORY)
        end
        nil
      end

      # xmlSchemaPErrFull (msg is a printf format, args its arguments)
      def p_err_full(ctxt, node, code, level, file, line, str1, str2, str3, col, msg, *args)
        schannel = nil
        if ctxt
          if level != Level::WARNING
            ctxt.nberrors += 1
            ctxt.err = code
          end
          schannel = ctxt.serror
        end
        raise_error(schannel, node, Domain::SCHEMASP, code, level, file, line,
          str1, str2, str3, 0, col, schema_vformat(msg, args))
        nil
      end

      # xmlSchemaPErr
      def p_err(ctxt, node, code, msg, str1, str2)
        p_err_full(ctxt, node, code, Level::ERROR, nil, 0, str1, str2, nil, 0, msg, str1, str2)
      end

      # xmlSchemaPErr2
      def p_err2(ctxt, node, child, error, msg, str1, str2)
        if child
          p_err(ctxt, child, error, msg, str1, str2)
        else
          p_err(ctxt, node, error, msg, str1, str2)
        end
      end

      # xmlSchemaPErrExt
      def p_err_ext(ctxt, node, code, str_data1, str_data2, str_data3, msg, str1, str2, str3, str4, str5)
        p_err_full(ctxt, node, code, Level::ERROR, nil, 0, str_data1, str_data2, str_data3, 0,
          msg, str1, str2, str3, str4, str5)
      end

      # xmlSchemaVErrMemory
      def v_err_memory(ctxt)
        p_err_memory(ctxt)
      end

      # xmlSchemaVErrFull
      def v_err_full(ctxt, node, code, level, file, line, str1, str2, str3, col, msg, *args)
        schannel = nil
        if ctxt
          if level != Level::WARNING
            ctxt.nberrors += 1
            ctxt.err = code
          end
          schannel = ctxt.serror
        end
        raise_error(schannel, node, Domain::SCHEMASV, code, level, file, line,
          str1, str2, str3, 0, col, schema_vformat(msg, args))
        nil
      end

      # vctxt->locFunc(vctxt->locCtxt, &f, &l) -> [file, line]
      def call_loc_func(vctxt)
        f = vctxt.loc_func
        r = if f.respond_to?(:arity) && f.arity == 0
          f.call
        else
          f.call(vctxt.loc_ctxt)
        end
        r.is_a?(Array) ? r : [nil, 0]
      end
      private :call_loc_func

      # xmlSchemaErr4Line
      def err4_line(ctxt, error_level, code, node, line, msg, str1, str2, str3, str4)
        return if ctxt.nil?

        if ctxt.type == XML_SCHEMA_CTXT_VALIDATOR
          vctxt = ctxt
          file = nil
          col = 0
          line ||= 0
          pinput = vctxt.parser_ctxt&.input
          # Error node. If we specify a line number, then do not channel any node to the
          # error function.
          if line == 0
            node = vctxt.inode.node if node.nil? && vctxt.depth >= 0 && vctxt.inode
            # Get filename and line if no node-tree.
            if node.nil? && pinput
              file = pinput.filename
              if vctxt.inode
                line = vctxt.inode.node_line
                col = 0
              else
                # This is inaccurate.
                line = pinput.line
                col = pinput.col
              end
            end
          else
            # Override the given node's (if any) position and channel only the given line
            # number.
            node = nil
            # Get filename.
            if vctxt.doc
              file = vctxt.doc.url
            elsif pinput
              file = pinput.filename
            end
          end
          if vctxt.loc_func && (file.nil? || line.nil? || line == 0)
            f, l = call_loc_func(vctxt)
            file = f if file.nil?
            line = l.to_i if line.nil? || line == 0
          end
          file = vctxt.filename if file.nil? && vctxt.filename

          v_err_full(vctxt, node, code, error_level, file, line, str1, str2, str3, col,
            msg, str1, str2, str3, str4)
        elsif ctxt.type == XML_SCHEMA_CTXT_PARSER
          p_err_full(ctxt, node, code, error_level, nil, 0, str1, str2, str3, 0,
            msg, str1, str2, str3, str4)
        end
        nil
      end

      # xmlSchemaErr3
      def err3(actxt, error, node, msg, str1, str2, str3)
        err4_line(actxt, Level::ERROR, error, node, 0, msg, str1, str2, str3, nil)
      end

      # xmlSchemaErr4
      def err4(actxt, error, node, msg, str1, str2, str3, str4)
        err4_line(actxt, Level::ERROR, error, node, 0, msg, str1, str2, str3, str4)
      end

      # xmlSchemaErr
      def err(actxt, error, node, msg, str1, str2)
        err4(actxt, error, node, msg, str1, str2, nil, nil)
      end

      # xmlSchemaFormatNodeForError: "Element '{ns}foo': " / "Element 'x', attribute 'y': "
      # (format-escaped), "" or nil
      def format_node_for_error(actxt, node)
        if node && node.type != ELEMENT_NODE && node.type != ATTRIBUTE_NODE
          # Don't try to format other nodes than element and attribute nodes.
          return +""
        end

        if node
          # Work on tree nodes.
          if node.type == ATTRIBUTE_NODE
            elem = node.parent
            msg = +"Element '"
            msg = str_cat(msg, format_q_name(elem.ns ? elem.ns.href : nil, elem.name))
            msg << "', attribute '"
          else
            msg = +"Element '"
          end
          msg = str_cat(msg, format_q_name(node.ns ? node.ns.href : nil, node.name))
          msg << "': "
        elsif actxt.type == XML_SCHEMA_CTXT_VALIDATOR
          vctxt = actxt
          # Work on node infos.
          if vctxt.inode.node_type == ATTRIBUTE_NODE
            ielem = vctxt.elem_infos[vctxt.depth]
            msg = +"Element '"
            msg = str_cat(msg, format_q_name(ielem.ns_name, ielem.local_name))
            msg << "', attribute '"
          else
            msg = +"Element '"
          end
          msg = str_cat(msg, format_q_name(vctxt.inode.ns_name, vctxt.inode.local_name))
          msg << "': "
        elsif actxt.type == XML_SCHEMA_CTXT_PARSER
          # Hmm, no node while parsing? Return an empty string.
          msg = +""
        else
          return nil
        end
        escape_format_string(msg)
      end

      # xmlSchemaInternalErr2
      def internal_err2(actxt, func_name, message, str1, str2)
        return if actxt.nil?

        msg = +"Internal error: %s, "
        msg = str_cat(msg, message)
        msg << ".\n"
        if actxt.type == XML_SCHEMA_CTXT_VALIDATOR
          err3(actxt, ErrCode::SCHEMAV_INTERNAL, nil, msg, func_name, str1, str2)
        elsif actxt.type == XML_SCHEMA_CTXT_PARSER
          err3(actxt, ErrCode::SCHEMAP_INTERNAL, nil, msg, func_name, str1, str2)
        end
        nil
      end

      # xmlSchemaInternalErr
      def internal_err(actxt, func_name, message)
        internal_err2(actxt, func_name, message, nil, nil)
      end

      # xmlSchemaPInternalErr (#if 0 in C)
      def p_internal_err(pctxt, func_name, message, str1, str2)
        internal_err2(pctxt, func_name, message, str1, str2)
      end

      # xmlSchemaCustomErr4
      def custom_err4(actxt, error, node, item, message, str1, str2, str3, str4)
        if node.nil? && item && actxt.type == XML_SCHEMA_CTXT_PARSER
          node = get_component_node(item)
          msg = format_item_for_report(nil, item, nil)
          msg = str_cat(msg, ": ")
        else
          msg = format_node_for_error(actxt, node)
        end
        msg = str_cat(msg, message)
        msg = str_cat(msg, ".\n")
        err4(actxt, error, node, msg, str1, str2, str3, str4)
      end

      # xmlSchemaCustomErr
      def custom_err(actxt, error, node, item, message, str1, str2)
        custom_err4(actxt, error, node, item, message, str1, str2, nil, nil)
      end

      # xmlSchemaCustomWarning
      def custom_warning(actxt, error, node, _type, message, str1, str2, str3)
        msg = format_node_for_error(actxt, node)
        msg = str_cat(msg, message)
        msg = str_cat(msg, ".\n")
        # URGENT TODO: Set the error code to something sane.
        err4_line(actxt, Level::WARNING, error, node, 0, msg, str1, str2, str3, nil)
      end

      # xmlSchemaKeyrefErr
      def keyref_err(vctxt, error, idc_node, _type, message, str1, str2)
        msg = +"Element '%s': "
        msg = str_cat(msg, message)
        msg << ".\n"
        qnames = vctxt.node_qnames.items
        err4_line(vctxt, Level::ERROR, error, nil, idc_node.node_line, msg,
          format_q_name(qnames[idc_node.node_qname_id + 1], qnames[idc_node.node_qname_id]),
          str1, str2, nil)
      end

      # xmlSchemaEvalErrorNodeType
      def eval_error_node_type(actxt, node)
        return node.type if node
        if actxt.type == XML_SCHEMA_CTXT_VALIDATOR && actxt.inode
          return actxt.inode.node_type
        end

        -1
      end

      # xmlSchemaIsGlobalItem -> 1 / 0
      def is_global_item(item)
        case item.type
        when XML_SCHEMA_TYPE_COMPLEX, XML_SCHEMA_TYPE_SIMPLE
          return 1 if (item.flags & XML_SCHEMAS_TYPE_GLOBAL) != 0
        when XML_SCHEMA_TYPE_GROUP
          return 1
        when XML_SCHEMA_TYPE_ELEMENT
          return 1 if (item.flags & XML_SCHEMAS_ELEM_GLOBAL) != 0
        when XML_SCHEMA_TYPE_ATTRIBUTE
          return 1 if (item.flags & XML_SCHEMAS_ATTR_GLOBAL) != 0
        else
          # Note that attribute groups are always global.
          return 1
        end
        0
      end

      # shared tail of xmlSchemaSimpleTypeErr / xmlSchemaPSimpleTypeErr:
      # "the [local ]atomic type 'xs:foo'" part (appended to msg)
      def simple_type_err_type_part(msg, type)
        msg = str_cat(msg, is_global_item(type) == 0 ? "the local " : "the ")
        if wxs_is_atomic(type)
          msg = str_cat(msg, "atomic type")
        elsif wxs_is_list(type)
          msg = str_cat(msg, "list type")
        elsif wxs_is_union(type)
          msg = str_cat(msg, "union type")
        end
        [msg, is_global_item(type) != 0]
      end
      private :simple_type_err_type_part

      # the "'xs:name'" / "'{ns}name'" part, escaped
      def simple_type_err_name_part(msg, type)
        msg = str_cat(msg, " '")
        if type.built_in_type != 0
          msg = str_cat(msg, "xs:")
          str = type.name
        else
          str = format_q_name(type.target_namespace, type.name)
        end
        str_cat(msg, escape_format_string(str))
      end
      private :simple_type_err_name_part

      # xmlSchemaSimpleTypeErr
      def simple_type_err(actxt, error, node, value, type, display_value)
        display_value = false if display_value == 0
        msg = format_node_for_error(actxt, node)
        with_value = display_value || eval_error_node_type(actxt, node) == ATTRIBUTE_NODE
        msg = if with_value
          str_cat(msg, "'%s' is not a valid value of ")
        else
          str_cat(msg, "The character content is not a valid value of ")
        end
        msg, global = simple_type_err_type_part(msg, type)
        if global
          msg = simple_type_err_name_part(msg, type)
          msg = str_cat(msg, "'")
        end
        msg = str_cat(msg, ".\n")
        if display_value || eval_error_node_type(actxt, node) == ATTRIBUTE_NODE
          err(actxt, error, node, msg, value, nil)
        else
          err(actxt, error, node, msg, nil, nil)
        end
      end

      # xmlSchemaFormatErrorNodeQName
      def format_error_node_q_name(ni, node)
        if node
          format_q_name(node.ns ? node.ns.href : nil, node.name)
        elsif ni
          format_q_name(ni.ns_name, ni.local_name)
        end
      end

      # xmlSchemaIllegalAttrErr
      def illegal_attr_err(actxt, error, ni, node)
        msg = format_node_for_error(actxt, node)
        msg = str_cat(msg, "The attribute '%s' is not allowed.\n")
        err(actxt, error, node, msg, format_error_node_q_name(ni, node), nil)
      end

      # xmlSchemaComplexTypeErr (+values+: Array of Strings from reg_exec_next_values)
      def complex_type_err(actxt, error, node, _type, message, nbval, nbneg, values)
        msg = format_node_for_error(actxt, node)
        msg = str_cat(msg, message)
        msg = str_cat(msg, ".")
        # Note that is does not make sense to report that we have a wildcard here, since the
        # wildcard might be unfolded into multiple transitions.
        total = nbval + nbneg
        if total > 0
          str = total > 1 ? +" Expected is one of ( " : +" Expected is ( "
          ns_name = nil
          i = 0
          while i < total
            cur = values[i]
            if cur.nil?
              i += 1
              next
            end
            cur = cur.b
            len = cur.bytesize
            pos = 0
            if cur.start_with?("not ")
              pos = 4
              str << "##other"
            end
            # Get the local name.
            local_name = nil
            e = pos
            if cur.getbyte(e) == 42 # '*'
              local_name = +"*"
              e += 1
            else
              e += 1 while e < len && cur.getbyte(e) != 124 # '|'
              local_name = cur.byteslice(pos, e - pos).force_encoding(Encoding::UTF_8) if e > pos
            end
            if e < len
              e += 1
              # Skip "*|*" if they come with negated expressions, since they represent the
              # same negated wildcard.
              if nbneg == 0 || cur.getbyte(e) != 42 || local_name != "*"
                # Get the namespace name.
                c2 = e
                if cur.getbyte(e) == 42
                  ns_name = +"{*}"
                else
                  e = len
                  ns_name = i >= nbval ? +"{##other:" : +"{"
                  ns_name << cur.byteslice(c2, e - c2).force_encoding(Encoding::UTF_8) if e > c2
                  ns_name << "}"
                end
                str << ns_name
                ns_name = nil
              else
                i += 1
                next
              end
            end
            str = str_cat(str, local_name)
            str << ", " if i < total - 1
            i += 1
          end
          str << " ).\n"
          msg = str_cat(msg, escape_format_string(str))
        else
          msg = str_cat(msg, "\n")
        end
        err(actxt, error, node, msg, nil, nil)
      end

      # xmlSchemaFacetErr
      def facet_err(actxt, error, node, value, length, type, facet, message, str1, str2)
        node_type = eval_error_node_type(actxt, node)
        msg = format_node_for_error(actxt, node)
        facet_type = if error == ErrCode::SCHEMAV_CVC_ENUMERATION_VALID
          # If enumerations are validated, one must not expect the facet to be given.
          XML_SCHEMA_FACET_ENUMERATION
        else
          facet.type
        end
        msg = str_cat(msg, "[")
        msg << "facet '"
        msg = str_cat(msg, facet_type_to_string(facet_type))
        msg << "'] "
        if message.nil?
          # Use a default message.
          if facet_type == XML_SCHEMA_FACET_LENGTH || facet_type == XML_SCHEMA_FACET_MINLENGTH ||
              facet_type == XML_SCHEMA_FACET_MAXLENGTH
            if node_type == ATTRIBUTE_NODE
              msg << "The value '%s' has a length of '%s'; "
            else
              msg << "The value has a length of '%s'; "
            end
            len = Types.get_facet_value_as_u_long(facet).to_s
            act_len = length.to_s
            if facet_type == XML_SCHEMA_FACET_LENGTH
              msg << "this differs from the allowed length of '%s'.\n"
            elsif facet_type == XML_SCHEMA_FACET_MAXLENGTH
              msg << "this exceeds the allowed maximum length of '%s'.\n"
            elsif facet_type == XML_SCHEMA_FACET_MINLENGTH
              msg << "this underruns the allowed minimum length of '%s'.\n"
            end
            if node_type == ATTRIBUTE_NODE
              err3(actxt, error, node, msg, value, act_len, len)
            else
              err(actxt, error, node, msg, act_len, len)
            end
          elsif facet_type == XML_SCHEMA_FACET_ENUMERATION
            msg << "The value '%s' is not an element of the set {%s}.\n"
            err(actxt, error, node, msg, value, format_facet_enum_set(actxt, type))
          elsif facet_type == XML_SCHEMA_FACET_PATTERN
            msg << "The value '%s' is not accepted by the pattern '%s'.\n"
            err(actxt, error, node, msg, value, facet.value)
          elsif facet_type == XML_SCHEMA_FACET_MININCLUSIVE
            msg << "The value '%s' is less than the minimum value allowed ('%s').\n"
            err(actxt, error, node, msg, value, facet.value)
          elsif facet_type == XML_SCHEMA_FACET_MAXINCLUSIVE
            msg << "The value '%s' is greater than the maximum value allowed ('%s').\n"
            err(actxt, error, node, msg, value, facet.value)
          elsif facet_type == XML_SCHEMA_FACET_MINEXCLUSIVE
            msg << "The value '%s' must be greater than '%s'.\n"
            err(actxt, error, node, msg, value, facet.value)
          elsif facet_type == XML_SCHEMA_FACET_MAXEXCLUSIVE
            msg << "The value '%s' must be less than '%s'.\n"
            err(actxt, error, node, msg, value, facet.value)
          elsif facet_type == XML_SCHEMA_FACET_TOTALDIGITS
            msg << "The value '%s' has more digits than are allowed ('%s').\n"
            err(actxt, error, node, msg, value, facet.value)
          elsif facet_type == XML_SCHEMA_FACET_FRACTIONDIGITS
            msg << "The value '%s' has more fractional digits than are allowed ('%s').\n"
            err(actxt, error, node, msg, value, facet.value)
          elsif node_type == ATTRIBUTE_NODE
            msg << "The value '%s' is not facet-valid.\n"
            err(actxt, error, node, msg, value, nil)
          else
            msg << "The value is not facet-valid.\n"
            err(actxt, error, node, msg, nil, nil)
          end
        else
          msg = str_cat(msg, message)
          msg << ".\n"
          err(actxt, error, node, msg, str1, str2)
        end
      end

      # VERROR / VERROR_INT / PERROR_INT / AERROR_INT are written out by callers:
      #   VERROR(err, type, msg)  -> custom_err(vctxt, err, nil, type, msg, nil, nil)
      #   VERROR_INT(func, msg)   -> internal_err(vctxt, func, msg)
      #   PERROR_INT(func, msg)   -> internal_err(pctxt, func, msg)

      # xmlSchemaPMissingAttrErr
      def p_missing_attr_err(ctxt, error, owner_item, owner_elem, name, message)
        des = format_item_for_report(nil, owner_item, owner_elem)
        if message
          p_err(ctxt, owner_elem, error, "%s: %s.\n", des, message)
        else
          p_err(ctxt, owner_elem, error, "%s: The attribute '%s' is required but missing.\n",
            des, name)
        end
      end

      # xmlSchemaPResCompAttrErr
      def p_res_comp_attr_err(ctxt, error, owner_item, owner_elem, name, ref_name, ref_uri,
        ref_type, ref_type_str)
        des = format_item_for_report(nil, owner_item, owner_elem)
        ref_type_str = item_type_to_str(ref_type) if ref_type_str.nil?
        p_err_ext(ctxt, owner_elem, error, nil, nil, nil,
          "%s, attribute '%s': The QName value '%s' does not resolve to a(n) %s.\n",
          des, name, format_q_name(ref_uri, ref_name), ref_type_str, nil)
      end

      # xmlSchemaPCustomAttrErr. +owner_des+ is the C in/out `xmlChar **ownerDes`: nil means a
      # NULL pointer (every C caller passes NULL). Returns [owner_des].
      def p_custom_attr_err(ctxt, error, owner_des, owner_item, attr, msg)
        des = if owner_des.nil?
          format_item_for_report(nil, owner_item, attr&.parent)
        else
          owner_des
        end
        if attr.nil?
          p_err_ext(ctxt, nil, error, nil, nil, nil, "%s, attribute '%s': %s.\n",
            des, "Unknown", msg, nil, nil)
        else
          p_err_ext(ctxt, attr, error, nil, nil, nil, "%s, attribute '%s': %s.\n",
            des, attr.name, msg, nil, nil)
        end
        [owner_des]
      end

      # xmlSchemaPIllegalAttrErr
      def p_illegal_attr_err(ctxt, error, _owner_comp, attr)
        str_a = format_node_for_error(ctxt, attr.parent)
        err4(ctxt, error, attr, "%sThe attribute '%s' is not allowed.\n", str_a,
          format_q_name_ns(attr.ns, attr.name), nil, nil)
      end

      # xmlSchemaPCustomErrExt
      def p_custom_err_ext(ctxt, error, item, item_elem, message, str1, str2, str3)
        des = format_item_for_report(nil, item, item_elem)
        msg = +"%s: "
        msg = str_cat(msg, message)
        msg << ".\n"
        item_elem = get_component_node(item) if item_elem.nil? && item
        p_err_ext(ctxt, item_elem, error, nil, nil, nil, msg, des, str1, str2, str3, nil)
      end

      # xmlSchemaPCustomErr
      def p_custom_err(ctxt, error, item, item_elem, message, str1)
        p_custom_err_ext(ctxt, error, item, item_elem, message, str1, nil, nil)
      end

      # xmlSchemaPAttrUseErr4
      def p_attr_use_err4(ctxt, error, node, owner_item, attruse, message, str1, str2, str3, str4)
        msg = format_item_for_report(nil, owner_item, nil)
        msg = str_cat(msg, ", ")
        msg = str_cat(msg, format_item_for_report(nil, attruse, nil))
        msg = str_cat(msg, ": ")
        msg = str_cat(msg, message)
        msg = str_cat(msg, ".\n")
        err4(ctxt, error, node, msg, str1, str2, str3, str4)
      end

      # xmlSchemaPIllegalFacetAtomicErr
      def p_illegal_facet_atomic_err(ctxt, error, type, base_type, facet)
        des = format_item_for_report(nil, type, type.node)
        p_err_ext(ctxt, type.node, error, nil, nil, nil,
          "%s: The facet '%s' is not allowed on types derived from the type %s.\n",
          des, facet_type_to_string(facet.type),
          format_item_for_report(nil, base_type, nil), nil, nil)
      end

      # xmlSchemaPIllegalFacetListUnionErr
      def p_illegal_facet_list_union_err(ctxt, error, type, facet)
        des = format_item_for_report(nil, type, type.node)
        p_err(ctxt, type.node, error, "%s: The facet '%s' is not allowed.\n",
          des, facet_type_to_string(facet.type))
      end

      # xmlSchemaPMutualExclAttrErr
      def p_mutual_excl_attr_err(ctxt, error, owner_item, attr, name1, name2)
        des = format_item_for_report(nil, owner_item, attr.parent)
        p_err_ext(ctxt, attr, error, nil, nil, nil,
          "%s: The attributes '%s' and '%s' are mutually exclusive.\n",
          des, name1, name2, nil, nil)
      end

      # xmlSchemaPSimpleTypeErr
      def p_simple_type_err(ctxt, error, _owner_item, node, type, expected, value, message, str1, str2)
        msg = format_node_for_error(ctxt, node)
        if message.nil?
          # Use default messages.
          if type
            msg = if node.type == ATTRIBUTE_NODE
              str_cat(msg, "'%s' is not a valid value of ")
            else
              str_cat(msg, "The character content is not a valid value of ")
            end
            msg, global = simple_type_err_type_part(msg, type)
            if global
              msg = simple_type_err_name_part(msg, type)
              msg = str_cat(msg, "'.")
            end
          else
            msg = if node.type == ATTRIBUTE_NODE
              str_cat(msg, "The value '%s' is not valid.")
            else
              str_cat(msg, "The character content is not valid.")
            end
          end
          if expected
            msg = str_cat(msg, " Expected is '")
            msg = str_cat(msg, escape_format_string(expected))
            msg = str_cat(msg, "'.\n")
          else
            msg = str_cat(msg, "\n")
          end
          if node.type == ATTRIBUTE_NODE
            p_err(ctxt, node, error, msg, value, nil)
          else
            p_err(ctxt, node, error, msg, nil, nil)
          end
        else
          msg = str_cat(msg, message)
          msg = str_cat(msg, ".\n")
          p_err_ext(ctxt, node, error, nil, nil, nil, msg, str1, str2, nil, nil, nil)
        end
      end

      # xmlSchemaPContentErr
      def p_content_err(ctxt, error, owner_item, owner_elem, child, message, content)
        des = format_item_for_report(nil, owner_item, owner_elem)
        if message
          p_err2(ctxt, owner_elem, child, error, "%s: %s.\n", des, message)
        elsif content
          p_err2(ctxt, owner_elem, child, error,
            "%s: The content is not valid. Expected is %s.\n", des, content)
        else
          p_err2(ctxt, owner_elem, child, error, "%s: The content is not valid.\n", des, nil)
        end
      end
    end
  end
end
