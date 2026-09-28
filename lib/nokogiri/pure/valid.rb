# frozen_string_literal: true

# Port of libxml2 valid.c: DTD declaration tables (xmlAddElementDecl, xmlAddAttributeDecl,
# xmlAddNotationDecl), IDs/refs, attribute normalization and DTD validation.

module Nokogiri
  module Pure
    module Valid
      module_function

      def pctxt(vctxt)
        vctxt&.pctxt
      end

      # xmlDoErrValid
      def do_err_valid(vctxt, node, code, level, str1, str2, str3, int1, msg)
        return if vctxt.nil?

        if (p = pctxt(vctxt))
          p.ctxt_err(node, Domain::VALID, code, level, str1, str2, str3, int1, msg)
        else
          err = XmlError.new(domain: Domain::VALID, code: code, message: msg, level: level, file: nil, line: 0,
            str1: str1, str2: str2, str3: str2, int1: int1, int2: 0, node: node)
          if node
            n = node
            10.times do
              break if n.type == ELEMENT_NODE || n.parent.nil?

              n = n.parent
            end
            err.node = n
            err.file = n.doc&.url if n.respond_to?(:doc) && n.doc
            line = n.type == ELEMENT_NODE ? n.line : 0
            line = Tree.get_line_no(n) if line == 0 || line == 65_535
            err.line = line
          end
          if Errors.handler
            Errors.report(err)
          elsif vctxt.error && level != Level::WARNING
            vctxt.error.call(vctxt.user_data, msg)
          elsif vctxt.warning && level == Level::WARNING
            vctxt.warning.call(vctxt.user_data, msg)
          end
        end
      end

      # xmlErrValid
      def err_valid(vctxt, code, msg, extra = nil)
        do_err_valid(vctxt, nil, code, Level::ERROR, extra, nil, nil, 0, msg)
      end

      # xmlErrValidNode
      def err_valid_node(vctxt, node, code, msg, str1 = nil, str2 = nil, str3 = nil)
        do_err_valid(vctxt, node, code, Level::ERROR, str1, str2, str3, 0, msg)
      end

      # xmlErrValidNodeNr
      def err_valid_node_nr(vctxt, node, code, msg, str1, int2, str3)
        do_err_valid(vctxt, node, code, Level::ERROR, str1, str3, nil, int2, msg)
      end

      # xmlErrValidWarning
      def err_valid_warning(vctxt, node, code, msg, str1 = nil, str2 = nil, str3 = nil)
        do_err_valid(vctxt, node, code, Level::WARNING, str1, str2, str3, 0, msg)
      end

      def split_qname4(name)
        if (i = name.index(":")) && i > 0 && i < name.length - 1
          [-name[(i + 1)..], -name[0, i]]
        else
          [-name, nil]
        end
      end

      # xmlAddElementDecl
      def add_element_decl(vctxt, dtd, name, type, content)
        return nil if dtd.nil? || name.nil?

        case type
        when ELEMENT_TYPE_EMPTY
          if content
            err_valid(vctxt, ErrCode::DTD_CONTENT_ERROR, "xmlAddElementDecl: content != NULL for EMPTY\n")
            return nil
          end
        when ELEMENT_TYPE_ANY
          if content
            err_valid(vctxt, ErrCode::DTD_CONTENT_ERROR, "xmlAddElementDecl: content != NULL for ANY\n")
            return nil
          end
        when ELEMENT_TYPE_MIXED
          if content.nil?
            err_valid(vctxt, ErrCode::DTD_CONTENT_ERROR, "xmlAddElementDecl: content == NULL for MIXED\n")
            return nil
          end
        when ELEMENT_TYPE_ELEMENT
          if content.nil?
            err_valid(vctxt, ErrCode::DTD_CONTENT_ERROR, "xmlAddElementDecl: content == NULL for ELEMENT\n")
            return nil
          end
        else
          err_valid(vctxt, ErrCode::ERR_ARGUMENT, "xmlAddElementDecl: invalid type\n")
          return nil
        end

        local_name, prefix = split_qname4(name)
        table = (dtd.elements ||= {})
        old_attributes = nil
        doc = dtd.doc
        if doc && doc.int_subset
          ret = doc.int_subset.elements&.[]([local_name, prefix])
          if ret && ret.etype == ELEMENT_TYPE_UNDEFINED
            old_attributes = ret.attributes
            ret.attributes = nil
            doc.int_subset.elements.delete([local_name, prefix])
            Tree.unlink_node(ret) if ret.parent
          end
        end
        ret = table[[local_name, prefix]]
        if ret
          if ret.etype != ELEMENT_TYPE_UNDEFINED
            err_valid_node(vctxt, dtd, ErrCode::DTD_ELEM_REDEFINED, "Redefinition of element #{name}\n", name)
            return nil
          end
        else
          ret = XmlElementDecl.new(local_name)
          ret.prefix = prefix
          table[[local_name, prefix]] = ret
          ret.attributes = old_attributes
        end
        ret.etype = type
        if content
          ret.econtent = content
          content.parent = nil
        end
        ret.parent = dtd
        ret.doc = dtd.doc
        if dtd.last.nil?
          dtd.children = dtd.last = ret
        else
          dtd.last.next = ret
          ret.prev = dtd.last
          dtd.last = ret
        end
        ret
      end

      # xmlGetDtdElementDesc2
      def get_dtd_element_desc2(dtd, name)
        return nil if dtd.nil?

        table = (dtd.elements ||= {})
        local_name, prefix = split_qname4(name)
        cur = table[[local_name, prefix]]
        if cur.nil?
          cur = XmlElementDecl.new(local_name)
          cur.doc = dtd.doc
          cur.prefix = prefix
          cur.etype = ELEMENT_TYPE_UNDEFINED
          table[[local_name, prefix]] = cur
        end
        cur
      end

      # xmlScanIDAttributeDecl
      def scan_id_attribute_decl(vctxt, elem, err)
        return 0 if elem.nil?

        ret = 0
        cur = elem.attributes
        while cur
          if cur.atype == ATTRIBUTE_ID
            ret += 1
            if ret > 1 && err
              err_valid_node(vctxt, elem, ErrCode::DTD_MULTIPLE_ID,
                "Element #{elem.name} has too many ID attributes defined : #{cur.name}\n", elem.name, cur.name)
            end
          end
          cur = cur.nexth
        end
        ret
      end

      # xmlAddAttributeDecl
      def add_attribute_decl(vctxt, dtd, elem, name, ns, type, defv, default_value, tree)
        return nil if dtd.nil? || name.nil? || elem.nil?

        unless (ATTRIBUTE_CDATA..ATTRIBUTE_NOTATION).cover?(type)
          err_valid(vctxt, ErrCode::ERR_ARGUMENT, "xmlAddAttributeDecl: invalid type\n")
          return nil
        end
        if default_value && !validate_attribute_value_internal(dtd.doc, type, default_value)
          err_valid_node(vctxt, dtd, ErrCode::DTD_ATTRIBUTE_DEFAULT,
            "Attribute #{elem} of #{name}: invalid default value\n", elem, name, default_value)
          default_value = nil
          vctxt.valid = 0 if vctxt
        end
        doc = dtd.doc
        if doc && doc.ext_subset.equal?(dtd) && doc.int_subset && doc.int_subset.attributes
          return nil if doc.int_subset.attributes[[name, ns, elem]]
        end
        table = (dtd.attributes ||= {})
        ret = XmlAttributeDecl.new(-name)
        ret.atype = type
        ret.doc = doc
        ret.elem = -elem
        ret.prefix = ns ? -ns : nil
        ret.def = defv
        ret.tree = tree
        ret.default_value = default_value&.dup
        elem_def = get_dtd_element_desc2(dtd, elem)
        return nil if elem_def.nil?

        key = [ret.name, ret.prefix, ret.elem]
        if table.key?(key)
          err_valid_warning(vctxt, dtd, ErrCode::DTD_ATTRIBUTE_REDEFINED,
            "Attribute #{name} of element #{elem}: already defined\n", name, elem)
          return nil
        end
        table[key] = ret

        if type == ATTRIBUTE_ID && scan_id_attribute_decl(vctxt, elem_def, true) != 0
          err_valid_node(vctxt, dtd, ErrCode::DTD_MULTIPLE_ID,
            "Element #{elem} has too may ID attributes defined : #{name}\n", elem, name)
          vctxt.valid = 0 if vctxt
        end

        if ret.name == "xmlns" || (ret.prefix && ret.prefix == "xmlns")
          ret.nexth = elem_def.attributes
          elem_def.attributes = ret
        else
          tmp = elem_def.attributes
          while tmp && (tmp.name == "xmlns" || (ret.prefix && ret.prefix == "xmlns"))
            break if tmp.nexth.nil?

            tmp = tmp.nexth
          end
          if tmp
            ret.nexth = tmp.nexth
            tmp.nexth = ret
          else
            ret.nexth = elem_def.attributes
            elem_def.attributes = ret
          end
        end

        ret.parent = dtd
        if dtd.last.nil?
          dtd.children = dtd.last = ret
        else
          dtd.last.next = ret
          ret.prev = dtd.last
          dtd.last = ret
        end
        ret
      end

      # xmlAddNotationDecl
      def add_notation_decl(vctxt, dtd, name, public_id, system_id)
        return nil if dtd.nil? || name.nil?
        return nil if public_id.nil? && system_id.nil?

        table = (dtd.notations ||= {})
        if table.key?(name)
          err_valid(vctxt, ErrCode::DTD_NOTATION_REDEFINED, "xmlAddNotationDecl: #{name} already defined\n", name)
          return nil
        end
        ret = XmlNotation.new(name.dup, public_id&.dup, system_id&.dup)
        table[name] = ret
        ret
      end

      # xmlAddID
      def add_id(vctxt, doc, value, attr)
        return nil if attr.nil? || !doc.equal?(attr.doc)

        res = Tree.add_id(attr, value)
        if res == 0 && vctxt && value && !value.empty?
          err_valid_node(vctxt, attr.parent, ErrCode::DTD_ID_REDEFINED, "ID #{value} already defined\n", value)
        end
        attr.id
      end

      # xmlAddRef
      def add_ref(_vctxt, doc, value, attr)
        return nil if doc.nil? || value.nil? || attr.nil?

        table = (doc.refs ||= {})
        ref = [value.dup, attr, nil, Tree.get_line_no(attr.parent)]
        (table[value] ||= []) << ref
        ref
      end

      # xmlIsRef
      def is_ref(doc, elem, attr)
        return false if attr.nil?

        doc ||= attr.doc
        return false if doc.nil?
        return false if doc.int_subset.nil? && doc.ext_subset.nil?
        return false if doc.type == HTML_DOCUMENT_NODE
        return false if elem.nil?

        aprefix = attr.ns&.prefix
        decl = Tree.get_dtd_q_attr_desc(doc.int_subset, elem.name, attr.name, aprefix)
        decl = Tree.get_dtd_q_attr_desc(doc.ext_subset, elem.name, attr.name, aprefix) if decl.nil? && doc.ext_subset
        !decl.nil? && (decl.atype == ATTRIBUTE_IDREF || decl.atype == ATTRIBUTE_IDREFS)
      end

      # xmlValidNormalizeString
      def normalize_string(str)
        str.sub(/\A +/, "").gsub(/ +/, " ").sub(/ \z/, "")
      end

      # xmlValidCtxtNormalizeAttributeValue
      def ctxt_normalize_attribute_value(vctxt, doc, elem, name, value)
        return nil if doc.nil? || elem.nil? || name.nil? || value.nil?

        local_name, prefix = split_qname4(name)
        attr_decl = nil
        extsubset = false
        if elem.ns&.prefix
          elemname = "#{elem.ns.prefix}:#{elem.name}"
          attr_decl = doc.int_subset.attributes&.[]([local_name, prefix, elemname]) if doc.int_subset
          if attr_decl.nil? && doc.ext_subset
            attr_decl = doc.ext_subset.attributes&.[]([local_name, prefix, elemname])
            extsubset = true if attr_decl
          end
        end
        attr_decl = doc.int_subset.attributes&.[]([local_name, prefix, elem.name]) if attr_decl.nil? && doc.int_subset
        if attr_decl.nil? && doc.ext_subset
          attr_decl = doc.ext_subset.attributes&.[]([local_name, prefix, elem.name])
          extsubset = true if attr_decl
        end
        return nil if attr_decl.nil?
        return nil if attr_decl.atype == ATTRIBUTE_CDATA

        ret = normalize_string(value)
        if doc.standalone != 0 && extsubset && value != ret
          err_valid_node(vctxt, elem, ErrCode::DTD_NOT_STANDALONE,
            "standalone: #{name} on #{elem.name} value had to be normalized based on external subset declaration\n",
            name, elem.name)
          vctxt.valid = 0
        end
        ret
      end

      # xmlValidNormalizeAttributeValue
      def normalize_attribute_value(doc, elem, name, value)
        return nil if doc.nil? || elem.nil? || name.nil? || value.nil?

        attr_decl = Tree.get_dtd_attr_desc(doc.int_subset, elem.name, name)
        attr_decl = Tree.get_dtd_attr_desc(doc.ext_subset, elem.name, name) if attr_decl.nil? && doc.ext_subset
        return nil if attr_decl.nil? || attr_decl.atype == ATTRIBUTE_CDATA

        normalize_string(value)
      end

      # ---- value checks ------------------------------------------------------------------------

      def doc_old10?(doc)
        doc && (doc.doc_properties & 8) != 0
      end

      def name_start?(doc, c)
        if doc_old10?(doc)
          Parser::Chars.old_name_start_char?(c)
        else
          Parser::Chars.name_start_char?(c)
        end
      end

      def name_char?(doc, c)
        if doc_old10?(doc)
          Parser::Chars.old_name_char?(c)
        else
          Parser::Chars.name_char?(c)
        end
      end

      def cps(value)
        s = value.dup.force_encoding(Encoding::UTF_8)
        return nil unless s.valid_encoding?

        s.codepoints
      end

      # xmlValidateNameValueInternal
      def validate_name_value_internal(doc, value)
        return false if value.nil?

        c = cps(value)
        return false if c.nil? || c.empty?
        return false unless name_start?(doc, c[0])

        c[1..].all? { |x| name_char?(doc, x) }
      end

      # xmlValidateNamesValueInternal
      def validate_names_value_internal(doc, value)
        return false if value.nil?

        c = cps(value)
        return false if c.nil? || c.empty?
        return false unless name_start?(doc, c[0])

        i = 1
        i += 1 while i < c.length && name_char?(doc, c[i])
        while i < c.length && c[i] == 0x20
          i += 1 while i < c.length && c[i] == 0x20
          return false if i >= c.length || !name_start?(doc, c[i])

          i += 1
          i += 1 while i < c.length && name_char?(doc, c[i])
        end
        i == c.length
      end

      # xmlValidateNmtokenValueInternal
      def validate_nmtoken_value_internal(doc, value)
        return false if value.nil?

        c = cps(value)
        return false if c.nil? || c.empty?

        c.all? { |x| name_char?(doc, x) }
      end

      # xmlValidateNmtokensValueInternal
      def validate_nmtokens_value_internal(doc, value)
        return false if value.nil?

        c = cps(value)
        return false if c.nil?

        i = 0
        i += 1 while i < c.length && Parser::Chars.blank?(c[i])
        return false if i >= c.length || !name_char?(doc, c[i])

        i += 1 while i < c.length && name_char?(doc, c[i])
        while i < c.length && c[i] == 0x20
          i += 1 while i < c.length && c[i] == 0x20
          return true if i >= c.length
          return false unless name_char?(doc, c[i])

          i += 1 while i < c.length && name_char?(doc, c[i])
        end
        i == c.length
      end

      # xmlValidateAttributeValueInternal
      def validate_attribute_value_internal(doc, type, value)
        case type
        when ATTRIBUTE_ENTITIES, ATTRIBUTE_IDREFS
          validate_names_value_internal(doc, value)
        when ATTRIBUTE_ENTITY, ATTRIBUTE_IDREF, ATTRIBUTE_ID, ATTRIBUTE_NOTATION
          validate_name_value_internal(doc, value)
        when ATTRIBUTE_NMTOKENS, ATTRIBUTE_ENUMERATION
          validate_nmtokens_value_internal(doc, value)
        when ATTRIBUTE_NMTOKEN
          validate_nmtoken_value_internal(doc, value)
        else
          true
        end
      end

      # xmlValidateNCName (tree.c): 0 if valid
      def validate_ncname(value, _space)
        return 1 if value.nil?

        c = cps(value)
        return 1 if c.nil? || c.empty?
        return 1 unless Parser::Chars.name_start_char?(c[0]) && c[0] != 0x3A
        return 1 unless c[1..].all? { |x| Parser::Chars.name_char?(x) && x != 0x3A }

        0
      end
    end
  end
end

require_relative "valid_validate"
