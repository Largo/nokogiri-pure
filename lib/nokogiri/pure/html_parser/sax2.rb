# frozen_string_literal: true

# The default HTML SAX handler (xmlSAX2InitHtmlDefaultSAXHandler): the SAX2.c callbacks that
# build the document tree. Every callback receives the handler's user data first, which for the
# default handler is the parser Context itself (like libxml2's ctx argument).
#
# A custom SAX handler for HTMLParser::Context is any object responding to (a subset of):
#   set_document_locator(ctx, locator), start_document(ctx), end_document(ctx),
#   internal_subset(ctx, name, external_id, system_id),
#   start_element(ctx, name, attrs)        attrs: flat [name, value, ...] Array (value may be nil) or nil
#   end_element(ctx, name), characters(ctx, str), cdata_block(ctx, str),
#   ignorable_whitespace(ctx, str), processing_instruction(ctx, target, data), comment(ctx, str),
#   serror(ctx, xml_error), error(ctx, msg), warning(ctx, msg)
# A method that isn't defined is treated as a NULL callback.

module Nokogiri
  module Pure
    module HTMLParser
      BOOLEAN_ATTRS = [
        "checked", "compact", "declare", "defer", "disabled", "ismap",
        "multiple", "nohref", "noresize", "noshade", "nowrap", "readonly",
        "selected",
      ].freeze

      # htmlIsBooleanAttr
      def self.boolean_attr?(name)
        BOOLEAN_ATTRS.any? { |a| strcasecmp(name, a) == 0 }
      end

      XML_DOC_USERBUILT = 1 << 5
      XML_DOC_HTML = 1 << 7

      # htmlNewDocNoDtD
      def self.new_doc_no_dtd(uri, external_id)
        doc = Tree.new_html_doc
        doc.version = nil
        doc.standalone = 1
        doc.compression = 0
        doc.charset = 1
        doc.doc_properties = XML_DOC_HTML | XML_DOC_USERBUILT
        Tree.create_int_subset(doc, "html", external_id, uri) if external_id || uri
        doc
      end

      # htmlNewDoc
      def self.new_doc(uri, external_id)
        if uri.nil? && external_id.nil?
          return new_doc_no_dtd("http://www.w3.org/TR/REC-html40/loose.dtd", "-//W3C//DTD HTML 4.0 Transitional//EN")
        end

        new_doc_no_dtd(uri, external_id)
      end

      # xmlPathToURI / xmlCanonicPath
      def self.path_to_uri(path)
        return nil if path.nil?

        path = path.to_s
        if path.include?("://")
          out = +""
          path.b.each_byte do |ch|
            if (ch >= 0x61 && ch <= 0x7A) || (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x30 && ch <= 0x39) ||
                "-_.!~*'()".b.include?(ch.chr) || ":/?#[]@!$&()*+,;='%".b.include?(ch.chr)
              out << ch.chr
            else
              out << format("%%%02X", ch)
            end
          end
          out.force_encoding(Encoding::UTF_8)
        else
          path.dup
        end
      end

      # xmlValidateNCName (space not allowed), approximated with the XML 1.0 5th ed. name rules
      def self.valid_ncname?(value)
        !value.nil? && value.match?(/\A[\p{L}_][\p{L}\p{N}\p{M}_.\-·]*\z/u)
      rescue ArgumentError, Encoding::CompatibilityError
        false
      end

      class SAX2Handler
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

        # xmlSAX2SetDocumentLocator
        def set_document_locator(ctxt, loc); end

        # xmlSAX2StartDocument (HTML branch)
        def start_document(ctxt)
          ctxt.my_doc ||= HTMLParser.new_doc_no_dtd(nil, nil)
          doc = ctxt.my_doc
          doc.doc_properties = XML_DOC_HTML
          doc.parse_flags = ctxt.options
          if doc.url.nil? && ctxt.filename
            doc.url = HTMLParser.path_to_uri(ctxt.filename)
          end
        end

        # xmlSAX2EndDocument
        def end_document(ctxt)
          doc = ctxt.my_doc
          if doc && doc.encoding.nil?
            enc = ctxt.actual_encoding
            doc.encoding = HTMLParser.to_utf8(enc).dup if enc
          end
        end

        # xmlSAX2AppendChild
        def append_child(ctxt, node)
          parent = ctxt.node || ctxt.my_doc
          last = parent.last
          if last.nil?
            parent.children = node
          else
            last.next = node
            node.prev = last
          end
          parent.last = node
          node.parent = parent
          if node.type != TEXT_NODE && ctxt.linenumbers != 0
            node.line = ctxt.line < 65535 ? ctxt.line : 65535
          end
        end

        # xmlSAX2StartElement (HTML branch)
        def start_element(ctxt, fullname, atts)
          doc = ctxt.my_doc
          return if fullname.nil? || doc.nil?

          ret = Tree.new_doc_node(doc, nil, fullname)
          append_child(ctxt, ret)
          if ctxt.node_push(ret) < 0
            Tree.unlink_node(ret)
            return
          end
          return if atts.nil?

          i = 0
          while i < atts.length
            attribute_internal(ctxt, atts[i], atts[i + 1])
            i += 2
          end
        end

        # xmlSAX2AttributeInternal (HTML branch)
        def attribute_internal(ctxt, fullname, value)
          node = ctxt.node
          doc = ctxt.my_doc
          value = fullname.dup if value.nil? && HTMLParser.boolean_attr?(fullname)

          ret = Tree.new_prop_internal(node, nil, fullname, nil)
          return if ret.nil?

          unless value.nil?
            t = Tree.new_doc_text(doc, value)
            t.parent = ret
            ret.children = t
            ret.last = t
          end

          if (ctxt.loadsubset & 8) == 0 && ret.children && ret.children.type == TEXT_NODE &&
              ret.children.next.nil?
            content = ret.children.content
            if fullname == "xml:id"
              unless HTMLParser.valid_ncname?(content)
                ctxt.ctxt_err(Domain::DTD, 539, Level::ERROR, content, nil, nil, 0,
                  "xml:id : attribute value #{content} is not an NCName\n")
                ctxt.valid = 0
              end
              add_id(ctxt, ret, content)
            elsif Tree.is_id(doc, node, ret)
              add_id(ctxt, ret, content)
            end
          end
        end

        # xmlAddID (with the parser's validation context)
        def add_id(ctxt, attr, value)
          return if attr.doc != ctxt.my_doc

          res = Tree.add_id(attr, value)
          if res == 0
            ctxt.ctxt_err(Domain::VALID, 513, Level::ERROR, value, nil, nil, 0,
              "ID #{value} already defined\n", attr.parent)
          end
        end

        # xmlSAX2EndElement
        def end_element(ctxt, _name)
          ctxt.node_pop
        end

        # xmlSAX2Text
        def text(ctxt, str, type)
          parent = ctxt.node
          return if parent.nil?

          last = parent.last
          if last.nil?
            last = type == TEXT_NODE ? Tree.new_text(str) : Tree.new_cdata_block(ctxt.my_doc, str)
            parent.children = last
            parent.last = last
            last.parent = parent
            last.doc = parent.doc
          elsif last.type == type && (type != TEXT_NODE || last.name.equal?(STRING_TEXT) || last.name == STRING_TEXT)
            max_length = (ctxt.options & PARSE_HUGE) != 0 ? MAX_HUGE_LENGTH : MAX_TEXT_LENGTH
            if str.bytesize > max_length || last.content.bytesize > max_length - str.bytesize
              ctxt.fatal_err(Err::RESOURCE_LIMIT, nil)
              ctxt.halt_parser
              return
            end
            last.content << str
          else
            last = type == TEXT_NODE ? Tree.new_text(str) : Tree.new_cdata_block(ctxt.my_doc, str)
            last.doc = ctxt.my_doc
            append_child(ctxt, last)
          end

          if type == TEXT_NODE && ctxt.linenumbers != 0
            if ctxt.line < 65535
              last.line = ctxt.line
            else
              last.line = 65535
              last.psvi = ctxt.line if (ctxt.options & PARSE_BIG_LINES) != 0
            end
          end
        end

        # xmlSAX2Characters
        def characters(ctxt, str)
          text(ctxt, str, TEXT_NODE)
        end

        # xmlSAX2CDataBlock
        def cdata_block(ctxt, str)
          text(ctxt, str, CDATA_SECTION_NODE)
        end

        # xmlSAX2IgnorableWhitespace
        def ignorable_whitespace(ctxt, str); end

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

        DEFAULT = new.freeze
      end
    end
  end
end
