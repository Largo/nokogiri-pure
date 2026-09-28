# frozen_string_literal: true

# Port of ext/nokogiri/xml_node.c and the small node-subclass glue files.

module Nokogiri
  module XML
    class Node
      T = Nokogiri::Pure::Tree
      P = Nokogiri::Pure
      private_constant :T, :P

      class << self
        # an allocated-but-uninitialized node has a NULL data pointer in C
        def allocate
          obj = super
          obj.instance_variable_set(:@__native, Nokogiri::Pure::Uninitialized.new(obj.class))
          obj
        end

        # rb_xml_node_new
        def new(name, document, *rest, &block)
          unless document.is_a?(Nokogiri::XML::Node)
            raise ArgumentError, "document must be a Nokogiri::XML::Node"
          end
          unless document.is_a?(Nokogiri::XML::Document)
            warn("Passing a Node as the second parameter to Node.new is deprecated. Please pass a Document instead, or prefer an alternative constructor like Node#add_child. This will become an error in Nokogiri v1.17.0.", uplevel: 1, category: :deprecated)
          end
          c_document_node = P.unwrap(document)
          c_node = T.new_node(nil, Nokogiri::Pure.str(name))
          c_node.doc = c_document_node.doc
          rb_node = P.wrap_node(c_node, equal?(Nokogiri::XML::Node) ? nil : self)
          rb_node.__send__(:initialize, name, document, *rest)
          yield rb_node if block
          rb_node
        end
      end

      # ---- reparenting helpers (xml_node.c statics) ----------------------------

      class << self
        def __relink_namespace(reparented) # :nodoc:
          return if reparented.type != P::ATTRIBUTE_NODE && reparented.type != P::ELEMENT_NODE

          if reparented.ns.nil? || reparented.ns.prefix.nil?
            name, prefix = T.split_qname2(reparented.name)
            if reparented.type == P::ATTRIBUTE_NODE
              return if prefix.nil? || prefix == "xmlns"
            end
            ns = T.search_ns(reparented.doc, reparented, prefix)
            if ns
              T.node_set_name(reparented, name) if name
              T.set_ns(reparented, ns)
            end
          end

          return if reparented.type != P::ELEMENT_NODE || reparented.parent.nil?

          doc = reparented.doc
          if reparented.ns.nil? && !reparented.parent.equal?(doc) &&
              doc._ruby_doc&.instance_variable_get(:@namespace_inheritance) == true
            T.set_ns(reparented, reparented.parent.ns)
          end

          if reparented.ns_def
            curr = reparented.ns_def
            prev = nil
            while curr
              ns = T.search_ns_by_href(doc, reparented.parent, curr.href)
              if ns && !ns.equal?(curr) && ns.prefix == curr.prefix
                if prev
                  prev.next = curr.next
                else
                  reparented.ns_def = curr.next
                end
              else
                prev = curr
              end
              curr = curr.next
            end
          end

          if reparented.ns
            ns = T.search_ns(doc, reparented, reparented.ns.prefix)
            if ns && !ns.equal?(reparented.ns) && ns.prefix == reparented.ns.prefix &&
                ns.href == reparented.ns.href
              T.set_ns(reparented, ns)
            end
          end

          return if reparented.ns.nil?

          child = reparented.children
          while child
            __relink_namespace(child)
            child = child.next
          end
          if reparented.type == P::ELEMENT_NODE
            attr = reparented.properties
            while attr
              __relink_namespace(attr)
              attr = attr.next
            end
          end
        end

        def __replace_node_wrapper(pivot, new_node) # :nodoc:
          retval = T.replace_node(pivot, new_node)
          retval = new_node if retval.equal?(pivot)
          if retval && retval.type == P::TEXT_NODE
            if retval.prev && retval.prev.type == P::TEXT_NODE
              retval = T.text_merge(retval.prev, retval)
            end
            if retval.next && retval.next.type == P::TEXT_NODE
              retval = T.text_merge(retval, retval.next)
            end
          end
          retval
        end
      end

      private def __reparent_node_with(reparentee_obj, prf)
        unless reparentee_obj.is_a?(Nokogiri::XML::Node)
          raise ArgumentError, "node must be a Nokogiri::XML::Node"
        end
        if reparentee_obj.is_a?(Nokogiri::XML::Document)
          raise ArgumentError, "node must be a Nokogiri::XML::Node"
        end

        reparentee = P.unwrap(reparentee_obj)
        pivot = @__native

        parent = prf == :add_child ? pivot : pivot.parent
        if parent
          ok = case parent.type
          when P::DOCUMENT_NODE, P::HTML_DOCUMENT_NODE
            [P::ELEMENT_NODE, P::PI_NODE, P::COMMENT_NODE, P::DOCUMENT_TYPE_NODE, P::TEXT_NODE,
             P::CDATA_SECTION_NODE, P::ENTITY_REF_NODE].include?(reparentee.type)
          when P::DOCUMENT_FRAG_NODE, P::ENTITY_REF_NODE, P::ELEMENT_NODE
            [P::ELEMENT_NODE, P::PI_NODE, P::COMMENT_NODE, P::TEXT_NODE, P::CDATA_SECTION_NODE,
             P::ENTITY_REF_NODE].include?(reparentee.type)
          when P::ATTRIBUTE_NODE
            [P::TEXT_NODE, P::ENTITY_REF_NODE].include?(reparentee.type)
          else
            false
          end
          raise ArgumentError, "cannot reparent #{reparentee_obj.class} there" unless ok
        end

        original_reparentee = reparentee

        if !reparentee.doc.equal?(pivot.doc) || reparentee.type == P::TEXT_NODE
          reparentee._private = nil if reparentee.type == P::TEXT_NODE
          original_ns_prefix_is_default = reparentee.ns && reparentee.ns.prefix.nil?
          reparentee = T.doc_copy_node(reparentee, pivot.doc, 1)
          raise RuntimeError, "Could not reparent node (xmlDocCopyNode)" if reparentee.nil?

          if original_ns_prefix_is_default && reparentee.ns && reparentee.ns.prefix
            reparentee.ns.prefix = nil
          end
        end

        T.unlink_node(original_reparentee)

        if prf == :replace && reparentee.type == P::TEXT_NODE && pivot.next && pivot.next.type == P::TEXT_NODE
          next_text = pivot.next
          new_next_text = T.doc_copy_node(next_text, pivot.doc, 1)
          T.unlink_node(next_text)
          T.add_next_sibling(pivot, new_next_text)
        end

        reparented = case prf
        when :add_child then T.add_child(pivot, reparentee)
        when :add_next then T.add_next_sibling(pivot, reparentee)
        when :add_prev then T.add_prev_sibling(pivot, reparentee)
        when :replace then Node.__replace_node_wrapper(pivot, reparentee)
        end
        raise RuntimeError, "Could not reparent node" if reparented.nil?

        reparentee_obj.instance_variable_set(:@__native, reparented)
        reparented_obj = P.wrap_node(reparented)
        reparented_obj.decorate!

        # raise_if_ancestor_of_self
        ancestor = reparented.parent
        while ancestor
          if ancestor.equal?(reparented)
            raise RuntimeError, "cycle detected: node '#{reparented.name}' is an ancestor of itself"
          end

          ancestor = ancestor.parent
        end

        Node.__relink_namespace(reparented)
        reparented_obj
      end

      # ---- public native methods --------------------------------------------

      def add_namespace_definition(prefix, href)
        c_node = @__native
        element = c_node
        c_prefix = Nokogiri::Pure.str_opt(prefix)
        c_namespace = T.search_ns(c_node.doc, c_node, c_prefix)
        unless c_namespace
          element = c_node.parent if c_node.type != P::ELEMENT_NODE
          c_namespace = T.new_ns(element, Nokogiri::Pure.str(href), c_prefix)
        end
        return nil unless c_namespace

        if prefix.nil? || !c_node.equal?(element)
          T.set_ns(c_node, c_namespace)
        end
        P.wrap_namespace(c_namespace, c_node.doc)
      end

      def attribute(name)
        prop = T.has_prop(@__native, Nokogiri::Pure.str(name))
        return nil unless prop

        P.wrap_node(prop)
      end

      def attribute_nodes
        out = []
        c_node = @__native
        # xmlElement (an <!ELEMENT> decl) keeps its attribute decls where xmlNode keeps properties
        prop = c_node.is_a?(Nokogiri::Pure::XmlElementDecl) ? c_node.attributes : c_node.properties
        while prop
          out << P.wrap_node(prop)
          prop = prop.next
        end
        out
      end

      def attribute_with_ns(name, namespace)
        prop = T.has_ns_prop(@__native, Nokogiri::Pure.str(name), Nokogiri::Pure.str_opt(namespace))
        return nil unless prop

        P.wrap_node(prop)
      end

      def blank?
        T.is_blank_node(@__native)
      end

      def child
        c = @__native.children
        c && P.wrap_node(c)
      end

      def children
        node = @__native
        list = []
        c = node.children
        while c
          list << c
          c = c.next
        end
        P.wrap_node_set(list, node.doc._ruby_doc)
      end

      def content
        c = T.node_get_content(@__native)
        c&.force_encoding(Encoding::UTF_8)
      end

      def create_external_subset(name, external_id, system_id)
        doc = @__native.doc
        raise RuntimeError, "Document already has an external subset" if doc.ext_subset

        dtd = T.new_dtd(doc, Nokogiri::Pure.str_opt(name), Nokogiri::Pure.str_opt(external_id), Nokogiri::Pure.str_opt(system_id))
        dtd && P.wrap_node(dtd)
      end

      def create_internal_subset(name, external_id, system_id)
        doc = @__native.doc
        raise RuntimeError, "Document already has an internal subset" if T.get_int_subset(doc)

        dtd = T.create_int_subset(doc, Nokogiri::Pure.str_opt(name), Nokogiri::Pure.str_opt(external_id), Nokogiri::Pure.str_opt(system_id))
        dtd && P.wrap_node(dtd)
      end

      def data_ptr?
        !@__native.nil?
      end

      def document
        @__native.doc._ruby_doc
      end

      def element_children
        node = @__native
        list = []
        c = T.first_element_child(node)
        while c
          list << c
          c = T.next_element_sibling(c)
        end
        P.wrap_node_set(list, node.doc._ruby_doc)
      end

      def encode_special_chars(string)
        T.encode_special_chars(@__native.doc, Nokogiri::Pure.str(string))
      end

      def external_subset
        doc = @__native.doc
        return nil unless doc

        dtd = doc.ext_subset
        dtd && P.wrap_node(dtd)
      end

      def first_element_child
        c = T.first_element_child(@__native)
        c && P.wrap_node(c)
      end

      def internal_subset
        doc = @__native.doc
        return nil unless doc

        dtd = T.get_int_subset(doc)
        dtd && P.wrap_node(dtd)
      end

      def key?(attribute)
        !T.has_prop(@__native, Nokogiri::Pure.str(attribute)).nil?
      end

      def lang
        T.node_get_lang(@__native)
      end

      def lang=(lang)
        T.node_set_lang(@__native, Nokogiri::Pure.str(lang))
        nil
      end

      def last_element_child
        c = T.last_element_child(@__native)
        c && P.wrap_node(c)
      end

      def line
        T.get_line_no(@__native)
      end

      def line=(line_number)
        c_node = @__native
        line_number = Nokogiri::Pure.int(line_number)
        if line_number < 65535
          c_node.line = line_number
        else
          c_node.line = 65535
          c_node.psvi = line_number if c_node.type == P::TEXT_NODE
        end
        line_number
      end

      def namespace
        c_node = @__native
        c_node.ns && P.wrap_namespace(c_node.ns, c_node.doc)
      end

      def namespace_definitions
        c_node = @__native
        out = []
        ns = c_node.ns_def
        while ns
          out << P.wrap_namespace(ns, c_node.doc)
          ns = ns.next
        end
        out
      end

      def namespace_scopes
        c_node = @__native
        list = T.get_ns_list(c_node.doc, c_node)
        return [] unless list

        list.map { |ns| P.wrap_namespace(ns, c_node.doc) }
      end

      def namespaced_key?(attribute, namespace)
        !T.has_ns_prop(@__native, Nokogiri::Pure.str(attribute), Nokogiri::Pure.str_opt(namespace)).nil?
      end

      def native_content=(content)
        node = @__native
        child = node.children
        while child
          nxt = child.next
          T.unlink_node(child)
          child = nxt
        end
        T.node_set_content(node, Nokogiri::Pure.str(content))
        content
      end

      def next_element
        s = T.next_element_sibling(@__native)
        s && P.wrap_node(s)
      end

      def next_sibling
        s = @__native.next
        s && P.wrap_node(s)
      end

      def node_name
        n = @__native.name
        n&.dup&.force_encoding(Encoding::UTF_8)
      end

      def node_name=(new_name)
        T.node_set_name(@__native, Nokogiri::Pure.str(new_name))
        new_name
      end

      def node_type
        @__native.type
      end

      def parent
        p = @__native.parent
        p && P.wrap_node(p)
      end

      def path
        T.get_node_path(@__native) || "?"
      end

      def pointer_id
        @__native.object_id
      end

      def previous_element
        s = T.previous_element_sibling(@__native)
        s && P.wrap_node(s)
      end

      def previous_sibling
        s = @__native.prev
        s && P.wrap_node(s)
      end

      def unlink
        T.unlink_node(@__native)
        self
      end

      protected

      def initialize_copy_with_args(other, level, new_parent_doc)
        unless other.is_a?(Nokogiri::XML::Node)
          raise TypeError, "argument must be a kind of Nokogiri::XML::Node"
        end

        c_other = P.unwrap(other)
        c_new_parent_doc = P.unwrap_document(new_parent_doc)
        c_self = T.doc_copy_node(c_other, c_new_parent_doc, Nokogiri::Pure.int(level))
        return nil if c_self.nil?

        @__native = c_self
        c_self._private = self
        new_parent_doc.decorate(self)
        self
      end

      def safe_process_xinclude(flags)
        c_node = @__native
        raise RuntimeError, "cannot process XInclude on an unlinked <xi:include> node" if c_node.parent.nil?

        c_copy = T.doc_copy_node(c_node, c_node.doc, 1)
        raise RuntimeError, "Could not copy node for xinclude substitution" if c_copy.nil?

        T.replace_node(c_node, c_copy)
        __process_xinclude_subtree(c_copy, Nokogiri::Pure.int(flags))
        nil
      end

      private

      def add_child_node(new_child)
        __reparent_node_with(new_child, :add_child)
      end

      def add_next_sibling_node(new_sibling)
        __reparent_node_with(new_sibling, :add_next)
      end

      def add_previous_sibling_node(new_sibling)
        __reparent_node_with(new_sibling, :add_prev)
      end

      def replace_node(new_node)
        __reparent_node_with(new_node, :replace)
      end

      def compare(other)
        P::XPath.cmp_nodes(P.unwrap(other), @__native)
      end

      def dump_html
        P::Save.html_node_dump(@__native.doc, @__native)
      end

      def get(attribute)
        return nil if attribute.nil?

        node = @__native
        attribute = Nokogiri::Pure.str(attribute)
        colon = attribute.index(":")
        value = if colon
          prefix = attribute[0, colon]
          attr_name = attribute[colon + 1..]
          ns = T.search_ns(node.doc, node, prefix)
          if ns
            T.get_ns_prop(node, attr_name, ns.href)
          else
            T.get_prop(node, attribute)
          end
        else
          T.get_no_ns_prop(node, attribute)
        end
        value&.force_encoding(Encoding::UTF_8)
      end

      def set(property, value)
        node = @__native
        return nil if node.type != P::ELEMENT_NODE

        property = Nokogiri::Pure.str(property)
        value = Nokogiri::Pure.str(value)
        prop = T.has_prop(node, property)
        if prop.is_a?(P::XmlAttr) && prop.children
          cur = prop.children
          while cur
            nxt = cur.next
            T.unlink_node(cur) if cur._private
            cur = nxt
          end
        end
        T.set_prop(node, property, value)
        value
      end

      def set_namespace(namespace)
        ns = namespace.nil? ? nil : P.unwrap(namespace)
        T.set_ns(@__native, ns)
        self
      end

      def in_context(str, options)
        P::Parser.node_in_context(self, Nokogiri::Pure.str(str), Nokogiri::Pure.int(options))
      end

      def native_write_to(io, encoding, indent_string, options)
        P::Save.native_write_to(@__native, io, Nokogiri::Pure.str_opt(encoding), Nokogiri::Pure.str(indent_string), Nokogiri::Pure.int(options))
        io
      end

      def prepend_newline?
        P::Save.should_prepend_newline(@__native)
      end

      def html_standard_serialize(preserve_newline)
        P::Save.html_standard_serialize(@__native, preserve_newline ? true : false)
      end

      def process_xincludes(flags)
        c_node = @__native
        if c_node.parent.nil? && __xinclude_element?(c_node)
          raise RuntimeError, "cannot process XInclude on an unlinked <xi:include> node"
        end

        __process_xinclude_subtree(c_node, Nokogiri::Pure.int(flags))
        self
      end

      def __xinclude_element?(c_node)
        c_node.type == P::ELEMENT_NODE && c_node.name == "include" && c_node.ns &&
          (c_node.ns.href == "http://www.w3.org/2003/XInclude" || c_node.ns.href == "http://www.w3.org/2001/XInclude")
      end

      def __process_xinclude_subtree(c_node, flags)
        errors = []
        status = P::Errors.collecting(errors) do
          P::XInclude.process_tree_flags(c_node, flags)
        end
        if status < 0
          P.raise_aggregate(errors, "Could not perform xinclude substitution")
        end
      end
    end

    # ---- Attr ------------------------------------------------------------------
    class Attr < Node
      class << self
        def new(document, name, *rest, &block)
          unless document.is_a?(Nokogiri::XML::Document)
            raise ArgumentError, "parameter must be a Nokogiri::XML::Document"
          end

          xml_doc = Nokogiri::Pure.unwrap_document(document)
          node = Nokogiri::Pure::Tree.new_doc_prop(xml_doc, Nokogiri::Pure.str(name), nil)
          rb_node = Nokogiri::Pure.wrap_node(node, self)
          rb_node.__send__(:initialize, document, name, *rest)
          yield rb_node if block
          rb_node
        end
      end

      def value=(content)
        t = Nokogiri::Pure::Tree
        attr = @__native
        cur = attr.children
        while cur
          nxt = cur.next
          t.unlink_node(cur) if cur._private
          cur = nxt
        end
        if content.nil?
          t.node_set_content(attr, nil)
        else
          value = t.encode_entities_reentrant(attr.doc, Nokogiri::Pure.str(content))
          if value.empty?
            t.node_set_content(attr, nil)
            text = t.new_doc_text(attr.doc, value)
            attr.children = attr.last = text
            text.parent = attr
          else
            t.node_set_content(attr, value)
          end
        end
        content
      end
    end

    # ---- Text / CDATA / Comment / PI / EntityReference ---------------------------
    class Text < CharacterData
      class << self
        def new(string, document, *rest, &block)
          raise TypeError, "wrong argument type #{string.class} (expected String)" unless string.is_a?(String)
          unless document.is_a?(Nokogiri::XML::Node)
            raise TypeError, "expected second parameter to be a Nokogiri::XML::Document, received #{document.class}"
          end

          c_document = if document.is_a?(Nokogiri::XML::Document)
            Nokogiri::Pure.unwrap_document(document)
          else
            warn("Passing a Node as the second parameter to Text.new is deprecated. Please pass a Document instead. This will become an error in Nokogiri v1.17.0.", uplevel: 1, category: :deprecated)
            Nokogiri::Pure.unwrap(document).doc
          end
          c_node = Nokogiri::Pure::Tree.new_doc_text(c_document, string)
          rb_node = Nokogiri::Pure.wrap_node(c_node, self)
          rb_node.__send__(:initialize, string, document, *rest)
          yield rb_node if block
          rb_node
        end
      end
    end

    class CDATA < Text
      class << self
        def new(document, content, *rest, &block)
          raise TypeError, "wrong argument type #{content.class} (expected String)" unless content.is_a?(String)
          unless document.is_a?(Nokogiri::XML::Node)
            raise TypeError, "expected first parameter to be a Nokogiri::XML::Document, received #{document.class}"
          end

          c_document = if document.is_a?(Nokogiri::XML::Document)
            Nokogiri::Pure.unwrap_document(document)
          else
            warn("Passing a Node as the first parameter to CDATA.new is deprecated. Please pass a Document instead. This will become an error in Nokogiri v1.17.0.", uplevel: 1, category: :deprecated)
            Nokogiri::Pure.unwrap(document).doc
          end
          c_node = Nokogiri::Pure::Tree.new_cdata_block(c_document, content)
          rb_node = Nokogiri::Pure.wrap_node(c_node, self)
          rb_node.__send__(:initialize, document, content, *rest)
          yield rb_node if block
          rb_node
        end
      end
    end

    class Comment < CharacterData
      class << self
        def new(document, content, *rest, &block)
          raise TypeError, "wrong argument type #{content.class} (expected String)" unless content.is_a?(String)

          doc_arg = document
          if document.is_a?(Nokogiri::XML::Node)
            doc_arg = document.document
          elsif !document.is_a?(Nokogiri::XML::Document) && !document.is_a?(Nokogiri::XML::DocumentFragment)
            raise ArgumentError, "first argument must be a XML::Document or XML::Node"
          end
          xml_doc = Nokogiri::Pure.unwrap_document(doc_arg)
          node = Nokogiri::Pure::Tree.new_doc_comment(xml_doc, content)
          rb_node = Nokogiri::Pure.wrap_node(node, self)
          rb_node.__send__(:initialize, document, content, *rest)
          yield rb_node if block
          rb_node
        end
      end
    end

    class ProcessingInstruction < Node
      class << self
        def new(document, name, content, *rest, &block)
          xml_doc = Nokogiri::Pure.unwrap_document(document)
          node = Nokogiri::Pure::Tree.new_doc_pi(xml_doc, Nokogiri::Pure.str(name), Nokogiri::Pure.str(content))
          rb_node = Nokogiri::Pure.wrap_node(node, self)
          rb_node.__send__(:initialize, document, name, content, *rest)
          yield rb_node if block
          rb_node
        end
      end
    end

    class EntityReference < Node
      class << self
        def new(document, name, *rest, &block)
          xml_doc = Nokogiri::Pure.unwrap_document(document)
          node = Nokogiri::Pure::Tree.new_reference(xml_doc, Nokogiri::Pure.str(name))
          rb_node = Nokogiri::Pure.wrap_node(node, self)
          rb_node.__send__(:initialize, document, name, *rest)
          yield rb_node if block
          rb_node
        end
      end
    end

    class DocumentFragment < Node
      class << self
        def native_new(rb_doc)
          c_doc = Nokogiri::Pure.unwrap_document(rb_doc)
          c_node = Nokogiri::Pure::Tree.new_doc_fragment(c_doc.doc)
          Nokogiri::Pure.wrap_node(c_node, self)
        end
      end
    end

    # ---- DTD & declarations ------------------------------------------------------
    class DTD < Node
      def notations
        dtd = @__native
        return nil unless dtd.notations

        h = {}
        dtd.notations.each do |name, n|
          h[name.dup] = Nokogiri::XML::Notation.new(n.name&.dup, n.public_id&.dup, n.system_id&.dup)
        end
        h
      end

      def elements
        dtd = @__native
        return nil unless dtd.elements

        h = {}
        dtd.elements.each_value { |e| h[e.name.dup] = Nokogiri::Pure.wrap_node(e) }
        h
      end

      def entities
        dtd = @__native
        return nil unless dtd.entities

        h = {}
        dtd.entities.each { |name, e| h[name.dup] = Nokogiri::Pure.wrap_node(e) }
        h
      end

      def attributes
        dtd = @__native
        h = {}
        return h unless dtd.attributes

        dtd.attributes.each_value { |a| h[a.name.dup] = Nokogiri::Pure.wrap_node(a) }
        h
      end

      def validate(document)
        doc = Nokogiri::Pure.unwrap_document(document)
        errors = []
        Nokogiri::Pure::Errors.collecting_then_clear(errors) do
          Nokogiri::Pure::Valid.validate_dtd(doc, @__native)
        end
        errors
      end

      def system_id
        @__native.system_id&.dup
      end

      def external_id
        @__native.external_id&.dup
      end
    end

    class ElementDecl < Node
      def element_type
        @__native.etype
      end

      def content
        c = @__native.econtent
        return nil unless c

        ElementContent.__wrap(document, c)
      end

      def prefix
        @__native.prefix&.dup
      end
    end

    class AttributeDecl < Node
      def attribute_type
        @__native.atype
      end

      def default
        @__native.default_value&.dup
      end

      def enumeration
        list = []
        enm = @__native.tree
        while enm
          list << enm.name.dup
          enm = enm.next
        end
        list
      end
    end

    class EntityDecl < Node
      INTERNAL_GENERAL = Nokogiri::Pure::INTERNAL_GENERAL_ENTITY
      EXTERNAL_GENERAL_PARSED = Nokogiri::Pure::EXTERNAL_GENERAL_PARSED_ENTITY
      EXTERNAL_GENERAL_UNPARSED = Nokogiri::Pure::EXTERNAL_GENERAL_UNPARSED_ENTITY
      INTERNAL_PARAMETER = Nokogiri::Pure::INTERNAL_PARAMETER_ENTITY
      EXTERNAL_PARAMETER = Nokogiri::Pure::EXTERNAL_PARAMETER_ENTITY
      INTERNAL_PREDEFINED = Nokogiri::Pure::INTERNAL_PREDEFINED_ENTITY

      def original_content
        @__native.orig&.dup
      end

      def content
        @__native.content&.dup
      end

      def entity_type
        @__native.etype
      end

      def external_id
        @__native.external_id&.dup
      end

      def system_id
        @__native.system_id&.dup
      end
    end

    class ElementContent
      class << self
        undef_method :new rescue nil
        undef_method :allocate rescue nil

        def __wrap(rb_document, c) # :nodoc:
          elem = Class.instance_method(:allocate).bind_call(self)
          elem.instance_variable_set(:@__native, c)
          elem.instance_variable_set(:@document, rb_document)
          elem
        end
      end

      def name
        @__native.name&.dup
      end

      def type
        @__native.type
      end

      def occur
        @__native.ocur
      end

      def prefix
        @__native.prefix&.dup
      end

      private

      def c1
        c = @__native.c1
        c && ElementContent.__wrap(@document, c)
      end

      def c2
        c = @__native.c2
        c && ElementContent.__wrap(@document, c)
      end
    end
  end
end
