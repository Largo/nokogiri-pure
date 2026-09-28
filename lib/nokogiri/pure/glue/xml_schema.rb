# frozen_string_literal: true

# Port of ext/nokogiri/xml_schema.c

# the schema engine is loaded lazily (it is big): see Nokogiri::Pure::SchemaGlue.load!

module Nokogiri
  module XML
    class Schema
      class << self
        # from_document(input) / from_document(input, parse_options)
        def from_document(*args)
          Nokogiri::Pure::SchemaGlue.load!
          unless args.size.between?(1, 2)
            raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 1..2)"
          end

          rb_document, rb_parse_options = args
          unless rb_document.is_a?(Nokogiri::XML::Node)
            raise TypeError, "expected parameter to be a Nokogiri::XML::Document, received #{rb_document.class}"
          end

          if rb_document.is_a?(Nokogiri::XML::Document)
            c_document = Nokogiri::Pure.unwrap_document(rb_document)
          else
            if $VERBOSE && Warning[:deprecated]
              warn("Passing a Node as the first parameter to Schema.from_document is deprecated. Please pass a " \
                "Document instead. This will become an error in Nokogiri v1.17.0.", uplevel: 1, category: :deprecated)
            end
            c_document = Nokogiri::Pure.unwrap(rb_document).doc
          end

          if Nokogiri::Pure::SchemaGlue.has_wrapped_blank_nodes?(c_document)
            c_document = Nokogiri::Pure::Tree.copy_doc(c_document, 1)
          end

          c_parser_context = Nokogiri::Pure::Schemas.new_doc_parser_ctxt(c_document)
          Nokogiri::Pure::SchemaGlue.parse_schema(self, c_parser_context, rb_parse_options)
        end
      end

      private

      def validate_document(document)
        Nokogiri::Pure::SchemaGlue.load!
        schema = @__native
        doc = Nokogiri::Pure.unwrap_document(document)
        errors = []
        s = Nokogiri::Pure::Schemas
        valid_ctxt = s.new_valid_ctxt(schema)
        raise RuntimeError, "Could not create a validation context" if valid_ctxt.nil?

        s.set_valid_structured_errors(valid_ctxt, ->(err) { errors << Nokogiri::Pure.wrap_error(err) })
        status = s.validate_doc(valid_ctxt, doc)
        errors << "Could not validate document" if status != 0 && errors.empty?
        errors
      end

      def validate_file(rb_filename)
        Nokogiri::Pure::SchemaGlue.load!
        schema = @__native
        filename = rb_filename.to_str
        raise ArgumentError, "string contains null byte" if filename.include?("\0")

        errors = []
        s = Nokogiri::Pure::Schemas
        valid_ctxt = s.new_valid_ctxt(schema)
        raise RuntimeError, "Could not create a validation context" if valid_ctxt.nil?

        s.set_valid_structured_errors(valid_ctxt, ->(err) { errors << Nokogiri::Pure.wrap_error(err) })
        status = s.validate_file(valid_ctxt, filename, 0)
        errors << "Could not validate file." if status != 0 && errors.empty?
        errors
      end
    end
  end

  module Pure
    module SchemaGlue
      module_function

      def load!
        return if defined?(@loaded) && @loaded

        require_relative "../schemas/load"
        @loaded = true
      end

      # noko_xml_document_has_wrapped_blank_nodes_p
      def has_wrapped_blank_nodes?(c_document)
        rb_doc = c_document._ruby_doc
        return false if rb_doc.nil?

        cache = rb_doc.instance_variable_get(:@node_cache)
        return false if cache.nil?

        cache.any? do |rb_node|
          node = rb_node.instance_variable_get(:@__native)
          node && Tree.is_blank_node(node)
        end
      end

      # xml_schema_parse_schema
      def parse_schema(rb_class, c_parser_context, rb_parse_options)
        if rb_parse_options.nil?
          rb_parse_options = Nokogiri::XML::ParseOptions::DEFAULT_SCHEMA
        end
        c_parse_options = Integer(rb_parse_options.to_i)

        rb_errors = []
        pusher = ->(err) { rb_errors << Pure.wrap_error(err) }
        c_schema = nil
        Errors.with_handler(pusher) do
          Schemas.set_parser_structured_errors(c_parser_context, pusher, nil)
          Schemas.with_nonet((c_parse_options & Schemas::PARSE_NONET) != 0) do
            c_schema = Schemas.parse(c_parser_context)
          end
        end

        if c_schema.nil?
          Pure.raise_aggregate(rb_errors, "Could not parse document")
        end

        rb_schema = rb_class.allocate
        rb_schema.instance_variable_set(:@__native, c_schema)
        rb_schema.instance_variable_set(:@errors, rb_errors)
        rb_schema.instance_variable_set(:@parse_options, rb_parse_options)
        rb_schema
      end
    end
  end
end
