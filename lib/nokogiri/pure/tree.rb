# frozen_string_literal: true

# A pure-Ruby port of the parts of libxml2's tree model (tree.c, entities.c, parts of valid.c)
# that Nokogiri depends on. Structures and function names deliberately mirror libxml2 so that
# the Nokogiri C glue can be ported line-by-line and libxml2 behaviour can be reproduced.
#
# Naming convention: libxml2 `xmlFooBar(...)` becomes `Tree.foo_bar(...)`.

module Nokogiri
  module Pure
    # xmlElementType
    ELEMENT_NODE = 1
    ATTRIBUTE_NODE = 2
    TEXT_NODE = 3
    CDATA_SECTION_NODE = 4
    ENTITY_REF_NODE = 5
    ENTITY_NODE = 6
    PI_NODE = 7
    COMMENT_NODE = 8
    DOCUMENT_NODE = 9
    DOCUMENT_TYPE_NODE = 10
    DOCUMENT_FRAG_NODE = 11
    NOTATION_NODE = 12
    HTML_DOCUMENT_NODE = 13
    DTD_NODE = 14
    ELEMENT_DECL = 15
    ATTRIBUTE_DECL = 16
    ENTITY_DECL = 17
    NAMESPACE_DECL = 18
    XINCLUDE_START = 19
    XINCLUDE_END = 20

    # xmlEntityType
    INTERNAL_GENERAL_ENTITY = 1
    EXTERNAL_GENERAL_PARSED_ENTITY = 2
    EXTERNAL_GENERAL_UNPARSED_ENTITY = 3
    INTERNAL_PARAMETER_ENTITY = 4
    EXTERNAL_PARAMETER_ENTITY = 5
    INTERNAL_PREDEFINED_ENTITY = 6

    # entity flags
    ENT_PARSED = 1 << 0
    ENT_CHECKED = 1 << 1
    ENT_EXPANDING = 1 << 2
    ENT_CHECKED_LAX = 1 << 3
    ENT_CONTAINS_LT = 1 << 4

    # xmlAttributeType
    ATTRIBUTE_CDATA = 1
    ATTRIBUTE_ID = 2
    ATTRIBUTE_IDREF = 3
    ATTRIBUTE_IDREFS = 4
    ATTRIBUTE_ENTITY = 5
    ATTRIBUTE_ENTITIES = 6
    ATTRIBUTE_NMTOKEN = 7
    ATTRIBUTE_NMTOKENS = 8
    ATTRIBUTE_ENUMERATION = 9
    ATTRIBUTE_NOTATION = 10

    # xmlAttributeDefault
    ATTRIBUTE_NONE = 1
    ATTRIBUTE_REQUIRED = 2
    ATTRIBUTE_IMPLIED = 3
    ATTRIBUTE_FIXED = 4

    # xmlElementTypeVal
    ELEMENT_TYPE_UNDEFINED = 0
    ELEMENT_TYPE_EMPTY = 1
    ELEMENT_TYPE_ANY = 2
    ELEMENT_TYPE_MIXED = 3
    ELEMENT_TYPE_ELEMENT = 4

    # xmlElementContentType
    ELEMENT_CONTENT_PCDATA = 1
    ELEMENT_CONTENT_ELEMENT = 2
    ELEMENT_CONTENT_SEQ = 3
    ELEMENT_CONTENT_OR = 4

    # xmlElementContentOccur
    ELEMENT_CONTENT_ONCE = 1
    ELEMENT_CONTENT_OPT = 2
    ELEMENT_CONTENT_MULT = 3
    ELEMENT_CONTENT_PLUS = 4

    XML_XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace"
    XML_XMLNS_NAMESPACE = "http://www.w3.org/2000/xmlns/"

    # special node names (libxml2 compares these by pointer)
    STRING_TEXT = "text"
    STRING_TEXT_NOENC = "textnoenc"
    STRING_COMMENT = "comment"

    # xmlNode. Also the base for every other node-like structure.
    class XmlNode
      attr_accessor :_private, :type, :name, :children, :last, :parent, :next, :prev, :doc,
        :ns, :content, :properties, :ns_def, :line, :extra, :psvi

      def initialize(type, name = nil, doc = nil)
        @_private = nil
        @type = type
        @name = name
        @children = nil
        @last = nil
        @parent = nil
        @next = nil
        @prev = nil
        @doc = doc
        @ns = nil
        @content = nil
        @properties = nil
        @ns_def = nil
        @line = 0
        @extra = 0
        @psvi = nil
      end

      def each_child
        c = @children
        while c
          n = c.next
          yield c
          c = n
        end
      end

      def child_list
        out = []
        c = @children
        while c
          out << c
          c = c.next
        end
        out
      end

      def element? = @type == ELEMENT_NODE

      def inspect
        "#<Pure::XmlNode type=#{@type} name=#{@name.inspect}>"
      end
    end

    class XmlAttr < XmlNode
      attr_accessor :atype, :id

      def initialize(name = nil, doc = nil)
        super(ATTRIBUTE_NODE, name, doc)
        @atype = 0
        @id = nil
      end
    end

    class XmlDoc < XmlNode
      attr_accessor :compression, :standalone, :int_subset, :ext_subset, :old_ns, :version,
        :encoding, :ids, :refs, :url, :charset, :parse_flags, :doc_properties, :_ruby_doc

      def initialize(version = "1.0", type = DOCUMENT_NODE)
        super(type, nil, nil)
        @doc = self
        @compression = -1
        @standalone = -1
        @int_subset = nil
        @ext_subset = nil
        @old_ns = nil
        @version = version
        @encoding = nil
        @ids = nil
        @refs = nil
        @url = nil
        @charset = 1
        @parse_flags = 0
        @doc_properties = 0
      end

      def html? = @type == HTML_DOCUMENT_NODE
    end

    class XmlDtd < XmlNode
      attr_accessor :notations, :elements, :attributes, :entities, :pentities, :external_id, :system_id

      def initialize(name = nil, external_id = nil, system_id = nil)
        super(DTD_NODE, name, nil)
        @notations = nil
        @elements = nil
        @attributes = nil
        @entities = nil
        @pentities = nil
        @external_id = external_id
        @system_id = system_id
      end
    end

    class XmlEntity < XmlNode
      attr_accessor :orig, :length, :etype, :external_id, :system_id, :uri, :owner, :flags, :expanded_size

      def initialize(name = nil, etype = nil, doc = nil)
        super(ENTITY_DECL, name, doc)
        @orig = nil
        @length = 0
        @etype = etype
        @external_id = nil
        @system_id = nil
        @uri = nil
        @owner = 0
        @flags = 0
        @expanded_size = 0
      end
    end

    # xmlElement (an <!ELEMENT> declaration)
    class XmlElementDecl < XmlNode
      attr_accessor :etype, :econtent, :attributes, :prefix, :cont_model

      def initialize(name = nil)
        super(ELEMENT_DECL, name, nil)
        @etype = ELEMENT_TYPE_UNDEFINED
        @econtent = nil
        @attributes = nil
        @prefix = nil
        @cont_model = nil
      end
    end

    # xmlAttribute (an <!ATTLIST> declaration)
    class XmlAttributeDecl < XmlNode
      attr_accessor :nexth, :atype, :def, :default_value, :tree, :prefix, :elem

      def initialize(name = nil)
        super(ATTRIBUTE_DECL, name, nil)
        @nexth = nil
        @atype = ATTRIBUTE_CDATA
        @def = ATTRIBUTE_NONE
        @default_value = nil
        @tree = nil # XmlEnumeration list
        @prefix = nil
        @elem = nil
      end
    end

    XmlEnumeration = Struct.new(:name, :next)

    class XmlElementContent
      attr_accessor :type, :ocur, :name, :c1, :c2, :parent, :prefix, :_private

      def initialize(type, name = nil, prefix = nil)
        @type = type
        @ocur = ELEMENT_CONTENT_ONCE
        @name = name
        @prefix = prefix
        @c1 = nil
        @c2 = nil
        @parent = nil
        @_private = nil
      end
    end

    XmlNotation = Struct.new(:name, :public_id, :system_id)
    XmlID = Struct.new(:value, :attr, :name, :lineno, :doc)

    class XmlNs
      attr_accessor :next, :type, :href, :prefix, :_private, :context

      def initialize(href = nil, prefix = nil)
        @next = nil
        @type = NAMESPACE_DECL
        @href = href
        @prefix = prefix
        @_private = nil
        @context = nil
      end

      def inspect
        "#<Pure::XmlNs prefix=#{@prefix.inspect} href=#{@href.inspect}>"
      end
    end

    PREDEFINED_ENTITIES = {}.tap do |h|
      { "lt" => "<", "gt" => ">", "amp" => "&", "quot" => "\"", "apos" => "'" }.each do |name, value|
        e = XmlEntity.new(name, INTERNAL_PREDEFINED_ENTITY, nil)
        e.content = value
        e.orig = value
        e.length = 1
        h[name] = e
      end
      h.freeze
    end

    module Tree
      module_function

      def blank_ch?(c)
        c == " " || c == "\t" || c == "\n" || c == "\r"
      end

      # ---- constructors ---------------------------------------------------

      def new_doc(version = "1.0")
        XmlDoc.new(version || "1.0")
      end

      def new_html_doc
        d = XmlDoc.new(nil, HTML_DOCUMENT_NODE)
        d.charset = 1
        d
      end

      def new_node(ns, name)
        new_doc_node(nil, ns, name, nil)
      end

      def new_doc_node(doc, ns, name, content = nil)
        return nil if name.nil?

        cur = XmlNode.new(ELEMENT_NODE, -name, doc)
        cur.ns = ns
        if content
          node_parse_content(cur, content)
        end
        cur
      end

      # xmlNewDocRawNode: no entity parsing of content
      def new_doc_raw_node(doc, ns, name, content = nil)
        cur = new_doc_node(doc, ns, name)
        if cur && content
          t = new_doc_text(doc, content)
          add_child(cur, t)
        end
        cur
      end

      def new_text(content)
        t = XmlNode.new(TEXT_NODE, STRING_TEXT, nil)
        t.content = content.nil? ? nil : +content.to_s
        t
      end

      def new_doc_text(doc, content)
        t = new_text(content)
        t.doc = doc
        t
      end

      def new_text_noenc(content)
        t = new_text(content)
        t.name = STRING_TEXT_NOENC
        t
      end

      def new_cdata_block(doc, content)
        c = XmlNode.new(CDATA_SECTION_NODE, nil, doc)
        c.content = content.nil? ? nil : +content.to_s
        c
      end

      def new_doc_comment(doc, content)
        c = XmlNode.new(COMMENT_NODE, STRING_COMMENT, doc)
        c.content = content.nil? ? nil : +content.to_s
        c
      end

      def new_doc_pi(doc, name, content)
        return nil if name.nil?

        pi = XmlNode.new(PI_NODE, -name, doc)
        pi.content = content.nil? ? nil : +content.to_s
        pi
      end

      def new_doc_fragment(doc)
        XmlNode.new(DOCUMENT_FRAG_NODE, nil, doc)
      end

      def new_reference(doc, name)
        return nil if name.nil?

        cur = XmlNode.new(ENTITY_REF_NODE, nil, doc)
        if name.start_with?("&")
          name = name[1..]
          name = name[0...-1] if name.end_with?(";")
        end
        cur.name = -name
        ent = get_doc_entity(doc, cur.name)
        if ent
          cur.content = ent.content
          cur.children = ent
          cur.last = ent
        end
        cur
      end

      def new_entity_ref(doc, name)
        cur = XmlNode.new(ENTITY_REF_NODE, -name, doc)
        cur
      end

      def new_char_ref(doc, name)
        return nil if name.nil?

        if name.start_with?("&")
          name = name[1..]
          name = name[0...-1] if name.end_with?(";")
        end
        new_entity_ref(doc, name)
      end

      def new_ns(node, href, prefix)
        return nil if node && node.type != ELEMENT_NODE

        cur = XmlNs.new(href, prefix)
        if node
          if node.ns_def.nil?
            node.ns_def = cur
          else
            prev = node.ns_def
            return nil if prev.prefix == cur.prefix && prev.href

            while prev.next
              prev = prev.next
              return nil if prev.prefix == cur.prefix && prev.href
            end
            prev.next = cur
          end
        end
        cur
      end

      def new_xml_ns
        XmlNs.new(XML_XML_NAMESPACE, "xml")
      end

      def new_doc_prop(doc, name, value)
        return nil if name.nil?

        cur = XmlAttr.new(-name, doc)
        node_parse_content(cur, value) unless value.nil?
        cur
      end

      def new_prop_internal(node, ns, name, value)
        return nil if node && node.type != ELEMENT_NODE

        cur = XmlAttr.new(-name, nil)
        cur.parent = node
        doc = nil
        if node
          doc = node.doc
          cur.doc = doc
        end
        cur.ns = ns
        unless value.nil?
          t = new_doc_text(doc, value)
          t.parent = cur
          cur.children = t
          cur.last = t
          if doc && is_id(doc, node, cur)
            add_id(cur, value)
          end
        end
        if node
          if node.properties.nil?
            node.properties = cur
          else
            prev = node.properties
            prev = prev.next while prev.next
            prev.next = cur
            cur.prev = prev
          end
        end
        cur
      end

      def new_prop(node, name, value)
        new_prop_internal(node, nil, name, value)
      end

      def new_ns_prop(node, ns, name, value)
        new_prop_internal(node, ns, name, value)
      end

      def new_dtd(doc, name, external_id, system_id)
        return nil if doc&.ext_subset

        cur = XmlDtd.new(name, external_id, system_id)
        doc.ext_subset = cur if doc
        cur.doc = doc
        cur
      end

      def get_int_subset(doc)
        return nil if doc.nil?

        cur = doc.children
        while cur
          return cur if cur.type == DTD_NODE

          cur = cur.next
        end
        doc.int_subset
      end

      def create_int_subset(doc, name, external_id, system_id)
        if doc
          cur = get_int_subset(doc)
          return cur if cur
        end
        cur = XmlDtd.new(name, external_id, system_id)
        if doc
          doc.int_subset = cur
          cur.parent = doc
          cur.doc = doc
          if doc.children.nil?
            doc.children = cur
            doc.last = cur
          elsif doc.type == HTML_DOCUMENT_NODE
            prev = doc.children
            prev.prev = cur
            cur.next = prev
            doc.children = cur
          else
            nxt = doc.children
            nxt = nxt.next while nxt && nxt.type != ELEMENT_NODE
            if nxt.nil?
              cur.prev = doc.last
              cur.prev.next = cur
              cur.next = nil
              doc.last = cur
            else
              cur.next = nxt
              cur.prev = nxt.prev
              if cur.prev.nil?
                doc.children = cur
              else
                cur.prev.next = cur
              end
              nxt.prev = cur
            end
          end
        end
        cur
      end

      # ---- structural manipulation -----------------------------------------

      def unlink_node_internal(cur)
        if (parent = cur.parent)
          if cur.type == ATTRIBUTE_NODE
            parent.properties = cur.next if parent.properties.equal?(cur)
          else
            parent.children = cur.next if parent.children.equal?(cur)
            parent.last = cur.prev if parent.last.equal?(cur)
          end
          cur.parent = nil
        end
        cur.next.prev = cur.prev if cur.next
        cur.prev.next = cur.next if cur.prev
        cur.next = nil
        cur.prev = nil
      end

      def unlink_node(cur)
        return if cur.nil? || cur.type == NAMESPACE_DECL

        if cur.type == DTD_NODE
          doc = cur.doc
          if doc
            doc.int_subset = nil if doc.int_subset.equal?(cur)
            doc.ext_subset = nil if doc.ext_subset.equal?(cur)
          end
        end
        remove_entity(cur) if cur.type == ENTITY_DECL
        unlink_node_internal(cur)
      end

      def remove_entity(ent)
        dtd = ent.parent
        return unless dtd.is_a?(XmlDtd)

        table = if ent.etype == INTERNAL_PARAMETER_ENTITY || ent.etype == EXTERNAL_PARAMETER_ENTITY
          dtd.pentities
        else
          dtd.entities
        end
        table.delete(ent.name) if table && table[ent.name].equal?(ent)
      end

      def text_add_content(text, content)
        return if content.nil?

        text.content = (text.content || +"") + content
      end

      def text_merge(first, second)
        return second if first.nil?
        return first if second.nil?
        return nil if first.type != TEXT_NODE || second.type != TEXT_NODE ||
          first.equal?(second) || first.name != second.name

        text_add_content(first, second.content)
        unlink_node_internal(second)
        first
      end

      def text_concat(node, content)
        return -1 if node.nil?
        return -1 unless [TEXT_NODE, CDATA_SECTION_NODE, COMMENT_NODE, PI_NODE].include?(node.type)

        text_add_content(node, content)
        0
      end

      def add_child(parent, cur)
        return nil if parent.nil? || cur.nil? || parent.is_a?(XmlNs) || cur.is_a?(XmlNs) || parent.equal?(cur)

        if parent.type == TEXT_NODE
          text_add_content(parent, cur.content)
          return parent
        end
        if cur.type == ATTRIBUTE_NODE
          prev = parent.properties
          prev = prev.next while prev&.next
        else
          prev = parent.last
        end
        return cur if cur.equal?(prev)

        insert_node(parent.doc, cur, parent, prev, nil, true)
      end

      def add_child_list(parent, cur)
        return nil if parent.nil? || cur.nil?

        ret = nil
        while cur
          nxt = cur.next
          ret = add_child(parent, cur)
          cur = nxt
        end
        ret
      end

      def add_next_sibling(prev, cur)
        return nil if prev.nil? || cur.nil? || prev.is_a?(XmlNs) || cur.is_a?(XmlNs) || cur.equal?(prev)
        return cur if cur.equal?(prev.next)

        insert_node(prev.doc, cur, prev.parent, prev, prev.next, false)
      end

      def add_prev_sibling(nxt, cur)
        return nil if nxt.nil? || cur.nil? || nxt.is_a?(XmlNs) || cur.is_a?(XmlNs) || cur.equal?(nxt)
        return cur if cur.equal?(nxt.prev)

        insert_node(nxt.doc, cur, nxt.parent, nxt.prev, nxt, false)
      end

      def add_sibling(node, cur)
        return nil if node.nil? || cur.nil? || node.equal?(cur)

        if node.type != ATTRIBUTE_NODE && node.parent
          node = node.parent.last
        else
          node = node.next while node.next
        end
        return cur if cur.equal?(node)

        insert_node(node.doc, cur, node.parent, node, nil, true)
      end

      def insert_node(doc, cur, parent, prev, nxt, coalesce)
        return insert_prop(doc, cur, parent, prev, nxt) if cur.type == ATTRIBUTE_NODE

        if coalesce && cur.type == TEXT_NODE
          if prev && prev.type == TEXT_NODE && prev.name == cur.name
            text_add_content(prev, cur.content)
            unlink_node_internal(cur)
            return prev
          end
          if nxt && nxt.type == TEXT_NODE && nxt.name == cur.name
            nxt.content = (cur.content || +"") + (nxt.content || "") if cur.content
            unlink_node_internal(cur)
            return nxt
          end
        end

        old_parent = cur.parent
        if old_parent
          old_parent.children = cur.next if old_parent.children.equal?(cur)
          old_parent.last = cur.prev if old_parent.last.equal?(cur)
        end
        cur.next.prev = cur.prev if cur.next
        cur.prev.next = cur.next if cur.prev

        set_tree_doc(cur, doc) unless cur.doc.equal?(doc)

        cur.parent = parent
        cur.prev = prev
        cur.next = nxt
        if prev.nil?
          parent.children = cur if parent
        else
          prev.next = cur
        end
        if nxt.nil?
          parent.last = cur if parent
        else
          nxt.prev = cur
        end
        cur
      end

      def insert_prop(doc, cur, parent, prev, nxt)
        return nil if (prev && prev.type != ATTRIBUTE_NODE) || (nxt && nxt.type != ATTRIBUTE_NODE)

        attr = get_prop_node_internal(parent, cur.name, cur.ns&.href, false)
        unlink_node_internal(cur)
        set_tree_doc(cur, doc) unless cur.doc.equal?(doc)
        cur.parent = parent
        cur.prev = prev
        cur.next = nxt
        if prev.nil?
          parent.properties = cur if parent
        else
          prev.next = cur
        end
        nxt.prev = cur if nxt
        if attr && !attr.equal?(cur)
          remove_prop(attr)
        end
        cur
      end

      def replace_node(old, cur)
        return nil if old.equal?(cur)
        return nil if old.nil? || old.is_a?(XmlNs) || old.parent.nil?

        if cur.nil? || cur.is_a?(XmlNs)
          unlink_node(old)
          return old
        end
        return old if old.type == ATTRIBUTE_NODE && cur.type != ATTRIBUTE_NODE
        return old if cur.type == ATTRIBUTE_NODE && old.type != ATTRIBUTE_NODE

        unlink_node_internal(cur)
        set_tree_doc(cur, old.doc)
        cur.parent = old.parent
        cur.next = old.next
        cur.next.prev = cur if cur.next
        cur.prev = old.prev
        cur.prev.next = cur if cur.prev
        if cur.parent
          if cur.type == ATTRIBUTE_NODE
            cur.parent.properties = cur if cur.parent.properties.equal?(old)
          else
            cur.parent.children = cur if cur.parent.children.equal?(old)
            cur.parent.last = cur if cur.parent.last.equal?(old)
          end
        end
        old.next = old.prev = nil
        old.parent = nil
        old
      end

      def set_tree_doc(tree, doc)
        return if tree.nil? || tree.is_a?(XmlNs)
        return if tree.doc.equal?(doc)

        if tree.type == ELEMENT_NODE
          prop = tree.properties
          while prop
            set_list_doc(prop.children, doc) if prop.children
            node_set_doc(prop, doc)
            prop = prop.next
          end
        end
        if tree.children && tree.type != ENTITY_REF_NODE
          set_list_doc(tree.children, doc)
        end
        node_set_doc(tree, doc)
      end

      def set_list_doc(list, doc)
        cur = list
        while cur
          set_tree_doc(cur, doc) unless cur.doc.equal?(doc)
          cur = cur.next
        end
      end

      def node_set_doc(node, doc)
        old_doc = node.doc
        case node.type
        when ATTRIBUTE_NODE
          remove_id(old_doc, node) if node.id
        when ENTITY_REF_NODE
          node.children = nil
          node.last = nil
          node.content = nil
          if doc && (doc.int_subset || doc.ext_subset)
            ent = get_doc_entity(doc, node.name)
            if ent
              node.children = ent
              node.last = ent
              node.content = ent.content
            end
          end
        when DTD_NODE
          if old_doc
            old_doc.int_subset = nil if old_doc.int_subset.equal?(node)
            old_doc.ext_subset = nil if old_doc.ext_subset.equal?(node)
          end
        when ENTITY_DECL
          remove_entity(node)
        end
        node.doc = doc
      end

      def doc_set_root_element(doc, root)
        return nil if doc.nil? || root.nil? || root.is_a?(XmlNs)

        old = doc.children
        old = old.next while old && old.type != ELEMENT_NODE
        return old if old.equal?(root)

        unlink_node_internal(root)
        set_tree_doc(root, doc)
        root.parent = doc
        if old.nil?
          if doc.children.nil?
            doc.children = root
            doc.last = root
          else
            add_sibling(doc.children, root)
          end
        else
          replace_node(old, root)
        end
        old
      end

      def doc_get_root_element(doc)
        return nil if doc.nil?

        ret = doc.children
        while ret
          return ret if ret.type == ELEMENT_NODE

          ret = ret.next
        end
        nil
      end

      def first_element_child(parent)
        return nil if parent.nil?

        case parent.type
        when ELEMENT_NODE, ENTITY_NODE, DOCUMENT_NODE, DOCUMENT_FRAG_NODE, HTML_DOCUMENT_NODE
          cur = parent.children
          while cur
            return cur if cur.type == ELEMENT_NODE

            cur = cur.next
          end
        end
        nil
      end

      def last_element_child(parent)
        return nil if parent.nil?

        case parent.type
        when ELEMENT_NODE, ENTITY_NODE, DOCUMENT_NODE, DOCUMENT_FRAG_NODE, HTML_DOCUMENT_NODE
          cur = parent.last
          while cur
            return cur if cur.type == ELEMENT_NODE

            cur = cur.prev
          end
        end
        nil
      end

      def next_element_sibling(node)
        return nil if node.nil?

        case node.type
        when ELEMENT_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE, ENTITY_NODE, PI_NODE,
             COMMENT_NODE, DTD_NODE, XINCLUDE_START, XINCLUDE_END
          node = node.next
          while node
            return node if node.type == ELEMENT_NODE

            node = node.next
          end
        end
        nil
      end

      def previous_element_sibling(node)
        return nil if node.nil?

        case node.type
        when ELEMENT_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE, ENTITY_NODE, PI_NODE,
             COMMENT_NODE, XINCLUDE_START, XINCLUDE_END
          node = node.prev
          while node
            return node if node.type == ELEMENT_NODE

            node = node.prev
          end
        end
        nil
      end

      # ---- copying -----------------------------------------------------------

      def doc_copy_node(node, doc, extended)
        static_copy_node(node, doc, nil, extended)
      end

      def copy_node(node, extended)
        static_copy_node(node, nil, nil, extended)
      end

      def static_copy_node(node, doc, parent, extended)
        return nil if node.nil?

        case node.type
        when TEXT_NODE, CDATA_SECTION_NODE, ELEMENT_NODE, DOCUMENT_FRAG_NODE, ENTITY_REF_NODE,
             PI_NODE, COMMENT_NODE, XINCLUDE_START, XINCLUDE_END
          # fall through
        when ATTRIBUTE_NODE
          return copy_prop_internal(doc, parent, node)
        when NAMESPACE_DECL
          return copy_namespace_list(node)
        when DOCUMENT_NODE, HTML_DOCUMENT_NODE
          return copy_doc(node, extended)
        else
          return nil
        end

        ret = XmlNode.new(node.type, node.name, doc)
        ret.parent = parent
        if node.type != ELEMENT_NODE && node.content && node.type != ENTITY_REF_NODE &&
            node.type != XINCLUDE_END && node.type != XINCLUDE_START
          ret.content = +node.content
        elsif node.type == ELEMENT_NODE
          ret.line = node.line
        end
        return ret if extended == 0

        if (node.type == ELEMENT_NODE || node.type == XINCLUDE_START) && node.ns_def
          ret.ns_def = copy_namespace_list(node.ns_def)
        end
        if node.type == ELEMENT_NODE && node.ns
          ns = search_ns(doc, ret, node.ns.prefix)
          if ns.nil?
            ns = search_ns(node.doc, node, node.ns.prefix)
            if ns
              root = ret
              root = root.parent while root.parent
              ret.ns = new_ns(root, ns.href, ns.prefix)
            else
              ret.ns = new_reconciled_ns(ret, node.ns)
            end
          else
            ret.ns = ns
          end
        end
        if node.type == ELEMENT_NODE && node.properties
          ret.properties = copy_prop_list(ret, node.properties)
        end
        if node.type == ENTITY_REF_NODE
          if doc.nil? || !node.doc.equal?(doc)
            ret.children = get_doc_entity(doc, ret.name)
          else
            ret.children = node.children
          end
          ret.last = ret.children
        elsif node.children && extended != 2
          cur = node.children
          insert = ret
          while cur
            copy = static_copy_node(cur, doc, insert, 2)
            unless insert.last.equal?(copy)
              if insert.last.nil?
                insert.children = copy
              else
                copy.prev = insert.last
                insert.last.next = copy
              end
              insert.last = copy
            end
            if cur.type != ENTITY_REF_NODE && cur.children
              cur = cur.children
              insert = copy
              next
            end
            loop do
              if cur.next
                cur = cur.next
                break
              end
              cur = cur.parent
              insert = insert.parent
              if cur.equal?(node)
                cur = nil
                break
              end
            end
          end
        end
        ret
      end

      def static_copy_node_list(node, doc, parent)
        ret = nil
        p = nil
        new_subset = nil
        while node
          nxt = node.next
          if node.type == DTD_NODE
            if doc.nil?
              node = nxt
              next
            end
            if doc.int_subset.nil? && new_subset.nil?
              q = copy_dtd(node)
              set_tree_doc(q, doc)
              q.parent = parent
              new_subset = q
            else
              q = doc.int_subset
              if q.prev.nil?
                q.parent.children = q.next if q.parent
              else
                q.prev.next = q.next
              end
              if q.next.nil?
                q.parent.last = q.prev if q.parent
              else
                q.next.prev = q.prev
              end
              q.parent = parent
              q.next = nil
              q.prev = nil
            end
          else
            q = static_copy_node(node, doc, parent, 1)
          end
          return nil if q.nil?

          if ret.nil?
            q.prev = nil
            ret = p = q
          elsif !p.equal?(q)
            p.next = q
            q.prev = p
            p = q
          end
          node = nxt
        end
        doc.int_subset = new_subset if doc && new_subset
        ret
      end

      def doc_copy_node_list(doc, node)
        static_copy_node_list(node, doc, nil)
      end

      def copy_prop_internal(doc, target, cur)
        return nil if cur.nil?
        return nil if target && target.type != ELEMENT_NODE

        ret_doc = if target
          target.doc
        elsif doc
          doc
        elsif cur.parent
          cur.parent.doc
        elsif cur.children
          cur.children.doc
        end
        ret = new_doc_prop(ret_doc, cur.name, nil)
        ret.parent = target
        if cur.ns && target
          ns = search_ns(target.doc, target, cur.ns.prefix)
          if ns.nil?
            ns = search_ns(cur.doc, cur.parent, cur.ns.prefix)
            if ns
              root = target
              pred = nil
              while root.parent
                pred = root
                root = root.parent
              end
              root = pred if root.equal?(target.doc)
              ret.ns = new_ns(root, ns.href, ns.prefix)
            end
          elsif ns.href == cur.ns.href
            ret.ns = ns
          else
            ret.ns = new_reconciled_ns(target, cur.ns)
          end
        else
          ret.ns = nil
        end
        if cur.children
          ret.children = static_copy_node_list(cur.children, ret.doc, ret)
          ret.last = nil
          tmp = ret.children
          while tmp
            ret.last = tmp if tmp.next.nil?
            tmp = tmp.next
          end
        end
        if target && target.doc && cur.doc && cur.parent && cur.children
          if is_id(cur.doc, cur.parent, cur)
            id = node_get_content(cur)
            add_id(ret, id)
          end
        end
        ret
      end

      def copy_prop(target, cur)
        copy_prop_internal(nil, target, cur)
      end

      def copy_prop_list(target, cur)
        return nil if target && target.type != ELEMENT_NODE

        ret = nil
        p = nil
        while cur
          q = copy_prop(target, cur)
          return nil if q.nil?

          if p.nil?
            ret = p = q
          else
            p.next = q
            q.prev = p
            p = q
          end
          cur = cur.next
        end
        ret
      end

      def copy_namespace(cur)
        return nil if cur.nil?

        new_ns(nil, cur.href, cur.prefix)
      end

      def copy_namespace_list(cur)
        ret = nil
        p = nil
        while cur
          q = copy_namespace(cur)
          if p.nil?
            ret = p = q
          else
            p.next = q
            p = q
          end
          cur = cur.next
        end
        ret
      end

      def copy_doc(doc, recursive)
        ret = XmlDoc.new(doc.version, doc.type)
        ret.name = doc.name
        ret.encoding = doc.encoding
        ret.url = doc.url
        ret.charset = doc.charset
        ret.compression = doc.compression
        ret.standalone = doc.standalone
        return ret if recursive.nil? || recursive == 0

        ret.last = nil
        ret.children = nil
        if doc.int_subset
          ret.int_subset = copy_dtd(doc.int_subset)
          set_tree_doc(ret.int_subset, ret)
        end
        ret.old_ns = copy_namespace_list(doc.old_ns) if doc.old_ns
        if doc.children
          ret.children = static_copy_node_list(doc.children, ret, ret)
          ret.last = nil
          tmp = ret.children
          while tmp
            ret.last = tmp if tmp.next.nil?
            tmp = tmp.next
          end
        end
        ret
      end

      def copy_dtd(dtd)
        return nil if dtd.nil?

        ret = new_dtd(nil, dtd.name, dtd.external_id, dtd.system_id)
        if dtd.entities
          ret.entities = {}
          dtd.entities.each { |k, e| ret.entities[k] = copy_entity(e, ret) }
        end
        if dtd.notations
          ret.notations = {}
          dtd.notations.each { |k, n| ret.notations[k] = n.dup }
        end
        if dtd.elements
          ret.elements = {}
          dtd.elements.each { |k, e| ret.elements[k] = copy_element_decl(e, ret) }
        end
        if dtd.attributes
          ret.attributes = {}
          dtd.attributes.each { |k, a| ret.attributes[k] = copy_attribute_decl(a, ret) }
        end
        if dtd.pentities
          ret.pentities = {}
          dtd.pentities.each { |k, e| ret.pentities[k] = copy_entity(e, ret) }
        end
        cur = dtd.children
        p = nil
        while cur
          q = nil
          case cur.type
          when ENTITY_DECL
            case cur.etype
            when INTERNAL_GENERAL_ENTITY, EXTERNAL_GENERAL_PARSED_ENTITY, EXTERNAL_GENERAL_UNPARSED_ENTITY
              q = ret.entities && ret.entities[cur.name]
            when INTERNAL_PARAMETER_ENTITY, EXTERNAL_PARAMETER_ENTITY
              q = ret.pentities && ret.pentities[cur.name]
            end
          when ELEMENT_DECL
            q = ret.elements && ret.elements[[cur.name, cur.prefix]]
          when ATTRIBUTE_DECL
            q = ret.attributes && ret.attributes[[cur.name, cur.prefix, cur.elem]]
          when COMMENT_NODE
            q = copy_node(cur, 0)
          end
          if q.nil?
            cur = cur.next
            next
          end
          if p.nil?
            ret.children = q
          else
            p.next = q
          end
          q.prev = p
          q.parent = ret
          q.next = nil
          ret.last = q
          p = q
          cur = cur.next
        end
        ret
      end

      def copy_entity(ent, dtd)
        e = XmlEntity.new(ent.name, ent.etype, dtd.doc)
        e.external_id = ent.external_id
        e.system_id = ent.system_id
        e.content = ent.content
        e.orig = ent.orig
        e.uri = ent.uri
        e.length = ent.length
        e
      end

      def copy_element_decl(el, _dtd)
        e = XmlElementDecl.new(el.name)
        e.etype = el.etype
        e.econtent = copy_element_content(el.econtent)
        e.prefix = el.prefix
        e
      end

      def copy_element_content(c)
        return nil if c.nil?

        n = XmlElementContent.new(c.type, c.name, c.prefix)
        n.ocur = c.ocur
        if c.c1
          n.c1 = copy_element_content(c.c1)
          n.c1.parent = n
        end
        if c.c2
          n.c2 = copy_element_content(c.c2)
          n.c2.parent = n
        end
        n
      end

      def copy_attribute_decl(a, _dtd)
        n = XmlAttributeDecl.new(a.name)
        n.atype = a.atype
        n.def = a.def
        n.default_value = a.default_value
        n.tree = a.tree
        n.prefix = a.prefix
        n.elem = a.elem
        n
      end

      # ---- namespaces -------------------------------------------------------

      def tree_ensure_xml_decl(doc)
        doc.old_ns ||= new_xml_ns
      end

      def search_ns(_doc, node, prefix)
        return nil if node.nil? || node.is_a?(XmlNs)

        doc = node.doc
        if doc && prefix == "xml"
          return tree_ensure_xml_decl(doc)
        end

        orig = node
        while node.type != ELEMENT_NODE
          node = node.parent
          return nil if node.nil?
        end
        parent = node
        while node && node.type == ELEMENT_NODE
          cur = node.ns_def
          while cur
            return cur if cur.prefix == prefix && cur.href

            cur = cur.next
          end
          unless orig.equal?(node)
            cur = node.ns
            return cur if cur && cur.prefix == prefix && cur.href
          end
          node = node.parent
        end
        if doc.nil? && prefix == "xml"
          cur = new_xml_ns
          cur.next = parent.ns_def
          parent.ns_def = cur
          return cur
        end
        nil
      end

      def ns_in_scope(node, ancestor, prefix)
        while node && !node.equal?(ancestor)
          return -1 if node.type == ENTITY_REF_NODE || node.type == ENTITY_DECL

          if node.type == ELEMENT_NODE
            tst = node.ns_def
            while tst
              return 0 if tst.prefix.nil? && prefix.nil?
              return 0 if tst.prefix && prefix && tst.prefix == prefix

              tst = tst.next
            end
          end
          node = node.parent
        end
        return -1 unless node.equal?(ancestor)

        1
      end

      def search_ns_by_href(_doc, node, href)
        return nil if node.nil? || node.is_a?(XmlNs)

        doc = node.doc
        if doc && href == XML_XML_NAMESPACE
          return tree_ensure_xml_decl(doc)
        end

        orig = node
        is_attr = node.type == ATTRIBUTE_NODE
        while node.type != ELEMENT_NODE
          node = node.parent
          return nil if node.nil?
        end
        parent = node
        while node && node.type == ELEMENT_NODE
          cur = node.ns_def
          while cur
            if cur.href == href && (!is_attr || cur.prefix) && ns_in_scope(orig, node, cur.prefix) == 1
              return cur
            end

            cur = cur.next
          end
          unless orig.equal?(node)
            cur = node.ns
            if cur && cur.href == href && (!is_attr || cur.prefix) && ns_in_scope(orig, node, cur.prefix) == 1
              return cur
            end
          end
          node = node.parent
        end
        if doc.nil? && href == XML_XML_NAMESPACE
          cur = new_xml_ns
          cur.next = parent.ns_def
          parent.ns_def = cur
          return cur
        end
        nil
      end

      def new_reconciled_ns(tree, ns)
        return nil if tree.nil? || tree.type != ELEMENT_NODE
        return nil if ns.nil? || !ns.is_a?(XmlNs)

        defn = search_ns_by_href(tree.doc, tree, ns.href)
        return defn if defn

        base = ns.prefix.nil? ? "default" : ns.prefix[0, 20]
        prefix = base
        counter = 1
        defn = search_ns(tree.doc, tree, prefix)
        while defn
          return nil if counter > 1000

          prefix = "#{base}#{counter}"
          counter += 1
          defn = search_ns(tree.doc, tree, prefix)
        end
        new_ns(tree, ns.href, prefix)
      end

      def set_ns(node, ns)
        return if node.nil?

        node.ns = ns if node.type == ELEMENT_NODE || node.type == ATTRIBUTE_NODE
      end

      def get_ns_list(_doc, node)
        return nil if node.nil? || node.is_a?(XmlNs)

        namespaces = []
        while node
          if node.type == ELEMENT_NODE
            cur = node.ns_def
            while cur
              namespaces << cur unless namespaces.any? { |n| n.prefix == cur.prefix }
              cur = cur.next
            end
          end
          node = node.parent
        end
        namespaces.empty? ? nil : namespaces
      end

      # ---- attributes -------------------------------------------------------

      def get_prop_node_internal(node, name, ns_name, use_dtd)
        return nil if node.nil? || node.type != ELEMENT_NODE || name.nil?

        prop = node.properties
        if ns_name.nil?
          while prop
            return prop if prop.ns.nil? && prop.name == name

            prop = prop.next
          end
        else
          while prop
            return prop if prop.ns && prop.name == name && prop.ns.href == ns_name

            prop = prop.next
          end
        end
        return nil unless use_dtd

        doc = node.doc
        if doc&.int_subset
          elem_qname = if node.ns&.prefix
            "#{node.ns.prefix}:#{node.name}"
          else
            node.name
          end
          attr_decl = nil
          if ns_name.nil?
            attr_decl = get_dtd_q_attr_desc(doc.int_subset, elem_qname, name, nil)
            attr_decl ||= get_dtd_q_attr_desc(doc.ext_subset, elem_qname, name, nil) if doc.ext_subset
          elsif ns_name == XML_XML_NAMESPACE
            attr_decl = get_dtd_q_attr_desc(doc.int_subset, elem_qname, name, "xml")
            attr_decl ||= get_dtd_q_attr_desc(doc.ext_subset, elem_qname, name, "xml") if doc.ext_subset
          else
            ns_list = get_ns_list(doc, node)
            return nil if ns_list.nil?

            ns_list.each do |cur|
              next unless cur.href == ns_name

              attr_decl = get_dtd_q_attr_desc(doc.int_subset, elem_qname, name, cur.prefix)
              break if attr_decl

              if doc.ext_subset
                attr_decl = get_dtd_q_attr_desc(doc.ext_subset, elem_qname, name, cur.prefix)
                break if attr_decl
              end
            end
          end
          return attr_decl if attr_decl&.default_value
        end
        nil
      end

      def get_prop_node_value_internal(prop)
        return nil if prop.nil?

        if prop.type == ATTRIBUTE_NODE
          node_get_content(prop)
        elsif prop.type == ATTRIBUTE_DECL
          prop.default_value&.dup
        end
      end

      def has_prop(node, name)
        return nil if node.nil? || node.type != ELEMENT_NODE || name.nil?

        prop = node.properties
        while prop
          return prop if prop.name == name

          prop = prop.next
        end
        doc = node.doc
        if doc&.int_subset
          attr_decl = get_dtd_attr_desc(doc.int_subset, node.name, name)
          attr_decl ||= get_dtd_attr_desc(doc.ext_subset, node.name, name) if doc.ext_subset
          return attr_decl if attr_decl&.default_value
        end
        nil
      end

      def has_ns_prop(node, name, ns_name)
        get_prop_node_internal(node, name, ns_name, true)
      end

      def get_prop(node, name)
        get_prop_node_value_internal(has_prop(node, name))
      end

      def get_no_ns_prop(node, name)
        get_prop_node_value_internal(get_prop_node_internal(node, name, nil, true))
      end

      def get_ns_prop(node, name, ns_name)
        get_prop_node_value_internal(get_prop_node_internal(node, name, ns_name, true))
      end

      # xmlNodeGetAttrValue: no DTD defaults
      def node_get_attr_value(node, name, ns_name)
        prop = get_prop_node_internal(node, name, ns_name, false)
        prop && get_prop_node_value_internal(prop)
      end

      def split_qname2(name)
        return nil if name.nil? || name.start_with?(":")

        idx = name.index(":")
        return nil if idx.nil? || idx == name.length - 1

        [name[idx + 1..], name[0, idx]]
      end

      # returns [localname, prefix]
      def split_qname4(name)
        return [name, nil] if name.start_with?(":")

        idx = name.index(":")
        return [name, nil] if idx.nil? || idx == name.length - 1

        [name[idx + 1..], name[0, idx]]
      end

      def build_qname(ncname, prefix)
        prefix.nil? ? ncname : "#{prefix}:#{ncname}"
      end

      def set_prop(node, name, value)
        return nil if node.nil? || name.nil? || node.type != ELEMENT_NODE

        localname, prefix = split_qname4(name)
        if prefix
          ns = search_ns(node.doc, node, prefix)
          return set_ns_prop(node, ns, localname, value) if ns
        end
        set_ns_prop(node, nil, name, value)
      end

      def set_ns_prop(node, ns, name, value)
        return nil if ns && ns.href.nil?
        return nil if name.nil?

        prop = get_prop_node_internal(node, name, ns&.href, false)
        if prop
          children = value.nil? ? nil : new_doc_text(node.doc, value)
          if prop.id
            remove_id(node.doc, prop)
            prop.atype = ATTRIBUTE_ID
          end
          prop.children = nil
          prop.last = nil
          prop.ns = ns
          unless value.nil?
            prop.children = children
            children.parent = prop
            prop.last = children
          end
          add_id(prop, value) if prop.atype == ATTRIBUTE_ID
          return prop
        end
        new_prop_internal(node, ns, name, value)
      end

      def remove_prop(cur)
        return -1 if cur.nil? || cur.parent.nil?

        tmp = cur.parent.properties
        if tmp.equal?(cur)
          cur.parent.properties = cur.next
          cur.next.prev = nil if cur.next
          free_prop(cur)
          return 0
        end
        while tmp
          if tmp.next.equal?(cur)
            tmp.next = cur.next
            tmp.next.prev = tmp if tmp.next
            free_prop(cur)
            return 0
          end
          tmp = tmp.next
        end
        -1
      end

      def free_prop(cur)
        remove_id(cur.doc, cur) if cur.doc && cur.id
        cur.parent = nil
        cur.next = nil
        cur.prev = nil
      end

      def unset_prop(node, name)
        prop = get_prop_node_internal(node, name, nil, false)
        return -1 if prop.nil?

        unlink_node_internal(prop)
        free_prop(prop)
        0
      end

      def unset_ns_prop(node, ns, name)
        prop = get_prop_node_internal(node, name, ns&.href, false)
        return -1 if prop.nil?

        unlink_node_internal(prop)
        free_prop(prop)
        0
      end

      # ---- IDs ---------------------------------------------------------------

      def is_id(doc, elem, attr)
        return false if attr.nil? || attr.name.nil?

        if doc && doc.type == HTML_DOCUMENT_NODE
          return true if attr.name == "id"
          return false if elem.nil? || elem.type != ELEMENT_NODE
          return true if attr.name == "name" && elem.name == "a"
        else
          return true if attr.ns&.prefix && attr.name == "id" && attr.ns.prefix == "xml"
          return false if doc.nil? || (doc.int_subset.nil? && doc.ext_subset.nil?)
          return false if elem.nil? || elem.type != ELEMENT_NODE || elem.name.nil?

          fullelemname = elem.ns&.prefix ? "#{elem.ns.prefix}:#{elem.name}" : elem.name
          aprefix = attr.ns&.prefix
          attr_decl = get_dtd_q_attr_desc(doc.int_subset, fullelemname, attr.name, aprefix)
          attr_decl ||= get_dtd_q_attr_desc(doc.ext_subset, fullelemname, attr.name, aprefix) if doc.ext_subset
          return true if attr_decl && attr_decl.atype == ATTRIBUTE_ID
        end
        false
      end

      def add_id(attr, value)
        return 0 if value.nil? || value.empty? || attr.nil?

        doc = attr.doc
        return 0 if doc.nil?

        table = (doc.ids ||= {})
        return 0 if table.key?(value)

        remove_id(doc, attr) if attr.id
        id = XmlID.new(value.dup, attr, nil, get_line_no(attr.parent), doc)
        table[value.dup] = id
        attr.atype = ATTRIBUTE_ID
        attr.id = id
        1
      end

      def remove_id(doc, attr)
        return -1 if doc.nil? || attr.nil? || attr.id.nil?

        table = doc.ids
        return -1 if table.nil?

        table.delete(attr.id.value)
        attr.id = nil
        0
      end

      def get_id(doc, id)
        return nil if doc.nil? || id.nil? || doc.ids.nil?

        entry = doc.ids[id]
        return nil if entry.nil?
        return doc if entry.attr.nil?

        entry.attr
      end

      # ---- DTD lookup --------------------------------------------------------

      def get_dtd_attr_desc(dtd, elem, name)
        return nil if dtd.nil? || dtd.attributes.nil? || elem.nil? || name.nil?

        localname, prefix = split_qname4(name)
        dtd.attributes[[localname, prefix, elem]]
      end

      def get_dtd_q_attr_desc(dtd, elem, name, prefix)
        return nil if dtd.nil? || dtd.attributes.nil?

        dtd.attributes[[name, prefix, elem]]
      end

      def get_dtd_element_desc(dtd, name)
        return nil if dtd.nil? || dtd.elements.nil? || name.nil?

        localname, prefix = split_qname4(name)
        dtd.elements[[localname, prefix]]
      end

      def get_dtd_q_element_desc(dtd, name, prefix)
        return nil if dtd.nil? || dtd.elements.nil?

        dtd.elements[[name, prefix]]
      end

      # ---- entities ---------------------------------------------------------

      def get_predefined_entity(name)
        PREDEFINED_ENTITIES[name]
      end

      def get_doc_entity(doc, name)
        if doc
          if doc.int_subset&.entities
            cur = doc.int_subset.entities[name]
            return cur if cur
          end
          if doc.standalone != 1 && doc.ext_subset&.entities
            cur = doc.ext_subset.entities[name]
            return cur if cur
          end
        end
        get_predefined_entity(name)
      end

      def get_parameter_entity(doc, name)
        return nil if doc.nil?

        if doc.int_subset&.pentities
          ret = doc.int_subset.pentities[name]
          return ret if ret
        end
        doc.ext_subset&.pentities&.[](name)
      end

      def get_dtd_entity(doc, name)
        return nil if doc.nil?

        doc.ext_subset&.entities&.[](name)
      end

      # returns [error_code, entity]
      def add_entity(doc, ext_subset, name, type, external_id, system_id, content)
        return [:argument, nil] if doc.nil? || name.nil?

        dtd = ext_subset ? doc.ext_subset : doc.int_subset
        return [:no_dtd, nil] if dtd.nil?

        case type
        when INTERNAL_GENERAL_ENTITY, EXTERNAL_GENERAL_PARSED_ENTITY, EXTERNAL_GENERAL_UNPARSED_ENTITY
          predef = get_predefined_entity(name)
          if predef
            valid = false
            if type == INTERNAL_GENERAL_ENTITY && content
              c = predef.content
              if content == c && [">", "'", "\""].include?(c)
                valid = true
              elsif content.start_with?("&#")
                if content[2] == "x"
                  valid = content[3..].casecmp?(format("%02X;", c.ord))
                else
                  valid = content[2..] == format("%02d;", c.ord)
                end
              end
            end
            return [:redecl_predef_entity, nil] unless valid
          end
          table = (dtd.entities ||= {})
        when INTERNAL_PARAMETER_ENTITY, EXTERNAL_PARAMETER_ENTITY
          table = (dtd.pentities ||= {})
        else
          return [:argument, nil]
        end
        return [:entity_redefined, nil] if table.key?(name)

        ret = XmlEntity.new(name, type, dtd.doc)
        ret.external_id = external_id
        ret.system_id = system_id
        if content
          ret.length = content.bytesize
          ret.content = +content
        end
        table[name] = ret
        ret.parent = dtd
        ret.doc = dtd.doc
        if dtd.last.nil?
          dtd.children = dtd.last = ret
        else
          dtd.last.next = ret
          ret.prev = dtd.last
          dtd.last = ret
        end
        [nil, ret]
      end

      def add_doc_entity(doc, name, type, external_id, system_id, content)
        add_entity(doc, false, name, type, external_id, system_id, content)[1]
      end

      def add_dtd_entity(doc, name, type, external_id, system_id, content)
        add_entity(doc, true, name, type, external_id, system_id, content)[1]
      end

      # xmlEncodeEntitiesInternal (attr: false => xmlEncodeEntitiesReentrant, true => xmlEncodeAttributeEntities)
      def encode_entities_internal(doc, input, attr)
        return nil if input.nil?

        html = doc && doc.type == HTML_DOCUMENT_NODE
        keep_non_ascii = (doc && doc.encoding) || html
        out = +""
        bytes = input.b
        i = 0
        len = bytes.bytesize
        while i < len
          c = bytes.getbyte(i)
          if c == 0x3C # <
            if html && attr && bytes.getbyte(i + 1) == 0x21 && bytes.getbyte(i + 2) == 0x2D &&
                bytes.getbyte(i + 3) == 0x2D && (e = bytes.index("-->", i))
              out << bytes.byteslice(i, e + 3 - i)
              i = e + 3
              next
            end
            out << "&lt;"
          elsif c == 0x3E
            out << "&gt;"
          elsif c == 0x26 # &
            if html && attr && bytes.getbyte(i + 1) == 0x7B && (e = bytes.index("}", i))
              out << bytes.byteslice(i, e + 1 - i)
              i = e + 1
              next
            end
            out << "&amp;"
          elsif (c >= 0x20 && c < 0x80) || c == 0x0A || c == 0x09 || (html && c == 0x0D)
            out << c
          elsif c >= 0x80
            if keep_non_ascii
              out << c
            else
              cp, l = Encoding_.utf8_char(bytes, i)
              if cp.nil?
                cp = 0xFFFD
                l = 1
              elsif !Encoding_.xml_char?(cp)
                cp = 0xFFFD
              end
              out << format("&#x%X;", cp)
              i += l
              next
            end
          elsif c == 0x09 || c == 0x0A || c == 0x0D || c >= 0x20
            out << "&##{c};"
          end
          i += 1
        end
        out.force_encoding(Encoding::UTF_8)
      end

      def encode_entities_reentrant(doc, input)
        encode_entities_internal(doc, input, false)
      end

      def encode_attribute_entities(doc, input)
        encode_entities_internal(doc, input, true)
      end

      SPECIAL_CHARS_RE = /[<>&"\r]/
      SPECIAL_CHARS_MAP = { "<" => "&lt;", ">" => "&gt;", "&" => "&amp;", "\"" => "&quot;", "\r" => "&#13;" }.freeze

      def encode_special_chars(_doc, input)
        return nil if input.nil?

        input.gsub(SPECIAL_CHARS_RE, SPECIAL_CHARS_MAP)
      end

      # ---- content ----------------------------------------------------------

      # xmlNodeParseContentInternal. If parent is given, replaces its children. Returns the list head.
      def node_parse_content_internal(doc, parent, value)
        head = nil
        last = nil
        link = lambda do |node|
          node.parent = parent
          if last.nil?
            head = node
          else
            last.next = node
            node.prev = last
          end
          last = node
        end

        if value && !value.empty?
          buf = +""
          s = value
          len = s.length
          i = 0
          q = 0
          while i < len
            if s[i] == "&"
              buf << s[q...i] if i != q
              q = i
              charval = 0
              if s[i + 1] == "#" && s[i + 2] == "x"
                i += 3
                tmp = nil
                while i < len && (tmp = s[i]) != ";"
                  if tmp.match?(/[0-9a-fA-F]/)
                    charval = charval * 16 + tmp.to_i(16)
                  else
                    charval = 0
                    break
                  end
                  charval = 0x110000 if charval > 0x110000
                  i += 1
                end
                i += 1 if tmp == ";" && i < len
                q = i
              elsif s[i + 1] == "#"
                i += 2
                tmp = nil
                while i < len && (tmp = s[i]) != ";"
                  if tmp.match?(/[0-9]/)
                    charval = charval * 10 + tmp.to_i
                  else
                    charval = 0
                    break
                  end
                  charval = 0x110000 if charval > 0x110000
                  i += 1
                end
                i += 1 if tmp == ";" && i < len
                q = i
              else
                i += 1
                q = i
                i += 1 while i < len && s[i] != ";"
                break if i >= len

                if i != q
                  val = s[q...i]
                  ent = get_doc_entity(doc, val)
                  if ent && ent.etype == INTERNAL_PREDEFINED_ENTITY
                    buf << ent.content
                  else
                    unless buf.empty?
                      t = new_doc_text(doc, nil)
                      t.content = buf
                      buf = +""
                      link.call(t)
                    end
                    if ent && (ent.flags & ENT_PARSED) == 0 && (ent.flags & ENT_EXPANDING) == 0 && ent.content
                      ent.flags |= ENT_EXPANDING
                      node_parse_content_internal(doc, ent, ent.content)
                      ent.flags &= ~ENT_EXPANDING
                      ent.flags |= ENT_PARSED
                    end
                    ref = new_entity_ref(doc, val)
                    ref.last = ent
                    if ent
                      ref.children = ent
                      ref.content = ent.content
                    end
                    link.call(ref)
                  end
                end
                i += 1
                q = i
              end
              if charval != 0
                charval = 0xFFFD if charval >= 0x110000
                buf << charval.chr(Encoding::UTF_8)
              end
            else
              i += 1
            end
          end
          buf << s[q...i] if i != q && q < len
          if !buf.empty?
            t = new_doc_text(doc, nil)
            t.content = buf
            link.call(t)
          elsif head.nil?
            t = new_doc_text(doc, "")
            link.call(t)
          end
        end

        if parent
          parent.children = head
          parent.last = last
        end
        head
      end

      def node_parse_content(node, content)
        node_parse_content_internal(node.doc, node, content)
      end

      def string_get_node_list(doc, value)
        node_parse_content_internal(doc, nil, value)
      end

      def node_set_content(cur, content)
        return if cur.nil?

        case cur.type
        when DOCUMENT_FRAG_NODE, ELEMENT_NODE, ATTRIBUTE_NODE
          node_parse_content(cur, content)
        when TEXT_NODE, CDATA_SECTION_NODE, PI_NODE, COMMENT_NODE
          cur.content = content.nil? ? nil : +content
          cur.properties = nil
        end
      end

      def node_add_content(cur, content)
        return if cur.nil? || content.nil? || content.empty?

        case cur.type
        when DOCUMENT_FRAG_NODE, ELEMENT_NODE
          add_child(cur, new_doc_text(cur.doc, content))
        when TEXT_NODE, CDATA_SECTION_NODE, PI_NODE, COMMENT_NODE
          text_add_content(cur, content)
        end
      end

      def node_set_name(cur, name)
        return if cur.nil? || name.nil?

        case cur.type
        when ELEMENT_NODE, ATTRIBUTE_NODE, PI_NODE, ENTITY_REF_NODE
          cur.name = -name
        end
      end

      def node_list_get_string(doc, list, in_line)
        return nil if list.nil?

        esc_mode = if in_line
          0
        elsif list.parent && list.parent.type == ATTRIBUTE_NODE
          2
        else
          1
        end
        node_list_get_string_internal(doc, list, esc_mode)
      end

      def node_list_get_raw_string(doc, list, in_line)
        return nil if list.nil?

        node_list_get_string_internal(doc, list, in_line ? 0 : 3)
      end

      def node_list_get_string_internal(doc, node, esc_mode)
        return +"" if node.nil?

        if esc_mode == 0 && (node.type == TEXT_NODE || node.type == CDATA_SECTION_NODE) && node.next.nil?
          return node.content.nil? ? +"" : node.content.dup
        end
        buf = +""
        while node
          if node.type == TEXT_NODE || node.type == CDATA_SECTION_NODE
            if node.content
              buf << case esc_mode
              when 0 then node.content
              when 1 then encode_entities_reentrant(doc, node.content)
              when 2 then encode_attribute_entities(doc, node.content)
              else encode_special_chars(doc, node.content)
              end
            end
          elsif node.type == ENTITY_REF_NODE
            if esc_mode == 0
              buf_get_node_content(buf, node)
            else
              buf << "&" << node.name << ";"
            end
          end
          node = node.next
        end
        buf
      end

      def buf_get_node_content(buf, cur)
        case cur.type
        when DOCUMENT_NODE, HTML_DOCUMENT_NODE, DOCUMENT_FRAG_NODE, ELEMENT_NODE, ATTRIBUTE_NODE, ENTITY_DECL
          buf_get_child_content(buf, cur)
        when CDATA_SECTION_NODE, TEXT_NODE, COMMENT_NODE, PI_NODE
          buf << cur.content if cur.content
        when ENTITY_REF_NODE
          buf_get_entity_ref_content(buf, cur)
        when NAMESPACE_DECL
          buf << cur.href if cur.href
        end
        buf
      end

      def buf_get_child_content(buf, tree)
        cur = tree.children
        while cur
          case cur.type
          when TEXT_NODE, CDATA_SECTION_NODE
            buf << cur.content if cur.content
          when ENTITY_REF_NODE
            buf_get_entity_ref_content(buf, cur)
          else
            if cur.children
              cur = cur.children
              next
            end
          end
          while cur.next.nil?
            cur = cur.parent
            return if cur.equal?(tree) || cur.nil?
          end
          cur = cur.next
        end
      end

      def buf_get_entity_ref_content(buf, ref)
        if ref.children
          ent = ref.children
        else
          ent = get_doc_entity(ref.doc, ref.name)
          return if ent.nil?
        end
        if ent.etype == INTERNAL_PREDEFINED_ENTITY
          buf << ent.content
          return
        end
        return if (ent.flags & ENT_EXPANDING) != 0

        ent.flags |= ENT_EXPANDING
        buf_get_child_content(buf, ent)
        ent.flags &= ~ENT_EXPANDING
      end

      def node_get_content(cur)
        return nil if cur.nil?

        if cur.is_a?(XmlNs)
          return cur.href&.dup
        end

        case cur.type
        when DOCUMENT_NODE, HTML_DOCUMENT_NODE, ENTITY_REF_NODE
          # fall through to buffer
        when DOCUMENT_FRAG_NODE, ELEMENT_NODE, ATTRIBUTE_NODE, ENTITY_DECL
          children = cur.children
          return +"" if children.nil?

          if (children.type == TEXT_NODE || children.type == CDATA_SECTION_NODE) && children.next.nil?
            return children.content.nil? ? +"" : children.content.dup
          end
        when CDATA_SECTION_NODE, TEXT_NODE, COMMENT_NODE, PI_NODE
          return cur.content.nil? ? +"" : cur.content.dup
        else
          return nil
        end
        buf_get_node_content(+"", cur)
      end

      # ---- misc queries -------------------------------------------------------

      def is_blank_node(node)
        return false if node.nil?
        return false if node.type != TEXT_NODE && node.type != CDATA_SECTION_NODE
        return true if node.content.nil?

        !node.content.match?(/[^ \t\n\r]/)
      end

      def node_get_lang(cur)
        return nil if cur.nil? || cur.is_a?(XmlNs)

        while cur
          lang = node_get_attr_value(cur, "lang", XML_XML_NAMESPACE)
          return lang if lang

          cur = cur.parent
        end
        nil
      end

      def node_set_lang(cur, lang)
        return if cur.nil? || cur.type != ELEMENT_NODE

        ns = search_ns_by_href(cur.doc, cur, XML_XML_NAMESPACE)
        return if ns.nil?

        set_ns_prop(cur, ns, "lang", lang)
      end

      def node_get_space_preserve(cur)
        return -1 if cur.nil? || cur.type != ELEMENT_NODE

        while cur
          space = node_get_attr_value(cur, "space", XML_XML_NAMESPACE)
          if space
            return 1 if space == "preserve"
            return 0 if space == "default"
          end
          cur = cur.parent
        end
        -1
      end

      def node_get_base(doc, cur)
        return nil if cur.nil? && doc.nil?
        return nil if cur.is_a?(XmlNs)

        doc ||= cur.doc
        if doc && doc.type == HTML_DOCUMENT_NODE
          cur = doc.children
          while cur && cur.name
            if cur.type != ELEMENT_NODE
              cur = cur.next
              next
            end
            if cur.name.casecmp?("html") || cur.name.casecmp?("head")
              cur = cur.children
              next
            end
            if cur.name.casecmp?("base")
              return node_get_attr_value(cur, "href", nil)
            end

            cur = cur.next
          end
          return nil
        end
        ret = nil
        while cur
          if cur.type == ENTITY_DECL
            break if cur.uri.nil?

            return cur.uri.dup
          end
          if cur.type == ELEMENT_NODE
            base = node_get_attr_value(cur, "base", XML_XML_NAMESPACE)
            if base
              ret = ret ? URI_.build_uri(ret, base) : base
              return ret if ret.start_with?("http://", "ftp://", "urn:")
            end
          end
          cur = cur.parent
        end
        if doc&.url
          ret = ret.nil? ? doc.url.dup : URI_.build_uri(ret, doc.url)
        end
        ret
      end

      def get_line_no(node, depth = 0)
        return -1 if depth >= 5 || node.nil?

        result = -1
        case node.type
        when ELEMENT_NODE, TEXT_NODE, COMMENT_NODE, PI_NODE
          if node.line == 65535
            if node.type == TEXT_NODE && node.psvi.is_a?(Integer)
              result = node.psvi
            elsif node.type == ELEMENT_NODE && node.children
              result = get_line_no(node.children, depth + 1)
            elsif node.next
              result = get_line_no(node.next, depth + 1)
            elsif node.prev
              result = get_line_no(node.prev, depth + 1)
            end
          end
          result = node.line if result == -1 || result == 65535
        else
          prev = node.prev
          if prev && [ELEMENT_NODE, TEXT_NODE, COMMENT_NODE, PI_NODE].include?(prev.type)
            result = get_line_no(prev, depth + 1)
          elsif node.parent && node.parent.type == ELEMENT_NODE
            result = get_line_no(node.parent, depth + 1)
          end
        end
        result
      end

      def get_node_path(node)
        return nil if node.nil? || node.is_a?(XmlNs)

        buffer = +""
        cur = node
        while cur
          name = ""
          sep = "?"
          occur = 0
          nxt = nil
          case cur.type
          when DOCUMENT_NODE, HTML_DOCUMENT_NODE
            break if buffer.start_with?("/")

            sep = "/"
            nxt = nil
          when ELEMENT_NODE
            generic = false
            sep = "/"
            name = cur.name
            if cur.ns
              if cur.ns.prefix
                name = "#{cur.ns.prefix}:#{cur.name}"
              else
                generic = true
                name = "*"
              end
            end
            nxt = cur.parent
            same = lambda do |tmp|
              tmp.type == ELEMENT_NODE && (generic || (cur.name == tmp.name &&
                (tmp.ns.equal?(cur.ns) || (tmp.ns && cur.ns && cur.ns.prefix == tmp.ns.prefix))))
            end
            tmp = cur.prev
            while tmp
              occur += 1 if same.call(tmp)
              tmp = tmp.prev
            end
            if occur == 0
              tmp = cur.next
              while tmp && occur == 0
                occur += 1 if same.call(tmp)
                tmp = tmp.next
              end
              occur = 1 if occur != 0
            else
              occur += 1
            end
          when COMMENT_NODE
            sep = "/"
            name = "comment()"
            nxt = cur.parent
            occur = sibling_occurrence(cur) { |t| t.type == COMMENT_NODE }
          when TEXT_NODE, CDATA_SECTION_NODE
            sep = "/"
            name = "text()"
            nxt = cur.parent
            occur = sibling_occurrence(cur) { |t| t.type == TEXT_NODE || t.type == CDATA_SECTION_NODE }
          when PI_NODE
            sep = "/"
            name = "processing-instruction('#{cur.name}')"
            nxt = cur.parent
            occur = sibling_occurrence(cur) { |t| t.type == PI_NODE && t.name == cur.name }
          when ATTRIBUTE_NODE
            sep = "/@"
            name = cur.name
            if cur.ns
              name = cur.ns.prefix ? "#{cur.ns.prefix}:#{cur.name}" : cur.name
            end
            nxt = cur.parent
          else
            return nil
          end
          buffer = if occur == 0
            "#{sep}#{name}#{buffer}"
          else
            "#{sep}#{name}[#{occur}]#{buffer}"
          end
          cur = nxt
        end
        buffer
      end

      def sibling_occurrence(cur)
        occur = 0
        tmp = cur.prev
        while tmp
          occur += 1 if yield(tmp)
          tmp = tmp.prev
        end
        if occur == 0
          tmp = cur.next
          while tmp
            if yield(tmp)
              occur = 1
              break
            end
            tmp = tmp.next
          end
        else
          occur += 1
        end
        occur
      end

      # xmlDOMWrapRemoveNode-ish helper used by remove_namespaces!
      def each_node(root, &block)
        cur = root
        return if cur.nil?

        yield cur
        c = cur.children
        while c
          nxt = c.next
          each_node(c, &block) unless c.type == ENTITY_DECL || c.type == ENTITY_REF_NODE && false
          c = nxt
        end
      end
    end
  end
end
