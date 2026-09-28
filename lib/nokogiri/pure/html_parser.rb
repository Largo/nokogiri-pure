# frozen_string_literal: true

# Pure-Ruby port of libxml2 2.13.9's HTML 4 parser (HTMLparser.c) together with the SAX2.c
# callbacks that build the tree for it.
#
# Entry points (mirroring libxml2):
#   HTMLParser.read_memory(str, url, encoding, options)  htmlReadMemory
#   HTMLParser.read_io(reader, url, encoding, options)    htmlReadIO (+reader+ is a callable(len))
#   HTMLParser.new_doc(uri, external_id)                  htmlNewDoc
#   HTMLParser::Context                                   htmlParserCtxt (SAX handler pluggable)
#   HTMLParser.tag_lookup / entity_lookup / ...           see html_parser/tables.rb

require "strscan"
require_relative "tree"
require_relative "errors"
require_relative "encoding"
require_relative "html_parser/tables"
require_relative "html_parser/chvalid"
require_relative "html_parser/context"
require_relative "html_parser/parse"
require_relative "html_parser/sax2"
require_relative "html_parser/push"

module Nokogiri
  module Pure
    module HTMLParser
      module_function

      # htmlNewParserCtxt / htmlNewSAXParserCtxt
      def new_parser_ctxt(sax = nil, user_data = nil)
        Context.new(sax, user_data)
      end

      # htmlCreateMemoryParserCtxt
      def create_memory_parser_ctxt(buffer, url = nil, encoding = nil, sax: nil, user_data: nil)
        ctxt = Context.new(sax, user_data)
        ctxt.push_memory_input(buffer, url, encoding)
        ctxt
      end

      # htmlCtxtParseDocument
      def ctxt_parse_document(ctxt)
        ctxt.html = 1
        ctxt.parse_document
        ret = ctxt.err_no == Err::NO_MEMORY ? nil : ctxt.my_doc
        ctxt.my_doc = nil
        ret
      end

      # htmlReadMemory
      def read_memory(buffer, url, encoding, options)
        ctxt = Context.new
        ctxt.use_options(options)
        ctxt.push_memory_input(buffer, url, encoding)
        ctxt_parse_document(ctxt)
      end

      # htmlReadIO: +reader+.call(len) returns a String, nil (EOF) or :error
      def read_io(reader, url, encoding, options)
        ctxt = Context.new
        ctxt.use_options(options)
        ctxt.push_io_input(reader, url, encoding)
        ctxt_parse_document(ctxt)
      end

      NOT_WELL_BALANCED = 85

      # The HTML-document branch of xmlParseInNodeContext (parser.c). Returns [error_code, list]
      # where list is the first node of the parsed (unlinked, parent-less) sibling list or nil.
      # +node+ is the context node struct; +data+ the (binary) input string.
      def parse_in_node_context(node, data, options)
        ok_types = [ELEMENT_NODE, ATTRIBUTE_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE,
                    PI_NODE, COMMENT_NODE, DOCUMENT_NODE, HTML_DOCUMENT_NODE]
        return [Err::INTERNAL_ERROR, nil] if node.nil? || !ok_types.include?(node.type)

        while node && node.type != ELEMENT_NODE && node.type != DOCUMENT_NODE && node.type != HTML_DOCUMENT_NODE
          node = node.parent
        end
        return [Err::INTERNAL_ERROR, nil] if node.nil?

        doc = node.type == ELEMENT_NODE ? node.doc : node
        return [Err::INTERNAL_ERROR, nil] if doc.nil? || doc.type != HTML_DOCUMENT_NODE

        # htmlCreateMemoryParserCtxt returns NULL for an empty buffer
        return [Err::NO_MEMORY, nil] if data.nil? || data.empty?

        ctxt = Context.new
        ctxt.push_memory_input(data)
        options |= PARSE_NOIMPLIED
        options |= PARSE_NODICT
        ctxt.dict_names = 0
        ctxt.switch_input_encoding_name(doc.encoding) if doc.encoding
        ctxt.xml_use_options(options)
        ctxt.my_doc = doc
        ctxt.input_id = 2

        fake = Tree.new_doc_comment(node.doc, nil)
        Tree.add_child(node, fake)
        ctxt.node_push(node) if node.type == ELEMENT_NODE
        ctxt.loadsubset |= 8 if ctxt.validate != 0 || ctxt.replace_entities != 0

        ctxt.parse_content

        ctxt.fatal_err(NOT_WELL_BALANCED, nil) if ctxt.cur < ctxt.input_end

        ret = if ctxt.well_formed != 0 || (ctxt.recovery != 0 && ctxt.err_no != Err::NO_MEMORY)
          Err::OK
        else
          ctxt.err_no
        end

        cur = fake.next
        fake.next = nil
        node.last = fake
        cur.prev = nil if cur
        list = cur
        while cur
          cur.parent = nil
          cur = cur.next
        end
        Tree.unlink_node(fake)
        list = nil if ret != Err::OK
        [ret, list]
      end

      # noko_io_read: wrap a Ruby IO-like object as a libxml2 read callback
      def io_reader(io)
        lambda do |len|
          begin
            s = io.read(len)
          rescue StandardError
            next :error
          end
          next nil if s.nil?
          next :error unless s.is_a?(String)

          s
        end
      end
    end
  end
end
