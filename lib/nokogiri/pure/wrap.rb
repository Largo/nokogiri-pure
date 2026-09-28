# frozen_string_literal: true

module Nokogiri
  module Pure
    # Ruby wrapper <-> tree struct plumbing (the equivalents of noko_xml_node_wrap & friends).
    #
    # Each wrapper object keeps its struct in the ivar @__native; each struct keeps its wrapper
    # in #_private (documents in #_ruby_doc), exactly like the C extension's DATA_PTR/_private.

    CLASS_FOR_TYPE = {}

    module_function

    def init_class_table
      return unless CLASS_FOR_TYPE.empty?

      CLASS_FOR_TYPE.merge!(
        ELEMENT_NODE => Nokogiri::XML::Element,
        TEXT_NODE => Nokogiri::XML::Text,
        ATTRIBUTE_NODE => Nokogiri::XML::Attr,
        ENTITY_REF_NODE => Nokogiri::XML::EntityReference,
        COMMENT_NODE => Nokogiri::XML::Comment,
        DOCUMENT_FRAG_NODE => Nokogiri::XML::DocumentFragment,
        PI_NODE => Nokogiri::XML::ProcessingInstruction,
        ENTITY_DECL => Nokogiri::XML::EntityDecl,
        CDATA_SECTION_NODE => Nokogiri::XML::CDATA,
        DTD_NODE => Nokogiri::XML::DTD,
        ATTRIBUTE_DECL => Nokogiri::XML::AttributeDecl,
        ELEMENT_DECL => Nokogiri::XML::ElementDecl,
      )
    end

    # noko_xml_node_wrap
    def wrap_node(c_node, klass = nil)
      return nil if c_node.nil?

      type = c_node.type
      if type == DOCUMENT_NODE || type == HTML_DOCUMENT_NODE
        return c_node._ruby_doc
      end

      c_doc = c_node.doc
      rb_doc = c_doc&._ruby_doc
      if rb_doc && (existing = c_node._private)
        return existing
      end

      klass ||= CLASS_FOR_TYPE[type] || Nokogiri::XML::Node
      rb_node = klass.allocate
      rb_node.instance_variable_set(:@__native, c_node)
      c_node._private = rb_node
      rb_doc&.decorate(rb_node)
      rb_node
    end

    # noko_xml_document_wrap_with_init_args
    def wrap_document(klass, c_doc, args = [])
      klass ||= Nokogiri::XML::Document
      rb_doc = klass.allocate
      rb_doc.instance_variable_set(:@__native, c_doc)
      c_doc._ruby_doc = rb_doc
      rb_doc.instance_variable_set(:@node_cache, [])
      rb_doc.instance_variable_set(:@decorators, nil)
      rb_doc.instance_variable_set(:@errors, nil)
      rb_doc.__send__(:initialize, *args)
      rb_doc
    end

    # noko_xml_namespace_wrap
    def wrap_namespace(c_ns, c_doc)
      if (existing = c_ns._private)
        return existing
      end

      rb_ns = Class.instance_method(:allocate).bind_call(Nokogiri::XML::Namespace)
      rb_ns.instance_variable_set(:@__native, c_ns)
      if c_doc && (rb_doc = c_doc._ruby_doc)
        rb_ns.instance_variable_set(:@document, rb_doc)
      end
      c_ns._private = rb_ns
      rb_ns
    end

    # noko_xml_node_wrap_node_set_result
    def wrap_node_set_result(c_node)
      if c_node.is_a?(XmlNs)
        wrap_namespace(c_node, nil)
      else
        wrap_node(c_node)
      end
    end

    # noko_xml_node_set_wrap
    def wrap_node_set(c_nodes, rb_document)
      set = Nokogiri::XML::NodeSet.allocate
      set.instance_variable_set(:@__native, c_nodes || [])
      unless rb_document.nil?
        set.instance_variable_set(:@document, rb_document)
        rb_document.decorate(set)
      end
      c_nodes&.each { |n| wrap_node_set_result(n) }
      set
    end

    def unwrap(rb_obj)
      c = rb_obj.instance_variable_get(:@__native)
      raise RuntimeError, "Uninitialized #{rb_obj.class} struct (null data pointer)" if c.nil?

      c
    end

    def unwrap_document(rb_doc)
      unwrap(rb_doc)
    end

    def node_set_nodes(rb_set)
      rb_set.instance_variable_get(:@__native) || rb_set.instance_variable_set(:@__native, [])
    end

    # used by glue code to raise aggregated parse errors
    def raise_aggregate(errors, fallback)
      exception = Nokogiri::XML::SyntaxError.aggregate(errors)
      raise exception if exception

      raise RuntimeError, fallback
    end

    def str_or_nil(s)
      s&.dup
    end
  end
end
