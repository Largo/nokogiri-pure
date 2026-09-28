# frozen_string_literal: true

module Nokogiri
  module Pure
    module XPath
      # xmlXPathParserContext: the value stack and the evaluator (xmlXPathCompOpEval & friends).
      #
      # Errors: #xp_error (the XP_ERROR macro) reports the error and aborts the evaluation by
      # raising XPath::Abort (#abort!), which the entry points (XPath.eval, XPath.compiled_eval,
      # ...) rescue.
      # #xpath_err (xmlXPathErr) only reports and records it; the evaluator aborts as soon as it
      # notices ctxt.error != 0 after calling a function.
      # The unwinding of XP_ERROR & co. to the evaluation entry points. raise/rescue rather than
      # catch/throw: Kernel#catch runs its block from C, a native stack frame per nested
      # evaluation, which ruby.wasm's small native stack can't afford. (An Exception rather than a
      # StandardError, so that a `rescue => e` in between lets it through like a throw.)
      class Abort < Exception # rubocop:disable Lint/InheritException
      end
      NO_BACKTRACE = [].freeze

      class ParserContext
        attr_accessor :error, :context, :comp, :value_tab, :ancestor, :xptr, :base, :cur_offset
        # the live recursion depth (ctxt->context->depth while evaluating)
        attr_reader :depth

        def initialize(context, comp = nil, base = nil, cur_offset = 0)
          @context = context
          @comp = comp
          @base = base
          @cur_offset = cur_offset
          @value_tab = []
          @error = EXPRESSION_OK
          @ancestor = nil
          @xptr = 0
          @sorted = nil
          # the last node-set a specialised traversal produced (known to hold no namespace
          # nodes) while it isn't merged into
          @ns_free = nil
          @func_cache = nil
          @sib_memo = nil
          @depth = context ? context.depth : 0
        end

        # ---- value stack ------------------------------------------------------------------

        def value
          @value_tab.last
        end

        def value_nr
          @value_tab.length
        end

        def value_pop
          @value_tab.pop
        end

        def value_push(v)
          if v.nil?
            mem_error
          end
          @value_tab.push(v)
          @value_tab.length - 1
        end

        # xmlXPathPopBoolean
        def pop_boolean
          obj = value_pop
          if obj.nil?
            xpath_err(INVALID_OPERAND)
            return false
          end
          obj == true || obj == false ? obj : XPath.cast_to_boolean(obj)
        end

        # xmlXPathPopNumber
        def pop_number
          obj = value_pop
          if obj.nil?
            xpath_err(INVALID_OPERAND)
            return 0.0
          end
          obj.is_a?(Float) ? obj : cast_to_number_internal(obj)
        end

        # xmlXPathPopString
        def pop_string
          obj = value_pop
          if obj.nil?
            xpath_err(INVALID_OPERAND)
            return +""
          end
          s = cast_to_string_internal(obj)
          s
        end

        # xmlXPathPopNodeSet
        def pop_node_set
          if value.nil?
            xpath_err(INVALID_OPERAND)
            return nil
          end
          unless value.is_a?(Array)
            xpath_err(INVALID_TYPE)
            return nil
          end
          value_pop
        end

        # xmlXPathPopExternal
        def pop_external
          if value.nil?
            xpath_err(INVALID_OPERAND)
            return nil
          end
          unless value.is_a?(UserObject)
            xpath_err(INVALID_TYPE)
            return nil
          end
          value_pop.user
        end

        # ---- errors -----------------------------------------------------------------------

        # xmlXPathErr: report (only the first error) without aborting
        def xpath_err(code)
          code = MAXERRNO if code < 0 || code > MAXERRNO
          return if @error != EXPRESSION_OK

          @error = code
          le = @context&.last_error
          return if le && le.code == XML_ERR_NO_MEMORY && le.domain == Domain::XPATH

          XPath.report_error(@context, code, @base, @cur_offset)
        end

        # XP_ERROR: report and abort
        def xp_error(code)
          xpath_err(code)
          raise Abort, nil, NO_BACKTRACE
        end

        # abort the evaluation (unwinding to the entry point) without reporting anything
        def abort!
          raise Abort, nil, NO_BACKTRACE
        end

        # xmlXPathPErrMemory
        def mem_error
          @error = MEMORY_ERROR
          XPath.report_memory_error(@context)
          raise Abort, nil, NO_BACKTRACE
        end

        def check_error!
          raise Abort, nil, NO_BACKTRACE if @error != EXPRESSION_OK
        end

        # CHECK_ARITY
        def check_arity(nargs, x)
          xp_error(INVALID_ARITY) if nargs != x
          xp_error(STACK_ERROR) if @value_tab.length < x
        end

        # CAST_TO_STRING
        def cast_top_to_string
          v = @value_tab.last
          fn_string(1) if !v.nil? && !v.is_a?(String)
        end

        # CAST_TO_NUMBER
        def cast_top_to_number
          v = @value_tab.last
          fn_number(1) if !v.nil? && !v.is_a?(Float)
        end

        # CAST_TO_BOOLEAN
        def cast_top_to_boolean
          v = @value_tab.last
          fn_boolean(1) if !v.nil? && v != true && v != false
        end

        # CHECK_TYPE
        def check_type_string
          xp_error(INVALID_TYPE) unless @value_tab.last.is_a?(String)
        end

        def check_type_number
          xp_error(INVALID_TYPE) unless @value_tab.last.is_a?(Float)
        end

        def check_type_boolean
          v = @value_tab.last
          xp_error(INVALID_TYPE) unless v == true || v == false
        end

        # ---- casts with memory-error reporting ----------------------------------------------

        def node_to_string(node)
          s = Tree.node_get_content(node)
          mem_error if s.nil?
          s
        end

        def cast_node_set_to_string_internal(ns)
          return +"" if ns.empty?

          XPath.node_set_sort(ns) if ns.length > 1
          node_to_string(ns[0])
        end

        # xmlXPathCastToString (+ memory error handling of the callers)
        def cast_to_string_internal(v)
          case v
          when String then v
          when Array then cast_node_set_to_string_internal(v)
          when Float then XPath.format_number(v)
          when true then +"true"
          when false then +"false"
          else +""
          end
        end

        # xmlXPathCastToNumberInternal
        def cast_to_number_internal(v)
          case v
          when Float then v
          when String then XPath.string_eval_number(v)
          when Array then XPath.string_eval_number(cast_node_set_to_string_internal(v))
          when true then 1.0
          when false then 0.0
          else NAN
          end
        end

        # xmlXPathNodeToNumberInternal
        def node_to_number(node)
          return NAN if node.nil?

          XPath.string_eval_number(node_to_string(node))
        end

        # ---- parser-context API (xmlXPathNewParserContext users such as XPointer) ------------
        #
        # +base+ is the expression string and +cur_offset+ the current byte offset in it (the
        # ctxt->base / ctxt->cur pair); both may be reassigned by the caller.

        # the byte at the current position (0 at the end), like CUR
        def cur_byte
          @base.getbyte(@cur_offset) || 0
        end

        # the byte +n+ positions ahead, like NXT(n)
        def nxt_byte(n)
          @base.getbyte(@cur_offset + n) || 0
        end

        # NEXT
        def next_byte
          @cur_offset += 1 if @cur_offset < @base.bytesize
        end

        # SKIP_BLANKS
        def skip_blanks
          while (c = @base.getbyte(@cur_offset)) && (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D)
            @cur_offset += 1
          end
        end

        # the rest of the expression from the current position
        def rest
          @base.byteslice(@cur_offset, @base.bytesize - @cur_offset).force_encoding(::Encoding::UTF_8)
        end

        # xmlXPathParseName / xmlXPathParseNCName: nil if there's no name (errors are recorded
        # with #xpath_err, without aborting)
        def parse_name
          scan_name_with(:name)
        end

        def parse_ncname
          scan_name_with(:ncname)
        end

        def scan_name_with(what)
          name, pos, err = Compiler.new(@base).scan_at(@cur_offset, what)
          if err
            @cur_offset = err.offset
            xpath_err(err.code)
            return nil
          end
          @cur_offset = pos
          name
        end

        # xmlXPathEvalExpr: compile the expression at +base+ (from the current position) and
        # evaluate it, leaving the result on the value stack. Errors are recorded in #error
        # (and reported), never raised.
        def eval_expr
          return if @context&.last_error && @context.last_error.code != 0

          str = @cur_offset == 0 ? @base : rest
          start = @cur_offset
          comp = XPath.cached_compile(str, @context ? @context.flags : 0)
          if comp.is_a?(CompileError)
            @cur_offset = start + comp.offset
            xpath_err(comp.code)
            return
          end
          @cur_offset = @base.bytesize
          @comp = comp
          ctx = @context
          saved = [ctx.node, ctx.doc, ctx.context_size, ctx.proximity_position, ctx.function,
                   ctx.function_uri, ctx.depth]
          aborted = true
          begin
            run_eval(false)
            aborted = false
          rescue Abort
            # (aborted)
          end
          XPath.restore_context(ctx, saved) if aborted
          nil
        end

        # xmlXPathRoot
        def root
          @value_tab.push(@context.doc ? [@context.doc] : [])
        end

        # run a function (a callable or a fn_* method name) with the XP_ERROR abort caught, the
        # way a C caller sees it return; for callers outside the evaluator (e.g. XPointer calling
        # xmlXPathIdFunction)
        def call_function(f, nargs)
          begin
            f.is_a?(Symbol) ? __send__(f, nargs) : f.call(self, nargs)
          rescue Abort
            # (aborted)
          end
          nil
        end

        # ---- evaluation entry -------------------------------------------------------------

        # xmlXPathRunEval
        def run_eval(to_bool)
          comp = @comp
          if comp.nil? || comp.root.nil?
            xp_error(STACK_ERROR)
          end
          old_depth = @depth
          @sib_memo = nil
          @ns_free = nil
          if to_bool
            res = comp_op_eval_to_boolean(comp.root, false)
            @depth = old_depth
            return res
          end
          comp_op_eval(comp.root)
          @depth = old_depth
          0
        end

        # ---- the evaluator ----------------------------------------------------------------

        # xmlXPathCompOpEval
        def comp_op_eval(op)
          ctx = @context
          xp_error(RECURSION_LIMIT_EXCEEDED) if @depth >= XPATH_MAX_RECURSION_DEPTH
          @depth += 1
          case op.op
          when 10 # OP_COLLECT
            if op.fused && (n = ctx.node) && n.type != NAMESPACE_DECL
              # "axis::test" from the context node: same as pushing the node-set of the context
              # node and running the collector's single-node fast path
              seq = []
              plan = op.plan
              plan[2].call(n, ctx.doc, op.value5, op.value4 ? op_uri(op) : nil, seq, plan[1])
              @value_tab.push(seq)
              @sorted = seq if op.sorted_axis
              @ns_free = seq
            elsif (d = op.dos_op) && (op.impure.nil? || pure_functions?(op.impure))
              comp_op_eval(d.c1)
              node_collect_and_test(d, nil, nil, false)
            elsif (c1 = op.c1)
              comp_op_eval(c1)
              node_collect_and_test(op, nil, nil, false)
            end
          when 17 # OP_SORT
            comp_op_eval(op.c1) if op.c1
            v = @value_tab.last
            if v.is_a?(Array) && v.length > 1 && !v.equal?(@sorted)
              XPath.node_set_sort(v)
            end
          when 9 # OP_NODE
            comp_op_eval(op.c1) if op.c1
            comp_op_eval(op.c2) if op.c2
            n = ctx.node
            @value_tab.push(n.nil? ? [] : (n.type == NAMESPACE_DECL ? [XPath.node_set_dup_ns(n.next, n)] : [n]))
          when 8 # OP_ROOT
            @value_tab.push(ctx.doc ? [ctx.doc] : [])
          when 11 # OP_VALUE
            @value_tab.push(op.value4) # (compiled literals are frozen Strings / Floats)
          when 13 # OP_FUNCTION
            eval_function(op)
          when 14 # OP_ARG
            comp_op_eval(op.c1) if op.c1
            comp_op_eval(op.c2) if op.c2
          when 15, 16 # OP_PREDICATE, OP_FILTER
            eval_filter(op)
          when 1 # OP_AND
            comp_op_eval(op.c1)
            fn_boolean(1)
            v = @value_tab.last
            if v == true
              arg2 = @value_tab.pop
              comp_op_eval(op.c2)
              fn_boolean(1)
              @value_tab[-1] = (@value_tab.last && arg2) unless @value_tab.empty?
            end
          when 2 # OP_OR
            comp_op_eval(op.c1)
            fn_boolean(1)
            v = @value_tab.last
            if !v.nil? && v != true
              arg2 = @value_tab.pop
              comp_op_eval(op.c2)
              fn_boolean(1)
              @value_tab[-1] = (@value_tab.last || arg2) unless @value_tab.empty?
            end
          when 3 # OP_EQUAL
            if (step = op.eq_step) && (n = ctx.node) && n.type != NAMESPACE_DECL
              # the node-set of the step compared with a literal (xmlXPathEqualNodeSetString /
              # xmlXPathEqualNodeSetFloat), without the intermediate value-stack traffic
              seq = []
              plan = step.plan
              plan[2].call(n, ctx.doc, step.value5, step.value4 ? op_uri(step) : nil, seq, plan[1])
              neq = op.value == 0
              v = op.eq_value
              @value_tab.push(v.is_a?(String) ? equal_node_set_string(seq, v, neq) : equal_node_set_float(seq, v, neq))
              @depth -= 1
              return
            end
            comp_op_eval(op.c1)
            comp_op_eval(op.c2)
            equal = op.value != 0 ? equal_values : not_equal_values
            @value_tab.push(equal)
          when 4 # OP_CMP
            comp_op_eval(op.c1)
            comp_op_eval(op.c2)
            @value_tab.push(compare_values(op.value != 0, op.value2 != 0))
          when 5 # OP_PLUS
            comp_op_eval(op.c1)
            comp_op_eval(op.c2) if op.c2
            case op.value
            when 0 then sub_values
            when 1 then add_values
            when 2 then value_flip_sign
            when 3
              cast_top_to_number
              check_type_number
            end
          when 6 # OP_MULT
            comp_op_eval(op.c1)
            comp_op_eval(op.c2)
            case op.value
            when 0 then mult_values
            when 1 then div_values
            when 2 then mod_values
            end
          when 7 # OP_UNION
            comp_op_eval(op.c1)
            comp_op_eval(op.c2)
            arg2 = @value_tab.pop
            arg1 = @value_tab.pop
            if !arg1.instance_of?(Array) || !arg2.instance_of?(Array)
              xp_error(INVALID_TYPE)
            end
            unless arg2.empty?
              @sorted = nil if arg1.equal?(@sorted)
              @ns_free = nil if arg1.equal?(@ns_free)
              XPath.node_set_merge(arg1, arg2)
            end
            @value_tab.push(arg1)
          when 12 # OP_VARIABLE
            eval_variable(op)
          when 0 # OP_END
            # nothing
          else
            xp_error(INVALID_OPERAND)
          end
          @depth -= 1
        end

        # the namespace URI for a COLLECT op's prefix (nil for none / the "*" wildcard)
        def op_uri(op)
          prefix = op.value4
          return nil if prefix.nil? || prefix == WILDCARD_PREFIX

          uri = @context.ns_lookup(prefix)
          xp_error(UNDEF_PREFIX_ERROR) if uri.nil?
          uri
        end

        # do these (prefixed) function calls resolve to side-effect free builtins?
        def pure_functions?(ops)
          ctx = @context
          return false if ctx.func_lookup_func

          i = 0
          while i < ops.length
            f = ops[i]
            i += 1
            uri = ctx.ns_lookup(f.value5)
            return false unless uri && PURE_FUNCS[ctx.function_lookup_ns(f.value4, uri)]
          end
          true
        end

        # Can the arguments +args+ (Op#fast_args) be pushed by #push_fast_args? The steps need
        # a context node that isn't a namespace node, and the ARG chain walk that is skipped must
        # not have hit the recursion limit (its deepest op is a step under the SORT of the first
        # argument, #args + 1 levels down).
        def fast_args_ok?(args)
          (n = @context.node) && n.type != NAMESPACE_DECL &&
            @depth + args.length + 1 < XPATH_MAX_RECURSION_DEPTH
        end

        # the string value of the first argument ([kind, op] of Op#pred_args) as the string
        # predicates see it: evaluated like #push_fast_args, then cast like CAST_TO_STRING
        def pred_hay(arg)
          kind, x = arg
          ctx = @context
          n = ctx.node
          return node_to_string(n) if kind == :node

          seq = []
          plan = x.plan
          plan[2].call(n, ctx.doc, x.value5, x.value4 ? op_uri(x) : nil, seq, plan[1])
          @sorted = seq if x.sorted_axis
          XPath.node_set_sort(seq) if kind == :sorted_step && seq.length > 1 && !seq.equal?(@sorted)
          return +"" if seq.empty?

          XPath.node_set_sort(seq) if seq.length > 1
          node_to_string(seq[0])
        end

        # push the values of the arguments +args+ (Op#fast_args), exactly as evaluating the
        # function's ARG chain would
        def push_fast_args(args)
          ctx = @context
          n = ctx.node
          i = 0
          len = args.length
          while i < len
            kind, x = args[i]
            i += 1
            case kind
            when :value
              @value_tab.push(x.value4)
            when :node
              @value_tab.push([n])
            else
              seq = []
              plan = x.plan
              plan[2].call(n, ctx.doc, x.value5, x.value4 ? op_uri(x) : nil, seq, plan[1])
              @sorted = seq if x.sorted_axis
              if kind == :sorted_step && seq.length > 1 && !seq.equal?(@sorted)
                XPath.node_set_sort(seq)
              end
              @value_tab.push(seq)
            end
          end
        end

        # count(<sibling axis>::test) from +n+ for the fused COLLECT op +st+. The memo lives for
        # one evaluation and is dropped around anything that could run user code (extension
        # functions, variable lookups), the only way the tree can change during an evaluation.
        def count_siblings(st, n)
          uri = st.value4 ? op_uri(st) : nil
          doc = @context.doc
          memos = (@sib_memo ||= {}.compare_by_identity)
          m = memos[st]
          if m.nil? || !m[0].equal?(doc) || m[1] != uri
            m = memos[st] = [doc, uri, {}.compare_by_identity]
          end
          st.count_meth.call(n, doc, st.value5, uri, m[2])
        end

        def eval_variable(op)
          @sib_memo = nil
          comp_op_eval(op.c1) if op.c1
          if op.value5.nil?
            val = @context.variable_lookup(op.value4)
            xp_error(UNDEF_VARIABLE_ERROR) if val.nil?
          else
            uri = @context.ns_lookup(op.value5)
            xp_error(UNDEF_PREFIX_ERROR) if uri.nil?
            val = @context.variable_lookup_ns(op.value4, uri)
            xp_error(UNDEF_VARIABLE_ERROR) if val.nil?
          end
          value_push(val)
        end

        def eval_function(op)
          if (m = op.std_meth)
            if (st = op.count_step) && (n = @context.node) && n.type != NAMESPACE_DECL &&
                @depth + 1 < XPATH_MAX_RECURSION_DEPTH
              # count(sibling-axis::test): the same number the collected node-set would have
              @value_tab.push(count_siblings(st, n).to_f)
              # (the generic path leaves @sorted pointing at the discarded step result)
              @sorted = nil if st.sorted_axis
              check_error!
              return
            end
            if (pr = op.std_pred) && fast_args_ok?(op.pred_args)
              # contains(step, 'literal') & co.: the result, without the value stack traffic
              @value_tab.push(pr.call(pred_hay(op.pred_args[0]), op.pred_args[1][1].value4))
              check_error!
              return
            end
            frame = @value_tab.length
            if (args = op.fast_args) && fast_args_ok?(args)
              push_fast_args(args)
            elsif op.c1
              comp_op_eval(op.c1)
            end
            nargs = op.value
            xp_error(INVALID_OPERAND) if @value_tab.length < frame + nargs
            m.bind_call(self, nargs) # (not __send__ with a varying name: see FastCollect.plan_for)
            check_error!
            xp_error(STACK_ERROR) if @value_tab.length != frame + 1
            return
          end

          ctx = @context
          if (pa = op.pred_args) && (cache = @func_cache) && (entry = cache[op]) &&
              (pr = STRING_PREDICATES[entry[0]]) && fast_args_ok?(pa)
            # a registered string predicate (nokogiri-builtin:css-class) of a context step and a
            # literal, once resolved: its result, without the value stack traffic and the call
            # bookkeeping (whose only lasting effect is on the fields reset here)
            check_error!
            hay = pred_hay(pa[0])
            @sorted = nil
            @ns_free = nil
            @sib_memo = nil
            @value_tab.push(pr.call(hay, pa[1][1].value4))
            return
          end
          frame = @value_tab.length
          if (args = op.fast_args) && fast_args_ok?(args)
            push_fast_args(args)
            check_error!
          elsif op.c1
            comp_op_eval(op.c1)
            check_error!
          end
          nargs = op.value
          xp_error(INVALID_OPERAND) if @value_tab.length < frame + nargs
          cache = (@func_cache ||= {}.compare_by_identity)
          entry = cache[op]
          if entry
            func, uri = entry
          else
            uri = nil
            if op.value5.nil?
              func = ctx.function_lookup(op.value4)
            else
              uri = ctx.ns_lookup(op.value5)
              xp_error(UNDEF_PREFIX_ERROR) if uri.nil?
              func = ctx.function_lookup_ns(op.value4, uri)
            end
            xp_error(UNKNOWN_FUNC_ERROR) if func.nil?
            cache[op] = [func, uri]
          end
          old_func = ctx.function
          old_func_uri = ctx.function_uri
          ctx.function = op.value4
          ctx.function_uri = uri
          @sorted = nil # (an extension function may hand back a reordered node-set)
          @ns_free = nil
          @sib_memo = nil # (and may modify the tree)
          # libxml2 keeps the recursion depth in ctxt->context->depth: publish the live depth
          # so that evaluations nested in the function continue from it
          old_depth = ctx.depth
          ctx.depth = @depth
          func.call(self, nargs)
          @sib_memo = nil
          ctx.depth = old_depth
          ctx.function = old_func
          ctx.function_uri = old_func_uri
          check_error!
          xp_error(STACK_ERROR) if @value_tab.length != frame + 1
        end

        # XPATH_OP_PREDICATE / XPATH_OP_FILTER in xmlXPathCompOpEval
        def eval_filter(op)
          if op.first_one
            first = [nil]
            comp_op_eval_first(op.c1, first)
            v = @value_tab.last
            v.slice!(1..) if v.is_a?(Array) && v.length > 1 # xmlXPathNodeSetClearFromPos(set, 1)
            return
          end
          if op.last_fn
            last = [nil]
            comp_op_eval_last(op.c1, last)
            v = @value_tab.last
            if v.is_a?(Array) && v.length > 1 # xmlXPathNodeSetKeepLast
              keep = v.last
              v.clear
              v << keep
            end
            return
          end
          comp_op_eval(op.c1) if op.c1
          return if op.c2.nil?
          return if @value_tab.empty?

          xp_error(INVALID_TYPE) unless @value_tab.last.instance_of?(Array)
          set = @value_tab.pop
          node_set_filter(set, op.c2, 1, set.length, true)
          @value_tab.push(set)
        end

        # xmlXPathCompOpEvalFirst
        def comp_op_eval_first(op, first)
          ctx = @context
          xp_error(RECURSION_LIMIT_EXCEEDED) if @depth >= XPATH_MAX_RECURSION_DEPTH
          @depth += 1
          case op.op
          when OP_END
            # nothing
          when OP_UNION
            comp_op_eval_first(op.c1, first)
            v = @value_tab.last
            if v.instance_of?(Array) && v.length >= 1
              XPath.node_set_sort(v) if v.length > 1 && !v.equal?(@sorted)
              first[0] = v[0]
            end
            comp_op_eval_first(op.c2, first)
            arg2 = @value_tab.pop
            arg1 = @value_tab.pop
            if !arg1.instance_of?(Array) || !arg2.instance_of?(Array)
              xp_error(INVALID_TYPE)
            end
            unless arg2.empty?
              @sorted = nil if arg1.equal?(@sorted)
              @ns_free = nil if arg1.equal?(@ns_free)
              XPath.node_set_merge(arg1, arg2)
            end
            @value_tab.push(arg1)
          when OP_ROOT
            @value_tab.push(ctx.doc ? [ctx.doc] : [])
          when OP_NODE
            comp_op_eval(op.c1) if op.c1
            comp_op_eval(op.c2) if op.c2
            @value_tab.push(XPath.node_set_create(ctx.node))
          when OP_COLLECT
            if op.c1
              comp_op_eval(op.c1)
              node_collect_and_test(op, first, nil, false)
            end
          when OP_VALUE
            @value_tab.push(XPath.object_copy(op.value4))
          when OP_SORT
            comp_op_eval_first(op.c1, first) if op.c1
            v = @value_tab.last
            XPath.node_set_sort(v) if v.is_a?(Array) && v.length > 1 && !v.equal?(@sorted)
          when OP_FILTER
            comp_op_eval_filter_first(op, first)
          else
            comp_op_eval(op)
          end
          @depth -= 1
        end

        # xmlXPathCompOpEvalLast
        def comp_op_eval_last(op, last)
          ctx = @context
          xp_error(RECURSION_LIMIT_EXCEEDED) if @depth >= XPATH_MAX_RECURSION_DEPTH
          @depth += 1
          case op.op
          when OP_END
            # nothing
          when OP_UNION
            comp_op_eval_last(op.c1, last)
            v = @value_tab.last
            if v.instance_of?(Array) && v.length >= 1
              XPath.node_set_sort(v) if v.length > 1 && !v.equal?(@sorted)
              last[0] = v[-1]
            end
            comp_op_eval_last(op.c2, last)
            arg2 = @value_tab.pop
            arg1 = @value_tab.pop
            if !arg1.instance_of?(Array) || !arg2.instance_of?(Array)
              xp_error(INVALID_TYPE)
            end
            unless arg2.empty?
              @sorted = nil if arg1.equal?(@sorted)
              @ns_free = nil if arg1.equal?(@ns_free)
              XPath.node_set_merge(arg1, arg2)
            end
            @value_tab.push(arg1)
          when OP_ROOT
            @value_tab.push(ctx.doc ? [ctx.doc] : [])
          when OP_NODE
            comp_op_eval(op.c1) if op.c1
            comp_op_eval(op.c2) if op.c2
            @value_tab.push(XPath.node_set_create(ctx.node))
          when OP_COLLECT
            if op.c1
              comp_op_eval(op.c1)
              node_collect_and_test(op, nil, last, false)
            end
          when OP_VALUE
            @value_tab.push(XPath.object_copy(op.value4))
          when OP_SORT
            comp_op_eval_last(op.c1, last) if op.c1
            v = @value_tab.last
            XPath.node_set_sort(v) if v.is_a?(Array) && v.length > 1 && !v.equal?(@sorted)
          else
            comp_op_eval(op)
          end
          @depth -= 1
        end

        # xmlXPathCompOpEvalFilterFirst
        def comp_op_eval_filter_first(op, first)
          if op.last_fn
            last = [nil]
            comp_op_eval_last(op.c1, last)
            v = @value_tab.last
            if v.is_a?(Array) && v.length > 1
              keep = v.last
              v.clear
              v << keep
              first[0] = v[0]
            end
            return
          end
          comp_op_eval(op.c1) if op.c1
          return if op.c2.nil?
          return if @value_tab.empty?

          xp_error(INVALID_TYPE) unless @value_tab.last.instance_of?(Array)
          set = @value_tab.pop
          node_set_filter(set, op.c2, 1, 1, true)
          first[0] = set[0] unless set.empty?
          @value_tab.push(set)
        end

        # xmlXPathCompOpEvalToBoolean
        def comp_op_eval_to_boolean(op, is_predicate)
          while true
            case op.op
            when 0 # OP_END
              return false
            when 11 # OP_VALUE
              res = op.value4
              return is_predicate ? evaluate_predicate_result(res) : XPath.cast_to_boolean(res)
            when 17 # OP_SORT
              return false if op.c1.nil?

              op = op.c1
              next
            when 10 # OP_COLLECT
              return false if op.c1.nil?

              if op.fused && (n = @context.node) && n.type != NAMESPACE_DECL
                plan = op.plan
                return FastCollect.exists?(plan[2], n, @context.doc, op.value5, op.value4 ? op_uri(op) : nil, plan[1])
              end

              comp_op_eval(op.c1)
              node_collect_and_test(op, nil, nil, true)
              res = @value_tab.pop
            when 3 # OP_EQUAL
              if (step = op.eq_step) && (n = @context.node) && n.type != NAMESPACE_DECL &&
                  @depth < XPATH_MAX_RECURSION_DEPTH
                # the fused "step = literal" of comp_op_eval, without the value stack
                seq = []
                plan = step.plan
                plan[2].call(n, @context.doc, step.value5, step.value4 ? op_uri(step) : nil, seq, plan[1])
                v = op.eq_value
                neq = op.value == 0
                return v.is_a?(String) ? equal_node_set_string(seq, v, neq) : equal_node_set_float(seq, v, neq)
              end

              comp_op_eval(op)
              res = @value_tab.pop
            else
              comp_op_eval(op)
              res = @value_tab.pop
            end
            return !res.empty? if res.is_a?(Array)
            return res if res.equal?(true) || res.equal?(false)
            return is_predicate ? evaluate_predicate_result(res) : XPath.cast_to_boolean(res)
          end
        end

        # xmlXPathEvaluatePredicateResult
        def evaluate_predicate_result(res)
          case res
          when true, false then res
          when Float then res == @context.proximity_position
          when Array then !res.empty?
          when String then !res.empty?
          else false
          end
        end

        # xmlXPathNodeSetFilter: filter +set+ in place with the predicate +filter_op+
        def node_set_filter(set, filter_op, min_pos, max_pos, _has_ns_nodes)
          return if set.empty?

          if set.length < min_pos
            set.clear
            return
          end

          ctx = @context
          oldnode = ctx.node
          olddoc = ctx.doc
          oldcs = ctx.context_size
          oldpp = ctx.proximity_position

          n = set.length
          ctx.context_size = n
          i = 0
          j = 0
          pos = 1
          while i < n
            node = set[i]
            ctx.node = node
            ctx.proximity_position = i + 1
            ctx.doc = node.doc if node.type != NAMESPACE_DECL && node.doc

            res = comp_op_eval_to_boolean(filter_op, true)

            if res && pos >= min_pos && pos <= max_pos
              set[j] = node if i != j
              j += 1
            end
            if res
              if pos == max_pos
                i += 1
                break
              end
              pos += 1
            end
            i += 1
          end
          set.slice!(j..) if j < set.length

          ctx.node = oldnode
          ctx.doc = olddoc
          ctx.context_size = oldcs
          ctx.proximity_position = oldpp
        end

        # xmlXPathCompOpEvalPredicate
        def comp_op_eval_predicate(op, set, min_pos, max_pos, has_ns_nodes)
          if op.c1
            xp_error(INVALID_OPERAND) if op.c1.op != OP_PREDICATE
            ctx = @context
            xp_error(RECURSION_LIMIT_EXCEEDED) if @depth >= XPATH_MAX_RECURSION_DEPTH
            @depth += 1
            comp_op_eval_predicate(op.c1, set, 1, set.length, has_ns_nodes)
            @depth -= 1
          end
          node_set_filter(set, op.c2, min_pos, max_pos, has_ns_nodes) if op.c2
        end

        # ---- axes -------------------------------------------------------------------------

        # fake libxslt container (name starting with ' ' or "fake node libxslt")
        def fake_parent?(par)
          par.type == ELEMENT_NODE && (nm = par.name) && (nm.start_with?(" ") || nm == "fake node libxslt")
        end

        # xmlXPathNextChild
        def next_child(cur)
          if cur.nil?
            node = @context.node
            return nil if node.nil?

            case node.type
            when ELEMENT_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE, ENTITY_NODE, PI_NODE,
                 COMMENT_NODE, NOTATION_NODE, DTD_NODE, DOCUMENT_NODE, DOCUMENT_TYPE_NODE,
                 DOCUMENT_FRAG_NODE, HTML_DOCUMENT_NODE
              return node.children
            end
            return nil
          end
          t = cur.type
          return nil if t == DOCUMENT_NODE || t == HTML_DOCUMENT_NODE

          cur.next
        end

        # xmlXPathNextChildElement
        def next_child_element(cur)
          if cur.nil?
            cur = @context.node
            return nil if cur.nil?

            case cur.type
            when ELEMENT_NODE, DOCUMENT_FRAG_NODE, ENTITY_REF_NODE, ENTITY_NODE
              cur = cur.children
              if cur
                return cur if cur.type == ELEMENT_NODE

                while true
                  cur = cur.next
                  break if cur.nil? || cur.type == ELEMENT_NODE
                end
                return cur
              end
              return nil
            when DOCUMENT_NODE, HTML_DOCUMENT_NODE
              return Tree.doc_get_root_element(cur)
            end
            return nil
          end
          case cur.type
          when ELEMENT_NODE, TEXT_NODE, ENTITY_REF_NODE, ENTITY_NODE, CDATA_SECTION_NODE, PI_NODE,
               COMMENT_NODE, XINCLUDE_END
            # ok
          else
            return nil
          end
          nxt = cur.next
          if nxt
            return nxt if nxt.type == ELEMENT_NODE

            cur = nxt
            while true
              cur = cur.next
              break if cur.nil? || cur.type == ELEMENT_NODE
            end
            return cur
          end
          nil
        end

        # xmlXPathNextDescendant
        def next_descendant(cur)
          ctxnode = @context.node
          if cur.nil?
            return nil if ctxnode.nil?

            t = ctxnode.type
            return nil if t == ATTRIBUTE_NODE || t == NAMESPACE_DECL
            return @context.doc.children if ctxnode.equal?(@context.doc)

            return ctxnode.children
          end
          return nil if cur.type == NAMESPACE_DECL

          if (ch = cur.children) && ch.type != ENTITY_DECL
            cur = ch
            return cur if cur.type != DTD_NODE
          end
          return nil if cur.equal?(ctxnode)

          while (nx = cur.next)
            cur = nx
            t = cur.type
            return cur if t != ENTITY_DECL && t != DTD_NODE
          end
          while true
            cur = cur.parent
            break if cur.nil?
            return nil if cur.equal?(ctxnode)
            return cur.next if cur.next
          end
          cur
        end

        # xmlXPathNextDescendantOrSelf
        def next_descendant_or_self(cur)
          return @context.node if cur.nil?

          ctxnode = @context.node
          return nil if ctxnode.nil?

          t = ctxnode.type
          return nil if t == ATTRIBUTE_NODE || t == NAMESPACE_DECL

          next_descendant(cur)
        end

        # xmlXPathNextParent
        def next_parent(cur)
          return nil unless cur.nil?

          node = @context.node
          return nil if node.nil?

          case node.type
          when ELEMENT_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE, ENTITY_NODE, PI_NODE,
               COMMENT_NODE, NOTATION_NODE, DTD_NODE, ELEMENT_DECL, ATTRIBUTE_DECL, XINCLUDE_START,
               XINCLUDE_END, ENTITY_DECL
            par = node.parent
            return @context.doc if par.nil?
            return nil if fake_parent?(par)

            par
          when ATTRIBUTE_NODE
            node.parent
          when DOCUMENT_NODE, DOCUMENT_TYPE_NODE, DOCUMENT_FRAG_NODE, HTML_DOCUMENT_NODE
            nil
          when NAMESPACE_DECL
            nx = node.next
            return nx if nx && nx.type != NAMESPACE_DECL

            nil
          end
        end

        # xmlXPathNextAncestor
        def next_ancestor(cur)
          if cur.nil?
            node = @context.node
            return nil if node.nil?

            case node.type
            when ELEMENT_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE, ENTITY_NODE, PI_NODE,
                 COMMENT_NODE, DTD_NODE, ELEMENT_DECL, ATTRIBUTE_DECL, ENTITY_DECL, NOTATION_NODE,
                 XINCLUDE_START, XINCLUDE_END
              par = node.parent
              return @context.doc if par.nil?
              return nil if fake_parent?(par)

              return par
            when ATTRIBUTE_NODE
              return node.parent
            when DOCUMENT_NODE, DOCUMENT_TYPE_NODE, DOCUMENT_FRAG_NODE, HTML_DOCUMENT_NODE
              return nil
            when NAMESPACE_DECL
              nx = node.next
              return nx if nx && nx.type != NAMESPACE_DECL

              return nil
            end
            return nil
          end
          doc = @context.doc
          return doc if cur.equal?(doc.children)
          return nil if cur.equal?(doc)

          case cur.type
          when ELEMENT_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE, ENTITY_NODE, PI_NODE,
               COMMENT_NODE, NOTATION_NODE, DTD_NODE, ELEMENT_DECL, ATTRIBUTE_DECL, ENTITY_DECL,
               XINCLUDE_START, XINCLUDE_END
            par = cur.parent
            return nil if par.nil?
            return nil if fake_parent?(par)

            par
          when ATTRIBUTE_NODE
            cur.parent
          when NAMESPACE_DECL
            nx = cur.next
            return nx if nx && nx.type != NAMESPACE_DECL

            nil
          end
        end

        # xmlXPathNextAncestorOrSelf
        def next_ancestor_or_self(cur)
          return @context.node if cur.nil?

          next_ancestor(cur)
        end

        # xmlXPathNextFollowingSibling
        def next_following_sibling(cur)
          t = @context.node.type
          return nil if t == ATTRIBUTE_NODE || t == NAMESPACE_DECL
          return nil if cur.equal?(@context.doc)
          return @context.node.next if cur.nil?

          cur.next
        end

        # xmlXPathNextPrecedingSibling
        def next_preceding_sibling(cur)
          t = @context.node.type
          return nil if t == ATTRIBUTE_NODE || t == NAMESPACE_DECL
          return nil if cur.equal?(@context.doc)
          return @context.node.prev if cur.nil?

          cur = cur.prev if cur.prev && cur.prev.type == DTD_NODE
          cur.prev
        end

        # xmlXPathNextFollowing
        def next_following(cur)
          if cur && cur.type != ATTRIBUTE_NODE && cur.type != NAMESPACE_DECL && cur.children
            return cur.children
          end

          if cur.nil?
            cur = @context.node
            if cur.type == ATTRIBUTE_NODE
              cur = cur.parent
            elsif cur.type == NAMESPACE_DECL
              nx = cur.next
              return nil if nx.nil? || nx.type == NAMESPACE_DECL

              cur = nx
            end
          end
          return nil if cur.nil?
          return cur.next if cur.next

          doc = @context.doc
          while true
            cur = cur.parent
            break if cur.nil?
            return nil if cur.equal?(doc)
            return cur.next if cur.next
          end
          cur
        end

        # xmlXPathNextPrecedingInternal
        def next_preceding_internal(cur)
          if cur.nil?
            cur = @context.node
            return nil if cur.nil?

            if cur.type == ATTRIBUTE_NODE
              cur = cur.parent
            elsif cur.type == NAMESPACE_DECL
              nx = cur.next
              return nil if nx.nil? || nx.type == NAMESPACE_DECL

              cur = nx
            end
            @ancestor = cur.parent
          end
          return nil if cur.type == NAMESPACE_DECL

          cur = cur.prev if cur.prev && cur.prev.type == DTD_NODE
          while cur.prev.nil?
            cur = cur.parent
            return nil if cur.nil?
            return nil if cur.equal?(@context.doc.children)
            return cur unless cur.equal?(@ancestor)

            @ancestor = cur.parent
          end
          cur = cur.prev
          cur = cur.last while cur.last
          cur
        end

        # xmlXPathNextNamespace
        def next_namespace(cur)
          ctx = @context
          return nil if ctx.node.type != ELEMENT_NODE

          if cur.nil?
            ctx.tmp_ns_list = Tree.get_ns_list(ctx.doc, ctx.node) || []
            return XML_NAMESPACE
          end
          list = ctx.tmp_ns_list
          if list && !list.empty?
            list.pop
          else
            ctx.tmp_ns_list = nil
            nil
          end
        end

        # xmlXPathNextAttribute
        def next_attribute(cur)
          node = @context.node
          return nil if node.nil?
          return nil if node.type != ELEMENT_NODE

          if cur.nil?
            return nil if node.equal?(@context.doc)

            return node.properties
          end
          cur.next
        end

        def axis_next(axis, cur)
          case axis
          when AXIS_ANCESTOR then next_ancestor(cur)
          when AXIS_ANCESTOR_OR_SELF then next_ancestor_or_self(cur)
          when AXIS_ATTRIBUTE then next_attribute(cur)
          when AXIS_CHILD then next_child(cur)
          when -AXIS_CHILD then next_child_element(cur)
          when AXIS_DESCENDANT then next_descendant(cur)
          when AXIS_DESCENDANT_OR_SELF then next_descendant_or_self(cur)
          when AXIS_FOLLOWING then next_following(cur)
          when AXIS_FOLLOWING_SIBLING then next_following_sibling(cur)
          when AXIS_NAMESPACE then next_namespace(cur)
          when AXIS_PARENT then next_parent(cur)
          when AXIS_PRECEDING then next_preceding_internal(cur)
          when AXIS_PRECEDING_SIBLING then next_preceding_sibling(cur)
          when AXIS_SELF then cur.nil? ? @context.node : nil
          end
        end

        # ---- xmlXPathNodeCollectAndTest -----------------------------------------------------

        # xmlXPathNodeCollectAndTest's context-node loop, for specialised traversals (no
        # first/last limits, not stopping at the first hit, no namespace context nodes)
        def collect_fast_multi(op, plan, context_seq, uri, pred_op, has_predicate_range, has_axis_range,
          max_pos, to_bool, dedup)
          doc = @context.doc
          name = op.value5
          arg = plan[1]
          meth = plan[2]
          out_seq = nil
          seq = []
          merge_state = dedup ? [] : nil
          range_buf = has_axis_range ? [] : nil
          # the child axis yields nothing for a node without children (most context nodes of
          # e.g. "//x[1]" are text nodes)
          child_axis = op.value == AXIS_CHILD
          i = 0
          n = context_seq.length
          while i < n
            cn = context_seq[i]
            i += 1
            next if child_axis && cn.children.nil?

            if has_axis_range
              meth.call(cn, doc, name, uri, range_buf, arg)
              if max_pos >= 1 && range_buf.length >= max_pos
                seq << range_buf[max_pos - 1]
                range_buf.clear
                if out_seq.nil?
                  out_seq = seq
                  seq = []
                elsif dedup
                  merge_and_clear(out_seq, seq, merge_state)
                else
                  out_seq.concat(seq)
                  seq.clear
                end
                break if to_bool
              else
                range_buf.clear
              end
              next
            end

            meth.call(cn, doc, name, uri, seq, arg)
            next if seq.empty?

            if pred_op
              if has_predicate_range
                comp_op_eval_predicate(pred_op, seq, max_pos, max_pos, false)
              else
                comp_op_eval_predicate(pred_op, seq, 1, seq.length, false)
              end
              next if seq.empty?
            end

            if out_seq.nil?
              out_seq = seq
              seq = []
            elsif dedup
              merge_and_clear(out_seq, seq, merge_state)
            else
              out_seq.concat(seq)
              seq.clear
            end
            break if to_bool
          end
          out_seq ||= seq.empty? ? seq : []
          @value_tab.push(out_seq)
          @sorted = out_seq if n == 1 && SORTED_AXES.include?(op.value)
          @ns_free = out_seq
          nil
        end

        # merge +set2+ into +set1+ skipping duplicates (xmlXPathNodeSetMergeAndClear); +state+ keeps
        # identity tables of set1 across calls within one collect.
        def merge_and_clear(set1, set2, state)
          if set1.length * set2.length <= 256 && state[0].nil?
            init_nb = set1.length
            set2.each do |n2|
              skip = false
              j = 0
              while j < init_nb
                n1 = set1[j]
                if n1.equal?(n2)
                  skip = true
                  break
                elsif n1.type == NAMESPACE_DECL && n2.type == NAMESPACE_DECL &&
                    n1.next.equal?(n2.next) && n1.prefix == n2.prefix
                  skip = true
                  break
                end
                j += 1
              end
              set1 << n2 unless skip
            end
          else
            seen = (state[0] ||= {}.compare_by_identity)
            ns_seen = state[1]
            indexed = state[2] || 0
            while indexed < set1.length
              n = set1[indexed]
              seen[n] = true
              if n.type == NAMESPACE_DECL
                ns_seen = (state[1] ||= {})
                ns_seen[[n.next.__id__, n.prefix]] = true
              end
              indexed += 1
            end
            set2.each do |n2|
              next if seen[n2]
              next if ns_seen && n2.type == NAMESPACE_DECL && ns_seen[[n2.next.__id__, n2.prefix]]

              set1 << n2
            end
            state[2] = indexed
          end
          set2.clear
          set1
        end

        # the node-set size at which libxml2's nodeTab can't grow any more (nodeMax doubles from 10
        # and must stay below XPATH_MAX_NODESET_LENGTH)
        NODESET_HARD_LIMIT = 10 * (2**20)

        # axes visiting a bounded, small number of nodes
        BOUNDED_AXES = [AXIS_CHILD, AXIS_ATTRIBUTE, AXIS_SELF, AXIS_FOLLOWING_SIBLING,
                        AXIS_PRECEDING_SIBLING, AXIS_PARENT].freeze

        # axes whose traversal from a single context node yields document order
        SORTED_AXES = [AXIS_CHILD, AXIS_DESCENDANT, AXIS_DESCENDANT_OR_SELF, AXIS_ATTRIBUTE, AXIS_SELF,
                       AXIS_FOLLOWING_SIBLING].freeze

        def node_collect_and_test(op, first, last, to_bool)
          axis = op.value
          test = op.value2
          type = op.value3
          prefix = op.value4
          name = op.value5
          uri = nil
          xpctxt = @context

          obj = @value_tab.last
          xp_error(INVALID_TYPE) unless obj.instance_of?(Array)
          @value_tab.pop

          if prefix && prefix != WILDCARD_PREFIX
            uri = xpctxt.ns_lookup(prefix)
            xp_error(UNDEF_PREFIX_ERROR) if uri.nil?
          end

          # fast path: one context node, no predicate, specialised traversal (identical result;
          # in boolean mode only the emptiness of the result matters)
          if (plan = op.plan) && obj.length == 1 && op.c2.nil? && first.nil? && last.nil? &&
              (!to_bool || axis != AXIS_DESCENDANT && axis != AXIS_DESCENDANT_OR_SELF) &&
              (cn = obj[0]).type != NAMESPACE_DECL
            seq = []
            plan[2].call(cn, xpctxt.doc, name, uri, seq, plan[1])
            @value_tab.push(seq)
            @sorted = seq if SORTED_AXES.include?(axis)
            @ns_free = seq
            return
          end

          dedup = true
          next_axis = axis
          case axis
          when AXIS_ANCESTOR, AXIS_ANCESTOR_OR_SELF, AXIS_PARENT, AXIS_PRECEDING, AXIS_PRECEDING_SIBLING
            first = nil
          when AXIS_ATTRIBUTE, AXIS_NAMESPACE, AXIS_SELF
            first = nil
            last = nil
            dedup = false
          when AXIS_CHILD
            last = nil
            next_axis = -AXIS_CHILD if (test == NODE_TEST_NAME || test == NODE_TEST_ALL) && type == NODE_TYPE_NODE
            dedup = false
          when AXIS_DESCENDANT, AXIS_DESCENDANT_OR_SELF, AXIS_FOLLOWING, AXIS_FOLLOWING_SIBLING
            last = nil
          else
            return
          end

          context_seq = obj
          if context_seq.empty?
            @value_tab.push(obj)
            return
          end

          max_pos = 0
          pred_op = nil
          has_predicate_range = false
          has_axis_range = false
          if (pred = op.c2)
            pred_op = pred
            if op.positional
              max_pos = op.max_pos
              if pred.c1
                pred_op = pred.c1
                has_predicate_range = true
              else
                pred_op = nil
                has_axis_range = true
              end
            end
          end
          break_on_first_hit = to_bool && pred_op.nil?
          fast = first.nil? && last.nil? && !break_on_first_hit ? op.plan : nil
          if fast && (!has_axis_range || BOUNDED_AXES.include?(axis)) &&
              # (namespace nodes are the XmlNs structs)
              (context_seq.equal?(@ns_free) || !context_seq.any?(XmlNs))
            return collect_fast_multi(op, fast, context_seq, uri, pred_op, has_predicate_range,
              has_axis_range, max_pos, to_bool, dedup)
          end
          # with an axis range ([n]) the specialised traversal can't stop early: only use it for
          # the short, bounded axes
          fast = nil if has_axis_range && !BOUNDED_AXES.include?(axis)
          range_buf = [] if fast && has_axis_range

          old_context_node = xpctxt.node
          out_seq = nil
          seq = nil
          merge_state = dedup ? [] : nil
          total = 0
          any_ns = false
          first_node = first && first[0]
          last_node = last && last[0]

          context_idx = 0
          nctx = context_seq.length
          while context_idx < nctx
            xpctxt.node = context_seq[context_idx]
            context_idx += 1
            seq ||= []
            pos = 0
            has_ns_nodes = false
            outcome = nil # nil (normal end), :range_end, :first_hit

            cur = nil
            if fast && (cn = xpctxt.node).type != NAMESPACE_DECL
              if has_axis_range
                # the node at position max_pos among the hits (XP_TEST_HIT with hasAxisRange)
                fast[2].call(cn, xpctxt.doc, name, uri, range_buf, fast[1])
                if max_pos >= 1 && range_buf.length >= max_pos
                  seq << range_buf[max_pos - 1]
                  outcome = :range_end
                end
                range_buf.clear
              else
                fast[2].call(cn, xpctxt.doc, name, uri, seq, fast[1])
              end
              cur = nil
            else
              cur = axis_next(next_axis, cur)
            end
            while cur

              if first_node
                break if first_node.equal?(cur)
                break if total % 256 == 0 && XPath.cmp_nodes_ext(first_node, cur) >= 0
              end
              if last_node
                break if last_node.equal?(cur)
                break if total % 256 == 0 && XPath.cmp_nodes_ext(cur, last_node) >= 0
              end
              total += 1

              hit = nil # :node or :ns
              ctype = cur.type
              case test
              when NODE_TEST_NAME
                if axis == AXIS_ATTRIBUTE
                  if ctype == ATTRIBUTE_NODE && name == cur.name
                    ns = cur.ns
                    if prefix.nil?
                      hit = :node if ns.nil? || ns.prefix.nil?
                    elsif ns && uri == ns.href
                      hit = :node
                    end
                  end
                elsif axis == AXIS_NAMESPACE
                  if ctype == NAMESPACE_DECL && cur.prefix && name && cur.prefix == name
                    hit = :ns
                  end
                elsif ctype == ELEMENT_NODE && name == cur.name
                  ns = cur.ns
                  if prefix.nil?
                    hit = :node if ns.nil?
                  elsif prefix == WILDCARD_PREFIX
                    hit = :node
                  elsif ns && uri == ns.href
                    hit = :node
                  end
                end
              when NODE_TEST_ALL
                if axis == AXIS_ATTRIBUTE
                  if ctype == ATTRIBUTE_NODE
                    if prefix.nil?
                      hit = :node
                    elsif (ns = cur.ns) && uri == ns.href
                      hit = :node
                    end
                  end
                elsif axis == AXIS_NAMESPACE
                  hit = :ns if ctype == NAMESPACE_DECL
                elsif ctype == ELEMENT_NODE
                  if prefix.nil?
                    hit = :node
                  elsif (ns = cur.ns) && uri == ns.href
                    hit = :node
                  end
                end
              when NODE_TEST_TYPE
                if type == NODE_TYPE_NODE
                  case ctype
                  when DOCUMENT_NODE, HTML_DOCUMENT_NODE, ELEMENT_NODE, ATTRIBUTE_NODE, PI_NODE,
                       COMMENT_NODE, CDATA_SECTION_NODE, TEXT_NODE
                    hit = :node
                  when NAMESPACE_DECL
                    if axis == AXIS_NAMESPACE
                      hit = :ns
                    else
                      has_ns_nodes = true
                      hit = :node
                    end
                  end
                elsif ctype == type
                  hit = ctype == NAMESPACE_DECL ? :ns : :node
                elsif type == NODE_TYPE_TEXT && ctype == CDATA_SECTION_NODE
                  hit = :node
                end
              when NODE_TEST_PI
                hit = :node if ctype == PI_NODE && (name.nil? || name == cur.name)
              when NODE_TEST_NONE
                xpctxt.node = old_context_node
                @value_tab.push(out_seq || [])
                return
              end

              if hit.nil?
                cur = axis_next(next_axis, cur)
                next
              end

              if hit == :ns
                has_ns_nodes = true
                if has_axis_range
                  pos += 1
                  if pos == max_pos
                    XPath.node_set_add_ns(seq, xpctxt.node, cur)
                    outcome = :range_end
                    break
                  end
                else
                  XPath.node_set_add_ns(seq, xpctxt.node, cur)
                  if break_on_first_hit
                    outcome = :first_hit
                    break
                  end
                end
              elsif has_axis_range
                pos += 1
                if pos == max_pos
                  seq << (ctype == NAMESPACE_DECL ? XPath.node_set_dup_ns(cur.next, cur) : cur)
                  outcome = :range_end
                  break
                end
              else
                # xmlXPathNodeSetAddUnique fails once the set can't grow past
                # XPATH_MAX_NODESET_LENGTH (e.g. the following axis cycling through entities)
                mem_error if seq.length >= NODESET_HARD_LIMIT
                seq << (ctype == NAMESPACE_DECL ? XPath.node_set_dup_ns(cur.next, cur) : cur)
                if break_on_first_hit
                  outcome = :first_hit
                  break
                end
              end
              cur = axis_next(next_axis, cur)
            end
            any_ns ||= has_ns_nodes

            if outcome == :range_end
              if out_seq.nil?
                out_seq = seq
                seq = nil
              elsif dedup
                merge_and_clear(out_seq, seq, merge_state)
              else
                out_seq.concat(seq)
                seq.clear
              end
              break if to_bool

              next
            elsif outcome == :first_hit
              if out_seq.nil?
                out_seq = seq
                seq = nil
              elsif dedup
                merge_and_clear(out_seq, seq, merge_state)
              else
                out_seq.concat(seq)
                seq.clear
              end
              break
            end

            # apply predicates
            if pred_op && !seq.empty?
              if has_predicate_range
                comp_op_eval_predicate(pred_op, seq, max_pos, max_pos, has_ns_nodes)
              else
                comp_op_eval_predicate(pred_op, seq, 1, seq.length, has_ns_nodes)
              end
            end

            next if seq.empty?

            if out_seq.nil?
              out_seq = seq
              seq = nil
            elsif dedup
              merge_and_clear(out_seq, seq, merge_state)
            else
              out_seq.concat(seq)
              seq.clear
            end
            break if to_bool
          end

          if out_seq.nil?
            out_seq = seq && seq.empty? ? seq : []
          end
          @value_tab.push(out_seq)
          xpctxt.node = old_context_node
          xpctxt.tmp_ns_list = nil

          if nctx == 1 && !any_ns && SORTED_AXES.include?(axis)
            @sorted = out_seq
          end
          nil
        end

        # ---- comparisons / arithmetic -----------------------------------------------------

        # the string-value of +node+ when it is trivially consistent with xmlXPathNodeValHash
        # (single text child / text-like node), else nil
        def simple_string_value(node)
          case node.type
          when 2, 1 # ATTRIBUTE_NODE, ELEMENT_NODE
            c = node.children
            return "" if c.nil?
            return nil unless c.next.nil? && ((t = c.type) == TEXT_NODE || t == CDATA_SECTION_NODE)

            c.content || ""
          when 3, 4, 8, 7 # TEXT, CDATA, COMMENT, PI
            node.content || ""
          end
        end

        # xmlXPathEqualNodeSetString
        def equal_node_set_string(arg, str, neq)
          return false if arg.empty?

          if arg.length == 1 && (v = simple_string_value(arg[0]))
            # (the hash pre-check can't change the outcome for such nodes)
            return neq ? v != str : v == str
          end

          hash = XPath.string_hash(str)
          arg.each do |node|
            if XPath.node_val_hash(node) == hash
              str2 = node_to_string(node)
              if str == str2
                next if neq

                return true
              elsif neq
                return true
              end
            elsif neq
              return true
            end
          end
          false
        end

        # xmlXPathEqualNodeSetFloat
        def equal_node_set_float(arg, f, neq)
          ret = false
          arg.each do |node|
            v = XPath.string_eval_number(node_to_string(node))
            if !v.nan?
              if !neq && v == f
                return true
              elsif neq && v != f
                return true
              end
            elsif neq
              ret = true
            end
          end
          ret
        end

        # xmlXPathEqualNodeSets
        def equal_node_sets(ns1, ns2, neq)
          return false if ns1.empty? || ns2.empty?

          unless neq
            if ns1.length * ns2.length > 64
              ids = {}.compare_by_identity
              ns1.each { |n| ids[n] = true }
              ns2.each { |n| return true if ids[n] }
            else
              ns1.each { |n1| ns2.each { |n2| return true if n1.equal?(n2) } }
            end
          end

          values1 = Array.new(ns1.length)
          values2 = Array.new(ns2.length)
          hashs2 = Array.new(ns2.length)
          ns1.each_with_index do |n1, i|
            h1 = XPath.node_val_hash(n1)
            ns2.each_with_index do |n2, j|
              hashs2[j] = XPath.node_val_hash(n2) if i == 0
              if h1 != hashs2[j]
                return true if neq
              else
                values1[i] ||= node_to_string(n1)
                values2[j] ||= node_to_string(n2)
                ret = (values1[i] == values2[j]) ^ neq
                return true if ret
              end
            end
          end
          false
        end

        # xmlXPathEqualValuesCommon (neither argument is a node-set)
        def equal_values_common(arg1, arg2)
          case arg1
          when true, false
            case arg2
            when true, false then arg1 == arg2
            when Float then arg1 == XPath.cast_number_to_boolean(arg2)
            when String then arg1 == !arg2.empty?
            else false
            end
          when Float
            case arg2
            when true, false then arg2 == XPath.cast_number_to_boolean(arg1)
            when String then equal_numbers(arg1, XPath.string_eval_number(arg2))
            when Float then equal_numbers(arg1, arg2)
            else false
            end
          when String
            case arg2
            when true, false then arg2 == !arg1.empty?
            when String then arg1 == arg2
            when Float then equal_numbers(XPath.string_eval_number(arg1), arg2)
            else false
            end
          else
            false
          end
        end

        def equal_numbers(a, b)
          return false if a.nan? || b.nan?

          a == b
        end

        # xmlXPathEqualValues
        def equal_values
          arg2 = @value_tab.pop
          arg1 = @value_tab.pop
          xp_error(INVALID_OPERAND) if arg1.nil? || arg2.nil?

          if arg1.is_a?(Array) || arg2.is_a?(Array)
            arg1, arg2 = arg2, arg1 unless arg1.is_a?(Array)
            case arg2
            when Array then equal_node_sets(arg1, arg2, false)
            when true, false then !arg1.empty? == arg2
            when Float then equal_node_set_float(arg1, arg2, false)
            when String then equal_node_set_string(arg1, arg2, false)
            else false
            end
          else
            equal_values_common(arg1, arg2)
          end
        end

        # xmlXPathNotEqualValues
        def not_equal_values
          arg2 = @value_tab.pop
          arg1 = @value_tab.pop
          xp_error(INVALID_OPERAND) if arg1.nil? || arg2.nil?

          if arg1.is_a?(Array) || arg2.is_a?(Array)
            arg1, arg2 = arg2, arg1 unless arg1.is_a?(Array)
            case arg2
            when Array then equal_node_sets(arg1, arg2, true)
            when true, false then !arg1.empty? != arg2
            when Float then equal_node_set_float(arg1, arg2, true)
            when String then equal_node_set_string(arg1, arg2, true)
            else false
            end
          else
            !equal_values_common(arg1, arg2)
          end
        end

        # compare two numbers (the non node-set tail of xmlXPathCompareValues)
        def compare_numbers(inf, strict, v1, v2)
          return false if v1.nan? || v2.nan?

          arg1i = XPath.is_inf(v1)
          arg2i = XPath.is_inf(v2)
          if inf && strict
            if (arg1i == -1 && arg2i != -1) || (arg2i == 1 && arg1i != 1)
              true
            elsif arg1i == 0 && arg2i == 0
              v1 < v2
            else
              false
            end
          elsif inf && !strict
            if arg1i == -1 || arg2i == 1
              true
            elsif arg1i == 0 && arg2i == 0
              v1 <= v2
            else
              false
            end
          elsif !inf && strict
            if (arg1i == 1 && arg2i != 1) || (arg2i == -1 && arg1i != -1)
              true
            elsif arg1i == 0 && arg2i == 0
              v1 > v2
            else
              false
            end
          else
            if arg1i == 1 || arg2i == -1
              true
            elsif arg1i == 0 && arg2i == 0
              v1 >= v2
            else
              false
            end
          end
        end

        # xmlXPathCompareValues on two popped values
        def compare_values(inf, strict)
          arg2 = @value_tab.pop
          arg1 = @value_tab.pop
          xp_error(INVALID_OPERAND) if arg1.nil? || arg2.nil?

          compare_objects(inf, strict, arg1, arg2)
        end

        def compare_objects(inf, strict, arg1, arg2)
          if arg1.is_a?(Array) || arg2.is_a?(Array)
            if arg1.is_a?(Array) && arg2.is_a?(Array)
              return compare_node_sets(inf, strict, arg1, arg2)
            elsif arg1.is_a?(Array)
              return compare_node_set_value(inf, strict, arg1, arg2)
            else
              return compare_node_set_value(!inf, strict, arg2, arg1)
            end
          end
          v1 = arg1.is_a?(Float) ? arg1 : cast_to_number_internal(arg1)
          v2 = arg2.is_a?(Float) ? arg2 : cast_to_number_internal(arg2)
          compare_numbers(inf, strict, v1, v2)
        end

        # xmlXPathCompareNodeSetValue
        def compare_node_set_value(inf, strict, arg, val)
          case val
          when Float
            # xmlXPathCompareNodeSetFloat
            arg.each do |node|
              v = XPath.string_eval_number(node_to_string(node))
              return true if compare_numbers(inf, strict, v, val)
            end
            false
          when Array
            compare_node_sets(inf, strict, arg, val)
          when String
            # xmlXPathCompareNodeSetString
            f = XPath.string_eval_number(val)
            arg.each do |node|
              v = XPath.string_eval_number(node_to_string(node))
              return true if compare_numbers(inf, strict, v, f)
            end
            false
          when true, false
            compare_numbers(inf, strict, arg.empty? ? 0.0 : 1.0, val ? 1.0 : 0.0)
          else
            xp_error(INVALID_TYPE)
          end
        end

        # xmlXPathCompareNodeSets
        def compare_node_sets(inf, strict, ns1, ns2)
          return false if ns1.empty? || ns2.empty?

          values2 = nil
          ns1.each do |n1|
            val1 = node_to_number(n1)
            next if val1.nan?

            values2 ||= ns2.map { |n2| node_to_number(n2) }
            values2.each do |v2|
              next if v2.nan?

              ret = if inf && strict
                val1 < v2
              elsif inf && !strict
                val1 <= v2
              elsif !inf && strict
                val1 > v2
              else
                val1 >= v2
              end
              return true if ret
            end
          end
          false
        end

        # xmlXPathValueFlipSign
        def value_flip_sign
          cast_top_to_number
          check_type_number
          @value_tab[-1] = -@value_tab[-1]
        end

        def pop_operand_number
          arg = @value_tab.pop
          xp_error(INVALID_OPERAND) if arg.nil?
          arg.is_a?(Float) ? arg : cast_to_number_internal(arg)
        end

        # xmlXPathAddValues
        def add_values
          val = pop_operand_number
          cast_top_to_number
          check_type_number
          @value_tab[-1] += val
        end

        # xmlXPathSubValues
        def sub_values
          val = pop_operand_number
          cast_top_to_number
          check_type_number
          @value_tab[-1] -= val
        end

        # xmlXPathMultValues
        def mult_values
          val = pop_operand_number
          cast_top_to_number
          check_type_number
          @value_tab[-1] *= val
        end

        # xmlXPathDivValues
        def div_values
          val = pop_operand_number
          cast_top_to_number
          check_type_number
          @value_tab[-1] = @value_tab[-1] / val
        end

        # xmlXPathModValues
        def mod_values
          arg2 = pop_operand_number
          cast_top_to_number
          check_type_number
          arg1 = @value_tab[-1]
          @value_tab[-1] = if arg2 == 0
            NAN
          else
            XPath.fmod(arg1, arg2)
          end
        end
      end

      module_function

      # C fmod semantics (result has the sign of the dividend)
      def fmod(x, y)
        return NAN if x.nan? || y.nan? || x.infinite? || y == 0
        return x if y.infinite?

        r = x.abs % y.abs
        x < 0 || (x == 0 && 1.0 / x < 0) ? -r : r
      end

      # ------------------------------------------------------------------------------------------
      # entry points
      # ------------------------------------------------------------------------------------------

      # xmlXPathNewContext
      def new_context(doc)
        Context.new(doc)
      end

      # xmlXPathNewParserContext
      def new_parser_context(str, context)
        ParserContext.new(context, nil, str.b.force_encoding(::Encoding::UTF_8), 0)
      end

      # xmlXPathCtxtCompile: returns a CompExpr or nil (after reporting the error)
      def ctxt_compile(context, str)
        comp = cached_compile(str, context ? context.flags : 0)
        if comp.is_a?(CompileError)
          pctxt = ParserContext.new(context, nil, str, comp.offset)
          pctxt.xpath_err(comp.code)
          return nil
        end
        comp
      end

      def compile(str)
        ctxt_compile(nil, str)
      end

      # xmlXPathCompiledEvalInternal: returns [res, value]
      def compiled_eval_internal(comp, context, to_bool)
        return [-1, nil] if comp.nil?

        if to_bool
          r = compiled_eval_to_boolean(comp, context)
          return [r, nil]
        end
        [0, compiled_eval(comp, context)]
      end

      def restore_saved(context, node, doc, cs, pp, fn, fn_uri, depth)
        context.node = node
        context.doc = doc
        context.context_size = cs
        context.proximity_position = pp
        context.function = fn
        context.function_uri = fn_uri
        context.depth = depth
        context.tmp_ns_list = nil
      end

      # xmlXPathCompiledEval: the value, or nil after an error
      def compiled_eval(comp, context)
        return nil if comp.nil?

        context.last_error = nil
        pctxt = ParserContext.new(context, comp, nil, 0)
        node = context.node
        doc = context.doc
        cs = context.context_size
        pp = context.proximity_position
        fn = context.function
        fn_uri = context.function_uri
        depth = context.depth
        res_obj = nil
        ok = false
        begin
          pctxt.run_eval(false)
          if pctxt.value_nr != 1
            pctxt.xpath_err(STACK_ERROR)
          else
            res_obj = pctxt.value_pop
          end
          ok = true
        rescue Abort
          # (aborted)
        end
        restore_saved(context, node, doc, cs, pp, fn, fn_uri, depth) unless ok
        pctxt.error == EXPRESSION_OK ? res_obj : nil
      end

      # xmlXPathCompiledEvalToBoolean: 1, 0 or -1
      def compiled_eval_to_boolean(comp, context)
        return -1 if comp.nil?

        context.last_error = nil
        pctxt = ParserContext.new(context, comp, nil, 0)
        node = context.node
        doc = context.doc
        cs = context.context_size
        pp = context.proximity_position
        fn = context.function
        fn_uri = context.function_uri
        depth = context.depth
        res = nil
        ok = false
        begin
          res = pctxt.run_eval(true)
          pctxt.xpath_err(STACK_ERROR) if pctxt.value_nr != 0
          ok = true
        rescue Abort
          # (aborted)
        end
        restore_saved(context, node, doc, cs, pp, fn, fn_uri, depth) unless ok
        return -1 if !ok || pctxt.error != EXPRESSION_OK

        res ? 1 : 0
      end

      def restore_context(context, saved)
        context.node, context.doc, context.context_size, context.proximity_position,
          context.function, context.function_uri, context.depth = saved
        context.tmp_ns_list = nil
      end


      # xmlXPathEval / xmlXPathEvalExpression: returns the value, or nil after reporting an error
      def eval(str, context)
        return nil if context.nil?

        context.last_error = nil
        comp = cached_compile(str, context.flags)
        if comp.is_a?(CompileError)
          pctxt = ParserContext.new(context, nil, str, comp.offset)
          pctxt.xpath_err(comp.code)
          return nil
        end

        pctxt = ParserContext.new(context, comp, str, str.bytesize)
        saved = [context.node, context.doc, context.context_size, context.proximity_position,
                 context.function, context.function_uri, context.depth]
        res = nil
        aborted = true
        begin
          pctxt.run_eval(false)
          if pctxt.value_nr != 1
            pctxt.xpath_err(STACK_ERROR)
          else
            res = pctxt.value_pop
          end
          aborted = false
        rescue Abort
          # (aborted)
        end
        restore_context(context, saved) if aborted
        return nil if pctxt.error != EXPRESSION_OK

        res
      end

      def eval_expression(str, context)
        eval(str, context)
      end

      # xmlXPathNodeEval
      def node_eval(node, str, context)
        return nil if str.nil?
        return nil if set_context_node(node, context) < 0

        eval(str, context)
      end

      # xmlXPathSetContextNode
      def set_context_node(node, context)
        return -1 if node.nil? || context.nil?

        if node.doc.equal?(context.doc)
          context.node = node
          return 0
        end
        -1
      end
    end
  end
end
