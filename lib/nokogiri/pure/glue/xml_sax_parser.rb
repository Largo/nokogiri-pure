# frozen_string_literal: true

# Port of ext/nokogiri/xml_sax_parser.c: the xmlSAXHandler Nokogiri::XML::SAX::Parser installs.

module Nokogiri
  module XML
    module SAX
      class Parser
        private

        def initialize_native
          @__native = Nokogiri::Pure::Parser::XmlSAXGlue.handler
          self
        end
      end
    end
  end

  module Pure
    module Parser
      # the callbacks of xml_sax_parser.c; ctxt._private is the Ruby SAX::Parser
      module XmlSAXGlue
        module_function

        def doc(ctxt)
          ctxt._private.instance_variable_get(:@document)
        end

        def str(s)
          s.nil? ? nil : s.dup.force_encoding(Encoding::UTF_8)
        end

        def handler
          h = SAXHandler.new
          h.start_document = method(:start_document)
          h.end_document = method(:end_document)
          h.start_element = method(:start_element)
          h.end_element = method(:end_element)
          h.start_element_ns = method(:start_element_ns)
          h.end_element_ns = method(:end_element_ns)
          h.characters = method(:characters)
          h.comment = method(:comment)
          h.warning = method(:warning)
          h.error = method(:error)
          h.cdata_block = method(:cdata_block)
          h.processing_instruction = method(:processing_instruction)
          h.reference = method(:reference)
          h.get_entity = SAX2::GET_ENTITY
          h.internal_subset = SAX2::INTERNAL_SUBSET
          h.external_subset = SAX2::EXTERNAL_SUBSET
          h.is_standalone = SAX2::IS_STANDALONE
          h.has_internal_subset = SAX2::HAS_INTERNAL_SUBSET
          h.has_external_subset = SAX2::HAS_EXTERNAL_SUBSET
          h.resolve_entity = SAX2::RESOLVE_ENTITY
          h.get_parameter_entity = SAX2::GET_PARAMETER_ENTITY
          h.entity_decl = SAX2::ENTITY_DECL
          h.unparsed_entity_decl = SAX2::UNPARSED_ENTITY_DECL
          h.initialized = SAX2::XML_SAX2_MAGIC
          h
        end

        def start_document(ctxt)
          SAX2.start_document(ctxt)
          d = doc(ctxt)
          if ctxt.standalone != -1
            encoding = str(ctxt.encoding)
            version = str(ctxt.version)
            standalone = case ctxt.standalone
            when 0 then +"no"
            when 1 then +"yes"
            end
            d.xmldecl(version, encoding, standalone)
          end
          d.start_document
        end

        def end_document(ctxt)
          doc(ctxt).end_document
        end

        def start_element(ctxt, name, atts)
          attributes = []
          atts&.each_slice(2) do |a, v|
            break if a.nil?

            attributes << [str(a), str(v)]
          end
          doc(ctxt).start_element(str(name), attributes)
        end

        def end_element(ctxt, name)
          doc(ctxt).end_element(str(name))
        end

        def start_element_ns(ctxt, localname, prefix, uri, nb_namespaces, namespaces, nb_attributes, _nb_defaulted,
          attributes)
          attr_class = Nokogiri::XML::SAX::Parser::Attribute
          attribute_ary = []
          i = 0
          while i < nb_attributes
            a = attributes[i]
            attribute_ary << attr_class.new(str(a.name), str(a.prefix), str(a.ns), str(a.value))
            i += 1
          end
          ns_list = []
          j = 0
          while j < nb_namespaces
            pfx, href = namespaces[j]
            ns_list << [str(pfx), str(href)]
            j += 1
          end
          doc(ctxt).start_element_namespace(str(localname), attribute_ary, str(prefix), str(uri), ns_list)
        end

        def end_element_ns(ctxt, localname, prefix, uri)
          doc(ctxt).end_element_namespace(str(localname), str(prefix), str(uri))
        end

        def characters(ctxt, s)
          doc(ctxt).characters(str(s))
        end

        def comment(ctxt, s)
          doc(ctxt).comment(str(s))
        end

        def warning(ctxt, msg)
          doc(ctxt).warning(msg.b)
        end

        def error(ctxt, msg)
          doc(ctxt).error(msg.b)
        end

        def cdata_block(ctxt, s)
          doc(ctxt).cdata_block(str(s))
        end

        def processing_instruction(ctxt, name, content)
          doc(ctxt).processing_instruction(str(name), str(content))
        end

        def reference(ctxt, name)
          entity = SAX2.get_entity(ctxt, name)
          if entity && entity.content
            doc(ctxt).reference(str(entity.name), str(entity.content))
          else
            doc(ctxt).reference(str(name), nil)
          end
        end
      end
    end
  end
end
