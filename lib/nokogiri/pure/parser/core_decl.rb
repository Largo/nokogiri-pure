# frozen_string_literal: true

module Nokogiri
  module Pure
    module Parser
      class Ctxt
        XML_W3C_PIS = %w[xml-stylesheet xml-model].freeze
        PI_BODY_RE = /[^?\r\x00-\x08\x0B\x0C\x0E-\x1F�￾￿]+/

        # PARSER_IN_PE
        def in_pe?
          (ent = @input.entity) &&
            (ent.etype == INTERNAL_PARAMETER_ENTITY || ent.etype == EXTERNAL_PARAMETER_ENTITY)
        end

        # PARSER_EXTERNAL
        def external?
          @in_subset == 2 || ((ent = @input.entity) && ent.etype == EXTERNAL_PARAMETER_ENTITY)
        end

        # xmlPopPE
        def pop_pe
          ent = @input.entity
          ent.flags &= ~ENT_EXPANDING
          if (ent.flags & ENT_CHECKED) == 0
            consumed = @input.consumed + @end
            ent.expanded_size = [ent.expanded_size + consumed, ULONG_MAX].min
            @sizeentities = [@sizeentities + consumed, ULONG_MAX].min if ent.etype == EXTERNAL_PARAMETER_ENTITY
            ent.flags |= ENT_CHECKED
          end
          pop_input
          parser_entity_check(ent.expanded_size)
        end

        # xmlSkipBlankCharsPE
        def skip_blank_chars_pe
          res = 0
          in_param = in_pe?
          expand_param = external?
          return skip_blanks if !in_param && !expand_param

          until stopped?
            c = cur_byte
            if Chars.blank?(c)
              next_char
            elsif c == 0x25
              n1 = nxt(1)
              break if !expand_param || Chars.blank?(n1) || n1 == 0

              parse_pe_reference
              in_param = in_pe?
              expand_param = external?
            elsif c == 0
              break unless in_param

              pop_pe
              in_param = in_pe?
              expand_param = external?
            else
              break
            end
            res += 1
          end
          res
        end

        # ---- processing instructions -----------------------------------------------------------------

        # xmlParsePITarget
        def parse_pi_target
          name = parse_name
          if name && name.bytesize >= 3 && name.b[0, 3].casecmp?("xml")
            if name == "xml"
              fatal_err_msg(ErrCode::ERR_RESERVED_XML_NAME,
                "XML declaration allowed only at the start of the document\n")
              return name
            elsif name.bytesize == 3
              fatal_err(ErrCode::ERR_RESERVED_XML_NAME)
              return name
            end
            return name if XML_W3C_PIS.include?(name)

            warning_msg(ErrCode::ERR_RESERVED_XML_NAME, "xmlParsePITarget: invalid name prefix 'xml'\n")
          end
          if name&.b&.include?(":")
            ns_err(ErrCode::NS_ERR_COLON, "colons are forbidden from PI names '#{name}'\n", name)
          end
          name
        end

        # xmlParsePI
        def parse_pi
          return unless cur_byte == 0x3C && nxt(1) == 0x3F

          max_length = option?(PARSE_HUGE) ? XML_MAX_HUGE_LENGTH : XML_MAX_TEXT_LENGTH
          skip(2)
          target = parse_pi_target
          if target.nil?
            fatal_err(ErrCode::ERR_PI_NOT_STARTED)
            return
          end
          if cur_byte == 0x3F && nxt(1) == 0x3E
            skip(2)
            if @disable_sax == 0 && (cb = @sax.processing_instruction)
              cb.call(@user_data, target, nil)
            end
            return
          end
          buf = +""
          if skip_blanks == 0
            fatal_err_msg_str(ErrCode::ERR_SPACE_REQUIRED, "ParsePI: PI #{target} space expected\n", target)
          end
          cur = cur_char
          while Chars.char?(cur) && (cur != 0x3F || nxt(1) != 0x3E)
            buf << utf8_chr(cur)
            if buf.bytesize > max_length
              fatal_err_msg_str(ErrCode::ERR_PI_NOT_FINISHED, "PI #{target} too big found", target)
              return
            end
            nextl(@cl)
            @ss.pos = @cur
            n = @ss.skip(PI_BODY_RE)
            if n
              buf << @buf.byteslice(@cur, n)
              advance_text(n)
            end
            cur = cur_char
          end
          if cur != 0x3F
            fatal_err_msg_str(ErrCode::ERR_PI_NOT_FINISHED, "ParsePI: PI #{target} never end ...\n", target)
          else
            skip(2)
            if @disable_sax == 0 && (cb = @sax.processing_instruction)
              cb.call(@user_data, target, buf)
            end
          end
        end

        # ---- DTD declarations -----------------------------------------------------------------------

        # xmlParseNotationDecl
        def parse_notation_decl
          return if cur_byte != 0x3C || nxt(1) != 0x21

          skip(2)
          return unless cmp?("NOTATION")

          inputid = @input.id
          skip(8)
          if skip_blank_chars_pe == 0
            fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after '<!NOTATION'\n")
            return
          end
          name = parse_name
          if name.nil?
            fatal_err(ErrCode::ERR_NOTATION_NOT_STARTED)
            return
          end
          if name.b.include?(":")
            ns_err(ErrCode::NS_ERR_COLON, "colons are forbidden from notation names '#{name}'\n", name)
          end
          if skip_blank_chars_pe == 0
            fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after the NOTATION name'\n")
            return
          end
          systemid, pubid = parse_external_id(false)
          skip_blank_chars_pe
          if cur_byte == 0x3E
            if inputid != @input.id
              fatal_err_msg(ErrCode::ERR_ENTITY_BOUNDARY,
                "Notation declaration doesn't start and stop in the same entity\n")
            end
            next_char
            if @disable_sax == 0 && (cb = @sax.notation_decl)
              cb.call(@user_data, name, pubid, systemid)
            end
          else
            fatal_err(ErrCode::ERR_NOTATION_NOT_FINISHED)
          end
        end

        # xmlParseEntityDecl
        def parse_entity_decl
          return if cur_byte != 0x3C || nxt(1) != 0x21

          skip(2)
          return unless cmp?("ENTITY")

          orig = nil
          is_parameter = false
          inputid = @input.id
          skip(6)
          if skip_blank_chars_pe == 0
            fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after '<!ENTITY'\n")
          end
          if cur_byte == 0x25
            next_char
            if skip_blank_chars_pe == 0
              fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after '%'\n")
            end
            is_parameter = true
          end
          name = parse_name
          if name.nil?
            fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "xmlParseEntityDecl: no name\n")
            return
          end
          if name.b.include?(":")
            ns_err(ErrCode::NS_ERR_COLON, "colons are forbidden from entities names '#{name}'\n", name)
          end
          if skip_blank_chars_pe == 0
            fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after the entity name\n")
          end

          if is_parameter
            if cur_byte == 0x22 || cur_byte == 0x27
              value, orig = parse_entity_value
              if value && @disable_sax == 0 && (cb = @sax.entity_decl)
                cb.call(@user_data, name, INTERNAL_PARAMETER_ENTITY, nil, nil, value)
              end
            else
              uri, literal = parse_external_id(true)
              fatal_err(ErrCode::ERR_VALUE_REQUIRED) if uri.nil? && literal.nil?
              if uri
                if uri.include?("#")
                  fatal_err(ErrCode::ERR_URI_FRAGMENT)
                elsif @disable_sax == 0 && (cb = @sax.entity_decl)
                  cb.call(@user_data, name, EXTERNAL_PARAMETER_ENTITY, literal, uri, nil)
                end
              end
            end
          elsif cur_byte == 0x22 || cur_byte == 0x27
            value, orig = parse_entity_value
            if @disable_sax == 0 && (cb = @sax.entity_decl)
              cb.call(@user_data, name, INTERNAL_GENERAL_ENTITY, nil, nil, value)
            end
            if @my_doc.nil? || @my_doc.version == SAX_COMPAT_MODE
              if @my_doc.nil?
                @my_doc = Tree.new_doc(SAX_COMPAT_MODE)
                @my_doc.doc_properties = 1 << 6 # XML_DOC_INTERNAL
              end
              if @my_doc.int_subset.nil?
                @my_doc.int_subset = Tree.new_dtd(nil, "fake", nil, nil).tap { |d| d.doc = @my_doc }
                @my_doc.ext_subset = nil if @my_doc.ext_subset.equal?(@my_doc.int_subset)
              end
              SAX2.entity_decl(self, name, INTERNAL_GENERAL_ENTITY, nil, nil, value)
            end
          else
            uri, literal = parse_external_id(true)
            fatal_err(ErrCode::ERR_VALUE_REQUIRED) if uri.nil? && literal.nil?
            fatal_err(ErrCode::ERR_URI_FRAGMENT) if uri&.include?("#")
            if cur_byte != 0x3E && skip_blank_chars_pe == 0
              fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required before 'NDATA'\n")
            end
            if cmp?("NDATA")
              skip(5)
              if skip_blank_chars_pe == 0
                fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after 'NDATA'\n")
              end
              ndata = parse_name
              if @disable_sax == 0 && (cb = @sax.unparsed_entity_decl)
                cb.call(@user_data, name, literal, uri, ndata)
              end
            else
              if @disable_sax == 0 && (cb = @sax.entity_decl)
                cb.call(@user_data, name, EXTERNAL_GENERAL_PARSED_ENTITY, literal, uri, nil)
              end
              if @replace_entities != 0 && (@my_doc.nil? || @my_doc.version == SAX_COMPAT_MODE)
                if @my_doc.nil?
                  @my_doc = Tree.new_doc(SAX_COMPAT_MODE)
                  @my_doc.doc_properties = 1 << 6
                end
                if @my_doc.int_subset.nil?
                  @my_doc.int_subset = Tree.new_dtd(nil, "fake", nil, nil).tap { |d| d.doc = @my_doc }
                end
                SAX2.entity_decl(self, name, EXTERNAL_GENERAL_PARSED_ENTITY, literal, uri, nil)
              end
            end
          end
          skip_blank_chars_pe
          if cur_byte != 0x3E
            fatal_err_msg_str(ErrCode::ERR_ENTITY_NOT_FINISHED,
              "xmlParseEntityDecl: entity #{name} not terminated\n", name)
            halt
          else
            if inputid != @input.id
              fatal_err_msg(ErrCode::ERR_ENTITY_BOUNDARY,
                "Entity declaration doesn't start and stop in the same entity\n")
            end
            next_char
          end
          if orig
            cur = nil
            if is_parameter
              cur = @sax.get_parameter_entity&.call(@user_data, name)
            else
              cur = @sax.get_entity&.call(@user_data, name)
              cur = SAX2.get_entity(self, name) if cur.nil? && @user_data.equal?(self)
            end
            cur.orig = orig if cur && cur.orig.nil?
          end
        end

        # xmlParseDefaultDecl: returns [def, value]
        def parse_default_decl
          if cmp?("#REQUIRED")
            skip(9)
            return [ATTRIBUTE_REQUIRED, nil]
          end
          if cmp?("#IMPLIED")
            skip(8)
            return [ATTRIBUTE_IMPLIED, nil]
          end
          val = ATTRIBUTE_NONE
          if cmp?("#FIXED")
            skip(6)
            val = ATTRIBUTE_FIXED
            if skip_blank_chars_pe == 0
              fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after '#FIXED'\n")
            end
          end
          ret = parse_att_value
          if ret.nil?
            fatal_err_msg(@err_no, "Attribute default value declaration error\n")
            return [val, nil]
          end
          [val, ret]
        end

        # xmlParseNotationType: returns an XmlEnumeration list or nil
        def parse_notation_type
          if cur_byte != 0x28
            fatal_err(ErrCode::ERR_NOTATION_NOT_STARTED)
            return nil
          end
          ret = nil
          last = nil
          while true
            next_char
            skip_blank_chars_pe
            name = parse_name
            if name.nil?
              fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "Name expected in NOTATION declaration\n")
              return nil
            end
            tmp = ret
            while tmp
              if tmp.name == name
                validity_error(ErrCode::DTD_DUP_TOKEN,
                  "standalone: attribute notation value token #{name} duplicated\n", name, nil)
                break
              end
              tmp = tmp.next
            end
            if tmp.nil?
              cur = XmlEnumeration.new(name, nil)
              if last.nil?
                ret = last = cur
              else
                last.next = cur
                last = cur
              end
            end
            skip_blank_chars_pe
            break unless cur_byte == 0x7C
          end
          if cur_byte != 0x29
            fatal_err(ErrCode::ERR_NOTATION_NOT_FINISHED)
            return nil
          end
          next_char
          ret
        end

        # xmlParseEnumerationType
        def parse_enumeration_type
          if cur_byte != 0x28
            fatal_err(ErrCode::ERR_ATTLIST_NOT_STARTED)
            return nil
          end
          ret = nil
          last = nil
          while true
            next_char
            skip_blank_chars_pe
            name = parse_nmtoken
            if name.nil?
              fatal_err(ErrCode::ERR_NMTOKEN_REQUIRED)
              return ret
            end
            tmp = ret
            while tmp
              if tmp.name == name
                validity_error(ErrCode::DTD_DUP_TOKEN,
                  "standalone: attribute enumeration value token #{name} duplicated\n", name, nil)
                break
              end
              tmp = tmp.next
            end
            if tmp.nil?
              cur = XmlEnumeration.new(name, nil)
              if last.nil?
                ret = last = cur
              else
                last.next = cur
                last = cur
              end
            end
            skip_blank_chars_pe
            break unless cur_byte == 0x7C
          end
          if cur_byte != 0x29
            fatal_err(ErrCode::ERR_ATTLIST_NOT_FINISHED)
            return ret
          end
          next_char
          ret
        end

        # xmlParseEnumeratedType: returns [type, tree]
        def parse_enumerated_type
          if cmp?("NOTATION")
            skip(8)
            if skip_blank_chars_pe == 0
              fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after 'NOTATION'\n")
              return [0, nil]
            end
            tree = parse_notation_type
            return [0, nil] if tree.nil?

            return [ATTRIBUTE_NOTATION, tree]
          end
          tree = parse_enumeration_type
          return [0, nil] if tree.nil?

          [ATTRIBUTE_ENUMERATION, tree]
        end

        # xmlParseAttributeType: returns [type, tree]
        def parse_attribute_type
          if cmp?("CDATA")
            skip(5)
            [ATTRIBUTE_CDATA, nil]
          elsif cmp?("IDREFS")
            skip(6)
            [ATTRIBUTE_IDREFS, nil]
          elsif cmp?("IDREF")
            skip(5)
            [ATTRIBUTE_IDREF, nil]
          elsif cur_byte == 0x49 && nxt(1) == 0x44
            skip(2)
            [ATTRIBUTE_ID, nil]
          elsif cmp?("ENTITY")
            skip(6)
            [ATTRIBUTE_ENTITY, nil]
          elsif cmp?("ENTITIES")
            skip(8)
            [ATTRIBUTE_ENTITIES, nil]
          elsif cmp?("NMTOKENS")
            skip(8)
            [ATTRIBUTE_NMTOKENS, nil]
          elsif cmp?("NMTOKEN")
            skip(7)
            [ATTRIBUTE_NMTOKEN, nil]
          else
            parse_enumerated_type
          end
        end

        # xmlAttrNormalizeSpace
        def self.attr_normalize_space(src)
          src.sub(/\A +/, "").gsub(/ +/, " ").sub(/ \z/, "")
        end

        # xmlParseAttributeListDecl
        def parse_attribute_list_decl
          return if cur_byte != 0x3C || nxt(1) != 0x21

          skip(2)
          return unless cmp?("ATTLIST")

          inputid = @input.id
          skip(7)
          if skip_blank_chars_pe == 0
            fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after '<!ATTLIST'\n")
          end
          elem_name = parse_name
          if elem_name.nil?
            fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "ATTLIST: no name for Element\n")
            return
          end
          skip_blank_chars_pe
          grow
          while cur_byte != 0x3E && !stopped?
            grow
            attr_name = parse_name
            if attr_name.nil?
              fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "ATTLIST: no name for Attribute\n")
              break
            end
            grow
            if skip_blank_chars_pe == 0
              fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after the attribute name\n")
              break
            end
            type, tree = parse_attribute_type
            break if type <= 0

            grow
            if skip_blank_chars_pe == 0
              fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after the attribute type\n")
              break
            end
            defv, default_value = parse_default_decl
            break if defv <= 0

            default_value = Ctxt.attr_normalize_space(default_value) if type != ATTRIBUTE_CDATA && default_value
            grow
            if cur_byte != 0x3E && skip_blank_chars_pe == 0
              fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after the attribute default value\n")
              break
            end
            if @disable_sax == 0 && (cb = @sax.attribute_decl)
              cb.call(@user_data, elem_name, attr_name, type, defv, default_value, tree)
            end
            if @sax2 != 0 && default_value && defv != ATTRIBUTE_IMPLIED && defv != ATTRIBUTE_REQUIRED
              add_def_attrs(elem_name, attr_name, default_value)
            end
            add_special_attr(elem_name, attr_name, type) if @sax2 != 0
            grow
          end
          if cur_byte == 0x3E
            if inputid != @input.id
              fatal_err_msg(ErrCode::ERR_ENTITY_BOUNDARY,
                "Attribute list declaration doesn't start and stop in the same entity\n")
            end
            next_char
          end
        end

        # xmlAddDefAttrs
        def add_def_attrs(fullname, fullattr, value)
          return if @atts_special && @atts_special.key?([fullname, fullattr])

          @atts_default ||= {}
          if (i = fullname.index(":")) && i > 0 && i < fullname.length - 1
            key = [fullname[(i + 1)..], fullname[0, i]]
          else
            key = [fullname, nil]
          end
          defaults = (@atts_default[key] ||= [])
          if (i = fullattr.index(":")) && i > 0 && i < fullattr.length - 1
            name = -fullattr[(i + 1)..]
            prefix = -fullattr[0, i]
          else
            name = -fullattr
            prefix = nil
          end
          expanded_size = name.bytesize + (prefix ? prefix.bytesize : 0) + value.bytesize
          defaults << DefAttr.new(prefix, name, value, external? ? 1 : 0, expanded_size)
        end

        # xmlAddSpecialAttr
        def add_special_attr(fullname, fullattr, type)
          @atts_special ||= {}
          key = [fullname, fullattr]
          @atts_special[key] = type unless @atts_special.key?(key)
        end

        # xmlCleanSpecialAttr
        def clean_special_attr
          return if @atts_special.nil?

          @atts_special.delete_if { |_, v| v == ATTRIBUTE_CDATA }
          @atts_special = nil if @atts_special.empty?
        end

        # ---- element content declarations -------------------------------------------------------

        def new_element_content(name, type)
          ret = XmlElementContent.new(type)
          if name
            if (i = name.index(":")) && i > 0 && i < name.length - 1
              ret.prefix = -name[0, i]
              ret.name = -name[(i + 1)..]
            else
              ret.name = -name
            end
          end
          ret
        end

        # xmlParseElementMixedContentDecl
        def parse_element_mixed_content_decl(inputchk)
          ret = nil
          cur = nil
          elem = nil
          grow
          if cmp?("#PCDATA")
            skip(7)
            skip_blank_chars_pe
            if cur_byte == 0x29
              if @input.id != inputchk
                fatal_err_msg(ErrCode::ERR_ENTITY_BOUNDARY,
                  "Element content declaration doesn't start and stop in the same entity\n")
              end
              next_char
              ret = new_element_content(nil, ELEMENT_CONTENT_PCDATA)
              if cur_byte == 0x2A
                ret.ocur = ELEMENT_CONTENT_MULT
                next_char
              end
              return ret
            end
            if cur_byte == 0x28 || cur_byte == 0x7C
              ret = cur = new_element_content(nil, ELEMENT_CONTENT_PCDATA)
            end
            while cur_byte == 0x7C && !stopped?
              next_char
              n = new_element_content(nil, ELEMENT_CONTENT_OR)
              if elem.nil?
                n.c1 = cur
                cur.parent = n if cur
                ret = cur = n
              else
                cur.c2 = n
                n.parent = cur
                n.c1 = new_element_content(elem, ELEMENT_CONTENT_ELEMENT)
                n.c1.parent = n
                cur = n
              end
              skip_blank_chars_pe
              elem = parse_name
              if elem.nil?
                fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "xmlParseElementMixedContentDecl : Name expected\n")
                return nil
              end
              skip_blank_chars_pe
              grow
            end
            if cur_byte == 0x29 && nxt(1) == 0x2A
              if elem
                cur.c2 = new_element_content(elem, ELEMENT_CONTENT_ELEMENT)
                cur.c2.parent = cur
              end
              ret.ocur = ELEMENT_CONTENT_MULT if ret
              if @input.id != inputchk
                fatal_err_msg(ErrCode::ERR_ENTITY_BOUNDARY,
                  "Element content declaration doesn't start and stop in the same entity\n")
              end
              skip(2)
            else
              fatal_err(ErrCode::ERR_MIXED_NOT_STARTED)
              return nil
            end
          else
            fatal_err(ErrCode::ERR_PCDATA_REQUIRED)
          end
          ret
        end

        def parse_occurrence(node)
          case cur_byte
          when 0x3F
            node.ocur = ELEMENT_CONTENT_OPT
            next_char
          when 0x2A
            node.ocur = ELEMENT_CONTENT_MULT
            next_char
          when 0x2B
            node.ocur = ELEMENT_CONTENT_PLUS
            next_char
          else
            node.ocur = ELEMENT_CONTENT_ONCE
          end
        end

        # xmlParseElementChildrenContentDeclPriv
        def parse_element_children_content_decl_priv(inputchk, depth)
          max_depth = option?(PARSE_HUGE) ? 2048 : 256
          ret = cur = last = nil
          type = 0
          if depth > max_depth
            fatal_err_msg_int(ErrCode::ERR_RESOURCE_LIMIT,
              "xmlParseElementChildrenContentDecl : depth #{depth} too deep, use XML_PARSE_HUGE\n", depth)
            return nil
          end
          skip_blank_chars_pe
          grow
          if cur_byte == 0x28
            inputid = @input.id
            next_char
            skip_blank_chars_pe
            cur = ret = parse_element_children_content_decl_priv(inputid, depth + 1)
            return nil if cur.nil?

            skip_blank_chars_pe
            grow
          else
            elem = parse_name
            if elem.nil?
              fatal_err(ErrCode::ERR_ELEMCONTENT_NOT_STARTED)
              return nil
            end
            cur = ret = new_element_content(elem, ELEMENT_CONTENT_ELEMENT)
            grow
            parse_occurrence(cur)
            grow
          end
          skip_blank_chars_pe
          while cur_byte != 0x29 && !stopped?
            c = cur_byte
            if c == 0x2C || c == 0x7C
              if type == 0
                type = c
              elsif type != c
                fatal_err_msg_int(ErrCode::ERR_SEPARATOR_REQUIRED,
                  "xmlParseElementChildrenContentDecl : '#{type.chr}' expected\n", type)
                return nil
              end
              next_char
              op = new_element_content(nil, c == 0x2C ? ELEMENT_CONTENT_SEQ : ELEMENT_CONTENT_OR)
              if last.nil?
                op.c1 = ret
                ret.parent = op if ret
                ret = cur = op
              else
                cur.c2 = op
                op.parent = cur
                op.c1 = last
                last.parent = op
                cur = op
                last = nil
              end
            else
              fatal_err(ErrCode::ERR_ELEMCONTENT_NOT_FINISHED)
              return nil
            end
            grow
            skip_blank_chars_pe
            grow
            if cur_byte == 0x28
              inputid = @input.id
              next_char
              skip_blank_chars_pe
              last = parse_element_children_content_decl_priv(inputid, depth + 1)
              return nil if last.nil?

              skip_blank_chars_pe
            else
              elem = parse_name
              if elem.nil?
                fatal_err(ErrCode::ERR_ELEMCONTENT_NOT_STARTED)
                return nil
              end
              last = new_element_content(elem, ELEMENT_CONTENT_ELEMENT)
              parse_occurrence(last)
            end
            skip_blank_chars_pe
            grow
          end
          if cur && last
            cur.c2 = last
            last.parent = cur
          end
          if @input.id != inputchk
            fatal_err_msg(ErrCode::ERR_ENTITY_BOUNDARY,
              "Element content declaration doesn't start and stop in the same entity\n")
          end
          next_char
          case cur_byte
          when 0x3F
            if ret
              ret.ocur = if ret.ocur == ELEMENT_CONTENT_PLUS || ret.ocur == ELEMENT_CONTENT_MULT
                ELEMENT_CONTENT_MULT
              else
                ELEMENT_CONTENT_OPT
              end
            end
            next_char
          when 0x2A
            if ret
              ret.ocur = ELEMENT_CONTENT_MULT
              cur = ret
              while cur && cur.type == ELEMENT_CONTENT_OR
                if cur.c1 && (cur.c1.ocur == ELEMENT_CONTENT_OPT || cur.c1.ocur == ELEMENT_CONTENT_MULT)
                  cur.c1.ocur = ELEMENT_CONTENT_ONCE
                end
                if cur.c2 && (cur.c2.ocur == ELEMENT_CONTENT_OPT || cur.c2.ocur == ELEMENT_CONTENT_MULT)
                  cur.c2.ocur = ELEMENT_CONTENT_ONCE
                end
                cur = cur.c2
              end
            end
            next_char
          when 0x2B
            if ret
              found = false
              ret.ocur = if ret.ocur == ELEMENT_CONTENT_OPT || ret.ocur == ELEMENT_CONTENT_MULT
                ELEMENT_CONTENT_MULT
              else
                ELEMENT_CONTENT_PLUS
              end
              while cur && cur.type == ELEMENT_CONTENT_OR
                if cur.c1 && (cur.c1.ocur == ELEMENT_CONTENT_OPT || cur.c1.ocur == ELEMENT_CONTENT_MULT)
                  cur.c1.ocur = ELEMENT_CONTENT_ONCE
                  found = true
                end
                if cur.c2 && (cur.c2.ocur == ELEMENT_CONTENT_OPT || cur.c2.ocur == ELEMENT_CONTENT_MULT)
                  cur.c2.ocur = ELEMENT_CONTENT_ONCE
                  found = true
                end
                cur = cur.c2
              end
              ret.ocur = ELEMENT_CONTENT_MULT if found
            end
            next_char
          end
          ret
        end

        # xmlParseElementContentDecl: returns [type, tree]
        def parse_element_content_decl(name)
          inputid = @input.id
          if cur_byte != 0x28
            fatal_err_msg_str(ErrCode::ERR_ELEMCONTENT_NOT_STARTED,
              "xmlParseElementContentDecl : #{name} '(' expected\n", name)
            return [-1, nil]
          end
          next_char
          grow
          skip_blank_chars_pe
          if cmp?("#PCDATA")
            tree = parse_element_mixed_content_decl(inputid)
            res = ELEMENT_TYPE_MIXED
          else
            tree = parse_element_children_content_decl_priv(inputid, 1)
            res = ELEMENT_TYPE_ELEMENT
          end
          skip_blank_chars_pe
          [res, tree]
        end

        # xmlParseElementDecl
        def parse_element_decl
          ret = -1
          return ret if cur_byte != 0x3C || nxt(1) != 0x21

          skip(2)
          return ret unless cmp?("ELEMENT")

          content = nil
          inputid = @input.id
          skip(7)
          if skip_blank_chars_pe == 0
            fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after 'ELEMENT'\n")
            return -1
          end
          name = parse_name
          if name.nil?
            fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "xmlParseElementDecl: no name for Element\n")
            return -1
          end
          if skip_blank_chars_pe == 0
            fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after the element name\n")
          end
          if cmp?("EMPTY")
            skip(5)
            ret = ELEMENT_TYPE_EMPTY
          elsif cur_byte == 0x41 && nxt(1) == 0x4E && nxt(2) == 0x59
            skip(3)
            ret = ELEMENT_TYPE_ANY
          elsif cur_byte == 0x28
            ret, content = parse_element_content_decl(name)
          else
            fatal_err_msg(ErrCode::ERR_ELEMCONTENT_NOT_STARTED,
              "xmlParseElementDecl: 'EMPTY', 'ANY' or '(' expected\n")
            return -1
          end
          skip_blank_chars_pe
          if cur_byte != 0x3E
            fatal_err(ErrCode::ERR_GT_REQUIRED)
          else
            if inputid != @input.id
              fatal_err_msg(ErrCode::ERR_ENTITY_BOUNDARY,
                "Element declaration doesn't start and stop in the same entity\n")
            end
            next_char
            if @disable_sax == 0 && (cb = @sax.element_decl)
              content.parent = nil if content
              cb.call(@user_data, name, ret, content)
            end
          end
          ret
        end

        # xmlParseConditionalSections
        def parse_conditional_sections
          input_ids = []
          depth = 0
          until stopped?
            if cur_byte == 0x3C && nxt(1) == 0x21 && nxt(2) == 0x5B
              id = @input.id
              skip(3)
              skip_blank_chars_pe
              if cmp?("INCLUDE")
                skip(7)
                skip_blank_chars_pe
                if cur_byte != 0x5B
                  fatal_err(ErrCode::ERR_CONDSEC_INVALID)
                  halt
                  return
                end
                if @input.id != id
                  fatal_err_msg(ErrCode::ERR_ENTITY_BOUNDARY,
                    "All markup of the conditional section is not in the same entity\n")
                end
                next_char
                input_ids[depth] = id
                depth += 1
              elsif cmp?("IGNORE")
                ignore_depth = 0
                skip(6)
                skip_blank_chars_pe
                if cur_byte != 0x5B
                  fatal_err(ErrCode::ERR_CONDSEC_INVALID)
                  halt
                  return
                end
                if @input.id != id
                  fatal_err_msg(ErrCode::ERR_ENTITY_BOUNDARY,
                    "All markup of the conditional section is not in the same entity\n")
                end
                next_char
                until stopped?
                  if cur_byte == 0
                    fatal_err(ErrCode::ERR_CONDSEC_NOT_FINISHED)
                    return
                  end
                  if cur_byte == 0x3C && nxt(1) == 0x21 && nxt(2) == 0x5B
                    skip(3)
                    ignore_depth += 1
                  elsif cur_byte == 0x5D && nxt(1) == 0x5D && nxt(2) == 0x3E
                    skip(3)
                    break if ignore_depth == 0

                    ignore_depth -= 1
                  else
                    next_char
                  end
                end
                if @input.id != id
                  fatal_err_msg(ErrCode::ERR_ENTITY_BOUNDARY,
                    "All markup of the conditional section is not in the same entity\n")
                end
              else
                fatal_err(ErrCode::ERR_CONDSEC_INVALID_KEYWORD)
                halt
                return
              end
            elsif depth > 0 && cur_byte == 0x5D && nxt(1) == 0x5D && nxt(2) == 0x3E
              depth -= 1
              if @input.id != input_ids[depth]
                fatal_err_msg(ErrCode::ERR_ENTITY_BOUNDARY,
                  "All markup of the conditional section is not in the same entity\n")
              end
              skip(3)
            elsif cur_byte == 0x3C && (nxt(1) == 0x21 || nxt(1) == 0x3F)
              parse_markup_decl
            else
              fatal_err(ErrCode::ERR_EXT_SUBSET_NOT_FINISHED)
              halt
              return
            end
            break if depth == 0

            skip_blank_chars_pe
            grow
          end
        end

        # xmlParseMarkupDecl
        def parse_markup_decl
          grow
          return unless cur_byte == 0x3C

          if nxt(1) == 0x21
            case nxt(2)
            when 0x45 # E
              if nxt(3) == 0x4C
                parse_element_decl
              elsif nxt(3) == 0x4E
                parse_entity_decl
              else
                skip(2)
              end
            when 0x41 # A
              parse_attribute_list_decl
            when 0x4E # N
              parse_notation_decl
            when 0x2D # -
              parse_comment
            else
              fatal_err(@in_subset == 2 ? ErrCode::ERR_EXT_SUBSET_NOT_FINISHED : ErrCode::ERR_INT_SUBSET_NOT_FINISHED)
              skip(2)
            end
          elsif nxt(1) == 0x3F
            parse_pi
          end
        end

        # xmlParseTextDecl
        def parse_text_decl
          if cmp?("<?xml") && Chars.blank?(nxt(5))
            skip(5)
          else
            fatal_err(ErrCode::ERR_XMLDECL_NOT_STARTED)
            return
          end
          if skip_blanks == 0
            fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space needed after '<?xml'\n")
          end
          version = parse_version_info
          if version.nil?
            version = XML_DEFAULT_VERSION.dup
          elsif skip_blanks == 0
            fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space needed here\n")
          end
          @input.version = version
          parse_encoding_decl
          skip_blanks
          if cur_byte == 0x3F && nxt(1) == 0x3E
            skip(2)
          elsif cur_byte == 0x3E
            fatal_err(ErrCode::ERR_XMLDECL_NOT_FINISHED)
            next_char
          else
            fatal_err(ErrCode::ERR_XMLDECL_NOT_FINISHED)
            while !stopped? && (c = cur_byte) != 0
              next_char
              break if c == 0x3E
            end
          end
        end

        # xmlParseExternalSubset
        def parse_external_subset(external_id, system_id)
          initialize_late
          detect_encoding
          parse_text_decl if cmp?("<?xml")
          if @my_doc.nil?
            @my_doc = Tree.new_doc("1.0")
            @my_doc.doc_properties = 1 << 6
          end
          if @my_doc.int_subset.nil?
            Tree.create_int_subset(@my_doc, nil, external_id, system_id)
          end
          @in_subset = 2
          old_input_nr = input_nr
          skip_blank_chars_pe
          while (cur_byte != 0 || input_nr > old_input_nr) && !stopped?
            grow
            if cur_byte == 0x3C && nxt(1) == 0x21 && nxt(2) == 0x5B
              parse_conditional_sections
            elsif cur_byte == 0x3C && (nxt(1) == 0x21 || nxt(1) == 0x3F)
              parse_markup_decl
            else
              fatal_err(ErrCode::ERR_EXT_SUBSET_NOT_FINISHED)
              halt
              return
            end
            skip_blank_chars_pe
          end
          pop_pe while input_nr > old_input_nr
          fatal_err(ErrCode::ERR_EXT_SUBSET_NOT_FINISHED) if cur_byte != 0
        end

        # ---- references -------------------------------------------------------------------------------

        # xmlParseReference
        def parse_reference
          return if cur_byte != 0x26

          if nxt(1) == 0x23
            value = parse_char_ref
            return if value == 0

            if @disable_sax == 0 && (cb = @sax.characters)
              cb.call(@user_data, utf8_chr(value))
            end
            return
          end

          name = parse_entity_ref_internal
          return if name.nil?

          ent = lookup_general_entity(name, false)
          if ent.nil?
            if @replace_entities == 0 && @disable_sax == 0 && (cb = @sax.reference)
              cb.call(@user_data, name)
            end
            return
          end
          return if @well_formed == 0

          if ent.name.nil? || ent.etype == INTERNAL_PREDEFINED_ENTITY
            val = ent.content
            return if val.nil?

            if @disable_sax == 0 && (cb = @sax.characters)
              cb.call(@user_data, val.dup)
            end
            return
          end

          ent.flags |= ENT_PARSED if (ent.flags & ENT_PARSED) == 0 && ent.children

          if ent.etype == INTERNAL_GENERAL_ENTITY ||
              (!option?(PARSE_NO_XXE) && (@replace_entities != 0 || @validate != 0))
            if (ent.flags & ENT_PARSED) == 0
              ctxt_parse_entity(ent)
            elsif ent.children.nil?
              ctxt_parse_entity(ent)
            end
          end

          return if parser_entity_check(ent.expanded_size) != 0
          return if @disable_sax != 0

          sax = @sax
          if @replace_entities == 0
            sax.reference&.call(@user_data, ent.name)
          elsif ent.children && @node
            cur = ent.children
            if cur.type == TEXT_NODE || cur.type == CDATA_SECTION_NODE
              if cur.type == TEXT_NODE || sax.cdata_block.nil?
                sax.characters&.call(self, cur.content.to_s.dup)
              else
                sax.cdata_block&.call(self, cur.content.to_s.dup)
              end
              cur = cur.next
            end
            while cur
              if cur.next.nil? && (cur.type == TEXT_NODE || cur.type == CDATA_SECTION_NODE)
                if cur.type == TEXT_NODE || sax.cdata_block.nil?
                  sax.characters&.call(self, cur.content.to_s.dup)
                else
                  sax.cdata_block&.call(self, cur.content.to_s.dup)
                end
                break
              end
              @nodemem = 0
              @nodelen = 0
              copy = Tree.doc_copy_node(cur, @my_doc, 1)
              if @parse_mode == 5 # XML_PARSE_READER
                copy.extra = cur.extra
                copy._private = cur._private
              end
              copy.parent = @node
              last = @node.last
              if last.nil?
                @node.children = copy
              else
                last.next = copy
                copy.prev = last
              end
              @node.last = copy
              cur = cur.next
            end
          end
        end

        # xmlHandleUndeclaredEntity
        def handle_undeclared_entity(name)
          if @standalone == 1 || (@has_external_subset == 0 && @has_pe_refs == 0)
            fatal_err_msg_str(ErrCode::ERR_UNDECLARED_ENTITY, "Entity '#{name}' not defined\n", name)
          elsif @validate != 0
            validity_error(ErrCode::ERR_UNDECLARED_ENTITY, "Entity '#{name}' not defined\n", name, nil)
          elsif @loadsubset != 0 || (@replace_entities != 0 && !option?(PARSE_NO_XXE))
            err_msg_str(ErrCode::WAR_UNDECLARED_ENTITY, "Entity '#{name}' not defined\n", name)
          else
            warning_msg(ErrCode::WAR_UNDECLARED_ENTITY, "Entity '#{name}' not defined\n", name, nil)
          end
          @valid = 0
        end

        # xmlLookupGeneralEntity
        def lookup_general_entity(name, in_attr)
          ent = nil
          unless option?(PARSE_OLDSAX)
            ent = Tree.get_predefined_entity(name)
            return ent if ent
          end
          if (sax = @sax)
            ent = sax.get_entity.call(@user_data, name) if sax.get_entity
            if @well_formed == 1 && ent.nil? && option?(PARSE_OLDSAX)
              ent = Tree.get_predefined_entity(name)
            end
            if @well_formed == 1 && ent.nil? && @user_data.equal?(self)
              ent = SAX2.get_entity(self, name)
            end
          end
          if ent.nil?
            handle_undeclared_entity(name)
          elsif ent.etype == EXTERNAL_GENERAL_UNPARSED_ENTITY
            fatal_err_msg_str(ErrCode::ERR_UNPARSED_ENTITY, "Entity reference to unparsed entity #{name}\n", name)
            ent = nil
          elsif ent.etype == EXTERNAL_GENERAL_PARSED_ENTITY && in_attr
            fatal_err_msg_str(ErrCode::ERR_ENTITY_IS_EXTERNAL,
              "Attribute references external entity '#{name}'\n", name)
            ent = nil
          end
          ent
        end

        # xmlParseEntityRefInternal
        def parse_entity_ref_internal
          grow
          return nil if cur_byte != 0x26

          next_char
          name = parse_name
          if name.nil?
            fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "xmlParseEntityRef: no name\n")
            return nil
          end
          if cur_byte != 0x3B
            fatal_err(ErrCode::ERR_ENTITYREF_SEMICOL_MISSING)
            return nil
          end
          next_char
          name
        end

        # xmlParseStringEntityRef: returns [name, newpos]
        def parse_string_entity_ref(s, pos)
          return [nil, pos] if s.getbyte(pos) != 0x26

          pos += 1
          name, pos = parse_string_name(s, pos)
          if name.nil?
            fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "xmlParseStringEntityRef: no name\n")
            return [nil, pos]
          end
          if s.getbyte(pos) != 0x3B
            fatal_err(ErrCode::ERR_ENTITYREF_SEMICOL_MISSING)
            return [nil, pos]
          end
          [name, pos + 1]
        end

        # xmlParsePEReference
        def parse_pe_reference
          return if cur_byte != 0x25

          next_char
          name = parse_name
          if name.nil?
            fatal_err_msg(ErrCode::ERR_PEREF_NO_NAME, "PEReference: no name\n")
            return
          end
          if cur_byte != 0x3B
            fatal_err(ErrCode::ERR_PEREF_SEMICOL_MISSING)
            return
          end
          next_char
          @has_pe_refs = 1
          entity = @sax.get_parameter_entity&.call(@user_data, name)
          if entity.nil?
            handle_undeclared_entity(name)
          elsif entity.etype != INTERNAL_PARAMETER_ENTITY && entity.etype != EXTERNAL_PARAMETER_ENTITY
            warning_msg(ErrCode::WAR_UNDECLARED_ENTITY, "Internal: %#{name}; is not a parameter entity\n", name, nil)
          else
            if entity.etype == EXTERNAL_PARAMETER_ENTITY &&
                (option?(PARSE_NO_XXE) || (@loadsubset == 0 && @replace_entities == 0 && @validate == 0))
              return
            end
            if (entity.flags & ENT_EXPANDING) != 0
              fatal_err(ErrCode::ERR_ENTITY_LOOP)
              halt
              return
            end
            input = new_entity_input_stream(entity)
            return if input.nil?
            return if push_input(input) < 0

            entity.flags |= ENT_EXPANDING
            if entity.etype == EXTERNAL_PARAMETER_ENTITY
              detect_encoding
              parse_text_decl if cmp?("<?xml") && Chars.blank?(nxt(5))
            end
          end
        end

        # xmlNewEntityInputStream
        def new_entity_input_stream(ent)
          if ent.content
            input = new_input_string(Ctxt.c_string(ent.content))
          elsif ent.uri
            input = Loader.load_external_entity(ent.uri, ent.external_id, self)
          else
            return nil
          end
          return nil if input.nil?

          input.entity = ent
          input
        end

        # xmlLoadEntityContent
        def load_entity_content(entity)
          if entity.nil? || (entity.etype != EXTERNAL_PARAMETER_ENTITY &&
              entity.etype != EXTERNAL_GENERAL_PARSED_ENTITY) || entity.content
            fatal_err(ErrCode::ERR_ARGUMENT, "xmlLoadEntityContent parameter error")
            return -1
          end
          input = Loader.load_external_entity(entity.uri, entity.external_id, self)
          return -1 if input.nil?

          saved_tab = @input_tab
          save_registers
          saved_input = @input
          saved_encoding = @encoding
          @input_tab = []
          @input = nil
          @encoding = nil
          ret = -1
          begin
            input_push(input)
            detect_encoding
            if cmp?("<?xml") && Chars.blank?(nxt(5))
              parse_text_decl
              if @version == "1.0" && @input.version != "1.0"
                fatal_err_msg(ErrCode::ERR_VERSION_MISMATCH, "Version mismatch between document and entity\n")
              end
            end
            length = @cur
            @sizeentities = [@sizeentities + length, ULONG_MAX].min
            content = @buf.byteslice(@cur, @end - @cur)
            if input.buf_error != 0 || input.pending_error
              err_io(input.pending_error || input.buf_error, nil)
            else
              invalid = content.each_char.find { |ch| !Chars.char?(ch.ord) }
              if invalid || (input.bad && input.bad.any? { |b| b[0] >= @cur })
                bad = input.bad&.find { |b| b[0] >= @cur }
                v = bad ? bad[1] : invalid.b.getbyte(0)
                fatal_err_msg_int(ErrCode::ERR_INVALID_CHAR, "xmlLoadEntityContent: invalid char value #{v}\n", v)
              else
                @sizeentities = [@sizeentities + content.bytesize, ULONG_MAX].min
                entity.content = content
                entity.length = content.bytesize
                ret = 0
              end
            end
          ensure
            @input_tab = saved_tab
            @input = saved_input
            @encoding = saved_encoding
            load_registers
          end
          ret
        end

        # xmlParseStringPEReference: returns [entity, newpos]
        def parse_string_pe_reference(s, pos)
          return [nil, pos] if s.getbyte(pos) != 0x25

          pos += 1
          name, pos = parse_string_name(s, pos)
          if name.nil?
            fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "xmlParseStringPEReference: no name\n")
            return [nil, pos]
          end
          if s.getbyte(pos) != 0x3B
            fatal_err(ErrCode::ERR_ENTITYREF_SEMICOL_MISSING)
            return [nil, pos]
          end
          pos += 1
          @has_pe_refs = 1
          entity = @sax.get_parameter_entity&.call(@user_data, name)
          if entity.nil?
            handle_undeclared_entity(name)
          elsif entity.etype != INTERNAL_PARAMETER_ENTITY && entity.etype != EXTERNAL_PARAMETER_ENTITY
            warning_msg(ErrCode::WAR_UNDECLARED_ENTITY, "%#{name}; is not a parameter entity\n", name, nil)
          end
          [entity, pos]
        end

        # ---- doctype -----------------------------------------------------------------------------------

        # xmlParseDocTypeDecl
        def parse_doctype_decl
          skip(9)
          skip_blanks
          name = parse_name
          if name.nil?
            fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "xmlParseDocTypeDecl : no DOCTYPE name !\n")
          end
          @int_sub_name = name
          skip_blanks
          uri, external_id = parse_external_id(true)
          @has_external_subset = 1 if uri || external_id
          @ext_sub_uri = uri
          @ext_sub_system = external_id
          skip_blanks
          if @disable_sax == 0 && (cb = @sax.internal_subset)
            cb.call(@user_data, name, external_id, uri)
          end
          return if cur_byte == 0x5B

          fatal_err(ErrCode::ERR_DOCTYPE_NOT_FINISHED) if cur_byte != 0x3E
          next_char
        end

        # xmlParseInternalSubset
        def parse_internal_subset
          if cur_byte == 0x5B
            old_input_nr = input_nr
            next_char
            skip_blanks
            while (cur_byte != 0x5D || input_nr > old_input_nr) && !stopped?
              if external? && cur_byte == 0x3C && nxt(1) == 0x21 && nxt(2) == 0x5B
                parse_conditional_sections
              elsif cur_byte == 0x3C && (nxt(1) == 0x21 || nxt(1) == 0x3F)
                parse_markup_decl
              elsif cur_byte == 0x25
                parse_pe_reference
              else
                fatal_err(ErrCode::ERR_INT_SUBSET_NOT_FINISHED)
                break
              end
              skip_blank_chars_pe
              grow
            end
            pop_pe while input_nr > old_input_nr
            if cur_byte == 0x5D
              next_char
              skip_blanks
            end
          end
          if @well_formed != 0 && cur_byte != 0x3E
            fatal_err(ErrCode::ERR_DOCTYPE_NOT_FINISHED)
            return
          end
          next_char
        end
      end
    end
  end
end
