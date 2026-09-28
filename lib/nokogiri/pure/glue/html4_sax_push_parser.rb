# frozen_string_literal: true

# Port of ext/nokogiri/html4_sax_push_parser.c (plus the xml_sax_push_parser.c methods an
# HTML4::SAX::PushParser inherits: options, options=, replace_entities).

require_relative "../html_parser"
require_relative "html4_sax_parser"

module Nokogiri
  module HTML4
    module SAX
      class PushParser < Nokogiri::XML::SAX::PushParser
        def options
          __ctxt.options
        end

        def options=(options)
          error = __ctxt.xml_use_options(Integer(options))
          raise RuntimeError, format("Cannot set XML parser context options (%x)", error) if error != 0

          nil
        end

        def replace_entities
          (__ctxt.options & Nokogiri::Pure::HTMLParser::PARSE_NOENT) != 0
        end

        def replace_entities=(value)
          ctxt = __ctxt
          error = if value
            ctxt.xml_use_options(ctxt.options | Nokogiri::Pure::HTMLParser::PARSE_NOENT)
          else
            ctxt.xml_use_options(ctxt.options & ~Nokogiri::Pure::HTMLParser::PARSE_NOENT)
          end
          raise RuntimeError, format("failed to set parser context options (%x)", error) if error != 0

          value
        end

        private

        def initialize_native(rb_xml_sax, rb_filename, encoding)
          sax = Nokogiri::Pure::HTMLParser.sax_handler_for(rb_xml_sax)
          filename = rb_filename.nil? ? nil : rb_filename.to_str
          enc = :none
          unless encoding.nil?
            enc = Nokogiri::Pure::HTMLParser.parse_char_encoding(encoding.to_str)
            raise ArgumentError, "Unsupported Encoding" if enc == :error
          end
          ctxt = Nokogiri::Pure::HTMLParser.create_push_parser_ctxt(sax, nil, nil, filename, enc)
          raise RuntimeError, "Could not create a parser context" if ctxt.nil?

          ctxt.user_data = ctxt
          ctxt._private = rb_xml_sax
          @__native = ctxt
          self
        end

        def native_write(chunk, last_chunk)
          ctxt = __ctxt
          data = chunk.nil? ? nil : chunk.to_str
          Nokogiri::Pure::Errors.handler = nil # the C glue clears (not restores) the global handler
          status = Nokogiri::Pure::Errors.with_handler(nil) do
            ctxt.parse_chunk(data, last_chunk == true)
          end
          if status != 0 && (ctxt.options & Nokogiri::Pure::HTMLParser::PARSE_RECOVER) == 0
            # xmlCtxtGetLastError never returns NULL: without an error it's a zeroed struct
            e = ctxt.last_error || Nokogiri::Pure::XmlError.new(level: 0)
            raise Nokogiri::Pure.wrap_error(e)
          end
          self
        end

        def __ctxt
          c = @__native
          raise TypeError, "wrong argument type #{self.class} (expected xmlParserCtxt)" if c.nil?

          c
        end
      end
    end
  end
end
