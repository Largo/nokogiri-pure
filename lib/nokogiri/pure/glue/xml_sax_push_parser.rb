# frozen_string_literal: true

# Port of ext/nokogiri/xml_sax_push_parser.c

module Nokogiri
  module XML
    module SAX
      class PushParser
        def options
          @__native.options
        end

        def options=(options)
          err = @__native.set_options(Integer(options))
          raise RuntimeError, format("Cannot set XML parser context options (%x)", err) if err != 0

          nil
        end

        def replace_entities
          (@__native.options & Nokogiri::Pure::Parser::PARSE_NOENT) != 0
        end

        def replace_entities=(value)
          ctxt = @__native
          opts = value ? (ctxt.options | Nokogiri::Pure::Parser::PARSE_NOENT) : (ctxt.options & ~Nokogiri::Pure::Parser::PARSE_NOENT)
          err = ctxt.set_options(opts)
          raise RuntimeError, format("failed to set parser context options (%x)", err) if err != 0

          value
        end

        private

        def initialize_native(xml_sax, filename)
          sax = xml_sax.instance_variable_get(:@__native)
          filename = filename.nil? ? nil : (String.try_convert(filename) || raise(TypeError, "no implicit conversion into String"))
          ctxt = Nokogiri::Pure::Parser.create_push_parser_ctxt(sax, nil, nil, filename)
          raise RuntimeError, "Could not create a parser context" if ctxt.nil?

          ctxt.user_data = ctxt
          ctxt._private = xml_sax
          @__native = ctxt
          self
        end

        def native_write(chunk, last_chunk)
          ctxt = @__native
          chunk = chunk.nil? ? nil : (String.try_convert(chunk) || raise(TypeError, "no implicit conversion into String"))
          ret = Nokogiri::Pure::Errors.with_handler(nil) do
            ctxt.parse_chunk(chunk, last_chunk == true)
          end
          if ret != 0 && (ctxt.options & Nokogiri::Pure::Parser::PARSE_RECOVER) == 0
            e = ctxt.last_error
            raise Nokogiri::Pure.wrap_error(e) if e

            raise Nokogiri::XML::SyntaxError, "Unknown error"
          end
          self
        end
      end
    end
  end
end
