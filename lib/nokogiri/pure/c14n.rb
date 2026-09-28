# frozen_string_literal: true

module Nokogiri
  module Pure
    # XML Canonicalization: a port of libxml2's c14n.c
    module C14N
      C14N_1_0 = 0
      EXCLUSIVE_1_0 = 1
      C14N_1_1 = 2

      BEFORE_DOCUMENT_ELEMENT = 0
      INSIDE_DOCUMENT_ELEMENT = 1
      AFTER_DOCUMENT_ELEMENT = 2

      # error codes (xmlParserErrors)
      ERR_ARGUMENT = 115
      ERR_INVALID_URI = 91
      C14N_CREATE_CTXT = 1950
      C14N_REQUIRES_UTF8 = 1951
      C14N_CREATE_STACK = 1952
      C14N_INVALID_NODE = 1953
      C14N_UNKNOW_NODE = 1954
      C14N_RELATIVE_NAMESPACE = 1955

      class Failure < StandardError; end

      class VisibleNsStack
        attr_accessor :ns_cur_end, :ns_prev_start, :ns_prev_end, :ns_tab, :node_tab

        def initialize
          @ns_cur_end = 0
          @ns_prev_start = 0
          @ns_prev_end = 0
          @ns_tab = []
          @node_tab = []
        end

        def add(ns, node)
          @ns_tab[@ns_cur_end] = ns
          @node_tab[@ns_cur_end] = node
          @ns_cur_end += 1
        end

        def save
          [@ns_cur_end, @ns_prev_start, @ns_prev_end]
        end

        def restore(state)
          @ns_cur_end, @ns_prev_start, @ns_prev_end = state
        end

        def shift
          @ns_prev_start = @ns_prev_end
          @ns_prev_end = @ns_cur_end
        end
      end

      # a namespace with no prefix and no href (the "xmlns=''" default)
      NS_DEFAULT = XmlNs.new(nil, nil)

      class Ctx
        attr_accessor :doc, :visible_cb, :with_comments, :buf, :pos, :parent_is_doc, :ns_rendered, :mode,
          :inclusive_ns_prefixes

        def initialize(doc, visible_cb, mode, inclusive_ns_prefixes, with_comments)
          @doc = doc
          @visible_cb = visible_cb
          @with_comments = with_comments
          @buf = +""
          @parent_is_doc = true
          @pos = BEFORE_DOCUMENT_ELEMENT
          @ns_rendered = VisibleNsStack.new
          @mode = mode
          @inclusive_ns_prefixes = mode == EXCLUSIVE_1_0 ? inclusive_ns_prefixes : nil
        end

        def visible?(node, parent)
          @visible_cb ? (@visible_cb.call(node, parent) ? true : false) : true
        end

        def exclusive?
          @mode == EXCLUSIVE_1_0
        end
      end

      module_function

      def err(node, code, msg, str1 = nil)
        Errors.report(XmlError.new(domain: Domain::C14N, code: code, level: Level::ERROR,
          message: msg, str1: str1, node: node))
        raise Failure
      end

      def str_equal(s1, s2)
        return true if s1.equal?(s2)
        return s2.nil? || s2.empty? if s1.nil?
        return s1.empty? if s2.nil?

        s1 == s2
      end

      def xml_ns?(ns)
        ns && ns.prefix == "xml" && ns.href == XML_XML_NAMESPACE
      end

      def stack_find(cur, ns)
        prefix = ns&.prefix || ""
        href = ns&.href || ""
        has_empty_ns = str_equal(prefix, nil) && str_equal(href, nil)
        start = has_empty_ns ? 0 : cur.ns_prev_start
        i = cur.ns_cur_end - 1
        while i >= start
          ns1 = cur.ns_tab[i]
          return str_equal(href, ns1&.href) if str_equal(prefix, ns1&.prefix)

          i -= 1
        end
        has_empty_ns
      end

      def exc_stack_find(cur, ns, ctx)
        prefix = ns&.prefix || ""
        href = ns&.href || ""
        has_empty_ns = str_equal(prefix, nil) && str_equal(href, nil)
        i = cur.ns_cur_end - 1
        while i >= 0
          ns1 = cur.ns_tab[i]
          if str_equal(prefix, ns1&.prefix)
            return str_equal(href, ns1&.href) ? ctx.visible?(ns1, cur.node_tab[i]) : false
          end

          i -= 1
        end
        has_empty_ns
      end

      def str_cmp(a, b)
        return 0 if a.equal?(b)
        return -1 if a.nil?
        return 1 if b.nil?

        a.b <=> b.b
      end

      # xmlListInsert with a compare function: insert before the first element >= data
      def list_insert(list, data, &cmp)
        idx = list.index { |e| cmp.call(e, data) >= 0 } || list.length
        list.insert(idx, data)
      end

      def ns_compare(a, b)
        return 0 if a.equal?(b)

        str_cmp(a.prefix, b.prefix)
      end

      def attrs_compare(a1, a2)
        return 0 if a1.equal?(a2)
        return str_cmp(a1.name, a2.name) if a1.ns.equal?(a2.ns)
        return -1 if a1.ns.nil?
        return 1 if a2.ns.nil?
        return -1 if a1.ns.prefix.nil?
        return 1 if a2.ns.prefix.nil?

        ret = str_cmp(a1.ns.href, a2.ns.href)
        ret = str_cmp(a1.name, a2.name) if ret == 0
        ret
      end

      def print_namespaces(ns, ctx)
        buf = ctx.buf
        if ns.prefix
          buf << " xmlns:" << ns.prefix << "="
        else
          buf << " xmlns="
        end
        if ns.href
          Save.write_quoted(buf, ns.href)
        else
          buf << "\"\""
        end
      end

      def process_namespaces_axis(ctx, cur, visible)
        list = []
        has_empty_ns = false
        n = cur
        while n
          ns = n.ns_def if n.type == ELEMENT_NODE
          while ns
            tmp = Tree.search_ns(cur.doc, cur, ns.prefix)
            if tmp.equal?(ns) && !xml_ns?(ns) && ctx.visible?(ns, cur)
              already_rendered = stack_find(ctx.ns_rendered, ns)
              ctx.ns_rendered.add(ns, cur) if visible
              list_insert(list, ns) { |a, b| ns_compare(a, b) } unless already_rendered
              has_empty_ns = true if ns.prefix.nil? || ns.prefix.empty?
            end
            ns = ns.next
          end
          n = n.parent
        end
        if visible && !has_empty_ns
          print_namespaces(NS_DEFAULT, ctx) unless stack_find(ctx.ns_rendered, NS_DEFAULT)
        end
        list.each { |ns2| print_namespaces(ns2, ctx) }
      end

      def exc_process_namespaces_axis(ctx, cur, visible)
        list = []
        has_empty_ns = false
        has_visibly_utilized_empty_ns = false
        has_empty_ns_in_inclusive_list = false
        ctx.inclusive_ns_prefixes&.each do |prefix|
          if prefix == "#default" || prefix == ""
            prefix = nil
            has_empty_ns_in_inclusive_list = true
          end
          ns = Tree.search_ns(cur.doc, cur, prefix)
          next unless ns && !xml_ns?(ns) && ctx.visible?(ns, cur)

          already_rendered = stack_find(ctx.ns_rendered, ns)
          ctx.ns_rendered.add(ns, cur) if visible
          list_insert(list, ns) { |a, b| ns_compare(a, b) } unless already_rendered
          has_empty_ns = true if ns.prefix.nil? || ns.prefix.empty?
        end

        if cur.ns
          ns = cur.ns
        else
          ns = Tree.search_ns(cur.doc, cur, nil)
          has_visibly_utilized_empty_ns = true
        end
        if ns && !xml_ns?(ns)
          if visible && ctx.visible?(ns, cur)
            list_insert(list, ns) { |a, b| ns_compare(a, b) } unless exc_stack_find(ctx.ns_rendered, ns, ctx)
          end
          ctx.ns_rendered.add(ns, cur) if visible
          has_empty_ns = true if ns.prefix.nil? || ns.prefix.empty?
        end

        attr = cur.properties
        while attr
          if attr.ns && !xml_ns?(attr.ns) && ctx.visible?(attr, cur)
            already_rendered = exc_stack_find(ctx.ns_rendered, attr.ns, ctx)
            ctx.ns_rendered.add(attr.ns, cur)
            list_insert(list, attr.ns) { |a, b| ns_compare(a, b) } if !already_rendered && visible
            has_empty_ns = true if attr.ns.prefix.nil? || attr.ns.prefix.empty?
          elsif attr.ns && (attr.ns.prefix.nil? || attr.ns.prefix.empty?) && (attr.ns.href.nil? || attr.ns.href.empty?)
            has_visibly_utilized_empty_ns = true
          end
          attr = attr.next
        end

        if visible && has_visibly_utilized_empty_ns && !has_empty_ns && !has_empty_ns_in_inclusive_list
          print_namespaces(NS_DEFAULT, ctx) unless exc_stack_find(ctx.ns_rendered, NS_DEFAULT, ctx)
        elsif visible && !has_empty_ns && has_empty_ns_in_inclusive_list
          print_namespaces(NS_DEFAULT, ctx) unless stack_find(ctx.ns_rendered, NS_DEFAULT)
        end
        list.each { |ns2| print_namespaces(ns2, ctx) }
      end

      def xml_attr?(attr)
        attr.ns && xml_ns?(attr.ns)
      end

      def print_attrs(attr, ctx)
        buf = ctx.buf
        buf << " "
        buf << attr.ns.prefix << ":" if attr.ns && attr.ns.prefix && !attr.ns.prefix.empty?
        buf << attr.name << "=\""
        value = Tree.node_list_get_string(ctx.doc, attr.children, true)
        buf << normalize_string(value, :attr) if value
        buf << "\""
      end

      def find_hidden_parent_attr(ctx, cur, name, ns)
        while cur && !ctx.visible?(cur, cur.parent)
          res = Tree.has_ns_prop(cur, name, ns)
          return res if res

          cur = cur.parent
        end
        nil
      end

      def fixup_base_attr(ctx, xml_base_attr)
        res = Tree.node_list_get_string(ctx.doc, xml_base_attr.children, true) || +""
        cur = xml_base_attr.parent.parent
        while cur && !ctx.visible?(cur, cur.parent)
          attr = Tree.has_ns_prop(cur, "base", XML_XML_NAMESPACE)
          if attr
            tmp_str = Tree.node_list_get_string(ctx.doc, attr.children, true) || +""
            tmp_str += "/" if tmp_str.length > 1 && tmp_str[-2] == "."
            built = URI_.build_uri(res, tmp_str)
            if built.nil?
              err(cur, ERR_INVALID_URI, "processing xml:base attribute - can't construct uri")
            end
            res = built
          end
          cur = cur.parent
        end
        return nil if res.nil? || res.empty?

        Tree.new_ns_prop(nil, xml_base_attr.ns, "base", res)
      end

      def process_attrs_axis(ctx, cur, parent_visible)
        list = []
        cmp = ->(a, b) { attrs_compare(a, b) }
        case ctx.mode
        when C14N_1_0
          attr = cur.properties
          while attr
            list_insert(list, attr, &cmp) if ctx.visible?(attr, cur)
            attr = attr.next
          end
          if parent_visible && cur.parent && !ctx.visible?(cur.parent, cur.parent.parent)
            tmp = cur.parent
            while tmp
              attr = tmp.type == ELEMENT_NODE ? tmp.properties : nil
              while attr
                if xml_attr?(attr) && list.none? { |e| attrs_compare(e, attr) == 0 }
                  list_insert(list, attr, &cmp)
                end
                attr = attr.next
              end
              tmp = tmp.parent
            end
          end
        when EXCLUSIVE_1_0
          attr = cur.properties
          while attr
            list_insert(list, attr, &cmp) if ctx.visible?(attr, cur)
            attr = attr.next
          end
        when C14N_1_1
          xml_lang_attr = xml_space_attr = xml_base_attr = nil
          attr = cur.properties
          while attr
            if !parent_visible || !xml_attr?(attr)
              list_insert(list, attr, &cmp) if ctx.visible?(attr, cur)
            else
              matched = false
              if !matched && xml_lang_attr.nil? && attr.name == "lang"
                xml_lang_attr = attr
                matched = true
              end
              if !matched && xml_space_attr.nil? && attr.name == "space"
                xml_space_attr = attr
                matched = true
              end
              if !matched && xml_base_attr.nil? && attr.name == "base"
                xml_base_attr = attr
                matched = true
              end
              list_insert(list, attr, &cmp) if !matched && ctx.visible?(attr, cur)
            end
            attr = attr.next
          end
          if parent_visible
            xml_lang_attr ||= find_hidden_parent_attr(ctx, cur.parent, "lang", XML_XML_NAMESPACE)
            list_insert(list, xml_lang_attr, &cmp) if xml_lang_attr
            xml_space_attr ||= find_hidden_parent_attr(ctx, cur.parent, "space", XML_XML_NAMESPACE)
            list_insert(list, xml_space_attr, &cmp) if xml_space_attr
            xml_base_attr ||= find_hidden_parent_attr(ctx, cur.parent, "base", XML_XML_NAMESPACE)
            if xml_base_attr
              xml_base_attr = fixup_base_attr(ctx, xml_base_attr)
              list_insert(list, xml_base_attr, &cmp) if xml_base_attr
            end
          end
        end
        list.each { |a| print_attrs(a, ctx) }
      end

      def check_for_relative_namespaces(ctx, cur)
        ns = cur.ns_def
        while ns
          if ns.href && !ns.href.empty?
            u = URI_.parse(ns.href)
            err(cur, ERR_INVALID_URI, "parsing namespace uri") if u.nil?
            if u[:scheme].nil? || u[:scheme].empty?
              err(nil, C14N_RELATIVE_NAMESPACE, "Relative namespace UR is invalid here : (null)\n", nil)
            end
          end
          ns = ns.next
        end
      end

      def process_element_node(ctx, cur, visible)
        check_for_relative_namespaces(ctx, cur)
        state = ctx.ns_rendered.save
        parent_is_doc = false
        buf = ctx.buf
        if visible
          if ctx.parent_is_doc
            parent_is_doc = ctx.parent_is_doc
            ctx.parent_is_doc = false
            ctx.pos = INSIDE_DOCUMENT_ELEMENT
          end
          buf << "<"
          buf << cur.ns.prefix << ":" if cur.ns && cur.ns.prefix && !cur.ns.prefix.empty?
          buf << cur.name
        end
        if ctx.exclusive?
          exc_process_namespaces_axis(ctx, cur, visible)
        else
          process_namespaces_axis(ctx, cur, visible)
        end
        ctx.ns_rendered.shift if visible
        process_attrs_axis(ctx, cur, visible)
        buf << ">" if visible
        process_node_list(ctx, cur.children) if cur.children
        if visible
          buf << "</"
          buf << cur.ns.prefix << ":" if cur.ns && cur.ns.prefix && !cur.ns.prefix.empty?
          buf << cur.name << ">"
          if parent_is_doc
            ctx.parent_is_doc = parent_is_doc
            ctx.pos = AFTER_DOCUMENT_ELEMENT
          end
        end
        ctx.ns_rendered.restore(state)
      end

      def process_node(ctx, cur)
        visible = ctx.visible?(cur, cur.parent)
        buf = ctx.buf
        case cur.type
        when ELEMENT_NODE
          process_element_node(ctx, cur, visible)
        when CDATA_SECTION_NODE, TEXT_NODE
          buf << normalize_string(cur.content, :text) if visible && cur.content
        when PI_NODE
          if visible
            buf << (ctx.pos == AFTER_DOCUMENT_ELEMENT ? "\n<?" : "<?")
            buf << cur.name
            if cur.content && !cur.content.empty?
              buf << " " << normalize_string(cur.content, :pi)
            end
            buf << (ctx.pos == BEFORE_DOCUMENT_ELEMENT ? "?>\n" : "?>")
          end
        when COMMENT_NODE
          if visible && ctx.with_comments
            buf << (ctx.pos == AFTER_DOCUMENT_ELEMENT ? "\n<!--" : "<!--")
            buf << normalize_string(cur.content, :comment) if cur.content
            buf << (ctx.pos == BEFORE_DOCUMENT_ELEMENT ? "-->\n" : "-->")
          end
        when DOCUMENT_NODE, DOCUMENT_FRAG_NODE, HTML_DOCUMENT_NODE
          if cur.children
            ctx.pos = BEFORE_DOCUMENT_ELEMENT
            ctx.parent_is_doc = true
            process_node_list(ctx, cur.children)
          end
        when ATTRIBUTE_NODE
          err(nil, C14N_INVALID_NODE, "Node XML_ATTRIBUTE_NODE is invalid here : processing node\n", "processing node")
        when NAMESPACE_DECL
          err(nil, C14N_INVALID_NODE, "Node XML_NAMESPACE_DECL is invalid here : processing node\n", "processing node")
        when ENTITY_REF_NODE
          err(nil, C14N_INVALID_NODE, "Node XML_ENTITY_REF_NODE is invalid here : processing node\n", "processing node")
        when ENTITY_NODE
          err(nil, C14N_INVALID_NODE, "Node XML_ENTITY_NODE is invalid here : processing node\n", "processing node")
        when DOCUMENT_TYPE_NODE, NOTATION_NODE, DTD_NODE, ELEMENT_DECL, ATTRIBUTE_DECL, ENTITY_DECL,
             XINCLUDE_START, XINCLUDE_END
          # ignored
        else
          err(nil, C14N_UNKNOW_NODE, "Unknown node type #{cur.type} found : processing node\n", "processing node")
        end
      end

      def process_node_list(ctx, cur)
        while cur
          process_node(ctx, cur)
          cur = cur.next
        end
      end

      NORMALIZE_RES = {
        attr: /[<&"\t\n\r]/,
        text: /[<>&\r]/,
        comment: /\r/,
        pi: /\r/,
      }.freeze
      NORMALIZE_MAP = {
        "<" => "&lt;", ">" => "&gt;", "&" => "&amp;", "\"" => "&quot;",
        "\t" => "&#x9;", "\n" => "&#xA;", "\r" => "&#xD;",
      }.freeze

      def normalize_string(input, mode)
        input.gsub(NORMALIZE_RES.fetch(mode), NORMALIZE_MAP)
      end

      # xmlC14NExecute. Returns the canonical UTF-8 string, or nil on failure.
      def execute(doc, visible_cb, mode, inclusive_ns_prefixes, with_comments)
        unless [C14N_1_0, EXCLUSIVE_1_0, C14N_1_1].include?(mode)
          Errors.report(XmlError.new(domain: Domain::C14N, code: ERR_ARGUMENT, level: Level::ERROR,
            message: "Invalid argument\n"))
          return nil
        end
        ctx = Ctx.new(doc, visible_cb, mode, inclusive_ns_prefixes, with_comments)
        begin
          process_node_list(ctx, doc.children) if doc.children
        rescue Failure
          return nil
        end
        io = StringIO.new
        Save.write_to_io(io, ctx.buf.b)
        io.string
      end
    end
  end
end
