# frozen_string_literal: true

# Port of ext/nokogiri/xml_document.c

module Nokogiri
  module XML
    class Document < Node
      class << self
        def read_io(io, url, encoding, options)
          errors = []
          c_document = Nokogiri::Pure::Errors.collecting(errors) do
            Nokogiri::Pure::Parser.read_io(io, url&.to_str, encoding&.to_str, Integer(options))
          end
          if c_document.nil?
            Nokogiri::Pure.raise_aggregate(errors, "Could not parse document")
          end
          rb_document = Nokogiri::Pure.wrap_document(self, c_document)
          rb_document.instance_variable_set(:@errors, errors)
          rb_document
        end

        def read_memory(input, url, encoding, options)
          errors = []
          input = input.to_str
          c_document = Nokogiri::Pure::Errors.collecting(errors) do
            Nokogiri::Pure::Parser.read_memory(input, url&.to_str, encoding&.to_str, Integer(options))
          end
          if c_document.nil?
            Nokogiri::Pure.raise_aggregate(errors, "Could not parse document")
          end
          rb_document = Nokogiri::Pure.wrap_document(self, c_document)
          rb_document.instance_variable_set(:@errors, errors)
          rb_document
        end

        def new(*args)
          version = args[0]
          version = "1.0" if version.nil?
          doc = Nokogiri::Pure::Tree.new_doc(version.to_str)
          Nokogiri::Pure.wrap_document(self, doc, args)
        end
      end

      def root
        c_root = Nokogiri::Pure::Tree.doc_get_root_element(@__native)
        c_root && Nokogiri::Pure.wrap_node(c_root)
      end

      def root=(new_root)
        t = Nokogiri::Pure::Tree
        c_document = @__native
        c_new_root = nil
        unless new_root.nil?
          unless new_root.is_a?(Nokogiri::XML::Node)
            raise ArgumentError, "expected Nokogiri::XML::Node but received #{new_root.class}"
          end

          c_new_root = Nokogiri::Pure.unwrap(new_root)
          raise TypeError, "root must be a Nokogiri::XML::Element" if c_new_root.type != Nokogiri::Pure::ELEMENT_NODE
        end
        c_current_root = t.doc_get_root_element(c_document)
        t.unlink_node(c_current_root) if c_current_root
        if c_new_root && !c_new_root.doc.equal?(c_document)
          c_new_root = t.doc_copy_node(c_new_root, c_document, 1)
          raise RuntimeError, "Could not reparent node (xmlDocCopyNode)" if c_new_root.nil?
        end
        t.doc_set_root_element(c_document, c_new_root) if c_new_root
        new_root
      end

      def encoding
        @__native.encoding&.dup
      end

      def encoding=(encoding)
        @__native.encoding = encoding.to_str.dup
        encoding
      end

      def version
        @__native.version&.dup
      end

      def url
        @__native.url&.dup
      end

      def canonicalize(mode = nil, namespaces = nil, with_comments = nil, &block)
        c_mode = 0
        unless mode.nil?
          raise TypeError, "wrong argument type #{mode.class} (expected Integer)" unless mode.is_a?(Integer)

          c_mode = mode
        end
        unless namespaces.nil?
          raise TypeError, "wrong argument type #{namespaces.class} (expected Array)" unless namespaces.is_a?(Array)
          if c_mode == 0 || c_mode == 2
            raise RuntimeError, "This canonicalizer does not support this operation"
          end
        end
        callback = nil
        if block
          callback = lambda do |c_node, c_parent|
            rb_node = if c_node.is_a?(Nokogiri::Pure::XmlNs)
              Nokogiri::Pure.wrap_namespace(c_node, c_parent.doc)
            else
              Nokogiri::Pure.wrap_node(c_node)
            end
            rb_parent = c_parent ? Nokogiri::Pure.wrap_node(c_parent) : nil
            block.call(rb_node, rb_parent) ? true : false
          end
        end
        ns_list = namespaces&.map(&:to_str)
        out = Nokogiri::Pure::C14N.execute(@__native, callback, c_mode, ns_list, with_comments ? true : false)
        raise RuntimeError, "canonicalization failed" if out.nil?

        out
      end

      def create_entity(name, type = nil, external_id = nil, system_id = nil, content = nil)
        c_document = @__native
        errors = []
        err_code, c_entity = Nokogiri::Pure::Errors.collecting(errors) do
          Nokogiri::Pure::Tree.add_entity(
            c_document, false,
            name&.to_str,
            type.nil? ? Nokogiri::Pure::INTERNAL_GENERAL_ENTITY : Integer(type),
            external_id&.to_str,
            system_id&.to_str,
            content&.to_str,
          )
        end
        if c_entity.nil?
          if errors.empty? && err_code
            errors << Nokogiri::Pure.wrap_error(Nokogiri::Pure::Parser.entity_add_error(err_code, name))
          end
          Nokogiri::Pure.raise_aggregate(errors, "Could not create entity")
        end
        Nokogiri::Pure.wrap_node(c_entity, Nokogiri::XML::EntityDecl)
      end

      def remove_namespaces!
        __remove_namespaces_from_node(@__native)
        self
      end

      protected

      def initialize_copy_with_args(other, level)
        c_other = Nokogiri::Pure.unwrap_document(other)
        c_self = Nokogiri::Pure::Tree.copy_doc(c_other, Integer(level))
        return nil if c_self.nil?

        c_self.type = c_other.type
        @__native = c_self
        c_self._ruby_doc = self
        @node_cache = []
        self
      end

      private

      def __remove_namespaces_from_node(node)
        Nokogiri::Pure::Tree.set_ns(node, nil)
        child = node.children
        while child
          __remove_namespaces_from_node(child)
          child = child.next
        end
        if [Nokogiri::Pure::ELEMENT_NODE, Nokogiri::Pure::XINCLUDE_START, Nokogiri::Pure::XINCLUDE_END].include?(node.type) &&
            node.ns_def
          node.ns_def = nil
        end
        if node.type == Nokogiri::Pure::ELEMENT_NODE
          prop = node.properties
          while prop
            prop.ns = nil
            prop = prop.next
          end
        end
      end
    end
  end
end
