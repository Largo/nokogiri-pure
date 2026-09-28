# frozen_string_literal: true

# Port of ext/nokogiri/html4_sax_parser.c, together with the parts of xml_sax_parser.c whose
# xmlSAXHandler callbacks the HTML parser uses (HTML4::SAX::Parser#initialize_native calls super
# and then replaces startDocument).

require_relative "../html_parser"

module Nokogiri
  module Pure
    module HTMLParser
      # The xmlSAXHandler that Nokogiri's SAX parsers install (xml_sax_parser.c), in the
      # HTMLParser handler interface. Every callback forwards to the Ruby parser's @document,
      # looked up on each call like rb_iv_get(ctxt->_private, "@document") does.
      class NokogiriSAXHandler
        attr_reader :rb_parser

        def initialize(rb_parser, html: true)
          @rb_parser = rb_parser
          @html = html
        end

        def html?
          @html
        end

        def doc
          @rb_parser.instance_variable_get(:@document)
        end

        def str(s)
          s.nil? ? nil : HTMLParser.to_utf8(s).dup
        end

        # noko_html4_sax_parser_start_document / noko_xml_sax_parser_start_document_callback
        def start_document(ctxt)
          SAX2Handler::DEFAULT.start_document(ctxt)
          if !@html && ctxt.standalone != -1
            standalone = case ctxt.standalone
            when 0 then "no"
            when 1 then "yes"
            end
            doc.xmldecl(str(ctxt.version), str(ctxt.encoding), standalone)
          end
          doc.start_document
        end

        def end_document(_ctxt)
          doc.end_document
        end

        def start_element(_ctxt, name, atts)
          attributes = []
          if atts
            i = 0
            while i < atts.length
              attributes << [str(atts[i]), str(atts[i + 1])]
              i += 2
            end
          end
          doc.start_element(str(name), attributes)
        end

        def end_element(_ctxt, name)
          doc.end_element(str(name))
        end

        def characters(_ctxt, s)
          doc.characters(str(s))
        end

        def comment(_ctxt, s)
          doc.comment(str(s))
        end

        def warning(_ctxt, msg)
          doc.warning(str(msg))
        end

        def error(_ctxt, msg)
          doc.error(str(msg))
        end

        def cdata_block(_ctxt, s)
          doc.cdata_block(str(s))
        end

        def processing_instruction(_ctxt, name, content)
          doc.processing_instruction(str(name), str(content))
        end

        # xmlSAX2InternalSubset
        def internal_subset(ctxt, name, external_id, system_id)
          SAX2Handler::DEFAULT.internal_subset(ctxt, name, external_id, system_id)
        end
      end

      # noko_xml_sax_parser_unwrap for the HTML glue: the handler of +rb_sax_parser+
      def self.sax_handler_for(rb_sax_parser)
        h = rb_sax_parser.instance_variable_get(:@__native)
        return h if h.is_a?(NokogiriSAXHandler)

        NokogiriSAXHandler.new(rb_sax_parser, html: rb_sax_parser.is_a?(Nokogiri::HTML4::SAX::Parser))
      end
    end
  end

  module HTML4
    module SAX
      class Parser < Nokogiri::XML::SAX::Parser
        private

        def initialize_native
          @__native = Nokogiri::Pure::HTMLParser::NokogiriSAXHandler.new(self, html: true)
          self
        end
      end
    end
  end
end
