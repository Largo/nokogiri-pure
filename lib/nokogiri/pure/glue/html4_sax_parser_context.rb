# frozen_string_literal: true

# Port of ext/nokogiri/html4_sax_parser_context.c (plus the xml_sax_parser_context.c methods an
# HTML4::SAX::ParserContext inherits: line, column, recovery, replace_entities).

require_relative "../html_parser"
require_relative "html4_sax_parser"

module Nokogiri
  module HTML4
    module SAX
      class ParserContext < Nokogiri::XML::SAX::ParserContext
        class << self
          # :nodoc:
          def native_memory(input, encoding)
            raise TypeError, "wrong argument type #{input.class} (expected String)" unless input.is_a?(String)
            raise RuntimeError, "input string cannot be empty" if input.empty?

            __check_encoding(encoding)
            ctxt = Nokogiri::Pure::HTMLParser.create_memory_parser_ctxt(input.b)
            __set_encoding(ctxt, encoding)
            ctxt.sax = Nokogiri::Pure::HTMLParser::NullSAX
            __wrap(ctxt)
          end

          # :nodoc:
          def native_file(filename, encoding)
            __check_encoding(encoding)
            rb_filename = filename
            filename = String.try_convert(filename)
            raise TypeError, "no implicit conversion of #{rb_filename.class} into String" if filename.nil?
            data = begin
              File.binread(filename)
            rescue SystemCallError, IOError
              nil
            end
            raise RuntimeError, "failed to create xml sax parser context" if data.nil?

            ctxt = Nokogiri::Pure::HTMLParser.create_memory_parser_ctxt(data, filename)
            __set_encoding(ctxt, encoding)
            ctxt.sax = Nokogiri::Pure::HTMLParser::NullSAX
            __wrap(ctxt)
          end

          # :nodoc:
          def native_io(io, encoding)
            raise TypeError, "argument expected to respond to :read" unless io.respond_to?(:read)

            __check_encoding(encoding)
            ctxt = Nokogiri::Pure::HTMLParser::Context.new
            ctxt.push_io_input(Nokogiri::Pure::HTMLParser.io_reader(io))
            __set_encoding(ctxt, encoding)
            ctxt.sax = Nokogiri::Pure::HTMLParser::NullSAX
            rb = __wrap(ctxt)
            rb.instance_variable_set(:@input, io)
            rb
          end

          private

          def __check_encoding(encoding)
            if !encoding.nil? && !encoding.is_a?(::Encoding)
              raise TypeError, "argument must be an Encoding object"
            end
          end

          # noko_xml_sax_parser_context_set_encoding
          def __set_encoding(ctxt, encoding)
            return if encoding.nil?

            name = encoding.name
            errors = []
            result = Nokogiri::Pure::Errors.collecting(errors) { ctxt.switch_input_encoding_name(name) }
            if result != 0
              exception = Nokogiri::XML::SyntaxError.aggregate(errors)
              raise exception if exception

              raise RuntimeError, "could not set encoding"
            end
          end

          def __wrap(ctxt)
            rb = Class.instance_method(:allocate).bind_call(self)
            rb.instance_variable_set(:@__native, ctxt)
            rb
          end
        end

        def parse_with(sax_parser)
          unless sax_parser.is_a?(Nokogiri::XML::SAX::Parser)
            raise ArgumentError, "argument must be a Nokogiri::XML::SAX::Parser"
          end

          ctxt = __ctxt
          ctxt.sax = Nokogiri::Pure::HTMLParser.sax_handler_for(sax_parser)
          ctxt.user_data = ctxt
          ctxt._private = sax_parser
          Nokogiri::Pure::Errors.with_handler(nil) do
            ctxt.parse_document
          end
          nil
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

        def replace_entities
          (__ctxt.options & Nokogiri::Pure::HTMLParser::PARSE_NOENT) != 0
        end

        def line
          ctxt = __ctxt
          ctxt.has_input ? ctxt.line : nil
        end

        def column
          ctxt = __ctxt
          ctxt.has_input ? ctxt.col : nil
        end

        def recovery=(value)
          ctxt = __ctxt
          error = if value
            ctxt.xml_use_options(ctxt.options | Nokogiri::Pure::HTMLParser::PARSE_RECOVER)
          else
            ctxt.xml_use_options(ctxt.options & ~Nokogiri::Pure::HTMLParser::PARSE_RECOVER)
          end
          raise RuntimeError, format("failed to set parser context options (%x)", error) if error != 0

          value
        end

        def recovery
          (__ctxt.options & Nokogiri::Pure::HTMLParser::PARSE_RECOVER) != 0
        end

        private

        def __ctxt
          c = @__native
          raise TypeError, "wrong argument type #{self.class} (expected xmlParserCtxt)" if c.nil?

          c
        end
      end
    end
  end
end
