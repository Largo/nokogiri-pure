# frozen_string_literal: true

# Port of libxslt transform.c: the transformation engine (template application, sequence
# constructors, all XSLT instructions, copying, whitespace stripping, xsltApplyStylesheet).

module Nokogiri
  module Pure
    module XSLT
      module_function

      def templ_push(ctxt, value)
        ctxt.templ_tab << value
        ctxt.templ = value
        ctxt.templ_tab.length - 1
      end

      def templ_pop(ctxt)
        return nil if ctxt.templ_tab.empty?

        ret = ctxt.templ_tab.pop
        ctxt.templ = ctxt.templ_tab.last
        ret
      end

      # xsltLocalVariablePop
      def local_variable_pop(ctxt, limit_nr, level)
        tab = ctxt.vars_tab
        return if tab.empty?

        loop do
          break if tab.length <= limit_nr

          variable = tab.last
          break if variable.level <= level

          free_stack_elem_list(variable) if variable.level >= 0
          tab.pop
          break if tab.empty?
        end
        ctxt.vars = tab.last
      end

      # xsltTemplateParamsCleanup
      def template_params_cleanup(ctxt)
        tab = ctxt.vars_tab
        while tab.length > ctxt.vars_base
          param = tab.pop
          free_stack_elem_list(param) if param.level >= 0
        end
        ctxt.vars = tab.last
      end

      # xsltPreCompEval
      def pre_comp_eval(ctxt, node, comp)
        xp = ctxt.xpath_ctxt
        old_node = xp.node
        old_pos = xp.proximity_position
        old_size = xp.context_size
        old_ns = xp.namespaces
        xp.node = node
        xp.namespaces = comp.ns_list
        res = XPath.compiled_eval(comp.comp, xp)
        xp.node = old_node
        xp.proximity_position = old_pos
        xp.context_size = old_size
        xp.namespaces = old_ns
        res
      end

      # xsltPreCompEvalToBoolean
      def pre_comp_eval_to_boolean(ctxt, node, comp)
        xp = ctxt.xpath_ctxt
        old_node = xp.node
        old_pos = xp.proximity_position
        old_size = xp.context_size
        old_ns = xp.namespaces
        xp.node = node
        xp.namespaces = comp.ns_list
        res = XPath.compiled_eval_to_boolean(comp.comp, xp)
        xp.node = old_node
        xp.proximity_position = old_pos
        xp.context_size = old_size
        xp.namespaces = old_ns
        res
      end

      # xsltNewTransformContext
      def new_transform_context(style, doc)
        cur = TransformContext.new
        cur.templ_tab = []
        cur.templ = nil
        cur.max_template_depth = MAX_DEPTH
        cur.vars_tab = []
        cur.vars = nil
        cur.vars_base = 0
        cur.max_template_vars = MAX_VARS
        cur.style = style
        cur.state = STATE_OK
        cur.type = OUTPUT_XML
        cur.depth = 0
        cur.op_limit = 0
        cur.op_count = 0
        cur.current_id = 0
        cur.key_init_level = 0
        cur.nb_keys = 0
        cur.has_templ_key_patterns = false
        cur.source_flags = {}.compare_by_identity
        cur.source_ids = {}.compare_by_identity
        cur.pattern_cache = {}.compare_by_identity
        xp = XPath::Context.new(doc)
        cur.xpath_ctxt = xp
        # XSLT_REGISTER_VARIABLE_LOOKUP
        xp.register_variable_lookup(->(data, name, ns_uri) { xpath_variable_lookup(data, name, ns_uri) }, cur)
        register_all_functions(xp)
        register_all_element(cur)
        xp.extra = cur
        # XSLT_REGISTER_FUNCTION_LOOKUP
        xp.register_func_lookup(->(data, name, ns_uri) { xpath_function_lookup(data, name, ns_uri) }, xp)
        xp.ns_hash = style.ns_hash
        init_ctxt_exts(cur)
        XPath.order_doc_elems(doc)
        cur.parser_options = PARSE_OPTIONS
        docu = new_document(cur, doc)
        docu.main = true
        cur.document = docu
        cur.inst = nil
        cur.output_file = nil
        cur.sec = default_security_prefs
        cur.xinclude = false
        cur.new_locale = ->(lang, lower_first) { new_locale(lang, lower_first) }
        cur.free_locale = ->(_locale) {}
        cur.gen_sort_key = ->(locale, str) { strxfrm(locale, str) }
        cur
      end

      # xsltFreeTransformContext
      def free_transform_context(ctxt)
        return if ctxt.nil?

        shutdown_ctxt_exts(ctxt)
        free_rvts(ctxt)
      end

      # xsltAddChild
      def add_child(parent, cur)
        return nil if cur.nil? || parent.nil?

        Tree.add_child(parent, cur)
      end

      def cdata_section_target?(ctxt, target)
        cs = ctxt.style.cdata_section
        return false if cs.nil? || ctxt.type != OUTPUT_XML || target.nil? || target.type != ELEMENT_NODE

        cs.key?([target.name, target.ns&.href])
      end

      # xsltCopyTextString
      def copy_text_string(ctxt, target, string, noescape)
        return nil if string.nil?

        if cdata_section_target?(ctxt, target)
          if target.last && target.last.type == CDATA_SECTION_NODE
            Tree.text_add_content(target.last, string)
            return target.last
          end
          copy = Tree.new_cdata_block(ctxt.output, string)
        elsif noescape
          if target && target.last && target.last.type == TEXT_NODE && target.last.name == STRING_TEXT_NOENC
            Tree.text_add_content(target.last, string) unless string.empty?
            return target.last
          end
          copy = Tree.new_text(string)
          copy.name = STRING_TEXT_NOENC
        else
          if target && target.last && target.last.type == TEXT_NODE && target.last.name == STRING_TEXT
            Tree.text_add_content(target.last, string) unless string.empty?
            return target.last
          end
          copy = Tree.new_text(string)
        end
        copy = add_child(target, copy) if target
        transform_error(ctxt, nil, target, "xsltCopyTextString: text copy failed\n") if copy.nil?
        copy
      end

      # xsltCopyText
      def copy_text(ctxt, target, cur, _interned)
        return nil if cur.type != TEXT_NODE && cur.type != CDATA_SECTION_NODE
        return nil if cur.content.nil?

        if cdata_section_target?(ctxt, target)
          if target.last && target.last.type == CDATA_SECTION_NODE
            Tree.text_add_content(target.last, cur.content) unless cur.content.empty?
            return target.last
          end
          copy = Tree.new_cdata_block(ctxt.output, cur.content)
        elsif target && target.last &&
            ((target.last.type == TEXT_NODE && target.last.name == cur.name) ||
             (target.last.type == CDATA_SECTION_NODE && cur.name == STRING_TEXT_NOENC))
          Tree.text_add_content(target.last, cur.content) unless cur.content.empty?
          return target.last
        else
          copy = Tree.new_text(cur.content)
          copy.name = STRING_TEXT_NOENC if cur.name == STRING_TEXT_NOENC
        end
        if copy
          if target
            copy.doc = target.doc
            copy = add_child(target, copy)
          end
        else
          transform_error(ctxt, nil, target, "xsltCopyText: text copy failed\n")
        end
        if copy.nil? || copy.content.nil?
          transform_error(ctxt, nil, target, "Internal error in xsltCopyText(): Failed to copy the string.\n")
          ctxt.state = STATE_STOPPED
        end
        copy
      end

      # xsltShallowCopyAttr
      def shallow_copy_attr(ctxt, invoc_node, target, attr)
        return nil if attr.nil?

        if target.type != ELEMENT_NODE
          transform_error(ctxt, nil, invoc_node, "Cannot add an attribute node to a non-element node.\n")
          return nil
        end
        if target.children
          transform_error(ctxt, nil, invoc_node, "Attribute nodes must be added before any child nodes to an element.\n")
          return nil
        end
        value = Tree.node_list_get_string(attr.doc, attr.children, true)
        if attr.ns
          ns = get_special_namespace(ctxt, invoc_node, attr.ns.href, attr.ns.prefix, target)
          if ns.nil?
            transform_error(ctxt, nil, invoc_node,
              "Namespace fixup error: Failed to acquire an in-scope namespace binding of the copied attribute '{#{attr.ns.href}}#{attr.name}'.\n")
          end
          Tree.set_ns_prop(target, ns, attr.name, value)
        else
          Tree.set_ns_prop(target, nil, attr.name, value)
        end
      end

      # xsltCopyAttrListNoOverwrite
      def copy_attr_list_no_overwrite(ctxt, invoc_node, target, attr)
        orig_ns = nil
        orig_set = false
        copy_ns = nil
        while attr
          if !orig_set || !attr.ns.equal?(orig_ns)
            orig_set = true
            orig_ns = attr.ns
            if attr.ns
              copy_ns = get_special_namespace(ctxt, invoc_node, attr.ns.href, attr.ns.prefix, target)
              return -1 if copy_ns.nil?
            else
              copy_ns = nil
            end
          end
          copy = if attr.children && attr.children.type == TEXT_NODE && attr.children.next.nil?
            Tree.new_ns_prop(target, copy_ns, attr.name, attr.children.content)
          elsif attr.children
            Tree.new_ns_prop(target, copy_ns, attr.name, Tree.node_list_get_string(attr.doc, attr.children, true))
          else
            Tree.new_ns_prop(target, copy_ns, attr.name, nil)
          end
          return -1 if copy.nil?

          attr = attr.next
        end
        0
      end

      # xmlDocCopyNode(node, doc, 0) for the node types libxslt shallow-copies
      def shallow_copy_node(node, doc)
        Tree.doc_copy_node(node, doc, 0)
      end

      # xsltShallowCopyElem
      def shallow_copy_elem(ctxt, node, insert, is_lre)
        return nil if node.type == DTD_NODE || insert.nil?
        return copy_text(ctxt, insert, node, false) if node.type == TEXT_NODE || node.type == CDATA_SECTION_NODE

        copy = shallow_copy_node(node, insert.doc)
        if copy
          copy.doc = ctxt.output
          copy = add_child(insert, copy)
          if copy.nil?
            transform_error(ctxt, nil, node, "xsltShallowCopyElem: copy failed\n")
            return copy
          end
          if node.type == ELEMENT_NODE
            if node.ns_def
              if is_lre
                copy_namespace_list(ctxt, copy, node.ns_def)
              else
                copy_namespace_list_internal(copy, node.ns_def)
              end
            end
            if node.ns
              copy.ns = if is_lre
                get_namespace(ctxt, node, node.ns, copy)
              else
                get_special_namespace(ctxt, node, node.ns.href, node.ns.prefix, copy)
              end
            elsif insert.type == ELEMENT_NODE && insert.ns
              get_special_namespace(ctxt, node, nil, nil, copy)
            end
          end
        else
          transform_error(ctxt, nil, node, "xsltShallowCopyElem: copy #{node.name} failed\n")
        end
        copy
      end

      # xsltCopyTreeList
      def copy_tree_list(ctxt, invoc_node, list, insert, is_lre, top_elem_visited)
        ret = nil
        while list
          copy = copy_tree(ctxt, invoc_node, list, insert, is_lre, top_elem_visited)
          ret ||= copy
          list = list.next
        end
        ret
      end

      # xsltCopyNamespaceListInternal
      def copy_namespace_list_internal(elem, ns)
        return nil if ns.nil?

        elem = nil if elem && elem.type != ELEMENT_NODE
        ret = nil
        p = nil
        while ns
          break unless ns.is_a?(XmlNs)

          if elem
            if elem.ns && elem.ns.prefix == ns.prefix && elem.ns.href == ns.href
              ns = ns.next
              next
            end
            lu_ns = Tree.search_ns(elem.doc, elem, ns.prefix)
            if lu_ns && lu_ns.href == ns.href
              ns = ns.next
              next
            end
          end
          q = Tree.new_ns(elem, ns.href, ns.prefix)
          if p.nil?
            ret = p = q
          elsif q
            p.next = q
            p = q
          end
          ns = ns.next
        end
        ret
      end

      # xsltShallowCopyNsNode
      def shallow_copy_ns_node(ctxt, invoc_node, insert, ns)
        return nil if insert.nil? || insert.type != ELEMENT_NODE

        if insert.children
          transform_error(ctxt, nil, invoc_node,
            "Namespace nodes must be added before any child nodes are added to an element.\n")
          return nil
        end
        if ns.prefix.nil?
          return nil if insert.ns.nil?
        elsif ns.prefix == "xml"
          return nil
        end
        tmpns = insert.ns_def
        while tmpns
          if tmpns.prefix.nil? == ns.prefix.nil? && tmpns.prefix == ns.prefix
            return nil
          end

          tmpns = tmpns.next
        end
        tmpns = Tree.search_ns(insert.doc, insert, ns.prefix)
        return nil if tmpns && tmpns.href == ns.href

        Tree.new_ns(insert, ns.href, ns.prefix)
      end

      # xsltCopyTree
      def copy_tree(ctxt, invoc_node, node, insert, is_lre, top_elem_visited)
        return nil if node.nil?

        if node.is_a?(XmlNs)
          return shallow_copy_ns_node(ctxt, invoc_node, insert, node)
        end

        case node.type
        when ELEMENT_NODE, ENTITY_REF_NODE, ENTITY_NODE, PI_NODE, COMMENT_NODE, DOCUMENT_NODE, HTML_DOCUMENT_NODE
          # continue
        when TEXT_NODE
          return copy_text_string(ctxt, insert, node.content, node.name == STRING_TEXT_NOENC)
        when CDATA_SECTION_NODE
          return copy_text_string(ctxt, insert, node.content, false)
        when ATTRIBUTE_NODE
          return shallow_copy_attr(ctxt, invoc_node, insert, node)
        else
          return nil
        end
        if res_tree_frag?(node)
          return node.children ? copy_tree_list(ctxt, invoc_node, node.children, insert, false, false) : nil
        end
        copy = shallow_copy_node(node, insert.doc)
        if copy
          copy.doc = ctxt.output
          copy = add_child(insert, copy)
          if copy.nil?
            transform_error(ctxt, nil, invoc_node, "xsltCopyTree: Copying of '#{node.name}' failed.\n")
            return copy
          end
          return insert.last unless insert.last.equal?(copy)

          copy.next = nil
          if node.type == ELEMENT_NODE
            if !top_elem_visited && node.parent && node.parent.type != DOCUMENT_NODE &&
                node.parent.type != HTML_DOCUMENT_NODE
              ns_list = Tree.get_ns_list(node.doc, node)
              ns_list&.each do |curns|
                ns = Tree.search_ns(insert.doc, insert, curns.prefix)
                ns = nil if ns && ns.href != curns.href
                ns ||= Tree.new_ns(copy, curns.href, curns.prefix)
                copy.ns = ns if node.ns.equal?(curns)
              end
            elsif node.ns_def
              if is_lre
                copy_namespace_list(ctxt, copy, node.ns_def)
              else
                copy_namespace_list_internal(copy, node.ns_def)
              end
            end
            if node.ns
              if copy.ns.nil?
                copy.ns = get_special_namespace(ctxt, invoc_node, node.ns.href, node.ns.prefix, copy)
              end
            elsif insert.type == ELEMENT_NODE && insert.ns
              get_special_namespace(ctxt, invoc_node, nil, nil, copy)
            end
            copy_attr_list_no_overwrite(ctxt, invoc_node, copy, node.properties) if node.properties
            top_elem_visited = true
          end
          copy_tree_list(ctxt, invoc_node, node.children, copy, is_lre, top_elem_visited) if node.children
        else
          transform_error(ctxt, nil, invoc_node, "xsltCopyTree: Copying of '#{node.name}' failed.\n")
        end
        copy
      end

      # xsltApplyFallbacks
      def apply_fallbacks(ctxt, node, inst)
        return 0 if ctxt.nil? || node.nil? || inst.nil? || inst.children.nil?

        ret = 0
        child = inst.children
        while child
          if xslt_elem?(child) && child.name == "fallback"
            ret += 1
            apply_sequence_constructor(ctxt, node, child.children, nil)
          end
          child = child.next
        end
        ret
      end

      # xsltDefaultProcessOneNode
      def default_process_one_node(ctxt, node, params)
        return if ctxt.state == STATE_STOPPED

        case node.type
        when DOCUMENT_NODE, HTML_DOCUMENT_NODE, ELEMENT_NODE
          # continue
        when CDATA_SECTION_NODE
          copy = copy_text(ctxt, ctxt.insert, node, false)
          transform_error(ctxt, nil, node, "xsltDefaultProcessOneNode: cdata copy failed\n") if copy.nil?
          return
        when TEXT_NODE
          copy = copy_text(ctxt, ctxt.insert, node, false)
          transform_error(ctxt, nil, node, "xsltDefaultProcessOneNode: text copy failed\n") if copy.nil?
          return
        when ATTRIBUTE_NODE
          cur = node.children
          cur = cur.next while cur && cur.type != TEXT_NODE
          if cur.nil?
            transform_error(ctxt, nil, node, "xsltDefaultProcessOneNode: no text for attribute\n")
          else
            copy = copy_text(ctxt, ctxt.insert, cur, false)
            transform_error(ctxt, nil, node, "xsltDefaultProcessOneNode: text copy failed\n") if copy.nil?
          end
          return
        else
          return
        end

        nbchild = 0
        cur = node.children
        while cur
          nbchild += 1 if real_node?(cur)
          cur = cur.next
        end

        xp = ctxt.xpath_ctxt
        old_size = xp.context_size
        old_pos = xp.proximity_position
        childno = 0
        cur = node.children
        while cur
          childno += 1
          case cur.type
          when DOCUMENT_NODE, HTML_DOCUMENT_NODE, ELEMENT_NODE
            xp.context_size = nbchild
            xp.proximity_position = childno
            if ctxt.depth >= ctxt.max_template_depth
              transform_error(ctxt, nil, cur,
                "xsltDefaultProcessOneNode: Maximum template depth exceeded.\n" \
                "You can adjust xsltMaxDepth (--maxdepth) in order to raise the maximum number of nested " \
                "template calls and variables/params (currently set to #{ctxt.max_template_depth}).\n")
              ctxt.state = STATE_STOPPED
              return
            end
            ctxt.depth += 1
            process_one_node(ctxt, cur, params)
            ctxt.depth -= 1
          when CDATA_SECTION_NODE
            template = get_template(ctxt, cur, nil)
            if template
              apply_xslt_template(ctxt, cur, template.content, template, params)
            else
              copy = copy_text(ctxt, ctxt.insert, cur, false)
              transform_error(ctxt, nil, cur, "xsltDefaultProcessOneNode: cdata copy failed\n") if copy.nil?
            end
          when TEXT_NODE
            template = get_template(ctxt, cur, nil)
            if template
              xp.context_size = nbchild
              xp.proximity_position = childno
              apply_xslt_template(ctxt, cur, template.content, template, params)
            else
              copy = copy_text(ctxt, ctxt.insert, cur, false)
              transform_error(ctxt, nil, cur, "xsltDefaultProcessOneNode: text copy failed\n") if copy.nil?
            end
          when PI_NODE, COMMENT_NODE
            template = get_template(ctxt, cur, nil)
            if template
              xp.context_size = nbchild
              xp.proximity_position = childno
              apply_xslt_template(ctxt, cur, template.content, template, params)
            end
          end
          cur = cur.next
        end
        xp.context_size = old_size
        xp.proximity_position = old_pos
      end

      # xsltProcessOneNode
      def process_one_node(ctxt, context_node, with_params)
        templ = get_template(ctxt, context_node, nil)
        if templ.nil?
          old_node = ctxt.node
          ctxt.node = context_node
          default_process_one_node(ctxt, context_node, with_params)
          ctxt.node = old_node
          return
        end
        old_rule = ctxt.current_template_rule
        ctxt.current_template_rule = templ
        apply_xslt_template(ctxt, context_node, templ.content, templ, with_params)
        ctxt.current_template_rule = old_rule
      end

      # xsltLocalVariablePush
      def local_variable_push(ctxt, variable, level)
        ctxt.vars_tab << variable
        ctxt.vars = variable
        variable.level = level
        0
      end

      # xsltReleaseLocalRVTs
      def release_local_rvts(ctxt, base)
        cur = ctxt.local_rvt
        return if cur.equal?(base)

        transform_error(ctxt, nil, nil, "localRVT not head of list\n") if cur.prev
        ctxt.local_rvt = base
        base.prev = nil if base
        loop do
          tmp = cur
          cur = cur.next
          if tmp.compression == RVT_LOCAL
            release_rvt(ctxt, tmp)
          elsif tmp.compression == RVT_GLOBAL
            register_persist_rvt(ctxt, tmp)
          elsif tmp.compression == RVT_FUNC_RESULT
            register_local_rvt(ctxt, tmp)
            tmp.compression = RVT_FUNC_RESULT
          else
            xml_generic_error("xsltReleaseLocalRVTs: Unexpected RVT flag #{tmp.psvi}\n")
          end
          break if cur.equal?(base)
        end
      end

      # xsltApplySequenceConstructor
      def apply_sequence_constructor(ctxt, context_node, list, templ)
        return if ctxt.nil? || list.nil?
        return if ctxt.state == STATE_STOPPED

        if ctxt.depth >= ctxt.max_template_depth
          transform_error(ctxt, nil, list,
            "xsltApplySequenceConstructor: A potential infinite template recursion was detected.\n" \
            "You can adjust xsltMaxDepth (--maxdepth) in order to raise the maximum number of nested " \
            "template calls and variables/params (currently set to #{ctxt.max_template_depth}).\n")
          debug(ctxt, context_node, list, nil)
          ctxt.state = STATE_STOPPED
          return
        end
        ctxt.depth += 1

        old_local_fragment_top = ctxt.local_rvt
        old_insert = insert = ctxt.insert
        old_inst = old_cur_inst = ctxt.inst
        old_context_node = ctxt.node
        old_vars_nr = ctxt.vars_tab.length
        level = 0
        cur = list
        list_parent = list.parent
        while cur
          if ctxt.op_limit != 0
            if ctxt.op_count >= ctxt.op_limit
              transform_error(ctxt, nil, cur, "xsltApplySequenceConstructor: Operation limit exceeded\n")
              ctxt.state = STATE_STOPPED
              break
            end
            ctxt.op_count += 1
          end
          ctxt.inst = cur
          break if insert.nil?

          copy = nil
          skip_children = false
          if xslt_elem?(cur)
            info = cur.psvi
            if info.nil?
              if cur.name == "message"
                message(ctxt, context_node, cur)
              else
                ctxt.insert = insert
                if apply_fallbacks(ctxt, context_node, cur) == 0
                  generic_error("xsltApplySequenceConstructor: #{cur.name} was not compiled\n")
                end
                ctxt.insert = old_insert
              end
              skip_children = true
            elsif info.func
              old_cur_inst = ctxt.inst
              ctxt.inst = cur
              ctxt.insert = insert
              info.func.call(ctxt, context_node, cur, info)
              release_local_rvts(ctxt, old_local_fragment_top) unless old_local_fragment_top.equal?(ctxt.local_rvt)
              ctxt.insert = old_insert
              ctxt.inst = old_cur_inst
              skip_children = true
            else
              if cur.name == "variable"
                tmpvar = ctxt.vars
                old_cur_inst = ctxt.inst
                ctxt.inst = cur
                parse_stylesheet_variable(ctxt, cur)
                ctxt.inst = old_cur_inst
                ctxt.vars.level = level unless tmpvar.equal?(ctxt.vars)
              elsif cur.name == "message"
                message(ctxt, context_node, cur)
              else
                transform_error(ctxt, nil, cur, "Unexpected XSLT element '#{cur.name}'.\n")
              end
              skip_children = true
            end
          elsif cur.type == TEXT_NODE || cur.type == CDATA_SECTION_NODE
            break if copy_text(ctxt, insert, cur, ctxt.internalized).nil?
          elsif cur.type == ELEMENT_NODE && cur.ns && !cur.psvi.nil?
            old_cur_inst = ctxt.inst
            ctxt.inst = cur
            function = if cur.psvi.equal?(EXT_MARKER)
              ext_element_lookup(ctxt, cur.name, cur.ns.href)
            else
              cur.psvi.func
            end
            if function.nil?
              found = false
              ctxt.insert = insert
              child = cur.children
              while child
                if xslt_elem?(child) && child.name == "fallback"
                  found = true
                  apply_sequence_constructor(ctxt, context_node, child.children, nil)
                end
                child = child.next
              end
              ctxt.insert = old_insert
              unless found
                transform_error(ctxt, nil, cur, "xsltApplySequenceConstructor: failed to find extension #{cur.name}\n")
              end
            else
              ctxt.lasttext = nil if cur.psvi.equal?(EXT_MARKER)
              ctxt.insert = insert
              function.call(ctxt, context_node, cur, cur.psvi)
              release_local_rvts(ctxt, old_local_fragment_top) unless old_local_fragment_top.equal?(ctxt.local_rvt)
              ctxt.insert = old_insert
            end
            ctxt.inst = old_cur_inst
            skip_children = true
          elsif cur.type == ELEMENT_NODE
            old_cur_inst = ctxt.inst
            ctxt.inst = cur
            copy = shallow_copy_elem(ctxt, cur, insert, true)
            break if copy.nil?

            if templ && old_insert.equal?(insert) && ctxt.templ && ctxt.templ.inherited_ns
              ctxt.templ.inherited_ns.each do |ns|
                uri = ns_alias_lookup(ctxt.style, ns.href)
                next if uri.equal?(UNDEFINED_DEFAULT_NS)

                uri = ns.href if uri.nil?
                ret = Tree.search_ns(copy.doc, copy, ns.prefix)
                Tree.new_ns(copy, uri, ns.prefix) if ret.nil? || ret.href != uri
              end
              copy.ns = get_namespace(ctxt, cur, copy.ns, copy) if copy.ns
            end
            attr_list_template_process(ctxt, copy, cur.properties) if cur.properties
            ctxt.inst = old_cur_inst
          end

          if !skip_children && cur.children && cur.children.type != ENTITY_DECL
            cur = cur.children
            level += 1
            insert = copy if copy
            next
          end

          # skip_children:
          break if ctxt.state == STATE_STOPPED

          if cur.next
            cur = cur.next
            next
          end
          loop do
            cur = cur.parent
            level -= 1
            if ctxt.vars_tab.length > old_vars_nr && ctxt.vars.level > level
              local_variable_pop(ctxt, old_vars_nr, level)
            end
            insert = insert&.parent
            break if cur.nil?
            if cur.equal?(list_parent)
              cur = nil
              break
            end
            if cur.next
              cur = cur.next
              break
            end
          end
        end
        # error:
        local_variable_pop(ctxt, old_vars_nr, -1) if ctxt.vars_tab.length > old_vars_nr
        ctxt.node = old_context_node
        ctxt.inst = old_inst
        ctxt.insert = old_insert
        ctxt.depth -= 1
      end

      # xsltApplyXSLTTemplate
      def apply_xslt_template(ctxt, context_node, list, templ, with_params)
        return if ctxt.nil?

        if templ.nil?
          transform_error(ctxt, nil, list, "xsltApplyXSLTTemplate: Bad arguments; @templ is mandatory.\n")
          return
        end
        return if list.nil?
        return if ctxt.state == STATE_STOPPED

        if ctxt.vars_tab.length >= ctxt.max_template_vars
          transform_error(ctxt, nil, list,
            "xsltApplyXSLTTemplate: A potential infinite template recursion was detected.\n" \
            "You can adjust maxTemplateVars (--maxvars) in order to raise the maximum number of " \
            "variables/params (currently set to #{ctxt.max_template_vars}).\n")
          debug(ctxt, context_node, list, nil)
          ctxt.state = STATE_STOPPED
          return
        end

        old_user_fragment_top = ctxt.tmp_rvt
        ctxt.tmp_rvt = nil
        old_vars_base = ctxt.vars_base
        ctxt.vars_base = ctxt.vars_tab.length
        ctxt.node = context_node
        templ_push(ctxt, templ)

        cur = list
        loop do
          if cur.type == TEXT_NODE
            cur = cur.next
            break if cur.nil?

            next
          end
          break if cur.type != ELEMENT_NODE || cur.name != "param" || cur.psvi.nil? || !xslt_elem?(cur)

          list = cur.next
          iparam = cur.psvi
          tmp_param = nil
          if with_params
            tmp_param = with_params
            while tmp_param
              if tmp_param.name == iparam.name && tmp_param.name_uri == iparam.ns
                local_variable_push(ctxt, tmp_param, -1)
                break
              end
              tmp_param = tmp_param.next
            end
          end
          parse_stylesheet_param(ctxt, cur) if tmp_param.nil?
          cur = cur.next
          break if cur.nil?
        end

        apply_sequence_constructor(ctxt, context_node, list, templ)

        template_params_cleanup(ctxt) if ctxt.vars_tab.length > ctxt.vars_base
        ctxt.vars_base = old_vars_base

        if ctxt.tmp_rvt
          curdoc = ctxt.tmp_rvt
          while curdoc
            tmp = curdoc
            curdoc = curdoc.next
            release_rvt(ctxt, tmp)
          end
        end
        ctxt.tmp_rvt = old_user_fragment_top
        templ_pop(ctxt)
      end

      # xsltApplyOneTemplate
      def apply_one_template(ctxt, context_node, list, templ, params)
        return if ctxt.nil? || list.nil?
        return if ctxt.state == STATE_STOPPED

        if params
          old_vars_nr = ctxt.vars_tab.length
          while params
            local_variable_push(ctxt, params, -1)
            params = params.next
          end
          apply_sequence_constructor(ctxt, context_node, list, templ)
          local_variable_pop(ctxt, old_vars_nr, -2)
        else
          apply_sequence_constructor(ctxt, context_node, list, templ)
        end
      end

      # xsltDocumentElem
      def document_elem(ctxt, node, inst, comp)
        return if ctxt.nil? || node.nil? || inst.nil? || comp.nil?

        url = nil
        if comp.filename.nil?
          if inst.name == "output"
            url = eval_attr_value_template(ctxt, inst, "file", SAXON_NAMESPACE)
            url ||= eval_attr_value_template(ctxt, inst, "href", SAXON_NAMESPACE)
          elsif inst.name == "write"
            url = eval_attr_value_template(ctxt, inst, "select", XALAN_NAMESPACE)
            if url
              cmp = XPath.ctxt_compile(ctxt.xpath_ctxt, url)
              url = eval_xpath_string(ctxt, cmp)
            end
            url ||= eval_attr_value_template(ctxt, inst, "file", XALAN_NAMESPACE)
            url ||= eval_attr_value_template(ctxt, inst, "href", XALAN_NAMESPACE)
          elsif inst.name == "document"
            url = eval_attr_value_template(ctxt, inst, "href", nil)
          end
        else
          url = comp.filename.dup
        end
        if url.nil?
          transform_error(ctxt, nil, inst, "xsltDocumentElem: href/URI-Reference not found\n")
          return
        end
        filename = URI_.build_uri(url, ctxt.output_file)
        if filename.nil?
          esc = uri_escape_str(url, ":/.?,")
          filename = URI_.build_uri(esc, ctxt.output_file) if esc
        end
        if filename.nil?
          transform_error(ctxt, nil, inst, "xsltDocumentElem: URL computation failed for #{url}\n")
          return
        end
        if ctxt.sec
          ret = check_write(ctxt.sec, ctxt, filename)
          if ret <= 0
            transform_error(ctxt, nil, inst, "xsltDocumentElem: write rights for #{filename} denied\n") if ret == 0
            return
          end
        end

        old_output_file = ctxt.output_file
        old_output = ctxt.output
        old_insert = ctxt.insert
        old_type = ctxt.type
        ctxt.output_file = filename
        style = Stylesheet.new(nil)
        res = nil
        begin
          prop = eval_attr_value_template(ctxt, inst, "version", nil)
          style.version = prop if prop
          prop = eval_attr_value_template(ctxt, inst, "encoding", nil)
          style.encoding = prop if prop
          prop = eval_attr_value_template(ctxt, inst, "method", nil)
          if prop
            style.method = nil
            style.method_uri = nil
            uri, prop = get_qname_uri(inst, prop)
            if prop.nil?
              style.errors += 1
            elsif uri.nil?
              if %w[xml html text].include?(prop)
                style.method = prop
              else
                transform_error(ctxt, nil, inst, "invalid value for method: #{prop}\n")
                style.warnings += 1
              end
            else
              style.method = prop
              style.method_uri = uri
            end
          end
          prop = eval_attr_value_template(ctxt, inst, "doctype-system", nil)
          style.doctype_system = prop if prop
          prop = eval_attr_value_template(ctxt, inst, "doctype-public", nil)
          style.doctype_public = prop if prop
          prop = eval_attr_value_template(ctxt, inst, "standalone", nil)
          if prop
            if prop == "yes"
              style.standalone = 1
            elsif prop == "no"
              style.standalone = 0
            else
              transform_error(ctxt, nil, inst, "invalid value for standalone: #{prop}\n")
              style.warnings += 1
            end
          end
          prop = eval_attr_value_template(ctxt, inst, "indent", nil)
          if prop
            if prop == "yes"
              style.indent = 1
            elsif prop == "no"
              style.indent = 0
            else
              transform_error(ctxt, nil, inst, "invalid value for indent: #{prop}\n")
              style.warnings += 1
            end
          end
          prop = eval_attr_value_template(ctxt, inst, "omit-xml-declaration", nil)
          if prop
            if prop == "yes"
              style.omit_xml_declaration = 1
            elsif prop == "no"
              style.omit_xml_declaration = 0
            else
              transform_error(ctxt, nil, inst, "invalid value for omit-xml-declaration: #{prop}\n")
              style.warnings += 1
            end
          end
          elements = eval_attr_value_template(ctxt, inst, "cdata-section-elements", nil)
          if elements
            style.strip_spaces ||= {}
            each_token(elements) do |element|
              uri, element = get_qname_uri(inst, element)
              key = [element, uri]
              style.strip_spaces[key] = "cdata" unless style.strip_spaces.key?(key)
            end
          end

          method = get_import_ptr(style, :method)
          doctype_public = get_import_ptr(style, :doctype_public)
          doctype_system = get_import_ptr(style, :doctype_system)
          encoding = get_import_ptr(style, :encoding)

          if method && method != "xml"
            if method == "html"
              ctxt.type = OUTPUT_HTML
              res = html_new_doc(doctype_system, doctype_public, !(doctype_public || doctype_system))
            elsif method == "xhtml"
              transform_error(ctxt, nil, inst, "xsltDocumentElem: unsupported method xhtml\n")
              ctxt.type = OUTPUT_HTML
              res = html_new_doc(doctype_system, doctype_public, true)
            elsif method == "text"
              ctxt.type = OUTPUT_TEXT
              res = Tree.new_doc(style.version)
            else
              transform_error(ctxt, nil, inst, "xsltDocumentElem: unsupported method (#{method})\n")
              break
            end
          else
            ctxt.type = OUTPUT_XML
            res = Tree.new_doc(style.version)
          end
          res.charset = 1
          res.encoding = encoding.dup if encoding
          ctxt.output = res
          ctxt.insert = res
          apply_sequence_constructor(ctxt, node, inst.children, nil)

          root = Tree.doc_get_root_element(res)
          if root
            doctype = root.ns&.prefix ? "#{root.ns.prefix}:#{root.name}" : root.name
            if method.nil? && root.ns.nil? && root.name.casecmp?("html")
              tmp = res.children
              while tmp && !tmp.equal?(root)
                break if tmp.type == ELEMENT_NODE
                break if tmp.type == TEXT_NODE && !Tree.is_blank_node(tmp)

                tmp = tmp.next
              end
              if tmp.equal?(root)
                ctxt.type = OUTPUT_HTML
                res.type = HTML_DOCUMENT_NODE
                if doctype_public || doctype_system
                  res.int_subset = Tree.create_int_subset(res, doctype, doctype_public, doctype_system)
                end
              end
            end
            if ctxt.type == OUTPUT_XML
              doctype_public = get_import_ptr(style, :doctype_public)
              doctype_system = get_import_ptr(style, :doctype_system)
              if doctype_public || doctype_system
                res.int_subset = Tree.create_int_subset(res, doctype, doctype_public, doctype_system)
              end
            end
          end

          redirect_write_append = false
          prop = eval_attr_value_template(ctxt, inst, "append", nil)
          if prop
            if prop == "true" || prop == "yes"
              style.omit_xml_declaration = 1
              redirect_write_append = true
            else
              style.omit_xml_declaration = 0
            end
          end
          ret = save_result_to_file_path(filename, res, style, redirect_write_append)
          transform_error(ctxt, nil, inst, "xsltDocumentElem: unable to save to #{filename}\n") if ret < 0
        end while false # rubocop:disable Lint/Loop
      ensure
        if old_output_file || ctxt
          ctxt.output = old_output
          ctxt.insert = old_insert
          ctxt.type = old_type
          ctxt.output_file = old_output_file
        end
      end

      def save_result_to_file_path(filename, res, style, append)
        path = filename.sub(%r{\Afile://(localhost)?}, "")
        bytes = save_result_to_string(res, style)
        File.open(path, append ? "ab" : "wb") { |f| f.write(bytes) }
        bytes.bytesize
      rescue SystemCallError, IOError
        -1
      end

      # xmlURIEscapeStr
      def uri_escape_str(str, list)
        return nil if str.nil?
        return str.dup if str.empty?

        out = +""
        str.each_byte do |b|
          c = b.chr
          if (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39) ||
              "-_.!~*'()".include?(c) || list.include?(c)
            out << c
          else
            out << format("%%%02X", b)
          end
        end
        out
      end

      # htmlNewDoc / htmlNewDocNoDtD
      def html_new_doc(uri, external_id, no_dtd)
        cur = Tree.new_html_doc
        cur.type = HTML_DOCUMENT_NODE
        cur.version = nil
        cur.standalone = 1
        cur.charset = 1
        if !no_dtd || uri || external_id
          if uri.nil? && external_id.nil? && !no_dtd
            uri = "http://www.w3.org/TR/REC-html40/loose.dtd"
            external_id = "-//W3C//DTD HTML 4.0 Transitional//EN"
          end
          Tree.create_int_subset(cur, "html", external_id, uri) if uri || external_id
        end
        cur
      end

      # xsltSort
      def sort(ctxt, _node, inst, comp)
        if comp.nil?
          transform_error(ctxt, nil, inst, "xsl:sort : compilation failed\n")
          return
        end
        transform_error(ctxt, nil, inst, "xsl:sort : improper use this should not be reached\n")
      end

      # xsltCopy
      def copy(ctxt, node, inst, comp)
        old_insert = ctxt.insert
        if ctxt.insert
          if node.is_a?(XmlNs)
            shallow_copy_ns_node(ctxt, inst, ctxt.insert, node)
          else
            case node.type
            when TEXT_NODE, CDATA_SECTION_NODE
              copy_text(ctxt, ctxt.insert, node, false)
            when DOCUMENT_NODE, HTML_DOCUMENT_NODE
              # nothing
            when ELEMENT_NODE
              copy = shallow_copy_elem(ctxt, node, ctxt.insert, false)
              ctxt.insert = copy
              apply_attribute_set(ctxt, node, inst, comp.use) if comp.use
            when ATTRIBUTE_NODE
              shallow_copy_attr(ctxt, inst, ctxt.insert, node)
            when PI_NODE
              copy = Tree.new_doc_pi(ctxt.insert.doc, node.name, node.content)
              add_child(ctxt.insert, copy)
            when COMMENT_NODE
              copy = Tree.new_doc_comment(nil, node.content)
              add_child(ctxt.insert, copy)
            end
          end
        end
        if !node.is_a?(XmlNs) &&
            [DOCUMENT_NODE, HTML_DOCUMENT_NODE, ELEMENT_NODE].include?(node.type)
          apply_sequence_constructor(ctxt, ctxt.node, inst.children, nil)
        end
        ctxt.insert = old_insert
      end

      # xsltText
      def text(ctxt, _node, inst, comp)
        return unless inst.children && comp

        text = inst.children
        while text
          if text.type != TEXT_NODE && text.type != CDATA_SECTION_NODE
            transform_error(ctxt, nil, inst, "xsl:text content problem\n")
            break
          end
          copy = Tree.new_doc_text(ctxt.output, text.content)
          copy.name = STRING_TEXT_NOENC if text.type != CDATA_SECTION_NODE
          add_child(ctxt.insert, copy)
          text = text.next
        end
      end

      # xsltElement
      def element(ctxt, node, inst, comp)
        return if ctxt.insert.nil?
        return unless comp.has_name

        old_insert = ctxt.insert
        if comp.name.nil?
          prop = eval_attr_value_template(ctxt, inst, "name", NAMESPACE)
          if prop.nil?
            transform_error(ctxt, nil, inst, "xsl:element: The attribute 'name' is missing.\n")
            ctxt.insert = old_insert
            return
          end
          unless valid_qname?(prop)
            transform_error(ctxt, nil, inst, "xsl:element: The effective name '#{prop}' is not a valid QName.\n")
          end
          name, prefix = split_qname(prop)
        else
          name, prefix = split_qname(comp.name)
        end

        copy = Tree.new_doc_node(ctxt.output, nil, name, nil)
        if copy.nil?
          transform_error(ctxt, nil, inst, "xsl:element : creation of #{name} failed\n")
          return
        end
        copy = add_child(ctxt.insert, copy)
        if copy.nil?
          transform_error(ctxt, nil, inst, "xsl:element : xsltAddChild failed\n")
          return
        end

        ns_name = nil
        if comp.has_ns
          if comp.ns
            ns_name = comp.ns unless comp.ns.empty?
          else
            tmp = eval_attr_value_template(ctxt, inst, "namespace", NAMESPACE)
            ns_name = tmp if tmp && !tmp.empty?
          end
          if ns_name == "http://www.w3.org/2000/xmlns/"
            transform_error(ctxt, nil, inst, "xsl:attribute: Namespace http://www.w3.org/2000/xmlns/ forbidden.\n")
            ctxt.insert = old_insert
            return
          end
          if ns_name == XML_XML_NAMESPACE
            prefix = "xml"
          elsif prefix == "xml"
            prefix = nil
          end
        else
          ns = Tree.search_ns(inst.doc, inst, prefix)
          if ns.nil?
            if prefix
              transform_error(ctxt, nil, inst,
                "xsl:element: The QName '#{prefix}:#{name}' has no namespace binding in scope in the stylesheet; " \
                "this is an error, since the namespace was not specified by the instruction itself.\n")
            end
          else
            ns_name = ns.href
          end
        end

        if ns_name
          copy.ns = if prefix == "xmlns"
            get_special_namespace(ctxt, inst, ns_name, "ns_1", copy)
          else
            get_special_namespace(ctxt, inst, ns_name, prefix, copy)
          end
        elsif copy.parent && copy.parent.type == ELEMENT_NODE && copy.parent.ns
          get_special_namespace(ctxt, inst, nil, nil, copy)
        end

        ctxt.insert = copy
        if comp.has_use
          if comp.use
            apply_attribute_set(ctxt, node, inst, comp.use)
          else
            attr_sets = eval_attr_value_template(ctxt, inst, "use-attribute-sets", nil)
            apply_attribute_set(ctxt, node, inst, attr_sets) if attr_sets
          end
        end
        apply_sequence_constructor(ctxt, ctxt.node, inst.children, nil) if inst.children
        ctxt.insert = old_insert
      end

      # xsltComment
      def comment(ctxt, node, inst, _comp)
        value = eval_template_string(ctxt, node, inst)
        if value && !value.empty? && (value.end_with?("-") || value.include?("--"))
          transform_error(ctxt, nil, inst, "xsl:comment : '--' or ending '-' not allowed in comment\n")
        end
        comment_node = Tree.new_doc_comment(nil, value)
        add_child(ctxt.insert, comment_node)
      end

      # xsltProcessingInstruction
      def processing_instruction(ctxt, node, inst, comp)
        return if ctxt.insert.nil?
        return unless comp.has_name

        if comp.name.nil?
          name = eval_attr_value_template(ctxt, inst, "name", nil)
          if name.nil?
            transform_error(ctxt, nil, inst, "xsl:processing-instruction : name is missing\n")
            return
          end
        else
          name = comp.name
        end
        value = eval_template_string(ctxt, node, inst)
        if value&.include?("?>")
          transform_error(ctxt, nil, inst, "xsl:processing-instruction: '?>' not allowed within PI content\n")
          return
        end
        pi = Tree.new_doc_pi(ctxt.insert.doc, name, value)
        add_child(ctxt.insert, pi)
      end

      # xsltCopyOf
      def copy_of(ctxt, node, inst, comp)
        return if ctxt.nil? || node.nil? || inst.nil?

        if comp.nil? || comp.select.nil? || comp.comp.nil?
          transform_error(ctxt, nil, inst, "xsl:copy-of : compilation failed\n")
          return
        end
        res = pre_comp_eval(ctxt, node, comp)
        if !res.nil?
          if res.is_a?(XPath::ValueTree)
            first = res[0]
            if first && real_node?(first)
              copy_tree_list(ctxt, inst, first.children, ctxt.insert, false, false)
            end
          elsif res.is_a?(Array)
            res.each do |cur|
              next if cur.nil?

              if cur.is_a?(XmlNs)
                copy_tree(ctxt, inst, cur, ctxt.insert, false, false)
              elsif cur.type == DOCUMENT_NODE || cur.type == HTML_DOCUMENT_NODE
                copy_tree_list(ctxt, inst, cur.children, ctxt.insert, false, false)
              elsif cur.type == ATTRIBUTE_NODE
                shallow_copy_attr(ctxt, inst, ctxt.insert, cur)
              else
                copy_tree(ctxt, inst, cur, ctxt.insert, false, false)
              end
            end
          else
            value = XPath.cast_to_string(res)
            copy_text_string(ctxt, ctxt.insert, value, false) unless value.empty?
          end
        else
          ctxt.state = STATE_STOPPED
        end
      end

      # xsltValueOf
      def value_of(ctxt, node, inst, comp)
        return if ctxt.nil? || node.nil? || inst.nil?

        if comp.nil? || comp.select.nil? || comp.comp.nil?
          transform_error(ctxt, nil, inst,
            "Internal error in xsltValueOf(): The XSLT 'value-of' instruction was not compiled.\n")
          return
        end
        res = pre_comp_eval(ctxt, node, comp)
        if !res.nil?
          value = XPath.cast_to_string(res)
          copy_text_string(ctxt, ctxt.insert, value, comp.noescape) unless value.empty?
        else
          transform_error(ctxt, nil, inst, "XPath evaluation returned no result.\n")
          ctxt.state = STATE_STOPPED
        end
      end

      # xsltNumber
      def number(ctxt, node, inst, comp)
        if comp.nil?
          transform_error(ctxt, nil, inst, "xsl:number : compilation failed\n")
          return
        end
        return if ctxt.nil? || node.nil? || inst.nil?

        comp.numdata.doc = inst.doc
        comp.numdata.node = inst
        xp = ctxt.xpath_ctxt
        old_ns = xp.namespaces
        xp.namespaces = comp.ns_list
        number_format(ctxt, comp.numdata, node)
        xp.namespaces = old_ns
      end

      # xsltApplyImports
      def apply_imports(ctxt, context_node, inst, comp)
        return if ctxt.nil? || inst.nil?

        if comp.nil?
          transform_error(ctxt, nil, inst,
            "Internal error in xsltApplyImports(): The XSLT 'apply-imports' instruction was not compiled.\n")
          return
        end
        if ctxt.current_template_rule.nil?
          transform_error(ctxt, nil, inst, "It is an error to call 'apply-imports' when there's no current template rule.\n")
          return
        end
        templ = get_template(ctxt, context_node, ctxt.current_template_rule.style)
        if templ
          old_rule = ctxt.current_template_rule
          ctxt.current_template_rule = templ
          apply_xslt_template(ctxt, context_node, templ.content, templ, nil)
          ctxt.current_template_rule = old_rule
        else
          default_process_one_node(ctxt, context_node, nil)
        end
      end

      # xsltCallTemplate
      def call_template(ctxt, node, inst, comp)
        return if ctxt.insert.nil?

        if comp.nil?
          transform_error(ctxt, nil, inst, "The XSLT 'call-template' instruction was not compiled.\n")
          return
        end
        if comp.templ.nil?
          comp.templ = find_template(ctxt, comp.name, comp.ns)
          if comp.templ.nil?
            if comp.ns
              transform_error(ctxt, nil, inst, "The called template '{#{comp.ns}}#{comp.name}' was not found.\n")
            else
              transform_error(ctxt, nil, inst, "The called template '#{comp.name}' was not found.\n")
            end
            return
          end
        end
        with_params = nil
        cur = inst.children
        while cur
          break if ctxt.state == STATE_STOPPED

          if xslt_elem?(cur)
            if cur.name == "with-param"
              param = parse_stylesheet_caller_param(ctxt, cur)
              if param
                param.next = with_params
                with_params = param
              end
            else
              generic_error("xsl:call-template: misplaced xsl:#{cur.name}\n")
            end
          else
            generic_error("xsl:call-template: misplaced #{cur.name} element\n")
          end
          cur = cur.next
        end
        apply_xslt_template(ctxt, node, comp.templ.content, comp.templ, with_params)
        free_stack_elem_list(with_params) if with_params
      end

      def node_set_value?(res)
        res.is_a?(Array) && !res.is_a?(XPath::ValueTree)
      end

      # xsltApplyTemplates
      def apply_templates(ctxt, node, inst, comp)
        if comp.nil?
          transform_error(ctxt, nil, inst, "xsl:apply-templates : compilation failed\n")
          return
        end
        return if ctxt.nil? || node.nil? || inst.nil?

        xp = ctxt.xpath_ctxt
        old_context_node = ctxt.node
        old_mode = ctxt.mode
        old_mode_uri = ctxt.mode_uri
        old_doc_info = ctxt.document
        old_list = ctxt.node_list
        old_size = xp.context_size
        old_pos = xp.proximity_position
        old_doc = xp.doc
        ctxt.mode = comp.mode
        ctxt.mode_uri = comp.mode_uri
        with_params = nil
        list = nil
        begin
          if comp.select
            if comp.comp.nil?
              transform_error(ctxt, nil, inst, "xsl:apply-templates : compilation failed\n")
              break
            end
            res = pre_comp_eval(ctxt, node, comp)
            if !res.nil?
              if node_set_value?(res)
                list = res
              else
                transform_error(ctxt, nil, inst, "The 'select' expression did not evaluate to a node set.\n")
                ctxt.state = STATE_STOPPED
                break
              end
            else
              transform_error(ctxt, nil, inst, "Failed to evaluate the 'select' expression.\n")
              ctxt.state = STATE_STOPPED
              break
            end
          else
            list = []
            cur = node.is_a?(XmlNs) ? nil : node.children
            while cur
              list << cur if real_node?(cur)
              cur = cur.next
            end
          end
          break if list.empty?

          ctxt.node_list = list
          if inst.children
            cur = inst.children
            while cur
              break if ctxt.state == STATE_STOPPED

              if cur.type == TEXT_NODE
                cur = cur.next
                next
              end
              break unless xslt_elem?(cur)

              if cur.name == "with-param"
                param = parse_stylesheet_caller_param(ctxt, cur)
                if param
                  param.next = with_params
                  with_params = param
                end
              end
              if cur.name == "sort"
                old_rule = ctxt.current_template_rule
                sorts = [cur]
                cur = cur.next
                while cur
                  break if ctxt.state == STATE_STOPPED

                  if cur.type == TEXT_NODE
                    cur = cur.next
                    next
                  end
                  break unless xslt_elem?(cur)

                  if cur.name == "with-param"
                    param = parse_stylesheet_caller_param(ctxt, cur)
                    if param
                      param.next = with_params
                      with_params = param
                    end
                  end
                  if cur.name == "sort"
                    if sorts.length >= MAX_SORT
                      transform_error(ctxt, nil, cur,
                        "The number (#{sorts.length}) of xsl:sort instructions exceeds the maximum allowed by this processor's settings.\n")
                      ctxt.state = STATE_STOPPED
                      break
                    else
                      sorts << cur
                    end
                  end
                  cur = cur.next
                end
                ctxt.current_template_rule = nil
                do_sort_function(ctxt, sorts, sorts.length)
                ctxt.current_template_rule = old_rule
                break
              end
              cur = cur.next
            end
          end
          xp.context_size = list.length
          list.each_with_index do |n, i|
            ctxt.node = n
            xp.doc = n.doc if !n.is_a?(XmlNs) && n.doc
            xp.proximity_position = i + 1
            process_one_node(ctxt, n, with_params)
          end
        end while false # rubocop:disable Lint/Loop
        free_stack_elem_list(with_params) if with_params
        xp.doc = old_doc
        xp.context_size = old_size
        xp.proximity_position = old_pos
        ctxt.document = old_doc_info
        ctxt.node_list = old_list
        ctxt.node = old_context_node
        ctxt.mode = old_mode
        ctxt.mode_uri = old_mode_uri
      end

      # xsltChoose
      def choose(ctxt, context_node, inst, _comp)
        return if ctxt.nil? || context_node.nil? || inst.nil?

        cur = inst.children
        if cur.nil?
          transform_error(ctxt, nil, inst, "xsl:choose: The instruction has no content.\n")
          return
        end
        if !xslt_elem?(cur) || cur.name != "when"
          transform_error(ctxt, nil, inst, "xsl:choose: xsl:when expected first\n")
          return
        end
        while xslt_elem?(cur) && cur.name == "when"
          wcomp = cur.psvi
          if wcomp.nil? || wcomp.test.nil? || wcomp.comp.nil?
            transform_error(ctxt, nil, cur,
              "Internal error in xsltChoose(): The XSLT 'when' instruction was not compiled.\n")
            return
          end
          res = pre_comp_eval_to_boolean(ctxt, context_node, wcomp)
          if res == -1
            ctxt.state = STATE_STOPPED
            return
          end
          if res == 1
            apply_sequence_constructor(ctxt, ctxt.node, cur.children, nil)
            return
          end
          cur = cur.next
        end
        if xslt_elem?(cur) && cur.name == "otherwise"
          apply_sequence_constructor(ctxt, ctxt.node, cur.children, nil)
        end
      end

      # xsltIf
      def xslt_if(ctxt, context_node, inst, comp)
        return if ctxt.nil? || context_node.nil? || inst.nil?

        if comp.nil? || comp.test.nil? || comp.comp.nil?
          transform_error(ctxt, nil, inst, "Internal error in xsltIf(): The XSLT 'if' instruction was not compiled.\n")
          return
        end
        old_local_fragment_top = ctxt.local_rvt
        res = pre_comp_eval_to_boolean(ctxt, context_node, comp)
        release_local_rvts(ctxt, old_local_fragment_top) unless old_local_fragment_top.equal?(ctxt.local_rvt)
        if res == -1
          ctxt.state = STATE_STOPPED
          return
        end
        apply_sequence_constructor(ctxt, context_node, inst.children, nil) if res == 1
      end

      # xsltForEach
      def for_each(ctxt, context_node, inst, comp)
        if ctxt.nil? || context_node.nil? || inst.nil?
          generic_error("xsltForEach(): Bad arguments.\n")
          return
        end
        if comp.nil?
          transform_error(ctxt, nil, inst,
            "Internal error in xsltForEach(): The XSLT 'for-each' instruction was not compiled.\n")
          return
        end
        if comp.select.nil? || comp.comp.nil?
          transform_error(ctxt, nil, inst,
            "Internal error in xsltForEach(): The selecting expression of the XSLT 'for-each' instruction was not compiled correctly.\n")
          return
        end
        xp = ctxt.xpath_ctxt
        old_doc_info = ctxt.document
        old_list = ctxt.node_list
        old_context_node = ctxt.node
        old_rule = ctxt.current_template_rule
        ctxt.current_template_rule = nil
        old_doc = xp.doc
        old_pos = xp.proximity_position
        old_size = xp.context_size
        begin
          res = pre_comp_eval(ctxt, context_node, comp)
          if !res.nil?
            unless node_set_value?(res)
              transform_error(ctxt, nil, inst, "The 'select' expression does not evaluate to a node set.\n")
              break
            end
            list = res
          else
            transform_error(ctxt, nil, inst, "Failed to evaluate the 'select' expression.\n")
            ctxt.state = STATE_STOPPED
            break
          end
          break if list.empty?

          ctxt.node_list = list
          cur_inst = inst.children
          if xslt_elem?(cur_inst) && cur_inst.name == "sort"
            sorts = [cur_inst]
            cur_inst = cur_inst.next
            too_many = false
            while xslt_elem?(cur_inst) && cur_inst.name == "sort"
              if sorts.length >= MAX_SORT
                transform_error(ctxt, nil, cur_inst,
                  "The number of xsl:sort instructions exceeds the maximum (#{MAX_SORT}) allowed by this processor.\n")
                too_many = true
                break
              end
              sorts << cur_inst
              cur_inst = cur_inst.next
            end
            break if too_many

            do_sort_function(ctxt, sorts, sorts.length)
          end
          xp.context_size = list.length
          list.each_with_index do |cur, i|
            ctxt.node = cur
            xp.doc = cur.doc if !cur.is_a?(XmlNs) && cur.doc
            xp.proximity_position = i + 1
            apply_sequence_constructor(ctxt, cur, cur_inst, nil)
          end
        end while false # rubocop:disable Lint/Loop
        ctxt.document = old_doc_info
        ctxt.node_list = old_list
        ctxt.node = old_context_node
        ctxt.current_template_rule = old_rule
        xp.doc = old_doc
        xp.context_size = old_size
        xp.proximity_position = old_pos
      end

      # xsltApplyStripSpaces
      def apply_strip_spaces(ctxt, node)
        current = node
        while current
          if real_node?(current) && current.children && find_elem_space_handling(ctxt, current)
            cur = current.children
            while cur
              delete = blank_node?(cur) ? cur : nil
              cur = cur.next
              Tree.unlink_node(delete) if delete
            end
          end
          apply_strip_spaces(ctxt, node.children) if node.type == ENTITY_REF_NODE
          if current.children && current.type != ENTITY_REF_NODE
            current = current.children
          elsif current.next
            current = current.next
          else
            loop do
              current = current.parent
              break if current.nil?
              return if current.equal?(node)

              if current.next
                current = current.next
                break
              end
            end
          end
        end
      end

      # xsltCountKeys
      def count_keys(ctxt)
        return -1 if ctxt.nil?

        ctxt.has_templ_key_patterns = false
        style = ctxt.style
        while style
          if style.key_match
            ctxt.has_templ_key_patterns = true
            break
          end
          style = next_import(style)
        end
        ctxt.nb_keys = 0
        style = ctxt.style
        while style
          keyd = style.keys
          while keyd
            ctxt.nb_keys += 1
            keyd = keyd.next
          end
          style = next_import(style)
        end
        ctxt.nb_keys
      end

      # xsltApplyStylesheetInternal
      def apply_stylesheet_internal(style, doc, params, output, user_ctxt)
        return nil if style.nil? || doc.nil?

        if doc.int_subset
          cur = doc.int_subset
          cur.next.prev = cur.prev if cur.next
          cur.prev.next = cur.next if cur.prev
          doc.children = cur.next if doc.children.equal?(cur)
          doc.last = cur.prev if doc.last.equal?(cur)
          cur.prev = cur.next = nil
        end
        root = Tree.doc_get_root_element(doc)
        XPath.order_doc_elems(doc) if root && !(root.content.is_a?(Integer) && root.content < 0)

        ctxt = user_ctxt || new_transform_context(style, doc)
        return nil if ctxt.nil?

        ctxt.initial_context_doc = doc
        ctxt.initial_context_node = doc
        ctxt.output_file = output
        res = nil
        begin
          method = get_import_ptr(style, :method)
          doctype_public = get_import_ptr(style, :doctype_public)
          doctype_system = get_import_ptr(style, :doctype_system)
          version = get_import_ptr(style, :version)
          encoding = get_import_ptr(style, :encoding)

          if method && method != "xml"
            if method == "html"
              ctxt.type = OUTPUT_HTML
              res = if doctype_public || doctype_system
                html_new_doc(doctype_system, doctype_public, false)
              elsif version.nil?
                html_new_doc(nil, nil, true)
              else
                html_new_doc(doctype_system, doctype_public, false)
              end
            elsif method == "xhtml"
              transform_error(ctxt, nil, doc, "xsltApplyStylesheetInternal: unsupported method xhtml, using html\n")
              ctxt.type = OUTPUT_HTML
              res = html_new_doc(doctype_system, doctype_public, false)
            elsif method == "text"
              ctxt.type = OUTPUT_TEXT
              res = Tree.new_doc(style.version)
            else
              transform_error(ctxt, nil, doc, "xsltApplyStylesheetInternal: unsupported method (#{method})\n")
              free_transform_context(ctxt) if user_ctxt.nil?
              return nil
            end
          else
            ctxt.type = OUTPUT_XML
            res = Tree.new_doc(style.version)
          end
          res.charset = 1
          res.encoding = encoding.dup if encoding

          ctxt.node = doc
          ctxt.output = res
          xp = ctxt.xpath_ctxt
          xp.context_size = 1
          xp.proximity_position = 1
          xp.node = nil

          apply_strip_spaces(ctxt, Tree.doc_get_root_element(doc)) if need_elem_space_handling(ctxt)
          ctxt.global_vars ||= {}
          eval_user_params(ctxt, params) if params
          count_keys(ctxt)
          eval_global_variables(ctxt)
          release_local_rvts(ctxt, nil) if ctxt.local_rvt

          ctxt.insert = res
          ctxt.vars_base = ctxt.vars_tab.length - 1
          process_one_node(ctxt, ctxt.node, nil)
          local_variable_pop(ctxt, 0, -2)
          shutdown_ctxt_exts(ctxt)

          root = Tree.doc_get_root_element(res)
          if root
            doctype = root.ns&.prefix ? "#{root.ns.prefix}:#{root.name}" : root.name
            if method.nil? && root.ns.nil? && root.name.casecmp?("html")
              tmp = res.children
              while tmp && !tmp.equal?(root)
                break if tmp.type == ELEMENT_NODE
                break if tmp.type == TEXT_NODE && !Tree.is_blank_node(tmp)

                tmp = tmp.next
              end
              if tmp.equal?(root)
                ctxt.type = OUTPUT_HTML
                res.type = HTML_DOCUMENT_NODE
                if doctype_public || doctype_system
                  res.int_subset = Tree.create_int_subset(res, doctype, doctype_public, doctype_system)
                end
              end
            end
            if ctxt.type == OUTPUT_XML
              doctype_public = get_import_ptr(style, :doctype_public)
              doctype_system = get_import_ptr(style, :doctype_system)
              if doctype_public || doctype_system
                node = res.children
                last = res.last
                res.children = nil
                res.last = nil
                res.int_subset = Tree.create_int_subset(res, doctype, doctype_public, doctype_system)
                if res.children
                  res.children.next = node
                  node.prev = res.children
                  res.last = last
                else
                  res.children = node
                  res.last = last
                end
              end
            end
          end
          res = nil if ctxt.state != STATE_OK
          if res && output
            ret = check_write(ctxt.sec, ctxt, output)
            if ret == 0
              transform_error(ctxt, nil, nil, "xsltApplyStylesheet: forbidden to save to #{output}\n")
            elsif ret < 0
              transform_error(ctxt, nil, nil, "xsltApplyStylesheet: saving to #{output} may not be possible\n")
            end
          end
        ensure
          free_transform_context(ctxt) if user_ctxt.nil?
        end
        res
      end

      # xsltApplyStylesheet: +params+ is a flat Array of Strings (name, xpath-expr, ...)
      def apply_stylesheet(style, doc, params)
        apply_stylesheet_internal(style, doc, params, nil, nil)
      end

      # xsltApplyStylesheetUser
      def apply_stylesheet_user(style, doc, params, output, _profile, user_ctxt)
        apply_stylesheet_internal(style, doc, params, output, user_ctxt)
      end

      def message_wrapper(ctxt, node, inst, _comp)
        message(ctxt, node, inst)
      end

      REGISTERED_ELEMENTS = {
        "apply-templates" => :apply_templates, "apply-imports" => :apply_imports,
        "call-template" => :call_template, "element" => :element, "attribute" => :attribute,
        "text" => :text, "processing-instruction" => :processing_instruction, "comment" => :comment,
        "copy" => :copy, "value-of" => :value_of, "number" => :number, "for-each" => :for_each,
        "if" => :xslt_if, "choose" => :choose, "sort" => :sort, "copy-of" => :copy_of,
        "message" => :message_wrapper, "variable" => :debug, "param" => :debug, "with-param" => :debug,
        "decimal-format" => :debug, "when" => :debug, "otherwise" => :debug, "fallback" => :debug,
      }.freeze

      # xsltRegisterAllElement
      def register_all_element(ctxt)
        REGISTERED_ELEMENTS.each do |name, meth|
          register_ext_element(ctxt, name, NAMESPACE, instr_func(meth))
        end
      end
    end
  end
end
