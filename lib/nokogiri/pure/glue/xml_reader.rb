# frozen_string_literal: true

# Port of ext/nokogiri/xml_reader.c

require_relative "../xmlreader"

module Nokogiri
  module XML
    class Reader
      class << self
        # from_memory(string, url = nil, encoding = nil, options = 0)
        def from_memory(*args)
          unless (1..4).cover?(args.length)
            raise ArgumentError, "wrong number of arguments (given #{args.length}, expected 1..4)"
          end

          rb_buffer, rb_url, encoding, rb_options = args
          raise ArgumentError, "string cannot be nil" unless rb_buffer

          c_url = rb_url ? Nokogiri::Pure::XmlReaderGlue.cstr(rb_url) : nil
          c_encoding = encoding ? Nokogiri::Pure::XmlReaderGlue.cstr(encoding) : nil
          c_options = rb_options ? Nokogiri::Pure::XmlReaderGlue.num2int(rb_options) : 0
          buffer = Nokogiri::Pure::XmlReaderGlue.string_value(rb_buffer)

          reader = Nokogiri::Pure::XmlReader.for_memory(buffer, c_url, c_encoding, c_options)
          raise RuntimeError, "couldn't create a parser" if reader.nil?

          rb_reader = Nokogiri::Pure::ALLOCATE.bind_call(self)
          rb_reader.instance_variable_set(:@__native, reader)
          rb_reader.send(:initialize, rb_buffer, rb_url, encoding)
          rb_reader
        end

        # from_io(io, url = nil, encoding = nil, options = 0)
        def from_io(*args)
          unless (1..4).cover?(args.length)
            raise ArgumentError, "wrong number of arguments (given #{args.length}, expected 1..4)"
          end

          rb_io, rb_url, encoding, rb_options = args
          raise ArgumentError, "io cannot be nil" unless rb_io

          c_url = rb_url ? Nokogiri::Pure::XmlReaderGlue.cstr(rb_url) : nil
          c_encoding = encoding ? Nokogiri::Pure::XmlReaderGlue.cstr(encoding) : nil
          c_options = rb_options ? Nokogiri::Pure::XmlReaderGlue.num2int(rb_options) : 0

          reader = Nokogiri::Pure::XmlReader.for_io(rb_io, c_url, c_encoding, c_options)
          raise RuntimeError, "couldn't create a parser" if reader.nil?

          rb_reader = Nokogiri::Pure::ALLOCATE.bind_call(self)
          rb_reader.instance_variable_set(:@__native, reader)
          rb_reader.send(:initialize, rb_io, rb_url, encoding)
          rb_reader
        end
      end

      def default?
        eh = @__native.is_default
        return false if eh == 0
        return true if eh == 1

        nil
      end

      def value?
        eh = @__native.has_value
        return false if eh == 0
        return true if eh == 1

        nil
      end

      def attributes?
        Nokogiri::Pure::XmlReaderGlue.has_attributes(@__native) == 1
      end

      def namespaces
        rb_namespaces = {}
        c_reader = @__native
        return rb_namespaces if Nokogiri::Pure::XmlReaderGlue.has_attributes(c_reader) == 0

        c_node = Nokogiri::Pure::XmlReaderGlue.expand_raising(self, c_reader)
        return nil if c_node.nil?

        Nokogiri::Pure::XmlReaderGlue.node_namespaces(c_node, rb_namespaces)
        rb_namespaces
      end

      def attribute_hash
        rb_attributes = {}
        c_reader = @__native
        return rb_attributes if Nokogiri::Pure::XmlReaderGlue.has_attributes(c_reader) == 0

        c_node = Nokogiri::Pure::XmlReaderGlue.expand_raising(self, c_reader)
        return nil if c_node.nil?

        c_property = c_node.properties
        while c_property
          rb_name = Nokogiri::Pure::XmlReaderGlue.str(c_property.name)
          c_value = Nokogiri::Pure::Tree.node_get_content(c_property)
          rb_value = c_value ? Nokogiri::Pure::XmlReaderGlue.str(c_value) : nil
          rb_attributes[rb_name] = rb_value
          c_property = c_property.next
        end
        rb_attributes
      end

      def attribute_at(index)
        return nil if index.nil?

        index = Integer(index)
        value = @__native.get_attribute_no(Nokogiri::Pure::XmlReaderGlue.num2int(index))
        return nil if value.nil?

        Nokogiri::Pure::XmlReaderGlue.str(value)
      end

      def attribute(name)
        return nil if name.nil?

        name = Nokogiri::Pure::XmlReaderGlue.cstr(name)
        value = @__native.get_attribute(name)
        return nil if value.nil?

        Nokogiri::Pure::XmlReaderGlue.str(value)
      end

      def attribute_count
        count = @__native.attribute_count
        return nil if count == -1

        count
      end

      def depth
        d = @__native.get_depth
        return nil if d == -1

        d
      end

      def xml_version
        Nokogiri::Pure::XmlReaderGlue.str(@__native.const_xml_version)
      end

      def lang
        Nokogiri::Pure::XmlReaderGlue.str(@__native.const_xml_lang)
      end

      def value
        Nokogiri::Pure::XmlReaderGlue.str(@__native.const_value)
      end

      def prefix
        Nokogiri::Pure::XmlReaderGlue.str(@__native.const_prefix)
      end

      def namespace_uri
        Nokogiri::Pure::XmlReaderGlue.str(@__native.const_namespace_uri)
      end

      def local_name
        Nokogiri::Pure::XmlReaderGlue.str(@__native.const_local_name)
      end

      def name
        Nokogiri::Pure::XmlReaderGlue.str(@__native.const_name)
      end

      def base_uri
        Nokogiri::Pure::XmlReaderGlue.str(@__native.base_uri)
      end

      def state
        @__native.read_state
      end

      def node_type
        @__native.node_type
      end

      def read
        c_reader = @__native
        rb_errors = errors
        status = Nokogiri::Pure::Errors.with_handler(Nokogiri::Pure::XmlReaderGlue.pusher(rb_errors)) do
          c_reader.read
        end

        c_document = c_reader.current_doc
        if c_document && c_document.encoding.nil?
          constructor_encoding = @encoding
          if constructor_encoding
            c_document.encoding = Nokogiri::Pure::XmlReaderGlue.cstr(constructor_encoding).dup
          else
            @encoding = "UTF-8"
            c_document.encoding = +"UTF-8"
          end
        end

        return self if status == 1
        return nil if status == 0

        exception = Nokogiri::XML::SyntaxError.aggregate(rb_errors)
        raise exception if exception

        raise RuntimeError, "Error pulling: #{status}"
      end

      def inner_xml
        value = @__native.read_inner_xml
        value ? Nokogiri::Pure::XmlReaderGlue.str(value) : nil
      end

      def outer_xml
        value = @__native.read_outer_xml
        value ? Nokogiri::Pure::XmlReaderGlue.str(value) : nil
      end

      def empty_element?
        @__native.is_empty_element != 0
      end

      def encoding
        parser_encoding = @__native.const_encoding
        return Nokogiri::Pure::XmlReaderGlue.str(parser_encoding) if parser_encoding

        constructor_encoding = @encoding
        return constructor_encoding if constructor_encoding

        nil
      end
    end
  end

  module Pure
    module XmlReaderGlue
      module_function

      # NOKOGIRI_STR_NEW2
      def str(s)
        return nil if s.nil?

        s.dup.force_encoding(Encoding::UTF_8)
      end

      # StringValue
      def string_value(v)
        return v if v.is_a?(String)

        s = String.try_convert(v)
        raise TypeError, "no implicit conversion of #{Pure::XmlReaderGlue.type_name(v)} into String" if s.nil?

        s
      end

      def type_name(v)
        case v
        when nil then "nil"
        when true then "true"
        when false then "false"
        else v.class.to_s
        end
      end

      # StringValueCStr
      def cstr(v)
        s = string_value(v)
        raise ArgumentError, "string contains null byte" if s.include?("\0")

        s
      end

      # NUM2INT
      def num2int(v)
        raise TypeError, "no implicit conversion from nil to integer" if v.nil?

        i = if v.is_a?(Integer)
          v
        elsif v.is_a?(Float)
          raise FloatDomainError, v.to_s if v.nan? || v.infinite?

          v.to_i
        else
          raise TypeError, "no implicit conversion of #{type_name(v)} into Integer" unless v.respond_to?(:to_int)

          v.to_int
        end
        if i > 2_147_483_647 || i < -2_147_483_648
          raise RangeError, "integer #{i} too #{i < 0 ? "small" : "big"} to convert to 'int'"
        end

        i
      end

      # noko__error_array_pusher
      def pusher(list)
        lambda do |err|
          unless list.is_a?(Array)
            raise TypeError, "wrong argument type #{type_name(list)} (expected Array)"
          end

          list << Pure.wrap_error(err)
        end
      end

      # has_attributes()
      def has_attributes(reader)
        node = reader.current_node
        return 0 if node.nil?
        return 1 if node.type == ELEMENT_NODE && (node.properties || node.ns_def)

        0
      end

      # the Expand dance shared by #namespaces and #attribute_hash
      def expand_raising(rb_reader, c_reader)
        rb_errors = rb_reader.errors
        c_node = nil
        # xmlSetStructuredErrorFunc(errors, pusher); ...; xmlSetStructuredErrorFunc(NULL, NULL)
        Errors.handler = pusher(rb_errors)
        begin
          c_node = c_reader.expand
        ensure
          Errors.handler = nil
        end
        if c_node.nil?
          if rb_errors.length > 0
            rb_error = rb_errors[0]
            raise Nokogiri::XML::SyntaxError, rb_error.to_s
          end
          return nil
        end
        c_node
      end

      # Nokogiri_xml_node_namespaces
      def node_namespaces(node, attr_hash)
        return if node.type != ELEMENT_NODE

        ns = node.ns_def
        while ns
          key = +"xmlns"
          if ns.prefix
            key << ":"
            key << ns.prefix
          end
          key.force_encoding(Encoding::UTF_8)
          if Encoding.default_internal
            key = key.encode(Encoding.default_internal)
          end
          attr_hash[key] = ns.href ? str(ns.href) : nil
          ns = ns.next
        end
      end
    end

  end
end
