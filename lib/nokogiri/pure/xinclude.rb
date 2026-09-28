# frozen_string_literal: true

module Nokogiri
  module Pure
    # XInclude processing: a port of libxml2's xinclude.c
    module XInclude
      XINCLUDE_NS = "http://www.w3.org/2001/XInclude"
      XINCLUDE_OLD_NS = "http://www.w3.org/2003/XInclude"
      XINCLUDE_NODE = "include"
      XINCLUDE_FALLBACK = "fallback"
      XINCLUDE_HREF = "href"
      XINCLUDE_PARSE = "parse"
      XINCLUDE_PARSE_XML = "xml"
      XINCLUDE_PARSE_TEXT = "text"
      XINCLUDE_PARSE_ENCODING = "encoding"
      XINCLUDE_PARSE_XPOINTER = "xpointer"
      MAX_DEPTH = 40

      PARSE_NOENT = 1 << 1
      PARSE_DTDLOAD = 1 << 2
      PARSE_NOXINCNODE = 1 << 15
      PARSE_NOBASEFIX = 1 << 18

      ERR_INTERNAL_ERROR = 1
      XINCLUDE_RECURSION = 1600
      XINCLUDE_PARSE_VALUE = 1601
      XINCLUDE_ENTITY_DEF_MISMATCH = 1602
      XINCLUDE_NO_HREF = 1603
      XINCLUDE_NO_FALLBACK = 1604
      XINCLUDE_HREF_URI = 1605
      XINCLUDE_TEXT_FRAGMENT = 1606
      XINCLUDE_TEXT_DOCUMENT = 1607
      XINCLUDE_INVALID_CHAR = 1608
      XINCLUDE_BUILD_FAILED = 1609
      XINCLUDE_UNKNOWN_ENCODING = 1610
      XINCLUDE_MULTIPLE_ROOT = 1611
      XINCLUDE_XPTR_FAILED = 1612
      XINCLUDE_XPTR_RESULT = 1613
      XINCLUDE_INCLUDE_IN_INCLUDE = 1614
      XINCLUDE_FALLBACKS_IN_INCLUDE = 1615
      XINCLUDE_FALLBACK_NOT_IN_INCLUDE = 1616
      XINCLUDE_DEPRECATED_NS = 1617
      XINCLUDE_FRAGMENT_ID = 1618

      Ref = Struct.new(:uri, :fragment, :base, :elem, :inc, :xml, :fallback, :expanding, :replace)
      CachedDoc = Struct.new(:doc, :url, :expanding)
      CachedTxt = Struct.new(:text, :url)

      class Ctxt
        attr_accessor :doc, :inc_tab, :txt_tab, :url_tab, :nb_errors, :fatal_err, :err_no, :legacy,
          :parse_flags, :depth, :is_stream

        def initialize(doc)
          @doc = doc
          @inc_tab = []
          @txt_tab = []
          @url_tab = []
          @nb_errors = 0
          @fatal_err = false
          @err_no = 0
          @legacy = false
          @parse_flags = 0
          @depth = 0
          @is_stream = false
        end
      end

      module_function

      def err(ctxt, node, code, msg, extra = nil)
        return if ctxt.fatal_err

        ctxt.nb_errors += 1
        Errors.report(XmlError.new(domain: Domain::XINCLUDE, code: code, level: Level::ERROR,
          message: extra.nil? ? msg : format(msg.gsub("%s", "%<e>s"), e: extra), str1: extra, node: node))
        ctxt.err_no = code
      end

      def get_prop(ctxt, cur, name)
        ret = Tree.node_get_attr_value(cur, name, XINCLUDE_NS)
        return ret if ret

        if ctxt.legacy
          ret = Tree.node_get_attr_value(cur, name, XINCLUDE_OLD_NS)
          return ret if ret
        end
        Tree.node_get_attr_value(cur, name, nil)
      end

      def xinclude_ns?(ns)
        ns && (ns.href == XINCLUDE_NS || ns.href == XINCLUDE_OLD_NS)
      end

      # xmlXIncludeParseFile
      def parse_file(ctxt, url)
        Parser.xinclude_parse_file(url, ctxt.parse_flags | PARSE_DTDLOAD)
      end

      def add_node(ctxt, cur)
        fragment = get_prop(ctxt, cur, XINCLUDE_PARSE_XPOINTER)
        href = get_prop(ctxt, cur, XINCLUDE_HREF)
        if href.nil?
          if fragment.nil?
            err(ctxt, cur, XINCLUDE_NO_HREF, "href or xpointer must be present\n")
            return nil
          end
          href = +""
        end
        xml = true
        parse = get_prop(ctxt, cur, XINCLUDE_PARSE)
        if parse
          if parse == XINCLUDE_PARSE_XML
            xml = true
          elsif parse == XINCLUDE_PARSE_TEXT
            xml = false
          else
            err(ctxt, cur, XINCLUDE_PARSE_VALUE, "invalid value %s for 'parse'\n", parse)
            return nil
          end
        end
        uri = URI_.parse(href)
        if uri.nil?
          err(ctxt, cur, XINCLUDE_HREF_URI, "invalid value href %s\n", href)
          return nil
        end
        if uri[:fragment]
          if ctxt.legacy
            fragment ||= uri[:fragment]
          else
            err(ctxt, cur, XINCLUDE_FRAGMENT_ID,
              "Invalid fragment identifier in URI %s use the xpointer attribute\n", href)
            return nil
          end
          uri[:fragment] = nil
        end
        href = URI_.compose(uri)
        base = Tree.node_get_base(ctxt.doc, cur)
        local = false
        if !href.empty?
          tmp = URI_.build_uri(href, base)
          if tmp.nil?
            err(ctxt, cur, XINCLUDE_HREF_URI, "failed build URL\n")
            return nil
          end
          href = tmp
          local = true if href == ctxt.doc.url
        else
          local = true
        end
        if local && xml && (fragment.nil? || fragment.empty?)
          err(ctxt, cur, XINCLUDE_RECURSION, "detected a local recursion with no xpointer in %s\n", href)
          return nil
        end
        ref = Ref.new(href, fragment, nil, cur, nil, xml, false, false, false)
        if (ctxt.parse_flags & PARSE_NOBASEFIX) == 0 && cur.doc && (cur.doc.parse_flags & PARSE_NOBASEFIX) == 0
          ref.base = base || +""
        end
        ctxt.inc_tab << ref
        ref
      end

      def recurse_doc(ctxt, doc)
        old = [ctxt.doc, ctxt.inc_tab, ctxt.is_stream]
        ctxt.doc = doc
        ctxt.inc_tab = []
        ctxt.is_stream = false
        do_process(ctxt, Tree.doc_get_root_element(doc))
        ctxt.doc, ctxt.inc_tab, ctxt.is_stream = old
      end

      # xmlBuildRelativeURI (the subset needed for base fixup)
      def build_relative_uri(uri, base)
        return nil if uri.nil? || uri.empty?

        ref = URI_.parse(uri)
        return uri.dup if ref.nil?
        return URI_.compose(ref) if base.nil? || base.empty?

        bas = URI_.parse(base)
        return URI_.compose(ref) if bas.nil?

        ref_server = ref[:authority]
        bas_server = bas[:authority]
        if bas[:scheme] != ref[:scheme] || bas_server != ref_server
          return URI_.compose(ref)
        end
        return +"" if bas[:path] == ref[:path]

        bptr = bas[:path].to_s
        rptr = ref[:path].to_s
        rptr = "/" if rptr.empty?
        return URI_.compose(ref) if bptr.start_with?("/") != rptr.start_with?("/")

        pos = 0
        pos += 1 while pos < bptr.length && pos < rptr.length && bptr[pos] == rptr[pos]
        return +"" if bptr[pos] == rptr[pos]

        ix = pos
        ix -= 1 while ix > 0 && rptr[ix - 1] != "/"
        uptr = rptr[ix..]
        nbslash = bptr[ix..].count("/")
        return +"./" if nbslash == 0 && uptr.empty?

        if nbslash == 0
          return Save.uri_escape_str(uptr, "/;&=+$,")
        end

        val = +"../" * nbslash
        val << (uptr.start_with?("/") ? uptr[1..] : uptr)
        Save.uri_escape_str(val, "/;&=+$,")
      end

      def base_fixup(ctxt, cur, copy, target_base)
        return if cur.type != ELEMENT_NODE

        base = Tree.node_get_base(cur.doc, cur)
        if base && base != target_base
          rel_base = build_relative_uri(base, target_base)
          if rel_base.nil?
            err(ctxt, cur, XINCLUDE_HREF_URI, "Building relative URI failed: %s\n", base)
            return
          end
          if rel_base.include?("/")
            ns = Tree.search_ns_by_href(copy.doc, copy, XML_XML_NAMESPACE)
            Tree.set_ns_prop(copy, ns, "base", rel_base) if ns
            return
          end
        end
        prop = Tree.get_prop_node_internal(copy, "base", XML_XML_NAMESPACE, false)
        if prop
          Tree.unlink_node_internal(prop)
          Tree.free_prop(prop)
        end
      end

      def copy_node(ctxt, elem, copy_children, target_base)
        result = nil
        insert_parent = nil
        insert_last = nil
        depth = 0
        if copy_children
          cur = elem.children
          return nil if cur.nil?
        else
          cur = elem
        end
        link = lambda do |copy|
          result ||= copy
          if insert_last
            insert_last.next = copy
            copy.prev = insert_last
          elsif insert_parent
            insert_parent.children = copy
          end
          insert_last = copy
        end
        loop do
          recurse = false
          if cur.type == DOCUMENT_NODE || cur.type == DTD_NODE
            # skip
          elsif cur.type == ELEMENT_NODE && cur.ns && cur.name == XINCLUDE_NODE && xinclude_ns?(cur.ns)
            ref = expand_node(ctxt, cur)
            return nil if ref.nil?

            item = ref.inc
            while item
              copy = Tree.static_copy_node(item, ctxt.doc, insert_parent, 1)
              link.call(copy)
              base_fixup(ctxt, item, copy, target_base) if depth == 0 && target_base
              item = item.next
            end
          else
            copy = Tree.static_copy_node(cur, ctxt.doc, insert_parent, 2)
            link.call(copy)
            base_fixup(ctxt, cur, copy, target_base) if depth == 0 && target_base
            recurse = cur.type != ENTITY_REF_NODE && !cur.children.nil?
          end
          if recurse
            cur = cur.children
            insert_parent = insert_last
            insert_last = nil
            depth += 1
            next
          end
          return result if cur.equal?(elem)

          while cur.next.nil?
            insert_parent.last = insert_last if insert_parent
            cur = cur.parent
            return result if cur.equal?(elem)

            insert_last = insert_parent
            insert_parent = insert_parent.parent
            depth -= 1
          end
          cur = cur.next
        end
      end

      def copy_xpointer(ctxt, nodes, target_base)
        list = nil
        last = nil
        nodes.each do |n|
          next if n.nil?

          node = case n.type
          when DOCUMENT_NODE, HTML_DOCUMENT_NODE
            root = Tree.doc_get_root_element(n)
            if root.nil?
              err(ctxt, n, ERR_INTERNAL_ERROR, "document without root\n")
              next
            end
            root
          when TEXT_NODE, CDATA_SECTION_NODE, ELEMENT_NODE, PI_NODE, COMMENT_NODE
            n
          else
            err(ctxt, n, XINCLUDE_XPTR_RESULT, "invalid node type in XPtr result\n")
            next
          end
          copy = copy_node(ctxt, node, false, target_base)
          return nil if copy.nil?

          if last.nil?
            list = copy
          else
            last = last.next while last.next
            copy.prev = last
            last.next = copy
          end
          last = copy
        end
        list
      end

      def merge_entity(ctxt, doc, ent)
        case ent.etype
        when INTERNAL_PARAMETER_ENTITY, EXTERNAL_PARAMETER_ENTITY, INTERNAL_PREDEFINED_ENTITY
          return
        end
        prev = Tree.get_doc_entity(doc, ent.name)
        if prev.nil?
          ret = Tree.add_doc_entity(doc, ent.name, ent.etype, ent.external_id, ent.system_id, ent.content)
          ret.uri = ent.uri.dup if ret && ent.uri
          return
        end
        mismatch = if ent.etype != prev.etype
          true
        elsif ent.system_id && prev.system_id
          ent.system_id != prev.system_id
        elsif ent.external_id && prev.external_id
          ent.external_id != prev.external_id
        elsif ent.content && prev.content
          ent.content != prev.content
        else
          true
        end
        return unless mismatch
        return unless ent.etype == EXTERNAL_GENERAL_UNPARSED_ENTITY

        err(ctxt, ent, XINCLUDE_ENTITY_DEF_MISMATCH, "mismatch in redefinition of entity %s\n", ent.name)
      end

      def merge_entities(ctxt, doc, from)
        return 0 if from.nil? || from.int_subset.nil?

        target = doc.int_subset
        if target.nil?
          cur = Tree.doc_get_root_element(doc)
          return -1 if cur.nil?

          target = Tree.create_int_subset(doc, cur.name, nil, nil)
        end
        source = from.int_subset
        source.entities&.values&.each { |ent| merge_entity(ctxt, doc, ent) }
        source = from.ext_subset
        if source&.entities && target.external_id != source.external_id && target.system_id != source.system_id
          source.entities.values.each { |ent| merge_entity(ctxt, doc, ent) }
        end
        0
      end

      def load_doc(ctxt, ref)
        url = ref.uri
        fragment = ref.fragment
        doc = nil
        loaded = false
        if url.empty? || url.start_with?("#") || (ctxt.doc && url == ctxt.doc.url)
          doc = ctxt.doc
          loaded = true
        end
        unless loaded
          cached = ctxt.url_tab.find { |c| c.url == url }
          if cached
            if cached.expanding
              err(ctxt, ref.elem, XINCLUDE_RECURSION, "inclusion loop detected\n")
              return -1
            end
            doc = cached.doc
            return -1 if doc.nil?

            loaded = true
          end
        end
        unless loaded
          save_flags = ctxt.parse_flags
          ctxt.parse_flags |= PARSE_NOENT if fragment
          doc = parse_file(ctxt, url)
          ctxt.parse_flags = save_flags
          cache = CachedDoc.new(doc, url.dup, false)
          ctxt.url_tab << cache
          return -1 if doc.nil?

          merge_entities(ctxt, ctxt.doc, doc)
          cache.expanding = true
          recurse_doc(ctxt, doc)
          cache.expanding = false
        end

        if fragment.nil?
          root = Tree.doc_get_root_element(doc)
          if root.nil?
            err(ctxt, ref.elem, ERR_INTERNAL_ERROR, "document without root\n")
            return -1
          end
          ref.inc = Tree.doc_copy_node(root, ctxt.doc, 1)
          base_fixup(ctxt, root, ref.inc, ref.base) if ref.base
        else
          if ctxt.is_stream && doc.equal?(ctxt.doc)
            err(ctxt, ref.elem, XINCLUDE_XPTR_FAILED, "XPointer expressions not allowed in streaming mode\n")
            return -1
          end
          ok, result = XPointer.eval(fragment, doc)
          unless ok
            err(ctxt, ref.elem, XINCLUDE_XPTR_FAILED, "XPointer evaluation failed: #%s\n", fragment)
            return -1
          end
          return 0 if result.nil?

          unless result.is_a?(Array)
            err(ctxt, ref.elem, XINCLUDE_XPTR_RESULT, "XPointer is not a range: #%s\n", fragment)
            return -1
          end
          nodes = result.map do |n|
            if n.is_a?(XmlNs)
              err(ctxt, ref.elem, XINCLUDE_XPTR_RESULT, "XPointer selects a namespace: #%s\n", fragment)
              next nil
            end
            case n.type
            when ELEMENT_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE, ENTITY_NODE, PI_NODE,
                 COMMENT_NODE, DOCUMENT_NODE, HTML_DOCUMENT_NODE
              n
            when ATTRIBUTE_NODE
              err(ctxt, ref.elem, XINCLUDE_XPTR_RESULT, "XPointer selects an attribute: #%s\n", fragment)
              nil
            else
              err(ctxt, ref.elem, XINCLUDE_XPTR_RESULT, "XPointer selects unexpected nodes: #%s\n", fragment)
              nil
            end
          end
          ref.inc = copy_xpointer(ctxt, nodes, ref.base)
        end
        0
      end

      def load_txt(ctxt, ref)
        url = ref.uri
        if url.empty?
          err(ctxt, ref.elem, XINCLUDE_TEXT_DOCUMENT, "text serialization of document not available\n")
          return -1
        end
        cached = ctxt.txt_tab.find { |t| t.url == url }
        if cached
          ref.inc = Tree.new_doc_text(ctxt.doc, cached.text)
          return 0
        end
        encoding = ref.elem ? get_prop(ctxt, ref.elem, XINCLUDE_PARSE_ENCODING) : nil
        handler = nil
        if encoding
          handler = Enc.find_handler(encoding)
          if handler.nil?
            err(ctxt, ref.elem, XINCLUDE_UNKNOWN_ENCODING, "encoding %s not supported\n", encoding)
            return -1
          end
        end
        bytes = Parser.load_external_resource(url, ctxt.parse_flags)
        return -1 if bytes.nil?

        text = begin
          (handler || Enc.find_handler("UTF-8")).decode_input(bytes)
        rescue ArgumentError, EncodingError
          nil
        end
        if text.nil? || !text.valid_encoding? || text.each_char.any? { |c| !Encoding_.xml_char?(c.ord) }
          err(ctxt, ref.elem, XINCLUDE_INVALID_CHAR, "%s contains invalid char\n", url)
          return -1
        end
        node = Tree.new_doc_text(ctxt.doc, nil)
        Tree.node_add_content(node, text)
        ctxt.txt_tab << CachedTxt.new(node.content&.dup, url.dup)
        ref.inc = node
        0
      end

      def load_fallback(ctxt, fallback, ref)
        ret = 0
        if fallback.children
          old = ctxt.nb_errors
          ref.inc = copy_node(ctxt, fallback, true, ref.base)
          ret = -1 if ctxt.nb_errors > old
        else
          ref.inc = nil
        end
        ref.fallback = true
        ret
      end

      def expand_node(ctxt, node)
        return nil if ctxt.fatal_err

        if ctxt.depth >= MAX_DEPTH
          err(ctxt, node, XINCLUDE_RECURSION, "maximum recursion depth exceeded\n")
          ctxt.fatal_err = true
          return nil
        end
        existing = ctxt.inc_tab.find { |r| r.elem.equal?(node) }
        if existing
          if existing.expanding
            err(ctxt, node, XINCLUDE_RECURSION, "inclusion loop detected\n")
            return nil
          end
          return existing
        end
        ref = add_node(ctxt, node)
        return nil if ref.nil?

        ref.expanding = true
        ctxt.depth += 1
        load_node(ctxt, ref)
        ctxt.depth -= 1
        ref.expanding = false
        ref
      end

      def load_node(ctxt, ref)
        cur = ref.elem
        ret = ref.xml ? load_doc(ctxt, ref) : load_txt(ctxt, ref)
        if ret < 0
          child = cur.children
          while child
            if child.type == ELEMENT_NODE && child.ns && child.name == XINCLUDE_FALLBACK && xinclude_ns?(child.ns)
              ret = load_fallback(ctxt, child, ref)
              break
            end
            child = child.next
          end
        end
        if ret < 0
          err(ctxt, cur, XINCLUDE_NO_FALLBACK, "could not load %s, and no fallback was found\n", ref.uri)
        end
        0
      end

      def include_node(ctxt, ref)
        cur = ref.elem
        return -1 if cur.nil?

        list = ref.inc
        ref.inc = nil
        if cur.parent && cur.parent.type != ELEMENT_NODE
          nb_elem = 0
          tmp = list
          while tmp
            nb_elem += 1 if tmp.type == ELEMENT_NODE
            tmp = tmp.next
          end
          if nb_elem > 1
            err(ctxt, ref.elem, XINCLUDE_MULTIPLE_ROOT, "XInclude error: would result in multiple root nodes\n")
            return -1
          end
        end
        if (ctxt.parse_flags & PARSE_NOXINCNODE) != 0
          while list
            nd = list
            list = list.next
            Tree.add_prev_sibling(cur, nd)
          end
          Tree.unlink_node(cur)
        else
          Tree.unset_prop(cur, "href") if ref.fallback
          cur.type = XINCLUDE_START
          child = cur.children
          while child
            nxt = child.next
            Tree.unlink_node(child)
            child = nxt
          end
          fin = Tree.new_doc_node(cur.doc, cur.ns, cur.name, nil)
          fin.type = XINCLUDE_END
          Tree.add_next_sibling(cur, fin)
          while list
            c = list
            list = list.next
            Tree.add_prev_sibling(fin, c)
          end
        end
        0
      end

      def test_node(ctxt, node)
        return false if node.nil? || node.type != ELEMENT_NODE || node.ns.nil?
        return false unless xinclude_ns?(node.ns)

        ctxt.legacy = true if node.ns.href == XINCLUDE_OLD_NS
        if node.name == XINCLUDE_NODE
          nb_fallback = 0
          child = node.children
          while child
            if child.type == ELEMENT_NODE && xinclude_ns?(child.ns)
              if child.name == XINCLUDE_NODE
                err(ctxt, node, XINCLUDE_INCLUDE_IN_INCLUDE, "%s has an 'include' child\n", XINCLUDE_NODE)
                return false
              end
              nb_fallback += 1 if child.name == XINCLUDE_FALLBACK
            end
            child = child.next
          end
          if nb_fallback > 1
            err(ctxt, node, XINCLUDE_FALLBACKS_IN_INCLUDE, "%s has multiple fallback children\n", XINCLUDE_NODE)
            return false
          end
          return true
        end
        if node.name == XINCLUDE_FALLBACK
          parent = node.parent
          if parent.nil? || parent.type != ELEMENT_NODE || !xinclude_ns?(parent.ns) || parent.name != XINCLUDE_NODE
            err(ctxt, node, XINCLUDE_FALLBACK_NOT_IN_INCLUDE, "%s is not the child of an 'include'\n", XINCLUDE_FALLBACK)
          end
        end
        false
      end

      def do_process(ctxt, tree)
        return 0 if tree.nil?

        start = ctxt.inc_tab.length
        cur = tree
        loop do
          if test_node(ctxt, cur)
            ref = expand_node(ctxt, cur)
            ref.replace = true if ref
          elsif cur.children && (cur.type == DOCUMENT_NODE || cur.type == ELEMENT_NODE)
            cur = cur.children
            next
          end
          loop do
            break if cur.equal?(tree)

            if cur.next
              cur = cur.next
              break
            end
            cur = cur.parent
            break if cur.nil?
          end
          break if cur.nil? || cur.equal?(tree)
        end
        ret = 0
        (start...ctxt.inc_tab.length).each do |i|
          ref = ctxt.inc_tab[i]
          if ref.replace
            include_node(ctxt, ref)
            ref.replace = false
          else
            ref.inc = nil
          end
          ret += 1
        end
        ctxt.inc_tab.clear if ctxt.is_stream
        ret
      end

      # xmlXIncludeProcessTreeFlags
      def process_tree_flags(tree, flags)
        return -1 if tree.nil? || tree.is_a?(XmlNs) || tree.doc.nil?

        ctxt = Ctxt.new(tree.doc)
        ctxt.parse_flags = flags
        ret = do_process(ctxt, tree)
        ret = -1 if ret >= 0 && ctxt.nb_errors > 0
        ret
      end
    end
  end
end
