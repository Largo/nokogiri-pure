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
