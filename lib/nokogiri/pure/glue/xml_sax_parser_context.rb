# frozen_string_literal: true

# Port of ext/nokogiri/xml_sax_parser_context.c

module Nokogiri
  module XML
    module SAX
      class ParserContext
        class << self
          def native_io(io, encoding)
            raise TypeError, "argument expected to respond to :read" unless io.respond_to?(:read)
            if !encoding.nil? && !encoding.is_a?(Encoding)
              raise TypeError, "argument must be an Encoding object"
            end

            ctxt = Nokogiri::Pure::Parser::Ctxt.new
            input = ctxt.new_input_stream
            input.io = io
            ctxt.input_push(input)
            __set_encoding(ctxt, encoding)
            ctxt.sax = nil
            rb = __wrap(ctxt)
            rb.instance_variable_set(:@input, io)
            rb
          end

          def native_file(path, encoding)
            if !encoding.nil? && !encoding.is_a?(Encoding)
              raise TypeError, "argument must be an Encoding object"
            end

            path = String.try_convert(path) || raise(TypeError, "no implicit conversion of #{path.class} into String")
            ctxt = Nokogiri::Pure::Parser::Ctxt.new
            ctxt.linenumbers = 1
            input = Nokogiri::Pure::Parser::Loader.load_external_entity(path, nil, ctxt)
            raise RuntimeError, "failed to create xml sax parser context" if input.nil?

            ctxt.input_push(input)
            __set_encoding(ctxt, encoding)
            ctxt.sax = nil
            __wrap(ctxt)
          end

          def native_memory(input, encoding)
            unless input.is_a?(String)
              tn = input.nil? || input == true || input == false ? input.inspect : input.class
              raise TypeError, "wrong argument type #{tn} (expected String)"
            end
            raise RuntimeError, "input string cannot be empty" if input.empty?
            if !encoding.nil? && !encoding.is_a?(Encoding)
              raise TypeError, "argument must be an Encoding object"
            end

            ctxt = Nokogiri::Pure::Parser.create_memory_parser_ctxt(input)
            __set_encoding(ctxt, encoding)
            ctxt.sax = nil
            rb = __wrap(ctxt)
            rb.instance_variable_set(:@input, input)
            rb
          end

          private

          def __wrap(ctxt)
            rb = allocate
            rb.instance_variable_set(:@__native, ctxt)
            rb
          end

          # noko_xml_sax_parser_context_set_encoding
          def __set_encoding(ctxt, encoding)
            return if encoding.nil?

            errors = []
            result = Nokogiri::Pure::Errors.collecting(errors) do
              ctxt.switch_encoding_name(encoding.name)
            end
            return if result == 0

            exception = Nokogiri::XML::SyntaxError.aggregate(errors)
            raise exception if exception

            raise RuntimeError, "could not set encoding"
          end
        end

        def parse_with(sax_parser)
          unless sax_parser.is_a?(Nokogiri::XML::SAX::Parser)
            raise ArgumentError, "argument must be a Nokogiri::XML::SAX::Parser"
          end

          ctxt = @__native
          if (inp = ctxt.input) && inp.io
            io = inp.io
            inp.io = nil
            bytes, = Nokogiri::Pure::Parser.read_all_io(io)
            inp.set_raw(bytes)
            ctxt.refresh_buffer
          end
          ctxt.sax = sax_parser.instance_variable_get(:@__native)
          ctxt.user_data = ctxt
          ctxt._private = sax_parser
          Nokogiri::Pure::Errors.handler = nil # the C glue clears (not restores) the global handler
          Nokogiri::Pure::Errors.with_handler(nil) do
            ctxt.parse_document
          end
          nil
        end

        def replace_entities=(value)
          ctxt = @__native
          opts = value ? (ctxt.options | Nokogiri::Pure::Parser::PARSE_NOENT) : (ctxt.options & ~Nokogiri::Pure::Parser::PARSE_NOENT)
          err = ctxt.set_options(opts)
          raise RuntimeError, format("failed to set parser context options (%x)", err) if err != 0

          value
        end

        def replace_entities
          (@__native.options & Nokogiri::Pure::Parser::PARSE_NOENT) != 0
        end

        def recovery=(value)
          ctxt = @__native
          opts = value ? (ctxt.options | Nokogiri::Pure::Parser::PARSE_RECOVER) : (ctxt.options & ~Nokogiri::Pure::Parser::PARSE_RECOVER)
          err = ctxt.set_options(opts)
          raise RuntimeError, format("failed to set parser context options (%x)", err) if err != 0

          value
        end

        def recovery
          (@__native.options & Nokogiri::Pure::Parser::PARSE_RECOVER) != 0
        end

        def line
          ctxt = @__native
          ctxt.input ? ctxt.current_line : nil
        end

        def column
          ctxt = @__native
          ctxt.input ? ctxt.current_col : nil
        end
      end
    end
  end
end
