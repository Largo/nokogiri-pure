# frozen_string_literal: true

module Nokogiri
  module Pure
    # XPointer (framework + element(), xmlns(), xpointer()/xpath1() schemes, shorthand pointers):
    # a port of libxml2's xpointer.c as built without LIBXML_XPTR_LOCS_ENABLED (Nokogiri's build).
    module XPointer
      XPTR_UNKNOWN_SCHEME = 1900
      XPTR_CHILDSEQ_START = 1901
      XPTR_EVAL_FAILED = 1902
      XPTR_EXTRA_OBJECTS = 1903

      module_function

      # xmlXPtrErr
      def xptr_err(ctxt, code, msg, extra = nil)
        return if ctxt.error != 0

        ctxt.error = code
        context = ctxt.context
        err = XmlError.new(domain: Domain::XPOINTER, code: code, level: Level::ERROR,
          message: extra.nil? ? msg : msg.sub("%s", extra), str1: extra, str2: ctxt.base,
          int1: ctxt.cur_offset, node: context&.debug_node)
        if context
          context.last_error = err
          if (h = context.error)
            h.call(err)
            return
          end
        end
        Errors.report(err)
      end

      # XP_ERROR: record and stop the current function
      def xp_err(ctxt, code)
        ctxt.xpath_err(code)
      end

      # xmlXPtrNewContext
      def new_context(doc)
        ctx = XPath.new_context(doc)
        ctx.xptr = 1
        ctx
      end

      # xmlXPtrGetNthChild
      def get_nth_child(cur, no)
        return cur if cur.nil? || cur.is_a?(XmlNs)

        cur = cur.children
        i = 0
        while i <= no
          return nil if cur.nil?

          if cur.type == ELEMENT_NODE || cur.type == DOCUMENT_NODE || cur.type == HTML_DOCUMENT_NODE
            i += 1
            break if i == no
          end
          cur = cur.next
        end
        cur
      end

      # xmlXPtrGetChildNo
      def get_child_no(ctxt, indx)
        unless ctxt.value.is_a?(Array)
          xp_err(ctxt, XPath::INVALID_TYPE)
          return
        end
        oldset = ctxt.value_pop
        if indx <= 0 || oldset.length != 1
          ctxt.value_push([])
          return
        end
        cur = get_nth_child(oldset[0], indx)
        if cur.nil?
          ctxt.value_push([])
          return
        end
        ctxt.value_push([cur])
      end

      # xmlXPtrEvalChildSeq
      def eval_child_seq(ctxt, name)
        if name.nil? && ctxt.cur_byte == 0x2F && ctxt.nxt_byte(1) != 0x31
          xptr_err(ctxt, XPTR_CHILDSEQ_START, "warning: ChildSeq not starting by /1\n")
        end
        if name
          ctxt.value_push(name)
          ctxt.call_function(:fn_id, 1)
          return if ctxt.error != 0
        end
        while ctxt.cur_byte == 0x2F
          child = 0
          overflow = false
          ctxt.next_byte
          while (c = ctxt.cur_byte) >= 0x30 && c <= 0x39
            child = child * 10 + (c - 0x30)
            overflow = true if child > 0x7FFFFFFF
            ctxt.next_byte
          end
          child = 0 if overflow
          get_child_no(ctxt, child)
        end
      end

      # xmlXPtrEvalXPtrPart
      def eval_xptr_part(ctxt, name)
        name ||= ctxt.parse_name
        return xp_err(ctxt, XPath::EXPR_ERROR) if name.nil?
        return xp_err(ctxt, XPath::EXPR_ERROR) if ctxt.cur_byte != 0x28

        ctxt.next_byte
        level = 1
        buffer = +"".b
        while (c = ctxt.cur_byte) != 0
          if c == 0x29
            level -= 1
            if level == 0
              ctxt.next_byte
              break
            end
          elsif c == 0x28
            level += 1
          elsif c == 0x5E
            n = ctxt.nxt_byte(1)
            ctxt.next_byte if n == 0x29 || n == 0x28 || n == 0x5E
          end
          buffer << ctxt.cur_byte
          ctxt.next_byte
        end
        return xp_err(ctxt, XPath::XPTR_SYNTAX_ERROR) if level != 0 && ctxt.cur_byte == 0

        buffer.force_encoding(::Encoding::UTF_8)
        old_base = ctxt.base
        old_cur = ctxt.cur_offset
        case name
        when "xpointer", "xpath1"
          ctxt.base = buffer
          ctxt.cur_offset = 0
          context = ctxt.context
          context.node = context.doc
          context.proximity_position = 1
          context.context_size = 1
          ctxt.xptr = name == "xpointer" ? 1 : 0
          ctxt.eval_expr
          ctxt.base = old_base
          ctxt.cur_offset = old_cur
        when "element"
          ctxt.base = buffer
          ctxt.cur_offset = 0
          if buffer.start_with?("/")
            ctxt.root
            eval_child_seq(ctxt, nil)
          else
            name2 = ctxt.parse_name
            if name2.nil?
              ctxt.base = old_base
              ctxt.cur_offset = old_cur
              return xp_err(ctxt, XPath::EXPR_ERROR)
            end
            eval_child_seq(ctxt, name2)
          end
          ctxt.base = old_base
          ctxt.cur_offset = old_cur
        when "xmlns"
          ctxt.base = buffer
          ctxt.cur_offset = 0
          prefix = ctxt.parse_ncname
          if prefix.nil?
            ctxt.base = old_base
            ctxt.cur_offset = old_cur
            return xp_err(ctxt, XPath::XPTR_SYNTAX_ERROR)
          end
          ctxt.skip_blanks
          if ctxt.cur_byte != 0x3D
            ctxt.base = old_base
            ctxt.cur_offset = old_cur
            return xp_err(ctxt, XPath::XPTR_SYNTAX_ERROR)
          end
          ctxt.next_byte
          ctxt.skip_blanks
          ctxt.context.register_ns(prefix, ctxt.rest)
          ctxt.base = old_base
          ctxt.cur_offset = old_cur
        else
          xptr_err(ctxt, XPTR_UNKNOWN_SCHEME, "unsupported scheme '%s'\n", name)
        end
      end

      # xmlXPtrEvalFullXPtr
      def eval_full_xptr(ctxt, name)
        name ||= ctxt.parse_name
        return xp_err(ctxt, XPath::EXPR_ERROR) if name.nil?

        while name
          ctxt.error = XPath::EXPRESSION_OK
          eval_xptr_part(ctxt, name)
          return if ctxt.error != XPath::EXPRESSION_OK && ctxt.error != XPTR_UNKNOWN_SCHEME

          unless ctxt.value.nil?
            return if ctxt.value.is_a?(Array) && !ctxt.value.empty?

            ctxt.value_pop until ctxt.value.nil?
          end
          ctxt.skip_blanks
          name = ctxt.parse_name
        end
      end

      # xmlXPtrEvalXPointer
      def eval_xpointer(ctxt)
        ctxt.skip_blanks
        if ctxt.cur_byte == 0x2F
          ctxt.root
          eval_child_seq(ctxt, nil)
        else
          name = ctxt.parse_name
          return xp_err(ctxt, XPath::EXPR_ERROR) if name.nil?

          if ctxt.cur_byte == 0x28
            eval_full_xptr(ctxt, name)
            return
          end
          eval_child_seq(ctxt, name)
        end
        ctxt.skip_blanks
        xp_err(ctxt, XPath::EXPR_ERROR) if ctxt.cur_byte != 0
      end

      # xmlXPtrEval(str, ctx). Returns the result node-set (Array) or nil.
      def xptr_eval(str, ctx)
        ctx.last_error = nil
        ctxt = XPath.new_parser_context(str, ctx)
        eval_xpointer(ctxt)
        return nil if ctx.last_error && ctx.last_error.code != 0

        res = nil
        if !ctxt.value.nil? && !ctxt.value.is_a?(Array)
          xptr_err(ctxt, XPTR_EVAL_FAILED, "xmlXPtrEval: evaluation failed to return a node set\n")
        else
          res = ctxt.value_pop
        end
        stack = 0
        until (tmp = ctxt.value_pop).nil?
          if tmp.is_a?(Array)
            stack += 1 if tmp.length != 1 || !tmp[0].equal?(ctx.doc)
          else
            stack += 1
          end
        end
        if stack != 0
          xptr_err(ctxt, XPTR_EXTRA_OBJECTS, "xmlXPtrEval: object(s) left on the eval stack\n")
        end
        return nil if ctx.last_error && ctx.last_error.code != 0

        res
      end

      # convenience for XInclude: [ok, result]
      def eval(fragment, doc)
        ctx = new_context(doc)
        res = xptr_eval(fragment, ctx)
        failed = ctx.last_error && ctx.last_error.code != 0
        [!failed, res]
      end
    end
  end
end
