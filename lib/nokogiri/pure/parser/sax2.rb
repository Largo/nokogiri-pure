# frozen_string_literal: true

module Nokogiri
  module Pure
    module Parser
      # xmlSAXHandler: every field is nil or a callable receiving (user_data, ...), like the C
      # function pointers. Identity comparisons (sax.ignorable_whitespace == sax.characters) work
      # because the default SAX2 callbacks are shared Method objects.
      class SAXHandler
        FIELDS = %i[internal_subset is_standalone has_internal_subset has_external_subset resolve_entity
          get_entity entity_decl notation_decl attribute_decl element_decl unparsed_entity_decl
          set_document_locator start_document end_document start_element end_element reference characters
          ignorable_whitespace processing_instruction comment warning error fatal_error get_parameter_entity
          cdata_block external_subset initialized start_element_ns end_element_ns serror].freeze
        attr_accessor(*FIELDS)

        def initialize
          @initialized = 0
        end
      end

      # SAX2.c: the default tree-building SAX handler
      module SAX2
        XML_SAX2_MAGIC = 0xDEEDBEAF

        module_function

        def default_handler
          h = SAXHandler.new
          sax_version(h, 2)
          h
        end

        # xmlSAXVersion
        def sax_version(h, version)
          if version == 2
            h.start_element_ns = START_ELEMENT_NS
            h.end_element_ns = END_ELEMENT_NS
            h.serror = nil
            h.initialized = XML_SAX2_MAGIC
          else
            h.initialized = 1
          end
          h.start_element = START_ELEMENT
          h.end_element = END_ELEMENT
          h.internal_subset = INTERNAL_SUBSET
          h.external_subset = EXTERNAL_SUBSET
          h.is_standalone = IS_STANDALONE
          h.has_internal_subset = HAS_INTERNAL_SUBSET
          h.has_external_subset = HAS_EXTERNAL_SUBSET
          h.resolve_entity = RESOLVE_ENTITY
          h.get_entity = GET_ENTITY
          h.get_parameter_entity = GET_PARAMETER_ENTITY
          h.entity_decl = ENTITY_DECL
          h.attribute_decl = ATTRIBUTE_DECL
          h.element_decl = ELEMENT_DECL
          h.notation_decl = NOTATION_DECL
          h.unparsed_entity_decl = UNPARSED_ENTITY_DECL
          h.set_document_locator = SET_DOCUMENT_LOCATOR
          h.start_document = START_DOCUMENT
          h.end_document = END_DOCUMENT
          h.reference = REFERENCE
          h.characters = CHARACTERS
          h.cdata_block = CDATA_BLOCK
          h.ignorable_whitespace = CHARACTERS
          h.processing_instruction = PROCESSING_INSTRUCTION
          h.comment = COMMENT
          h.warning = nil
          h.error = nil
          h.fatal_error = nil
          0
        end

        def is_standalone(ctxt)
          ctxt.my_doc && ctxt.my_doc.standalone == 1 ? 1 : 0
        end

        def has_internal_subset(ctxt)
          ctxt.my_doc&.int_subset ? 1 : 0
        end

        def has_external_subset(ctxt)
          ctxt.my_doc&.ext_subset ? 1 : 0
        end

        # xmlSAX2InternalSubset
        def internal_subset(ctxt, name, external_id, system_id)
          doc = ctxt.my_doc
          return if doc.nil?

          dtd = Tree.get_int_subset(doc)
          if dtd
            return if ctxt.html != 0

            Tree.unlink_node(dtd)
            doc.int_subset = nil
          end
          doc.int_subset = Tree.create_int_subset(doc, name, external_id, system_id)
        end

        # xmlSAX2ExternalSubset
        def external_subset(ctxt, name, external_id, system_id)
          return unless system_id && !ctxt.option?(PARSE_NO_XXE) &&
            (ctxt.validate != 0 || ctxt.loadsubset != 0) && ctxt.well_formed != 0 && ctxt.my_doc

          input = ctxt.sax.resolve_entity&.call(ctxt.user_data, external_id, system_id)
          return if input.nil?

          dtd = Tree.new_dtd(ctxt.my_doc, name, external_id, system_id)
          return if dtd.nil?

          ctxt.with_fresh_input_stack do
            ctxt.push_input(input)
            input.filename ||= Loader.canonic_path(system_id)
            input.line = 1
            input.col = 1
            ctxt.parse_external_subset(external_id, system_id)
            ctxt.pop_input while ctxt.input_nr > 1
            consumed = ctxt.input.consumed + ctxt.current_pos
            ctxt.sizeentities = [ctxt.sizeentities + consumed, ULONG_MAX].min
          end
        end

        # xmlSAX2ResolveEntity
        def resolve_entity(ctxt, public_id, system_id)
          uri = nil
          if system_id
            base = ctxt.input&.filename
            base ||= ctxt.directory
            if system_id.bytesize > XML_MAX_URI_LENGTH || (base && base.bytesize > XML_MAX_URI_LENGTH)
              ctxt.fatal_err(ErrCode::ERR_RESOURCE_LIMIT, "URI too long")
              return nil
            end
            uri = URIParser.build_uri(system_id, base)
            if uri.nil?
              ctxt.ctxt_err(nil, Domain::PARSER, ErrCode::ERR_INVALID_URI, Level::WARNING, system_id, nil, nil, 0,
                "Can't resolve URI: #{system_id}\n")
              return nil
            end
            if uri.bytesize > XML_MAX_URI_LENGTH
              ctxt.fatal_err(ErrCode::ERR_RESOURCE_LIMIT, "URI too long")
              return nil
            end
          end
          Loader.load_external_entity(uri, public_id, ctxt)
        end

        # xmlSAX2GetEntity
        def get_entity(ctxt, name)
          if ctxt.in_subset == 0
            ret = Tree.get_predefined_entity(name)
            return ret if ret
          end
          doc = ctxt.my_doc
          if doc && doc.standalone == 1
            if ctxt.in_subset == 2
              doc.standalone = 0
              ret = Tree.get_doc_entity(doc, name)
              doc.standalone = 1
            else
              ret = Tree.get_doc_entity(doc, name)
              if ret.nil?
                doc.standalone = 0
                ret = Tree.get_doc_entity(doc, name)
                if ret
                  ctxt.ctxt_err(nil, Domain::PARSER, ErrCode::ERR_NOT_STANDALONE, Level::FATAL, name, nil, nil, 0,
                    "Entity(#{name}) document marked standalone but requires external subset\n")
                end
                doc.standalone = 1
              end
            end
          else
            ret = doc ? Tree.get_doc_entity(doc, name) : Tree.get_predefined_entity(name)
          end
          ret
        end

        # xmlSAX2GetParameterEntity
        def get_parameter_entity(ctxt, name)
          Tree.get_parameter_entity(ctxt.my_doc, name)
        end

        def warn_msg(ctxt, code, msg, str1)
          ctxt.ctxt_err(nil, Domain::PARSER, code, Level::WARNING, str1, nil, nil, 0, msg)
        end

        # xmlSAX2EntityDecl
        def entity_decl(ctxt, name, type, public_id, system_id, content)
          doc = ctxt.my_doc
          return if doc.nil?

          ext_subset = ctxt.in_subset == 2
          res, ent = Tree.add_entity(doc, ext_subset, name, type, public_id, system_id, content)
          case res
          when nil
            nil
          when :entity_redefined
            if ctxt.pedantic != 0
              where = ext_subset ? "external" : "internal"
              warn_msg(ctxt, ErrCode::WAR_ENTITY_REDEFINED, "Entity(#{name}) already defined in the #{where} subset\n",
                name)
            end
            return
          when :redecl_predef_entity
            warn_msg(ctxt, ErrCode::ERR_REDECL_PREDEF_ENTITY, "Invalid redeclaration of predefined entity '#{name}'",
              name)
            return
          else
            return
          end
          if ent.uri.nil? && system_id
            base = nil
            ctxt.input_tab.reverse_each do |inp|
              if inp.filename
                base = inp.filename
                break
              end
            end
            base ||= ctxt.directory
            uri = URIParser.build_uri(system_id, base)
            if uri.nil?
              warn_msg(ctxt, ErrCode::ERR_INVALID_URI, "Can't resolve URI: #{system_id}\n", system_id)
            elsif uri.bytesize > XML_MAX_URI_LENGTH
              ctxt.fatal_err(ErrCode::ERR_RESOURCE_LIMIT, "URI too long")
            else
              ent.uri = uri
            end
          end
        end

        # xmlSAX2AttributeDecl
        def attribute_decl(ctxt, elem, fullname, type, defv, default_value, tree)
          doc = ctxt.my_doc
          return if doc.nil?

          if fullname == "xml:id" && type != ATTRIBUTE_ID
            tmp = ctxt.valid
            ctxt.ctxt_err(nil, Domain::DTD, ErrCode::DTD_XMLID_TYPE, Level::ERROR, nil, nil, nil, 0,
              "xml:id : attribute type should be ID\n")
            ctxt.valid = tmp
          end
          name, prefix = split_qname(ctxt, fullname)
          ctxt.vctxt.valid = 1
          if ctxt.in_subset == 1
            attr = Valid.add_attribute_decl(ctxt.vctxt, doc.int_subset, elem, name, prefix, type, defv,
              default_value, tree)
          elsif ctxt.in_subset == 2
            attr = Valid.add_attribute_decl(ctxt.vctxt, doc.ext_subset, elem, name, prefix, type, defv,
              default_value, tree)
          else
            ctxt.ctxt_err(nil, Domain::PARSER, ErrCode::ERR_INTERNAL_ERROR, Level::FATAL, name, nil, nil, 0,
              "SAX.xmlSAX2AttributeDecl(#{name}) called while not in subset\n")
            return
          end
          ctxt.valid = 0 if ctxt.vctxt.valid == 0
          if attr && ctxt.validate != 0 && ctxt.well_formed != 0 && doc.int_subset
            ctxt.valid &= Valid.validate_attribute_decl(ctxt.vctxt, doc, attr)
          end
        end

        # xmlSAX2ElementDecl
        def element_decl(ctxt, name, type, content)
          doc = ctxt.my_doc
          return if doc.nil?

          if ctxt.in_subset == 1
            elem = Valid.add_element_decl(ctxt.vctxt, doc.int_subset, name, type, content)
          elsif ctxt.in_subset == 2
            elem = Valid.add_element_decl(ctxt.vctxt, doc.ext_subset, name, type, content)
          else
            ctxt.ctxt_err(nil, Domain::PARSER, ErrCode::ERR_INTERNAL_ERROR, Level::FATAL, name, nil, nil, 0,
              "SAX.xmlSAX2ElementDecl(#{name}) called while not in subset\n")
            return
          end
          ctxt.valid = 0 if elem.nil?
          if ctxt.validate != 0 && ctxt.well_formed != 0 && doc.int_subset
            ctxt.valid &= Valid.validate_element_decl(ctxt.vctxt, doc, elem)
          end
        end

        # xmlSAX2NotationDecl
        def notation_decl(ctxt, name, public_id, system_id)
          doc = ctxt.my_doc
          return if doc.nil?

          if public_id.nil? && system_id.nil?
            ctxt.ctxt_err(nil, Domain::PARSER, ErrCode::ERR_NOTATION_PROCESSING, Level::FATAL, name, nil, nil, 0,
              "SAX.xmlSAX2NotationDecl(#{name}) externalID or PublicID missing\n")
            return
          elsif ctxt.in_subset == 1
            nota = Valid.add_notation_decl(ctxt.vctxt, doc.int_subset, name, public_id, system_id)
          elsif ctxt.in_subset == 2
            nota = Valid.add_notation_decl(ctxt.vctxt, doc.ext_subset, name, public_id, system_id)
          else
            ctxt.ctxt_err(nil, Domain::PARSER, ErrCode::ERR_NOTATION_PROCESSING, Level::FATAL, name, nil, nil, 0,
              "SAX.xmlSAX2NotationDecl(#{name}) called while not in subset\n")
            return
          end
          ctxt.valid = 0 if nota.nil?
          if ctxt.validate != 0 && ctxt.well_formed != 0 && doc.int_subset
            ctxt.valid &= Valid.validate_notation_decl(ctxt.vctxt, doc, nota)
          end
        end

        # xmlSAX2UnparsedEntityDecl
        def unparsed_entity_decl(ctxt, name, public_id, system_id, notation_name)
          entity_decl(ctxt, name, EXTERNAL_GENERAL_UNPARSED_ENTITY, public_id, system_id, notation_name)
        end

        def set_document_locator(_ctxt, _loc); end

        # xmlSAX2StartDocument
        def start_document(ctxt)
          if ctxt.html != 0
            ctxt.my_doc ||= Tree.new_html_doc
            ctxt.my_doc.parse_flags = ctxt.options
          else
            doc = ctxt.my_doc = Tree.new_doc(ctxt.version)
            doc.doc_properties = 0
            doc.doc_properties |= 8 if ctxt.option?(PARSE_OLD10)
            doc.parse_flags = ctxt.options
            doc.standalone = ctxt.standalone
          end
          if ctxt.my_doc && ctxt.my_doc.url.nil? && ctxt.input && ctxt.input.filename
            ctxt.my_doc.url = Loader.path_to_uri(ctxt.input.filename)
          end
        end

        # xmlSAX2EndDocument
        def end_document(ctxt)
          doc = ctxt.my_doc
          if ctxt.validate != 0 && ctxt.well_formed != 0 && doc && doc.int_subset
            ctxt.valid &= Valid.validate_document_final(ctxt.vctxt, doc)
          end
          if doc && doc.encoding.nil?
            enc = ctxt.actual_encoding
            doc.encoding = enc.dup if enc
          end
        end

        # xmlSAX2AppendChild
        def append_child(ctxt, node)
          ctxt.sax2_append_child(node)
        end

        # xmlSplitQName (SAX1): returns [name, prefix]
        def split_qname(ctxt, name)
          return [name, nil] if name.start_with?(":")

          idx = name.index(":")
          return [name, nil] if idx.nil?
          return [name, nil] if idx == name.length - 1 && false

          prefix = name[0, idx]
          rest = name[(idx + 1)..]
          if rest.empty?
            # "a:" -> whole name
            return [name, nil]
          end

          c = rest.ord
          unless (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x5F || c == 0x3A
            unless Chars.letter?(c) || c == 0x5F
              ctxt.fatal_err_msg_str(ErrCode::NS_ERR_QNAME, "Name #{name} is not XML Namespace compliant\n", name)
            end
          end
          [rest, prefix]
        end

        # ---- SAX1 element handling ---------------------------------------------------------------

        # xmlSAX2AttributeInternal
        def attribute_internal(ctxt, fullname, value, _prefix)
          if ctxt.html != 0
            name = fullname.dup
            ns = nil
          else
            name, ns = split_qname(ctxt, fullname)
            if name.empty? || (ns && name.empty?)
              if ns == "xmlns"
                ctxt.ctxt_err(nil, Domain::NAMESPACE, ErrCode::ERR_NS_DECL_ERROR, Level::ERROR, fullname, nil, nil, 0,
                  "invalid namespace declaration '#{fullname}'\n")
              else
                ctxt.ctxt_err(nil, Domain::NAMESPACE, ErrCode::WAR_NS_COLUMN, Level::WARNING, fullname, nil, nil, 0,
                  "Avoid attribute ending with ':' like '#{fullname}'\n")
              end
              ns = nil
              name = fullname.dup
            end
          end
          nval = nil
          ctxt.vctxt.valid = 1
          nval = Valid.ctxt_normalize_attribute_value(ctxt.vctxt, ctxt.my_doc, ctxt.node, fullname, value)
          ctxt.valid = 0 if ctxt.vctxt.valid != 1
          value = nval if nval

          if ctxt.html == 0 && ns.nil? && name == "xmlns"
            val = ctxt.replace_entities == 0 ? ctxt.expand_entities_in_att_value(value, false) : value
            return if val.nil?

            unless val.empty?
              uri = URIParser.parse(val)
              if uri.nil?
                ctxt.ctxt_err(nil, Domain::NAMESPACE, ErrCode::WAR_NS_URI, Level::WARNING, name, value, nil, 0,
                  "xmlns:#{name}: #{value} not a valid URI\n")
              elsif uri.scheme.nil?
                ctxt.ctxt_err(nil, Domain::NAMESPACE, ErrCode::WAR_NS_URI_RELATIVE, Level::WARNING, name, value, nil, 0,
                  "xmlns:#{name}: URI #{value} is not absolute\n")
              end
            end
            nsret = Tree.new_ns(ctxt.node, val, nil)
            if nsret && ctxt.validate != 0 && ctxt.well_formed != 0 && ctxt.my_doc&.int_subset
              ctxt.valid &= Valid.validate_one_namespace(ctxt.vctxt, ctxt.my_doc, ctxt.node, nil, nsret, val)
            end
            return
          end
          if ctxt.html == 0 && ns == "xmlns"
            val = ctxt.replace_entities == 0 ? ctxt.expand_entities_in_att_value(value, false) : value
            return if val.nil?

            if val.empty?
              ctxt.ctxt_err(nil, Domain::NAMESPACE, ErrCode::NS_ERR_EMPTY, Level::ERROR, name, nil, nil, 0,
                "Empty namespace name for prefix #{name}\n")
            end
            if ctxt.pedantic != 0 && !val.empty?
              uri = URIParser.parse(val)
              if uri.nil?
                ctxt.ctxt_err(nil, Domain::NAMESPACE, ErrCode::WAR_NS_URI, Level::WARNING, name, value, nil, 0,
                  "xmlns:#{name}: #{value} not a valid URI\n")
              elsif uri.scheme.nil?
                ctxt.ctxt_err(nil, Domain::NAMESPACE, ErrCode::WAR_NS_URI_RELATIVE, Level::WARNING, name, value, nil, 0,
                  "xmlns:#{name}: URI #{value} is not absolute\n")
              end
            end
            nsret = Tree.new_ns(ctxt.node, val, name)
            if nsret && ctxt.validate != 0 && ctxt.well_formed != 0 && ctxt.my_doc&.int_subset
              ctxt.valid &= Valid.validate_one_namespace(ctxt.vctxt, ctxt.my_doc, ctxt.node, nil, nsret, value)
            end
            return
          end

          namespace = nil
          if ns
            namespace = Tree.search_ns(ctxt.my_doc, ctxt.node, ns)
            if namespace.nil?
              ctxt.ctxt_err(nil, Domain::NAMESPACE, ErrCode::NS_ERR_UNDEFINED_NAMESPACE, Level::ERROR, ns, name, nil, 0,
                "Namespace prefix #{ns} of attribute #{name} is not defined\n")
            else
              prop = ctxt.node.properties
              while prop
                if prop.ns && name == prop.name && (namespace.equal?(prop.ns) || namespace.href == prop.ns.href)
                  ctxt.ctxt_err(nil, Domain::PARSER, ErrCode::ERR_ATTRIBUTE_REDEFINED, Level::FATAL, name, nil, nil, 0,
                    "Attribute #{name} in #{namespace.href} redefined\n")
                  return
                end
                prop = prop.next
              end
            end
          end

          ret = Tree.new_ns_prop(ctxt.node, namespace, name, nil)
          if ctxt.replace_entities == 0 && ctxt.html == 0
            Tree.node_parse_content(ret, value) if value
          elsif value
            t = Tree.new_doc_text(ctxt.my_doc, value)
            ret.children = ret.last = t
            t.parent = ret
          end

          if ctxt.html == 0 && ctxt.validate != 0 && ctxt.well_formed != 0 && ctxt.my_doc&.int_subset
            if ctxt.replace_entities == 0
              val = ctxt.expand_entities_in_att_value(value, false)
              if val.nil?
                ctxt.valid &= Valid.validate_one_attribute(ctxt.vctxt, ctxt.my_doc, ctxt.node, ret, value)
              else
                nvalnorm = Valid.ctxt_normalize_attribute_value(ctxt.vctxt, ctxt.my_doc, ctxt.node, fullname, val)
                val = nvalnorm if nvalnorm
                ctxt.valid &= Valid.validate_one_attribute(ctxt.vctxt, ctxt.my_doc, ctxt.node, ret, val)
              end
            else
              ctxt.vctxt.flags |= ValidCtxt::XML_VCTXT_IN_ENTITY if ctxt.input.entity
              ctxt.valid &= Valid.validate_one_attribute(ctxt.vctxt, ctxt.my_doc, ctxt.node, ret, value)
              ctxt.vctxt.flags &= ~ValidCtxt::XML_VCTXT_IN_ENTITY
            end
          elsif (ctxt.loadsubset & XML_SKIP_IDS) == 0 && ctxt.input.entity.nil? &&
              ret.children && ret.children.type == TEXT_NODE && ret.children.next.nil?
            content = ret.children.content
            if fullname == "xml:id"
              if Valid.validate_ncname(content, true) != 0
                ctxt.ctxt_err(nil, Domain::DTD, ErrCode::DTD_XMLID_VALUE, Level::ERROR, content, nil, nil, 0,
                  "xml:id : attribute value #{content} is not an NCName\n")
                ctxt.valid = 0
              end
              Valid.add_id(ctxt.vctxt, ctxt.my_doc, content, ret)
            elsif Tree.is_id(ctxt.my_doc, ctxt.node, ret)
              Valid.add_id(ctxt.vctxt, ctxt.my_doc, content, ret)
            elsif Valid.is_ref(ctxt.my_doc, ctxt.node, ret)
              Valid.add_ref(ctxt.vctxt, ctxt.my_doc, content, ret)
            end
          end
        end

        # xmlCheckDefaultedAttributes
        def check_defaulted_attributes(ctxt, name, prefix, atts)
          doc = ctxt.my_doc
          elem_decl = Tree.get_dtd_q_element_desc(doc.int_subset, name, prefix)
          internal = true
          if elem_decl.nil?
            elem_decl = Tree.get_dtd_q_element_desc(doc.ext_subset, name, prefix)
            internal = false
          end
          loop do
            if elem_decl
              attr = elem_decl.attributes
              if doc.standalone == 1 && doc.ext_subset && ctxt.validate != 0
                while attr
                  if attr.default_value &&
                      Tree.get_dtd_q_attr_desc(doc.ext_subset, attr.elem, attr.name, attr.prefix).equal?(attr) &&
                      Tree.get_dtd_q_attr_desc(doc.int_subset, attr.elem, attr.name, attr.prefix).nil?
                    fulln = attr.prefix ? "#{attr.prefix}:#{attr.name}" : attr.name
                    found = atts && atts.each_slice(2).any? { |n, _| n == fulln }
                    unless found
                      ctxt.ctxt_err(nil, Domain::DTD, ErrCode::DTD_STANDALONE_DEFAULTED, Level::ERROR, fulln, attr.elem,
                        nil, 0, "standalone: attribute #{fulln} on #{attr.elem} defaulted from external subset\n")
                      ctxt.valid = 0
                    end
                  end
                  attr = attr.nexth
                end
              end
              attr = elem_decl.attributes
              while attr
                if attr.default_value &&
                    ((attr.prefix && attr.prefix == "xmlns") || (attr.prefix.nil? && attr.name == "xmlns") ||
                     (ctxt.loadsubset & XML_COMPLETE_ATTRS) != 0)
                  tst = Tree.get_dtd_q_attr_desc(doc.int_subset, attr.elem, attr.name, attr.prefix)
                  if tst.equal?(attr) || tst.nil?
                    fulln = attr.prefix ? "#{attr.prefix}:#{attr.name}" : attr.name
                    found = atts && atts.each_slice(2).any? { |n, _| n == fulln }
                    attribute_internal(ctxt, fulln, attr.default_value, prefix) unless found
                  end
                end
                attr = attr.nexth
              end
            end
            break unless internal

            elem_decl = Tree.get_dtd_q_element_desc(doc.ext_subset, name, prefix)
            internal = false
          end
        end

        # xmlSAX2StartElement (SAX1)
        def start_element(ctxt, fullname, atts)
          doc = ctxt.my_doc
          return if fullname.nil? || doc.nil?

          if ctxt.validate != 0 && doc.ext_subset.nil? &&
              (doc.int_subset.nil? || (doc.int_subset.notations.nil? && doc.int_subset.elements.nil? &&
                doc.int_subset.attributes.nil? && doc.int_subset.entities.nil?))
            ctxt.ctxt_err(nil, Domain::DTD, ErrCode::ERR_NO_DTD, Level::ERROR, nil, nil, nil, 0,
              "Validation failed: no DTD found !")
            ctxt.valid = 0
            ctxt.validate = 0
          end
          if ctxt.html != 0
            prefix = nil
            name = fullname.dup
          else
            name, prefix = split_qname(ctxt, fullname)
          end
          ret = Tree.new_doc_node(doc, nil, name, nil)
          ctxt.nodemem = -1
          parent = ctxt.node || doc
          append_child(ctxt, ret)
          if ctxt.node_push(ret) < 0
            Tree.unlink_node(ret)
            return
          end
          if ctxt.html == 0
            check_defaulted_attributes(ctxt, name, prefix, atts) if doc.int_subset || doc.ext_subset
            atts&.each_slice(2) do |att, value|
              break if att.nil? || value.nil?

              attribute_internal(ctxt, att, value, prefix) if att.start_with?("xmlns")
            end
            ns = Tree.search_ns(doc, ret, prefix)
            ns = Tree.search_ns(doc, parent, prefix) if ns.nil? && parent
            if prefix && ns.nil?
              ctxt.ctxt_err(nil, Domain::NAMESPACE, ErrCode::NS_ERR_UNDEFINED_NAMESPACE, Level::WARNING, prefix, nil,
                nil, 0, "Namespace prefix #{prefix} is not defined\n")
              ns = Tree.new_ns(ret, nil, prefix)
            end
            if ns && ns.href && (!ns.href.empty? || ns.prefix)
              Tree.set_ns(ret, ns)
            end
          end
          if atts
            if ctxt.html != 0
              atts.each_slice(2) { |att, value| attribute_internal(ctxt, att, value, nil) if att }
            else
              atts.each_slice(2) do |att, value|
                break if att.nil? || value.nil?

                attribute_internal(ctxt, att, value, nil) unless att.start_with?("xmlns")
              end
            end
          end
          if ctxt.validate != 0 && (ctxt.vctxt.flags & ValidCtxt::XML_VCTXT_DTD_VALIDATED) == 0
            chk = Valid.validate_dtd_final(ctxt.vctxt, doc)
            ctxt.valid = 0 if chk <= 0
            ctxt.well_formed = 0 if chk < 0
            ctxt.valid &= Valid.validate_root(ctxt.vctxt, doc)
            ctxt.vctxt.flags |= ValidCtxt::XML_VCTXT_DTD_VALIDATED
          end
        end

        # xmlSAX2EndElement (SAX1)
        def end_element(ctxt, _name)
          ctxt.nodemem = -1
          if ctxt.validate != 0 && ctxt.well_formed != 0 && ctxt.my_doc&.int_subset
            ctxt.valid &= Valid.validate_one_element(ctxt.vctxt, ctxt.my_doc, ctxt.node)
          end
          ctxt.node_pop
        end

        # ---- SAX2 elements -------------------------------------------------------------------------

        # xmlSAX2TextNode
        def text_node(_ctxt, str)
          t = XmlNode.new(TEXT_NODE, STRING_TEXT, nil)
          t.content = +str
          t
        end

        # xmlSAX2AttributeNs
        def attribute_ns(ctxt, localname, prefix, value, alloc)
          ctxt.sax2_attribute_ns(localname, prefix, value, alloc)
        end

        # xmlSAX2StartElementNs
        def start_element_ns(ctxt, localname, prefix, uri, nb_namespaces, namespaces, nb_attributes, nb_defaulted,
          attributes)
          ctxt.sax2_start_element_ns(localname, prefix, uri, nb_namespaces, namespaces, nb_attributes, nb_defaulted,
            attributes)
        end

        # xmlSAX2EndElementNs
        def end_element_ns(ctxt, _localname, _prefix, _uri)
          ctxt.sax2_end_element_ns
        end

        # xmlSAX2Reference
        def reference(ctxt, name)
          ret = Tree.new_reference(ctxt.my_doc, name)
          append_child(ctxt, ret)
        end

        # xmlSAX2Text
        def text(ctxt, ch, type)
          ctxt.sax2_text(ch, type)
        end

        def characters(ctxt, ch)
          ctxt.sax2_text(ch, TEXT_NODE)
        end

        def ignorable_whitespace(_ctxt, _ch); end

        # xmlSAX2ProcessingInstruction
        def processing_instruction(ctxt, target, data)
          ret = Tree.new_doc_pi(ctxt.my_doc, target, data)
          append_child(ctxt, ret)
        end

        # xmlSAX2Comment
        def comment(ctxt, value)
          ret = Tree.new_doc_comment(ctxt.my_doc, value)
          append_child(ctxt, ret)
        end

        # xmlSAX2CDataBlock
        def cdata_block(ctxt, value)
          ctxt.sax2_text(value, CDATA_SECTION_NODE)
        end

        START_ELEMENT_NS = method(:start_element_ns)
        END_ELEMENT_NS = method(:end_element_ns)
        START_ELEMENT = method(:start_element)
        END_ELEMENT = method(:end_element)
        INTERNAL_SUBSET = method(:internal_subset)
        EXTERNAL_SUBSET = method(:external_subset)
        IS_STANDALONE = method(:is_standalone)
        HAS_INTERNAL_SUBSET = method(:has_internal_subset)
        HAS_EXTERNAL_SUBSET = method(:has_external_subset)
        RESOLVE_ENTITY = method(:resolve_entity)
        GET_ENTITY = method(:get_entity)
        GET_PARAMETER_ENTITY = method(:get_parameter_entity)
        ENTITY_DECL = method(:entity_decl)
        ATTRIBUTE_DECL = method(:attribute_decl)
        ELEMENT_DECL = method(:element_decl)
        NOTATION_DECL = method(:notation_decl)
        UNPARSED_ENTITY_DECL = method(:unparsed_entity_decl)
        SET_DOCUMENT_LOCATOR = method(:set_document_locator)
        START_DOCUMENT = method(:start_document)
        END_DOCUMENT = method(:end_document)
        REFERENCE = method(:reference)
        CHARACTERS = method(:characters)
        CDATA_BLOCK = method(:cdata_block)
        IGNORABLE_WHITESPACE = method(:ignorable_whitespace)
        PROCESSING_INSTRUCTION = method(:processing_instruction)
        COMMENT = method(:comment)
      end

      # The hot SAX2.c tree-building callbacks as parser-context methods (direct ivar access); the
      # SAX2 module functions above delegate here.
      class Ctxt
        # a '&' that does not start "&#38;", or a NUL
        NOT_AMP38_RE = /&(?!#38;)|\0/

        # xmlSAX2AppendChild
        def sax2_append_child(node)
          parent = if @in_subset == 1
            @my_doc.int_subset
          elsif @in_subset == 2
            @my_doc.ext_subset
          else
            @node || @my_doc
          end
          last = parent.last
          if last.nil?
            parent.children = node
          else
            last.next = node
            node.prev = last
          end
          parent.last = node
          node.parent = parent
          if node.type != TEXT_NODE && @linenumbers != 0 && @input
            line = @line
            node.line = line < 65_535 ? line : 65_535
          end
        end

        # xmlSAX2AttributeNs
        def sax2_attribute_ns(localname, prefix, value, alloc)
          node = @node
          namespace = nil
          if prefix
            if prefix == "xml"
              # (xmlParserNsLookupSax returns NULL for "xml")
              namespace = Tree.search_ns(node.doc, node, prefix)
            else
              idx = @ns_hash.fetch(prefix, INT_MAX)
              namespace = idx == INT_MAX || idx < @min_ns_index ? nil : @ns_extra[idx][0]
            end
          end
          ret = XmlAttr.new(localname, node.doc)
          ret.parent = node
          ret.ns = namespace
          if @replace_entities == 0 && @html == 0
            if alloc != true
              tmp = XmlNode.new(TEXT_NODE, STRING_TEXT, ret.doc)
              tmp.content = +value
              ret.children = ret.last = tmp
              tmp.parent = ret
            elsif !value.empty?
              if value.match?(NOT_AMP38_RE)
                Tree.node_parse_content(ret, value)
              else
                # only "&#38;" references (how the parser keeps '&' in values) and no NUL: what
                # xmlNodeParseContent makes of it is one text node with those turned into '&'
                tmp = XmlNode.new(TEXT_NODE, STRING_TEXT, ret.doc)
                tmp.content = value.include?("&") ? value.gsub("&#38;", "&") : value.dup
                ret.children = ret.last = tmp
                tmp.parent = ret
              end
            end
          elsif value
            tmp = XmlNode.new(TEXT_NODE, STRING_TEXT, ret.doc)
            tmp.content = +value
            ret.children = ret.last = tmp
            tmp.parent = ret
          end

          doc = @my_doc
          if @html == 0 && @validate != 0 && @well_formed != 0 && doc && doc.int_subset
            if @replace_entities == 0
              dup = value.include?("&") ? expand_entities_in_att_value(value, false) : nil
              if dup.nil?
                @valid &= Valid.validate_one_attribute(@vctxt, doc, node, ret, value)
              else
                if @atts_special
                  fullname = prefix ? "#{prefix}:#{localname}" : localname
                  @vctxt.valid = 1
                  nvalnorm = Valid.ctxt_normalize_attribute_value(@vctxt, doc, node, fullname, dup)
                  @valid = 0 if @vctxt.valid != 1
                  dup = nvalnorm if nvalnorm
                end
                @valid &= Valid.validate_one_attribute(@vctxt, doc, node, ret, dup)
              end
            else
              @vctxt.flags |= ValidCtxt::XML_VCTXT_IN_ENTITY if @input.entity
              @valid &= Valid.validate_one_attribute(@vctxt, doc, node, ret, value.dup)
              @vctxt.flags &= ~ValidCtxt::XML_VCTXT_IN_ENTITY
            end
          elsif (@loadsubset & XML_SKIP_IDS) == 0 && @input.entity.nil? &&
              (child = ret.children) && child.type == TEXT_NODE && child.next.nil?
            if prefix == "xml" && localname == "id"
              content = child.content
              if Valid.validate_ncname(content, true) != 0
                ctxt_err(nil, Domain::DTD, ErrCode::DTD_XMLID_VALUE, Level::ERROR, content, nil, nil, 0,
                  "xml:id : attribute value #{content} is not an NCName\n")
                @valid = 0
              end
              Valid.add_id(@vctxt, doc, content, ret)
            elsif doc.nil? || doc.int_subset || doc.ext_subset || doc.type == HTML_DOCUMENT_NODE
              # (without a DTD, in an XML document, an attribute other than xml:id is neither an
              # ID nor a reference: xmlIsID/xmlIsRef would return 0)
              content = child.content
              if Tree.is_id(doc, node, ret)
                Valid.add_id(@vctxt, doc, content, ret)
              elsif Valid.is_ref(doc, node, ret)
                Valid.add_ref(@vctxt, doc, content, ret)
              end
            end
          end
          ret
        end

        # xmlSAX2StartElementNs
        def sax2_start_element_ns(localname, prefix, uri, nb_namespaces, namespaces, nb_attributes, nb_defaulted,
          attributes)
          doc = @my_doc
          if @validate != 0 && doc.ext_subset.nil? &&
              (doc.int_subset.nil? || (doc.int_subset.notations.nil? && doc.int_subset.elements.nil? &&
                doc.int_subset.attributes.nil? && doc.int_subset.entities.nil?))
            ctxt_err(nil, Domain::DTD, ErrCode::DTD_NO_DTD, Level::ERROR, nil, nil, nil, 0,
              "Validation failed: no DTD found !")
            @valid = 0
            @validate = 0
          end
          localname = -"#{prefix}:#{localname}" if prefix && uri.nil?
          ret = XmlNode.new(ELEMENT_NODE, localname, doc)
          if nb_namespaces > 0
            last = nil
            i = 0
            while i < nb_namespaces
              pref, nsuri = namespaces[i]
              ns = XmlNs.new(nsuri, pref)
              if last.nil?
                ret.ns_def = last = ns
              else
                last.next = ns
                last = ns
              end
              ret.ns = ns if uri && prefix == pref
              ns_update_sax(pref, ns)
              if @html == 0 && @validate != 0 && @well_formed != 0 && doc&.int_subset
                @valid &= Valid.validate_one_namespace(@vctxt, doc, ret, prefix, ns, nsuri)
              end
              i += 1
            end
          end
          @nodemem = -1
          sax2_append_child(ret)
          # nodePush
          if @node_tab.length > ((@options & PARSE_HUGE) != 0 ? 2048 : 256)
            if node_push(ret) < 0
              Tree.unlink_node(ret)
              return
            end
          else
            @node_tab << ret
            @node = ret
          end

          if nb_defaulted != 0 && (@loadsubset & XML_COMPLETE_ATTRS) == 0
            nb_attributes -= nb_defaulted
          end
          if uri && ret.ns.nil?
            # xmlParserNsLookupSax
            if prefix.nil?
              idx = @ns_default_index
              ret.ns = idx == INT_MAX || idx < @min_ns_index ? nil : @ns_extra[idx][0]
            else
              ret.ns = ns_lookup_sax(prefix)
            end
            ret.ns = Tree.search_ns(doc, ret, prefix) if ret.ns.nil? && prefix == "xml"
            if ret.ns.nil?
              Tree.new_ns(ret, nil, prefix)
              if prefix
                ctxt_err(nil, Domain::NAMESPACE, ErrCode::NS_ERR_UNDEFINED_NAMESPACE, Level::WARNING, prefix, nil,
                  nil, 0, "Namespace prefix #{prefix} was not found\n")
              else
                ctxt_err(nil, Domain::NAMESPACE, ErrCode::NS_ERR_UNDEFINED_NAMESPACE, Level::WARNING, nil, nil,
                  nil, 0, "Namespace default prefix was not found\n")
              end
            end
          end

          if nb_attributes > 0
            prev = nil
            j = 0
            while j < nb_attributes
              a = attributes[j]
              attr = if a.prefix && a.ns.nil?
                sax2_attribute_ns(-"#{a.prefix}:#{a.name}", nil, a.value, a.alloc)
              else
                sax2_attribute_ns(a.name, a.prefix, a.value, a.alloc)
              end
              if attr
                if prev.nil?
                  @node.properties = attr
                else
                  prev.next = attr
                  attr.prev = prev
                end
                prev = attr
              end
              j += 1
            end
          end

          if @validate != 0 && (@vctxt.flags & ValidCtxt::XML_VCTXT_DTD_VALIDATED) == 0
            chk = Valid.validate_dtd_final(@vctxt, doc)
            @valid = 0 if chk <= 0
            @well_formed = 0 if chk < 0
            @valid &= Valid.validate_root(@vctxt, doc)
            @vctxt.flags |= ValidCtxt::XML_VCTXT_DTD_VALIDATED
          end
        end

        # xmlSAX2EndElementNs
        def sax2_end_element_ns
          @nodemem = -1
          if @validate != 0 && @well_formed != 0 && @my_doc&.int_subset
            @valid &= Valid.validate_one_element(@vctxt, @my_doc, @node)
          end
          # nodePop
          tab = @node_tab
          unless tab.empty?
            tab.pop
            @node = tab[-1]
          end
        end

        # xmlSAX2Text
        def sax2_text(ch, type)
          node = @node
          return if node.nil?

          last_child = node.last
          if last_child.nil?
            if type == TEXT_NODE
              last_child = XmlNode.new(TEXT_NODE, STRING_TEXT, node.doc)
              last_child.content = +ch
            else
              last_child = Tree.new_cdata_block(@my_doc, ch)
              last_child.doc = node.doc
            end
            node.children = last_child
            node.last = last_child
            last_child.parent = node
            @nodelen = ch.bytesize
            @nodemem = ch.bytesize + 1
          elsif last_child.type == type && (type != TEXT_NODE || last_child.name.equal?(STRING_TEXT))
            # coalesce
            max_length = (@options & PARSE_HUGE) != 0 ? XML_MAX_HUGE_LENGTH : XML_MAX_TEXT_LENGTH
            if @nodemem != 0 && (ch.bytesize > max_length || @nodelen > max_length - ch.bytesize)
              fatal_err(ErrCode::ERR_RESOURCE_LIMIT, "Text node too long, try XML_PARSE_HUGE")
              halt
              return
            end
            c = last_child.content
            if c.nil?
              last_child.content = c = +ch
            elsif c.frozen?
              last_child.content = c = c + ch
            else
              c << ch
            end
            @nodelen = c.bytesize
            @nodemem = @nodelen + 1
          else
            if type == TEXT_NODE
              last_child = XmlNode.new(TEXT_NODE, STRING_TEXT, @my_doc)
              last_child.content = +ch
            else
              last_child = Tree.new_cdata_block(@my_doc, ch)
            end
            sax2_append_child(last_child)
            if node.children
              @nodelen = ch.bytesize
              @nodemem = ch.bytesize + 1
            end
          end
          if type == TEXT_NODE && @linenumbers != 0 && @input
            line = @line
            if line < 65_535
              last_child.line = line
            else
              last_child.line = 65_535
              last_child.psvi = line if (@options & PARSE_BIG_LINES) != 0
            end
          end
        end
      end
    end
  end
end
