# frozen_string_literal: true

# DTD validation, port of libxml2 valid.c (the LIBXML_REGEXP_ENABLED variant: element content
# models are compiled to automata with Pure::XmlRegexp).

require_relative "xmlregexp"

module Nokogiri
  module Pure
    module Valid
      module_function

      def check_dtd?(doc)
        !doc.nil? && !(doc.int_subset.nil? && doc.ext_subset.nil?)
      end

      def qname(name, prefix)
        prefix ? "#{prefix}:#{name}" : name
      end

      def blank_node?(node)
        Tree.is_blank_node(node)
      end

      # ---- content models -----------------------------------------------------------------------

      # xmlValidBuildAContentModel
      def build_a_content_model(content, vctxt, am, st, name)
        if content.nil?
          err_valid_node(vctxt, nil, ErrCode::ERR_INTERNAL_ERROR, "Found NULL content in content model of #{name}\n",
            name)
          return false
        end
        case content.type
        when ELEMENT_CONTENT_PCDATA
          err_valid_node(vctxt, nil, ErrCode::ERR_INTERNAL_ERROR, "Found PCDATA in content model of #{name}\n", name)
          return false
        when ELEMENT_CONTENT_ELEMENT
          oldstate = st[0]
          fullname = qname(content.name, content.prefix)
          case content.ocur
          when ELEMENT_CONTENT_ONCE
            st[0] = XmlRegexp.automata_new_transition(am, st[0], nil, fullname, nil)
          when ELEMENT_CONTENT_OPT
            st[0] = XmlRegexp.automata_new_transition(am, st[0], nil, fullname, nil)
            XmlRegexp.automata_new_epsilon(am, oldstate, st[0])
          when ELEMENT_CONTENT_PLUS
            st[0] = XmlRegexp.automata_new_transition(am, st[0], nil, fullname, nil)
            XmlRegexp.automata_new_transition(am, st[0], st[0], fullname, nil)
          when ELEMENT_CONTENT_MULT
            st[0] = XmlRegexp.automata_new_epsilon(am, st[0], nil)
            XmlRegexp.automata_new_transition(am, st[0], st[0], fullname, nil)
          end
        when ELEMENT_CONTENT_SEQ
          oldstate = st[0]
          ocur = content.ocur
          if ocur != ELEMENT_CONTENT_ONCE
            st[0] = XmlRegexp.automata_new_epsilon(am, oldstate, nil)
            oldstate = st[0]
          end
          loop do
            return false unless build_a_content_model(content.c1, vctxt, am, st, name)

            content = content.c2
            break unless content.type == ELEMENT_CONTENT_SEQ && content.ocur == ELEMENT_CONTENT_ONCE
          end
          return false unless build_a_content_model(content, vctxt, am, st, name)

          oldend = st[0]
          st[0] = XmlRegexp.automata_new_epsilon(am, oldend, nil)
          case ocur
          when ELEMENT_CONTENT_OPT
            XmlRegexp.automata_new_epsilon(am, oldstate, st[0])
          when ELEMENT_CONTENT_MULT
            XmlRegexp.automata_new_epsilon(am, oldstate, st[0])
            XmlRegexp.automata_new_epsilon(am, oldend, oldstate)
          when ELEMENT_CONTENT_PLUS
            XmlRegexp.automata_new_epsilon(am, oldend, oldstate)
          end
        when ELEMENT_CONTENT_OR
          ocur = content.ocur
          if ocur == ELEMENT_CONTENT_PLUS || ocur == ELEMENT_CONTENT_MULT
            st[0] = XmlRegexp.automata_new_epsilon(am, st[0], nil)
          end
          oldstate = st[0]
          oldend = XmlRegexp.automata_new_state(am)
          loop do
            st[0] = oldstate
            return false unless build_a_content_model(content.c1, vctxt, am, st, name)

            XmlRegexp.automata_new_epsilon(am, st[0], oldend)
            content = content.c2
            break unless content.type == ELEMENT_CONTENT_OR && content.ocur == ELEMENT_CONTENT_ONCE
          end
          st[0] = oldstate
          return false unless build_a_content_model(content, vctxt, am, st, name)

          XmlRegexp.automata_new_epsilon(am, st[0], oldend)
          st[0] = XmlRegexp.automata_new_epsilon(am, oldend, nil)
          case ocur
          when ELEMENT_CONTENT_OPT
            XmlRegexp.automata_new_epsilon(am, oldstate, st[0])
          when ELEMENT_CONTENT_MULT
            XmlRegexp.automata_new_epsilon(am, oldstate, st[0])
            XmlRegexp.automata_new_epsilon(am, oldend, oldstate)
          when ELEMENT_CONTENT_PLUS
            XmlRegexp.automata_new_epsilon(am, oldend, oldstate)
          end
        else
          err_valid(vctxt, ErrCode::ERR_INTERNAL_ERROR, "ContentModel broken for element #{name}\n", name)
          return false
        end
        true
      end

      # xmlValidBuildContentModel
      def build_content_model(vctxt, elem)
        return 0 if vctxt.nil? || elem.nil?
        return 0 if elem.type != ELEMENT_DECL
        return 1 if elem.etype != ELEMENT_TYPE_ELEMENT

        if elem.cont_model
          if XmlRegexp.regexp_is_determinist(elem.cont_model) != 1
            vctxt.valid = 0
            return 0
          end
          return 1
        end
        am = XmlRegexp.new_automata
        st = [XmlRegexp.automata_get_init_state(am)]
        return 0 unless build_a_content_model(elem.econtent, vctxt, am, st, elem.name)

        XmlRegexp.automata_set_final_state(am, st[0])
        elem.cont_model = XmlRegexp.automata_compile(am)
        return 0 if elem.cont_model.nil?

        if XmlRegexp.regexp_is_determinist(elem.cont_model) != 1
          expr = snprintf_element_content(+"", 5000, elem.econtent, true)
          err_valid_node(vctxt, elem, ErrCode::DTD_CONTENT_NOT_DETERMINIST,
            "Content model of #{elem.name} is not deterministic: #{expr}\n", elem.name, expr)
          vctxt.valid = 0
          return 0
        end
        1
      end

      # xmlSnprintfElementContent
      def snprintf_element_content(buf, size, content, englob)
        return buf if content.nil?

        len = buf.bytesize
        if size - len < 50
          buf << " ..." if size - len > 4 && buf[-1] != "."
          return buf
        end
        buf << "(" if englob
        case content.type
        when ELEMENT_CONTENT_PCDATA
          buf << "#PCDATA"
        when ELEMENT_CONTENT_ELEMENT
          qlen = content.name.to_s.bytesize
          qlen += content.prefix.bytesize + 1 if content.prefix
          if size - len < qlen + 10
            buf << " ..."
            return buf
          end
          buf << content.prefix << ":" if content.prefix
          buf << content.name if content.name
        when ELEMENT_CONTENT_SEQ, ELEMENT_CONTENT_OR
          c1 = content.c1
          sub = c1.type == ELEMENT_CONTENT_OR || c1.type == ELEMENT_CONTENT_SEQ
          snprintf_element_content(buf, size, c1, sub)
          len = buf.bytesize
          if size - len < 50
            buf << " ..." if size - len > 4 && buf[-1] != "."
            return buf
          end
          buf << (content.type == ELEMENT_CONTENT_SEQ ? " , " : " | ")
          c2 = content.c2
          other = content.type == ELEMENT_CONTENT_SEQ ? ELEMENT_CONTENT_OR : ELEMENT_CONTENT_SEQ
          sub = (c2.type == other || c2.ocur != ELEMENT_CONTENT_ONCE) && c2.type != ELEMENT_CONTENT_ELEMENT
          snprintf_element_content(buf, size, c2, sub)
        end
        return buf if size - buf.bytesize <= 2

        buf << ")" if englob
        case content.ocur
        when ELEMENT_CONTENT_OPT then buf << "?"
        when ELEMENT_CONTENT_MULT then buf << "*"
        when ELEMENT_CONTENT_PLUS then buf << "+"
        end
        buf
      end

      # xmlSnprintfElements
      def snprintf_elements(buf, size, node, glob)
        return buf if node.nil?

        buf << "(" if glob
        cur = node
        while cur
          len = buf.bytesize
          if size - len < 50
            buf << " ..." if size - len > 4 && buf[-1] != "."
            return buf
          end
          case cur.type
          when ELEMENT_NODE
            qlen = cur.name.to_s.bytesize
            qlen += cur.ns.prefix.bytesize + 1 if cur.ns&.prefix
            if size - len < qlen + 10
              buf << " ..." if size - len > 4 && buf[-1] != "."
              return buf
            end
            buf << cur.ns.prefix << ":" if cur.ns&.prefix
            buf << cur.name if cur.name
            buf << " " if cur.next
          when TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE
            unless cur.type == TEXT_NODE && blank_node?(cur)
              buf << "CDATA"
              buf << " " if cur.next
            end
          when ATTRIBUTE_NODE, DOCUMENT_NODE, HTML_DOCUMENT_NODE, DOCUMENT_TYPE_NODE, DOCUMENT_FRAG_NODE,
            NOTATION_NODE, NAMESPACE_DECL
            buf << "???"
            buf << " " if cur.next
          end
          cur = cur.next
        end
        buf << ")" if glob
        buf
      end

      # walk children, descending into entity references (nodeVPush / nodeVPop)
      def each_content_node(child)
        stack = []
        cur = child
        while cur
          if cur.type == ENTITY_REF_NODE && cur.children && cur.children.children
            stack.push(cur)
            cur = cur.children.children
            next
          end
          r = yield cur
          return r if r == :stop

          cur = cur.next
          while cur.nil?
            cur = stack.pop
            break if cur.nil?

            cur = cur.next
          end
        end
        nil
      end

      # xmlValidateElementContent
      def validate_element_content(vctxt, child, elem_decl, warn, parent)
        return -1 if elem_decl.nil? || parent.nil? || vctxt.nil?

        cont = elem_decl.econtent
        name = elem_decl.name
        ret = 1
        build_content_model(vctxt, elem_decl) if elem_decl.cont_model.nil?
        return -1 if elem_decl.cont_model.nil?
        return -1 if XmlRegexp.regexp_is_determinist(elem_decl.cont_model) != 1

        exec = XmlRegexp.reg_new_exec_ctxt(elem_decl.cont_model, nil, nil)
        failed = false
        each_content_node(child) do |cur|
          case cur.type
          when TEXT_NODE
            unless blank_node?(cur)
              ret = 0
              failed = true
              next :stop
            end
          when CDATA_SECTION_NODE
            ret = 0
            failed = true
            next :stop
          when ELEMENT_NODE
            fullname = cur.ns&.prefix ? "#{cur.ns.prefix}:#{cur.name}" : cur.name
            ret = XmlRegexp.reg_exec_push_string(exec, fullname, nil)
          end
          nil
        end
        ret = XmlRegexp.reg_exec_push_string(exec, nil, nil) unless failed

        if warn && ret != 1 && ret != -3
          expr = snprintf_element_content(+"", 5000, cont, true)
          list = snprintf_elements(+"", 5000, child, true)
          if name
            err_valid_node(vctxt, parent, ErrCode::DTD_CONTENT_MODEL,
              "Element #{name} content does not follow the DTD, expecting #{expr}, got #{list}\n", name, expr, list)
          else
            err_valid_node(vctxt, parent, ErrCode::DTD_CONTENT_MODEL,
              "Element content does not follow the DTD, expecting #{expr}, got #{list}\n", expr, list)
          end
          ret = 0
        end
        ret = 1 if ret == -3
        ret
      end

      # xmlValidateOneCdataElement
      def validate_one_cdata_element(vctxt, doc, elem)
        return 0 if vctxt.nil? || doc.nil? || elem.nil? || elem.type != ELEMENT_NODE

        ret = 1
        each_content_node(elem.children) do |cur|
          case cur.type
          when COMMENT_NODE, PI_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE
            nil
          else
            ret = 0
            :stop
          end
        end
        ret
      end

      # xmlValidGetElemDecl: returns [decl, extsubset]
      def valid_get_elem_decl(vctxt, doc, elem)
        return [nil, false] if vctxt.nil? || doc.nil? || elem.nil? || elem.name.nil?

        ext = false
        decl = nil
        prefix = elem.ns&.prefix
        if prefix
          decl = Tree.get_dtd_q_element_desc(doc.int_subset, elem.name, prefix)
          if decl.nil? && doc.ext_subset
            decl = Tree.get_dtd_q_element_desc(doc.ext_subset, elem.name, prefix)
            ext = true if decl
          end
        end
        if decl.nil?
          decl = Tree.get_dtd_q_element_desc(doc.int_subset, elem.name, nil)
          if decl.nil? && doc.ext_subset
            decl = Tree.get_dtd_q_element_desc(doc.ext_subset, elem.name, nil)
            ext = true if decl
          end
        end
        if decl.nil?
          err_valid_node(vctxt, elem, ErrCode::DTD_UNKNOWN_ELEM, "No declaration for element #{elem.name}\n", elem.name)
        end
        [decl, ext]
      end

      # xmlValidateOneElement
      def validate_one_element(vctxt, doc, elem)
        return 0 unless check_dtd?(doc)
        return 0 if elem.nil?

        case elem.type
        when TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE, PI_NODE, COMMENT_NODE, XINCLUDE_START, XINCLUDE_END
          return 1
        when ELEMENT_NODE
          nil
        else
          err_valid_node(vctxt, elem, ErrCode::ERR_INTERNAL_ERROR, "unexpected element type\n")
          return 0
        end
        ret = 1
        elem_decl, extsubset = valid_get_elem_decl(vctxt, doc, elem)
        return 0 if elem_decl.nil?

        case elem_decl.etype
        when ELEMENT_TYPE_UNDEFINED
          err_valid_node(vctxt, elem, ErrCode::DTD_UNKNOWN_ELEM, "No declaration for element #{elem.name}\n", elem.name)
          return 0
        when ELEMENT_TYPE_EMPTY
          if elem.children
            err_valid_node(vctxt, elem, ErrCode::DTD_NOT_EMPTY,
              "Element #{elem.name} was declared EMPTY this one has content\n", elem.name)
            ret = 0
          end
        when ELEMENT_TYPE_ANY
          nil
        when ELEMENT_TYPE_MIXED
          if elem_decl.econtent && elem_decl.econtent.type == ELEMENT_CONTENT_PCDATA
            ret = validate_one_cdata_element(vctxt, doc, elem)
            if ret == 0
              err_valid_node(vctxt, elem, ErrCode::DTD_NOT_PCDATA,
                "Element #{elem.name} was declared #PCDATA but contains non text nodes\n", elem.name)
            end
          else
            child = elem.children
            while child
              if child.type == ELEMENT_NODE
                name = child.name
                found = false
                if child.ns&.prefix
                  fullname = "#{child.ns.prefix}:#{child.name}"
                  found = mixed_find(vctxt, elem_decl.econtent, fullname, false)
                end
                if !found && !mixed_find(vctxt, elem_decl.econtent, name, true)
                  err_valid_node(vctxt, elem, ErrCode::DTD_INVALID_CHILD,
                    "Element #{name} is not declared in #{elem.name} list of possible children\n", name, elem.name)
                  ret = 0
                end
              end
              child = child.next
            end
          end
        when ELEMENT_TYPE_ELEMENT
          if doc.standalone == 1 && extsubset
            child = elem.children
            while child
              if child.type == TEXT_NODE && child.content && child.content.match?(/\A[ \t\n\r]*\z/)
                err_valid_node(vctxt, elem, ErrCode::DTD_STANDALONE_WHITE_SPACE,
                  "standalone: #{elem.name} declared in the external subset contains white spaces nodes\n", elem.name)
                ret = 0
                break
              end
              child = child.next
            end
          end
          tmp = validate_element_content(vctxt, elem.children, elem_decl, true, elem)
          ret = 0 if tmp <= 0
        end

        # [ VC: Required Attribute ]
        attr = elem_decl.attributes
        while attr
          if attr.def == ATTRIBUTE_REQUIRED
            qualified = -1
            found = false
            if attr.prefix.nil? && attr.name == "xmlns"
              ns = elem.ns_def
              while ns
                if ns.prefix.nil?
                  found = true
                  break
                end
                ns = ns.next
              end
            elsif attr.prefix == "xmlns"
              ns = elem.ns_def
              while ns
                if attr.name == ns.prefix
                  found = true
                  break
                end
                ns = ns.next
              end
            else
              attrib = elem.properties
              while attrib
                if attrib.name == attr.name
                  if attr.prefix
                    name_space = attrib.ns || elem.ns
                    if name_space.nil?
                      qualified = 0 if qualified < 0
                    elsif name_space.prefix != attr.prefix
                      qualified = 1 if qualified < 1
                    else
                      found = true
                      break
                    end
                  else
                    found = true
                    break
                  end
                end
                attrib = attrib.next
              end
            end
            unless found
              if qualified == -1
                if attr.prefix.nil?
                  err_valid_node(vctxt, elem, ErrCode::DTD_MISSING_ATTRIBUTE,
                    "Element #{elem.name} does not carry attribute #{attr.name}\n", elem.name, attr.name)
                else
                  err_valid_node(vctxt, elem, ErrCode::DTD_MISSING_ATTRIBUTE,
                    "Element #{elem.name} does not carry attribute #{attr.prefix}:#{attr.name}\n",
                    elem.name, attr.prefix, attr.name)
                end
                ret = 0
              elsif qualified == 0
                err_valid_warning(vctxt, elem, ErrCode::DTD_NO_PREFIX,
                  "Element #{elem.name} required attribute #{attr.prefix}:#{attr.name} has no prefix\n",
                  elem.name, attr.prefix, attr.name)
              elsif qualified == 1
                err_valid_warning(vctxt, elem, ErrCode::DTD_DIFFERENT_PREFIX,
                  "Element #{elem.name} required attribute #{attr.prefix}:#{attr.name} has different prefix\n",
                  elem.name, attr.prefix, attr.name)
              end
            end
          elsif attr.def == ATTRIBUTE_FIXED
            if attr.prefix.nil? && attr.name == "xmlns"
              ns = elem.ns_def
              while ns
                if ns.prefix.nil?
                  if attr.default_value != ns.href
                    err_valid_node(vctxt, elem, ErrCode::DTD_ELEM_DEFAULT_NAMESPACE,
                      "Element #{elem.name} namespace name for default namespace does not match the DTD\n", elem.name)
                    ret = 0
                  end
                  break
                end
                ns = ns.next
              end
            elsif attr.prefix == "xmlns"
              ns = elem.ns_def
              while ns
                if attr.name == ns.prefix
                  if attr.default_value != ns.href
                    err_valid_node(vctxt, elem, ErrCode::DTD_ELEM_NAMESPACE,
                      "Element #{elem.name} namespace name for #{ns.prefix} does not match the DTD\n",
                      elem.name, ns.prefix)
                    ret = 0
                  end
                  break
                end
                ns = ns.next
              end
            end
          end
          attr = attr.nexth
        end
        ret
      end

      # the MIXED content lookup loop of xmlValidateOneElement
      def mixed_find(vctxt, cont, name, report_ctxt)
        while cont
          if cont.type == ELEMENT_CONTENT_ELEMENT
            return true if cont.name == name
          elsif cont.type == ELEMENT_CONTENT_OR && cont.c1 && cont.c1.type == ELEMENT_CONTENT_ELEMENT
            return true if cont.c1.name == name
          elsif cont.type != ELEMENT_CONTENT_OR || cont.c1.nil? || cont.c1.type != ELEMENT_CONTENT_PCDATA
            err_valid(report_ctxt ? vctxt : nil, ErrCode::DTD_MIXED_CORRUPT, "Internal: MIXED struct corrupted\n")
            return false
          end
          cont = cont.c2
        end
        false
      end

      # xmlValidateRoot
      def validate_root(vctxt, doc)
        return 0 if doc.nil?

        root = Tree.doc_get_root_element(doc)
        if root.nil? || root.name.nil?
          err_valid(vctxt, ErrCode::DTD_NO_ROOT, "no root element\n")
          return 0
        end
        if doc.int_subset && doc.int_subset.name
          if doc.int_subset.name != root.name
            if root.ns&.prefix && doc.int_subset.name == "#{root.ns.prefix}:#{root.name}"
              return 1
            end
            return 1 if doc.int_subset.name == "HTML" && root.name == "html"

            err_valid_node(vctxt, root, ErrCode::DTD_ROOT_NAME,
              "root and DTD name do not match '#{root.name}' and '#{doc.int_subset.name}'\n",
              root.name, doc.int_subset.name)
            return 0
          end
        end
        1
      end

      # xmlValidateAttributeValue2
      def validate_attribute_value2(vctxt, doc, name, type, value)
        ret = 1
        case type
        when ATTRIBUTE_ENTITY
          ent = Tree.get_doc_entity(doc, value)
          if ent.nil? && doc.standalone == 1
            doc.standalone = 0
            ent = Tree.get_doc_entity(doc, value)
          end
          if ent.nil?
            err_valid_node(vctxt, doc, ErrCode::DTD_UNKNOWN_ENTITY,
              "ENTITY attribute #{name} reference an unknown entity \"#{value}\"\n", name, value)
            ret = 0
          elsif ent.etype != EXTERNAL_GENERAL_UNPARSED_ENTITY
            err_valid_node(vctxt, doc, ErrCode::DTD_ENTITY_TYPE,
              "ENTITY attribute #{name} reference an entity \"#{value}\" of wrong type\n", name, value)
            ret = 0
          end
        when ATTRIBUTE_ENTITIES
          blank_split(value).each do |nam|
            ent = Tree.get_doc_entity(doc, nam)
            if ent.nil?
              err_valid_node(vctxt, doc, ErrCode::DTD_UNKNOWN_ENTITY,
                "ENTITIES attribute #{name} reference an unknown entity \"#{nam}\"\n", name, nam)
              ret = 0
            elsif ent.etype != EXTERNAL_GENERAL_UNPARSED_ENTITY
              err_valid_node(vctxt, doc, ErrCode::DTD_ENTITY_TYPE,
                "ENTITIES attribute #{name} reference an entity \"#{nam}\" of wrong type\n", name, nam)
              ret = 0
            end
          end
        when ATTRIBUTE_NOTATION
          nota = doc.int_subset&.notations&.[](value)
          nota = doc.ext_subset&.notations&.[](value) if nota.nil? && doc.ext_subset
          if nota.nil?
            err_valid_node(vctxt, doc, ErrCode::DTD_UNKNOWN_NOTATION,
              "NOTATION attribute #{name} reference an unknown notation \"#{value}\"\n", name, value)
            ret = 0
          end
        end
        ret
      end

      # the "while (*cur != 0) { nam = cur; skip non blanks; ...; skip blanks }" loop
      def blank_split(value)
        out = []
        s = value.b
        i = 0
        n = s.bytesize
        while i < n
          st = i
          i += 1 while i < n && !Parser::Chars.blank?(s.getbyte(i))
          out << s.byteslice(st, i - st).force_encoding(Encoding::UTF_8)
          break if i >= n

          i += 1 while i < n && Parser::Chars.blank?(s.getbyte(i))
        end
        out
      end

      # xmlValidateAttributeDecl
      def validate_attribute_decl(vctxt, doc, attr)
        return 0 unless check_dtd?(doc)
        return 1 if attr.nil?

        ret = 1
        if attr.default_value
          val = validate_attribute_value_internal(doc, attr.atype, attr.default_value)
          unless val
            err_valid_node(vctxt, attr, ErrCode::DTD_ATTRIBUTE_DEFAULT,
              "Syntax of default value for attribute #{attr.name} of #{attr.elem} is not valid\n", attr.name, attr.elem)
            ret = 0
          end
        end
        if attr.atype == ATTRIBUTE_ID && attr.def != ATTRIBUTE_IMPLIED && attr.def != ATTRIBUTE_REQUIRED
          err_valid_node(vctxt, attr, ErrCode::DTD_ID_FIXED,
            "ID attribute #{attr.name} of #{attr.elem} is not valid must be #IMPLIED or #REQUIRED\n",
            attr.name, attr.elem)
          ret = 0
        end
        if attr.atype == ATTRIBUTE_ID
          local, prefix = split_qname4(attr.elem)
          elem = doc.int_subset&.elements&.[]([local, prefix])
          if elem
            nb_id = scan_id_attribute_decl(vctxt, elem, false)
          else
            nb_id = 0
            doc.int_subset&.attributes&.each_value { |a| nb_id += 1 if a.elem == attr.elem && a.atype == ATTRIBUTE_ID }
          end
          if nb_id > 1
            err_valid_node_nr(vctxt, attr, ErrCode::DTD_ID_SUBSET,
              "Element #{attr.elem} has #{nb_id} ID attribute defined in the internal subset : #{attr.name}\n",
              attr.elem, nb_id, attr.name)
            ret = 0
          elsif doc.ext_subset
            ext_id = 0
            elem = doc.ext_subset.elements&.[]([local, prefix])
            ext_id = scan_id_attribute_decl(vctxt, elem, false) if elem
            if ext_id > 1
              err_valid_node_nr(vctxt, attr, ErrCode::DTD_ID_SUBSET,
                "Element #{attr.elem} has #{ext_id} ID attribute defined in the external subset : #{attr.name}\n",
                attr.elem, ext_id, attr.name)
              ret = 0
            elsif ext_id + nb_id > 1
              err_valid_node(vctxt, attr, ErrCode::DTD_ID_SUBSET,
                "Element #{attr.elem} has ID attributes defined in the internal and external subset : #{attr.name}\n",
                attr.elem, attr.name)
              ret = 0
            end
          end
        end
        if attr.default_value && attr.tree
          tree = attr.tree
          tree = tree.next while tree && tree.name != attr.default_value
          if tree.nil?
            err_valid_node(vctxt, attr, ErrCode::DTD_ATTRIBUTE_VALUE,
              "Default value \"#{attr.default_value}\" for attribute #{attr.name} of #{attr.elem} is not among the enumerated set\n",
              attr.default_value, attr.name, attr.elem)
            ret = 0
          end
        end
        ret
      end

      # xmlValidateElementDecl
      def validate_element_decl(vctxt, doc, elem)
        return 0 unless check_dtd?(doc)
        return 1 if elem.nil?

        ret = 1
        if elem.etype == ELEMENT_TYPE_MIXED
          cur = elem.econtent
          while cur
            break if cur.type != ELEMENT_CONTENT_OR
            break if cur.c1.nil?

            if cur.c1.type == ELEMENT_CONTENT_ELEMENT
              name = cur.c1.name
              nxt = cur.c2
              while nxt
                if nxt.type == ELEMENT_CONTENT_ELEMENT
                  if nxt.name == name && nxt.prefix == cur.c1.prefix
                    if cur.c1.prefix.nil?
                      err_valid_node(vctxt, elem, ErrCode::DTD_CONTENT_ERROR,
                        "Definition of #{elem.name} has duplicate references of #{name}\n", elem.name, name)
                    else
                      err_valid_node(vctxt, elem, ErrCode::DTD_CONTENT_ERROR,
                        "Definition of #{elem.name} has duplicate references of #{cur.c1.prefix}:#{name}\n",
                        elem.name, cur.c1.prefix, name)
                    end
                    ret = 0
                  end
                  break
                end
                break if nxt.c1.nil? || nxt.c1.type != ELEMENT_CONTENT_ELEMENT

                if nxt.c1.name == name && nxt.c1.prefix == cur.c1.prefix
                  if cur.c1.prefix.nil?
                    err_valid_node(vctxt, elem, ErrCode::DTD_CONTENT_ERROR,
                      "Definition of #{elem.name} has duplicate references to #{name}\n", elem.name, name)
                  else
                    err_valid_node(vctxt, elem, ErrCode::DTD_CONTENT_ERROR,
                      "Definition of #{elem.name} has duplicate references to #{cur.c1.prefix}:#{name}\n",
                      elem.name, cur.c1.prefix, name)
                  end
                  ret = 0
                end
                nxt = nxt.c2
              end
            end
            cur = cur.c2
          end
        end
        local, prefix = split_qname4(elem.name)
        [doc.int_subset, doc.ext_subset].each do |sub|
          next if sub.nil?

          tst = sub.elements&.[]([local, prefix])
          if tst && !tst.equal?(elem) && tst.prefix == elem.prefix && tst.etype != ELEMENT_TYPE_UNDEFINED
            err_valid_node(vctxt, elem, ErrCode::DTD_ELEM_REDEFINED, "Redefinition of element #{elem.name}\n", elem.name)
            ret = 0
          end
        end
        ret
      end

      # xmlValidateNotationDecl
      def validate_notation_decl(_vctxt, _doc, _nota) = 1

      def find_attr_decl(doc, elem_name, name, prefix)
        d = Tree.get_dtd_q_attr_desc(doc.int_subset, elem_name, name, prefix)
        d = Tree.get_dtd_q_attr_desc(doc.ext_subset, elem_name, name, prefix) if d.nil? && doc.ext_subset
        d
      end

      # xmlValidateOneAttribute
      def validate_one_attribute(vctxt, doc, elem, attr, value)
        return 0 unless check_dtd?(doc)
        return 0 if elem.nil? || elem.name.nil? || attr.nil? || attr.name.nil?

        ret = 1
        aprefix = attr.ns&.prefix
        attr_decl = nil
        attr_decl = find_attr_decl(doc, "#{elem.ns.prefix}:#{elem.name}", attr.name, aprefix) if elem.ns&.prefix
        attr_decl ||= find_attr_decl(doc, elem.name, attr.name, aprefix)
        if attr_decl.nil?
          err_valid_node(vctxt, elem, ErrCode::DTD_UNKNOWN_ATTRIBUTE,
            "No declaration for attribute #{attr.name} of element #{elem.name}\n", attr.name, elem.name)
          return 0
        end
        Tree.remove_id(doc, attr) if attr.id
        attr.atype = attr_decl.atype
        unless validate_attribute_value_internal(doc, attr_decl.atype, value)
          err_valid_node(vctxt, elem, ErrCode::DTD_ATTRIBUTE_VALUE,
            "Syntax of value for attribute #{attr.name} of #{elem.name} is not valid\n", attr.name, elem.name)
          ret = 0
        end
        if attr_decl.def == ATTRIBUTE_FIXED && value != attr_decl.default_value
          err_valid_node(vctxt, elem, ErrCode::DTD_ATTRIBUTE_DEFAULT,
            "Value for attribute #{attr.name} of #{elem.name} is different from default \"#{attr_decl.default_value}\"\n",
            attr.name, elem.name, attr_decl.default_value)
          ret = 0
        end
        if attr_decl.atype == ATTRIBUTE_ID &&
            (vctxt.nil? || (vctxt.flags & Parser::ValidCtxt::XML_VCTXT_IN_ENTITY) == 0)
          ret = 0 if add_id(vctxt, doc, value, attr).nil?
        end
        if attr_decl.atype == ATTRIBUTE_IDREF || attr_decl.atype == ATTRIBUTE_IDREFS
          ret = 0 if add_ref(vctxt, doc, value, attr).nil?
        end
        if attr_decl.atype == ATTRIBUTE_NOTATION
          tree = attr_decl.tree
          nota = doc.int_subset&.notations&.[](value)
          nota = doc.ext_subset&.notations&.[](value) if nota.nil?
          if nota.nil?
            err_valid_node(vctxt, elem, ErrCode::DTD_UNKNOWN_NOTATION,
              "Value \"#{value}\" for attribute #{attr.name} of #{elem.name} is not a declared Notation\n",
              value, attr.name, elem.name)
            ret = 0
          end
          tree = tree.next while tree && tree.name != value
          if tree.nil?
            err_valid_node(vctxt, elem, ErrCode::DTD_NOTATION_VALUE,
              "Value \"#{value}\" for attribute #{attr.name} of #{elem.name} is not among the enumerated notations\n",
              value, attr.name, elem.name)
            ret = 0
          end
        end
        if attr_decl.atype == ATTRIBUTE_ENUMERATION
          tree = attr_decl.tree
          tree = tree.next while tree && tree.name != value
          if tree.nil?
            err_valid_node(vctxt, elem, ErrCode::DTD_ATTRIBUTE_VALUE,
              "Value \"#{value}\" for attribute #{attr.name} of #{elem.name} is not among the enumerated set\n",
              value, attr.name, elem.name)
            ret = 0
          end
        end
        if attr_decl.def == ATTRIBUTE_FIXED && attr_decl.default_value != value
          err_valid_node(vctxt, elem, ErrCode::DTD_ATTRIBUTE_VALUE,
            "Value for attribute #{attr.name} of #{elem.name} must be \"#{attr_decl.default_value}\"\n",
            attr.name, elem.name, attr_decl.default_value)
          ret = 0
        end
        ret &= validate_attribute_value2(vctxt, doc, attr.name, attr_decl.atype, value)
        ret
      end

      # xmlValidateOneNamespace
      def validate_one_namespace(vctxt, doc, elem, prefix, ns, value)
        return 0 unless check_dtd?(doc)
        return 0 if elem.nil? || elem.name.nil? || ns.nil? || ns.href.nil?

        ret = 1
        attr_decl = nil
        if prefix
          fullname = "#{prefix}:#{elem.name}"
          attr_decl = if ns.prefix
            find_attr_decl(doc, fullname, ns.prefix, "xmlns")
          else
            find_attr_decl(doc, fullname, "xmlns", nil)
          end
        end
        attr_decl ||= if ns.prefix
          find_attr_decl(doc, elem.name, ns.prefix, "xmlns")
        else
          find_attr_decl(doc, elem.name, "xmlns", nil)
        end
        aname = ns.prefix ? "xmlns:#{ns.prefix}" : "xmlns"
        if attr_decl.nil?
          if ns.prefix
            err_valid_node(vctxt, elem, ErrCode::DTD_UNKNOWN_ATTRIBUTE,
              "No declaration for attribute xmlns:#{ns.prefix} of element #{elem.name}\n", ns.prefix, elem.name)
          else
            err_valid_node(vctxt, elem, ErrCode::DTD_UNKNOWN_ATTRIBUTE,
              "No declaration for attribute xmlns of element #{elem.name}\n", elem.name)
          end
          return 0
        end
        s = ->(*a) { ns.prefix ? a : a[1..] + [nil] }
        unless validate_attribute_value_internal(doc, attr_decl.atype, value)
          err_valid_node(vctxt, elem, ErrCode::DTD_INVALID_DEFAULT,
            "Syntax of value for attribute #{aname} of #{elem.name} is not valid\n", *s.(ns.prefix, elem.name))
          ret = 0
        end
        if attr_decl.def == ATTRIBUTE_FIXED && value != attr_decl.default_value
          err_valid_node(vctxt, elem, ErrCode::DTD_ATTRIBUTE_DEFAULT,
            "Value for attribute #{aname} of #{elem.name} is different from default \"#{attr_decl.default_value}\"\n",
            *s.(ns.prefix, elem.name, attr_decl.default_value))
          ret = 0
        end
        if attr_decl.atype == ATTRIBUTE_NOTATION
          tree = attr_decl.tree
          nota = doc.int_subset&.notations&.[](value)
          nota = doc.ext_subset&.notations&.[](value) if nota.nil?
          if nota.nil?
            err_valid_node(vctxt, elem, ErrCode::DTD_UNKNOWN_NOTATION,
              "Value \"#{value}\" for attribute #{aname} of #{elem.name} is not a declared Notation\n",
              *(ns.prefix ? [value, ns.prefix, elem.name] : [value, elem.name, nil]))
            ret = 0
          end
          tree = tree.next while tree && tree.name != value
          if tree.nil?
            err_valid_node(vctxt, elem, ErrCode::DTD_NOTATION_VALUE,
              "Value \"#{value}\" for attribute #{aname} of #{elem.name} is not among the enumerated notations\n",
              *(ns.prefix ? [value, ns.prefix, elem.name] : [value, elem.name, nil]))
            ret = 0
          end
        end
        if attr_decl.atype == ATTRIBUTE_ENUMERATION
          tree = attr_decl.tree
          tree = tree.next while tree && tree.name != value
          if tree.nil?
            err_valid_node(vctxt, elem, ErrCode::DTD_ATTRIBUTE_VALUE,
              "Value \"#{value}\" for attribute #{aname} of #{elem.name} is not among the enumerated set\n",
              *(ns.prefix ? [value, ns.prefix, elem.name] : [value, elem.name, nil]))
            ret = 0
          end
        end
        if attr_decl.def == ATTRIBUTE_FIXED && attr_decl.default_value != value
          err_valid_node(vctxt, elem, ErrCode::DTD_ELEM_NAMESPACE,
            "Value for attribute #{aname} of #{elem.name} must be \"#{attr_decl.default_value}\"\n",
            *s.(ns.prefix, elem.name, attr_decl.default_value))
          ret = 0
        end
        ret &= validate_attribute_value2(vctxt, doc, ns.prefix || "xmlns", attr_decl.atype, value)
        ret
      end

      # xmlValidateElement
      def validate_element(vctxt, doc, root)
        return 0 if root.nil?
        return 0 unless check_dtd?(doc)

        ret = 1
        elem = root
        loop do
          ret &= validate_one_element(vctxt, doc, elem)
          if elem.type == ELEMENT_NODE
            attr = elem.properties
            while attr
              value = attr.children.nil? ? +"" : Tree.node_list_get_string(doc, attr.children, 0)
              ret &= validate_one_attribute(vctxt, doc, elem, attr, value)
              attr = attr.next
            end
            ns = elem.ns_def
            while ns
              ret &= validate_one_namespace(vctxt, doc, elem, elem.ns&.prefix, ns, ns.href)
              ns = ns.next
            end
            if elem.children
              elem = elem.children
              next
            end
          end
          loop do
            return ret if elem.equal?(root)
            break if elem.next

            elem = elem.parent
          end
          elem = elem.next
        end
      end

      # xmlValidateRef
      def validate_ref(ref, vctxt, name, doc)
        value, attr, rname, lineno = ref
        return if attr.nil? && rname.nil?

        if attr.nil?
          blank_split(name).each do |str|
            if Tree.get_id(doc, str).nil?
              err_valid_node_nr(vctxt, nil, ErrCode::DTD_UNKNOWN_ID,
                "attribute #{rname} line #{lineno} references an unknown ID \"#{str}\"\n", rname, lineno, str)
              vctxt.valid = 0
            end
          end
        elsif attr.atype == ATTRIBUTE_IDREF
          if Tree.get_id(doc, name).nil?
            err_valid_node(vctxt, attr.parent, ErrCode::DTD_UNKNOWN_ID,
              "IDREF attribute #{attr.name} references an unknown ID \"#{name}\"\n", attr.name, name)
            vctxt.valid = 0
          end
        elsif attr.atype == ATTRIBUTE_IDREFS
          blank_split(name).each do |str|
            if Tree.get_id(doc, str).nil?
              err_valid_node(vctxt, attr.parent, ErrCode::DTD_UNKNOWN_ID,
                "IDREFS attribute #{attr.name} references an unknown ID \"#{str}\"\n", attr.name, str)
              vctxt.valid = 0
            end
          end
        end
        _ = value
      end

      # xmlValidateDocumentFinal
      def validate_document_final(vctxt, doc)
        return 0 if vctxt.nil?
        if doc.nil?
          err_valid(vctxt, ErrCode::DTD_NO_DOC, "xmlValidateDocumentFinal: doc == NULL\n")
          return 0
        end
        pctxt = vctxt.pctxt
        vctxt.valid = 1
        run = lambda do
          doc.refs&.each do |name, list|
            list.each { |ref| validate_ref(ref, vctxt, name, doc) }
          end
        end
        if pctxt
          pctxt.without_input(&run)
        else
          run.call
        end
        vctxt.valid
      end

      # xmlValidateNotationUse
      def validate_notation_use(vctxt, doc, notation_name)
        return -1 if doc.nil? || doc.int_subset.nil? || notation_name.nil?

        nota = doc.int_subset.notations&.[](notation_name)
        nota = doc.ext_subset.notations&.[](notation_name) if nota.nil? && doc.ext_subset
        if nota.nil? && vctxt
          err_valid_node(vctxt, doc, ErrCode::DTD_UNKNOWN_NOTATION, "NOTATION #{notation_name} is not declared\n",
            notation_name)
          return 0
        end
        1
      end

      # xmlValidateAttributeCallback
      def validate_attribute_callback(cur, vctxt, doc)
        case cur.atype
        when ATTRIBUTE_ENTITY, ATTRIBUTE_ENTITIES, ATTRIBUTE_NOTATION
          if cur.default_value
            r = validate_attribute_value2(vctxt, doc, cur.name, cur.atype, cur.default_value)
            vctxt.valid = 0 if r == 0 && vctxt.valid == 1
          end
          tree = cur.tree
          while tree
            r = validate_attribute_value2(vctxt, doc, cur.name, cur.atype, tree.name)
            vctxt.valid = 0 if r == 0 && vctxt.valid == 1
            tree = tree.next
          end
        end
        return unless cur.atype == ATTRIBUTE_NOTATION

        d = cur.doc
        if cur.elem.nil?
          err_valid(vctxt, ErrCode::ERR_INTERNAL_ERROR, "xmlValidateAttributeCallback(#{cur.name}): internal error\n",
            cur.name)
          return
        end
        local, prefix = split_qname4(cur.elem)
        elem = nil
        elem = d.int_subset&.elements&.[]([local, prefix]) if d
        elem = d.ext_subset&.elements&.[]([local, prefix]) if elem.nil? && d
        if elem.nil? && cur.parent && cur.parent.type == DTD_NODE
          elem = cur.parent.elements&.[]([local, prefix])
        end
        if elem.nil?
          err_valid_node(vctxt, nil, ErrCode::DTD_UNKNOWN_ELEM,
            "attribute #{cur.name}: could not find decl for element #{cur.elem}\n", cur.name, cur.elem)
          return
        end
        if elem.etype == ELEMENT_TYPE_EMPTY
          err_valid_node(vctxt, nil, ErrCode::DTD_EMPTY_NOTATION,
            "NOTATION attribute #{cur.name} declared for EMPTY element #{cur.elem}\n", cur.name, cur.elem)
          vctxt.valid = 0
        end
      end

      # xmlValidateDtdFinal
      def validate_dtd_final(vctxt, doc)
        return 0 if doc.nil? || vctxt.nil?
        return 0 if doc.int_subset.nil? && doc.ext_subset.nil?

        vctxt.valid = 1
        [doc.int_subset, doc.ext_subset].each do |dtd|
          next if dtd.nil?

          dtd.attributes&.each_value { |a| validate_attribute_callback(a, vctxt, doc) }
          dtd.entities&.each_value do |ent|
            next unless ent.etype == EXTERNAL_GENERAL_UNPARSED_ENTITY && ent.content

            vctxt.valid = 0 if validate_notation_use(vctxt, ent.doc, ent.content) != 1
          end
        end
        vctxt.valid
      end

      # xmlValidateDtd (Nokogiri::XML::DTD#validate)
      def validate_dtd(doc, dtd, vctxt = Parser::ValidCtxt.new)
        return 0 if dtd.nil? || doc.nil?

        old_ext = doc.ext_subset
        old_int = doc.int_subset
        doc.ext_subset = dtd
        doc.int_subset = nil
        doc.ids = nil
        doc.refs = nil
        begin
          ret = validate_root(vctxt, doc)
          if ret != 0
            root = Tree.doc_get_root_element(doc)
            ret = validate_element(vctxt, doc, root)
            ret &= validate_document_final(vctxt, doc)
          end
        ensure
          doc.ext_subset = old_ext
          doc.int_subset = old_int
          doc.ids = nil
          doc.refs = nil
        end
        ret
      end

      # xmlValidateDocument
      def validate_document(vctxt, doc)
        return 0 if doc.nil?
        if doc.int_subset.nil? && doc.ext_subset.nil?
          err_valid(vctxt, ErrCode::DTD_NO_DTD, "no DTD found!\n")
          return 0
        end
        doc.ids = nil
        doc.refs = nil
        ret = validate_dtd_final(vctxt, doc)
        return 0 if validate_root(vctxt, doc) == 0

        root = Tree.doc_get_root_element(doc)
        ret &= validate_element(vctxt, doc, root)
        ret &= validate_document_final(vctxt, doc)
        ret
      end
    end
  end
end
