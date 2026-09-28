# frozen_string_literal: true

# Port of ext/nokogiri/xml_relax_ng.c

# the RELAX NG engine is loaded lazily: see Nokogiri::Pure::RelaxNGGlue.load!

module Nokogiri
  module XML
    class RelaxNG < Nokogiri::XML::Schema
      class << self
        # :call-seq:
        #   from_document(document) → Nokogiri::XML::RelaxNG
        #   from_document(document, parse_options) → Nokogiri::XML::RelaxNG
        def from_document(*args)
          unless args.size.between?(1, 2)
            raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 1..2)"
          end

          Nokogiri::Pure::RelaxNGGlue.load!
          rb_document, rb_parse_options = args
          c_document = Nokogiri::Pure::RelaxNGGlue.unwrap_document(rb_document)
          c_document = c_document.doc # In case someone passes us a node. ugh.

          c_parser_context = Nokogiri::Pure::RelaxNG.new_doc_parser_ctxt(c_document)
          Nokogiri::Pure::RelaxNGGlue.parse_schema(self, c_parser_context, rb_parse_options)
        end
      end

      private

      def validate_document(document)
        g = Nokogiri::Pure::RelaxNGGlue
        g.load!
        schema = @__native
        doc = g.unwrap_document(document)
        errors = []
        r = Nokogiri::Pure::RelaxNG
        valid_ctxt = r.new_valid_ctxt(schema)
        raise RuntimeError, "Could not create a validation context" if valid_ctxt.nil?

        valid_ctxt.serror = ->(err) { errors << Nokogiri::Pure.wrap_error(err) }
        r.validate_doc(valid_ctxt, doc)
        errors
      end

      # RelaxNG inherits Schema's native validate_file, which unwraps self as an xmlSchema
      def validate_file(_filename)
        raise TypeError, "wrong argument type xmlRelaxNG (expected xmlSchema)"
      end
    end
  end

  module Pure
    module RelaxNGGlue
      module_function

      def load!
        return if defined?(@loaded) && @loaded

        require_relative "../relaxng"
        @loaded = true
      end

      # noko_xml_document_unwrap (TypedData_Get_Struct with the xmlDoc type)
      def unwrap_document(rb_document)
        unless rb_document.is_a?(Nokogiri::XML::Document)
          actual = case rb_document
          when nil then "nil"
          when true then "true"
          when false then "false"
          when Nokogiri::XML::Node then "xmlNode"
          when Nokogiri::XML::NodeSet then "xmlNodeSet"
          when Nokogiri::XML::Namespace then "xmlNs"
          else rb_document.class.to_s
          end
          raise TypeError, "wrong argument type #{actual} (expected xmlDoc)"
        end

        Pure.unwrap_document(rb_document)
      end

      # _noko_xml_relax_ng_parse_schema
      def parse_schema(rb_class, c_parser_context, rb_parse_options)
        rb_parse_options = Nokogiri::XML::ParseOptions::DEFAULT_SCHEMA if rb_parse_options.nil?

        rb_errors = []
        pusher = ->(err) { rb_errors << Pure.wrap_error(err) }
        c_schema = nil
        Errors.with_handler(pusher) do
          c_parser_context.serror = pusher
          c_schema = RelaxNG.parse(c_parser_context)
        end

        if c_schema.nil?
          exception = Nokogiri::XML::SyntaxError.aggregate(rb_errors)
          raise exception if exception

          raise RuntimeError, "Could not parse document"
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
