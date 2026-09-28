# frozen_string_literal: true

# Port of libxslt templates.c and attrvt.c: XPath evaluation helpers, attribute value
# templates (runtime and precompiled), literal result element attributes.

module Nokogiri
  module Pure
    module XSLT
      module_function

      # xsltEvalXPathPredicate
      def eval_xpath_predicate(ctxt, comp, ns_list)
        if ctxt.nil? || ctxt.inst.nil?
          transform_error(ctxt, nil, nil, "xsltEvalXPathPredicate: No context or instruction\n")
          return false
        end
        xp = ctxt.xpath_ctxt
        old_node = xp.node
        old_size = xp.context_size
        old_pos = xp.proximity_position
        old_ns = xp.namespaces
        old_inst = ctxt.inst
        xp.node = ctxt.node
        xp.namespaces = ns_list
        res = XPath.compiled_eval(comp, xp)
        if !res.nil?
          ret = eval_predicate_value(xp, res)
        else
          ctxt.state = STATE_STOPPED
          ret = false
        end
        xp.node = old_node
        xp.namespaces = old_ns
        ctxt.inst = old_inst
        xp.context_size = old_size
        xp.proximity_position = old_pos
        ret
      end

      # xmlXPathEvalPredicate
      def eval_predicate_value(xp, res)
        if res.is_a?(Float)
          res == xp.proximity_position
        else
          XPath.cast_to_boolean(res)
        end
      end

      # xsltEvalXPathStringNs
      def eval_xpath_string_ns(ctxt, comp, ns_list)
        if ctxt.nil? || ctxt.inst.nil?
          transform_error(ctxt, nil, nil, "xsltEvalXPathStringNs: No context or instruction\n")
          return nil
        end
        xp = ctxt.xpath_ctxt
        old_inst = ctxt.inst
        old_node = xp.node
        old_pos = xp.proximity_position
        old_size = xp.context_size
        old_ns = xp.namespaces
        xp.node = ctxt.node
        xp.namespaces = ns_list
        ret = nil
        res = comp.nil? ? nil : XPath.compiled_eval(comp, xp)
        if !res.nil?
          ret = res.is_a?(String) ? res : XPath.cast_to_string(res)
        else
          ctxt.state = STATE_STOPPED
        end
        ctxt.inst = old_inst
        xp.node = old_node
        xp.context_size = old_size
        xp.proximity_position = old_pos
        xp.namespaces = old_ns
        ret
      end

      # xsltEvalXPathString
      def eval_xpath_string(ctxt, comp)
        eval_xpath_string_ns(ctxt, comp, nil)
      end

      # xsltEvalTemplateString
      def eval_template_string(ctxt, context_node, inst)
        return nil if ctxt.nil? || context_node.nil? || inst.nil? || inst.type != ELEMENT_NODE
        return nil if inst.children.nil?

        insert = Tree.new_doc_node(ctxt.output, nil, "fake", nil)
        old_insert = ctxt.insert
        ctxt.insert = insert
        apply_one_template(ctxt, context_node, inst.children, nil, nil)
        ctxt.insert = old_insert
        Tree.node_get_content(insert)
      end

      # xsltAttrTemplateValueProcessNode
      def attr_template_value_process_node(ctxt, str, inst)
        return nil if str.nil?
        return +"" if str.empty?

        ret = nil
        ns_list = nil
        s = str.b
        start = 0
        cur = 0
        len = s.bytesize
        while cur < len
          c = s.getbyte(cur)
          if c == 0x7B # {
            if s.getbyte(cur + 1) == 0x7B
              cur += 1
              ret = strncat(ret, s.byteslice(start, cur - start))
              cur += 1
              start = cur
              next
            end
            ret = strncat(ret, s.byteslice(start, cur - start))
            start = cur
            cur += 1
            while cur < len && s.getbyte(cur) != 0x7D
              ch = s.getbyte(cur)
              if ch == 0x27 || ch == 0x22
                delim = ch
                cur += 1
                cur += 1 while cur < len && s.getbyte(cur) != delim
                cur += 1 if cur < len
              else
                cur += 1
              end
            end
            if cur >= len
              transform_error(ctxt, nil, inst, "xsltAttrTemplateValueProcessNode: unmatched '{'\n")
              ret = strncat(ret, s.byteslice(start, cur - start))
              return u8(ret)
            end
            start += 1
            expr = s.byteslice(start, cur - start)
            if expr.getbyte(0) == 0x7B
              ret = strcat(ret, expr)
            else
              ns_list ||= inst ? Tree.get_ns_list(inst.doc, inst) : nil
              comp = XPath.ctxt_compile(ctxt.xpath_ctxt, u8(expr))
              val = eval_xpath_string_ns(ctxt, comp, ns_list)
              ret = strcat(ret, val.b) if val
            end
            cur += 1
            start = cur
          elsif c == 0x7D # }
            cur += 1
            if s.getbyte(cur) == 0x7D
              ret = strncat(ret, s.byteslice(start, cur - start))
              cur += 1
              start = cur
              next
            else
              transform_error(ctxt, nil, inst, "xsltAttrTemplateValueProcessNode: unmatched '}'\n")
            end
          else
            cur += 1
          end
        end
        ret = strncat(ret, s.byteslice(start, cur - start)) if cur != start
        u8(ret)
      end

      # xmlStrncat semantics: nil + "" stays nil
      def strncat(ret, add)
        return ret if add.nil? || add.empty?

        ret.nil? ? add.dup : (ret << add)
      end

      # xmlStrcat semantics: nil + "" is ""
      def strcat(ret, add)
        return ret if add.nil?

        ret.nil? ? add.dup : (ret << add)
      end

      def u8(s)
        s&.force_encoding(Encoding::UTF_8)
      end

      # xsltAttrTemplateValueProcess
      def attr_template_value_process(ctxt, str)
        attr_template_value_process_node(ctxt, str, nil)
      end

      # xsltEvalAttrValueTemplate
      def eval_attr_value_template(ctxt, inst, name, ns)
        return nil if ctxt.nil? || inst.nil? || name.nil? || inst.type != ELEMENT_NODE

        expr = get_ns_prop(inst, name, ns)
        return nil if expr.nil?

        attr_template_value_process_node(ctxt, expr, inst)
      end

      # xsltEvalStaticAttrValueTemplate: returns [value_or_nil, found]
      def eval_static_attr_value_template(style, inst, name, ns)
        return [nil, false] if style.nil? || inst.nil? || name.nil? || inst.type != ELEMENT_NODE

        expr = get_ns_prop(inst, name, ns)
        return [nil, false] if expr.nil?
        return [nil, true] if expr.include?("{")

        [expr, true]
      end

      # xsltAttrTemplateProcess
      def attr_template_process(ctxt, target, attr)
        return nil if ctxt.nil? || attr.nil? || target.nil? || target.type != ELEMENT_NODE
        return nil if attr.type != ATTRIBUTE_NODE
        return nil if attr.ns && attr.ns.href == NAMESPACE

        if attr.children
          if attr.children.type != TEXT_NODE || attr.children.next
            transform_error(ctxt, nil, attr.parent,
              "Internal error: The children of an attribute node of a literal result element are not in the expected form.\n")
            return nil
          end
          value = attr.children.content || +""
        else
          value = +""
        end
        ret = target.properties
        while ret
          if (!attr.ns.nil?) == (!ret.ns.nil?) && ret.name == attr.name &&
              (attr.ns.nil? || ret.ns.href == attr.ns.href)
            break
          end

          ret = ret.next
        end
        if ret
          ret.children = nil
          ret.last = nil
          if ret.ns && ret.ns.prefix != attr.ns.prefix
            ret.ns = get_namespace(ctxt, attr.parent, attr.ns, target)
          end
        else
          ret = if attr.ns
            Tree.new_ns_prop(target, get_namespace(ctxt, attr.parent, attr.ns, target), attr.name, nil)
          else
            Tree.new_ns_prop(target, nil, attr.name, nil)
          end
        end
        if ret
          text = Tree.new_text(nil)
          ret.children = ret.last = text
          text.parent = ret
          text.doc = ret.doc
          if attr.psvi
            val = eval_avt(ctxt, attr.psvi, attr.parent)
            if val.nil?
              if attr.ns
                transform_error(ctxt, nil, attr.parent,
                  "Internal error: Failed to evaluate the AVT of attribute '{#{attr.ns.href}}#{attr.name}'.\n")
              else
                transform_error(ctxt, nil, attr.parent,
                  "Internal error: Failed to evaluate the AVT of attribute '#{attr.name}'.\n")
              end
              text.content = +""
            else
              text.content = val
            end
          else
            text.content = value.dup
          end
        elsif attr.ns
          transform_error(ctxt, nil, attr.parent,
            "Internal error: Failed to create attribute '{#{attr.ns.href}}#{attr.name}'.\n")
        else
          transform_error(ctxt, nil, attr.parent, "Internal error: Failed to create attribute '#{attr.name}'.\n")
        end
        ret
      end

      # xsltAttrListTemplateProcess
      def attr_list_template_process(ctxt, target, attrs)
        return nil if ctxt.nil? || target.nil? || attrs.nil? || target.type != ELEMENT_NODE

        old_insert = ctxt.insert
        ctxt.insert = target

        attr = attrs
        while attr
          if attr.ns && attr.name == "use-attribute-sets" && attr.ns.href == NAMESPACE
            apply_attribute_set(ctxt, ctxt.node, attr, nil)
          end
          attr = attr.next
        end
        has_attr = !target.properties.nil?

        orig_ns = nil
        orig_ns_set = false
        copy_ns = nil
        last = nil
        attr = attrs
        while attr
          if attr.ns && attr.ns.href == NAMESPACE
            attr = attr.next
            next
          end
          if attr.children
            if attr.children.type != TEXT_NODE || attr.children.next
              transform_error(ctxt, nil, attr.parent,
                "Internal error: The children of an attribute node of a literal result element are not in the expected form.\n")
              ctxt.insert = old_insert
              return nil
            end
            value = attr.children.content || +""
          else
            value = +""
          end
          if !orig_ns_set || !attr.ns.equal?(orig_ns)
            orig_ns_set = true
            orig_ns = attr.ns
            if attr.ns
              copy_ns = get_namespace(ctxt, attr.parent, attr.ns, target)
              if copy_ns.nil?
                ctxt.insert = old_insert
                return nil
              end
            else
              copy_ns = nil
            end
          end
          if has_attr
            copy = Tree.set_ns_prop(target, copy_ns, attr.name, nil)
          else
            copy = Tree.new_doc_prop(target.doc, attr.name, nil)
            copy.ns = copy_ns
            copy.parent = target
            if last.nil?
              target.properties = copy
            else
              last.next = copy
              copy.prev = last
            end
            last = copy
          end
          if copy.nil?
            if attr.ns
              transform_error(ctxt, nil, attr.parent,
                "Internal error: Failed to create attribute '{#{attr.ns.href}}#{attr.name}'.\n")
            else
              transform_error(ctxt, nil, attr.parent, "Internal error: Failed to create attribute '#{attr.name}'.\n")
            end
            ctxt.insert = old_insert
            return nil
          end
          text = Tree.new_text(nil)
          copy.last = copy.children = text
          text.parent = copy
          text.doc = copy.doc
          if attr.psvi
            value_avt = eval_avt(ctxt, attr.psvi, attr.parent)
            if value_avt.nil?
              if attr.ns
                transform_error(ctxt, nil, attr.parent,
                  "Internal error: Failed to evaluate the AVT of attribute '{#{attr.ns.href}}#{attr.name}'.\n")
              else
                transform_error(ctxt, nil, attr.parent,
                  "Internal error: Failed to evaluate the AVT of attribute '#{attr.name}'.\n")
              end
              text.content = +""
              ctxt.insert = old_insert
              return nil
            end
            text.content = value_avt
          else
            text.content = value.dup
          end
          if Tree.is_id(copy.doc, copy.parent, copy)
            Tree.add_id(copy, text.content)
          end
          attr = attr.next
        end
        ctxt.insert = old_insert
        target.properties
      end

      # ---- attrvt.c ---------------------------------------------------------------------------

      # xsltCompileAttr
      def compile_attr(style, attr)
        return if style.nil? || attr.nil? || attr.children.nil?

        if attr.children.type != TEXT_NODE || attr.children.next
          transform_error(nil, style, attr.parent,
            "Attribute '#{attr.name}': The content is expected to be a single text node when compiling an AVT.\n")
          style.errors += 1
          return
        end
        str = attr.children.content
        return if str.nil? || (!str.include?("{") && !str.include?("}"))
        return unless attr.psvi.nil?

        avt = AttrVT.new
        attr.psvi = avt
        avt.ns_list = Tree.get_ns_list(attr.doc, attr.parent)

        s = str.b
        len = s.bytesize
        cur = 0
        start = 0
        ret = nil
        lastavt = false
        catch(:avt_error) do
          while cur < len
            c = s.getbyte(cur)
            if c == 0x7B
              if s.getbyte(cur + 1) == 0x7B
                cur += 1
                ret = strncat(ret, s.byteslice(start, cur - start))
                cur += 1
                start = cur
                next
              end
              if s.getbyte(cur + 1) == 0x7D
                ret = strncat(ret, s.byteslice(start, cur - start))
                cur += 2
                start = cur
                next
              end
              if ret || cur - start > 0
                ret = strncat(ret, s.byteslice(start, cur - start))
                start = cur
                avt.strstart = true if avt.nb_seg == 0
                avt.segments << u8(ret)
                ret = nil
                lastavt = false
              end
              cur += 1
              while cur < len && s.getbyte(cur) != 0x7D
                ch = s.getbyte(cur)
                if ch == 0x27 || ch == 0x22
                  delim = ch
                  cur += 1
                  cur += 1 while cur < len && s.getbyte(cur) != delim
                  cur += 1 if cur < len
                else
                  cur += 1
                end
              end
              if cur >= len
                transform_error(nil, style, attr.parent, "Attribute '#{attr.name}': The AVT has an unmatched '{'.\n")
                style.errors += 1
                throw :avt_error
              end
              start += 1
              expr = u8(s.byteslice(start, cur - start))
              comp = xpath_compile(style, expr)
              if comp.nil?
                transform_error(nil, style, attr.parent,
                  "Attribute '#{attr.name}': Failed to compile the expression '#{expr}' in the AVT.\n")
                style.errors += 1
                throw :avt_error
              end
              avt.strstart = false if avt.nb_seg == 0
              avt.segments << nil if lastavt
              avt.segments << comp
              lastavt = true
              cur += 1
              start = cur
            elsif c == 0x7D
              cur += 1
              if s.getbyte(cur) == 0x7D
                ret = strncat(ret, s.byteslice(start, cur - start))
                cur += 1
                start = cur
                next
              else
                transform_error(nil, style, attr.parent, "Attribute '#{attr.name}': The AVT has an unmatched '}'.\n")
                throw :avt_error
              end
            else
              cur += 1
            end
          end
          if ret || cur - start > 0
            ret = strncat(ret, s.byteslice(start, cur - start))
            avt.strstart = true if avt.nb_seg == 0
            avt.segments << u8(ret)
          end
        end
      end

      # xsltEvalAVT
      def eval_avt(ctxt, avt, node)
        return nil if ctxt.nil? || avt.nil? || node.nil?

        ret = nil
        str = avt.strstart
        avt.segments.each do |seg|
          if str
            ret = strcat(ret, seg)
          else
            tmp = eval_xpath_string_ns(ctxt, seg, avt.ns_list)
            ret = strcat(ret, tmp) if tmp
          end
          str = !str
        end
        ret
      end
    end
  end
end
