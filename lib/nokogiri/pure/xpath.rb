# frozen_string_literal: true

# A pure-Ruby port of libxml2 2.13.9's XPath 1.0 engine (xpath.c).
#
# Representation of XPath values (xmlXPathObject):
#
#   XPATH_NODESET   -> a Ruby Array of tree structs (XmlNode / XmlAttr / XmlDoc / XmlNs)
#   XPATH_XSLT_TREE -> a Pure::XPath::ValueTree (subclass of Array, carries boolval/user)
#   XPATH_STRING    -> a Ruby String (UTF-8). Value strings are never mutated in place.
#   XPATH_NUMBER    -> a Ruby Float
#   XPATH_BOOLEAN   -> true / false
#   XPATH_USERS     -> a Pure::XPath::UserObject
#
# Namespace nodes in node-sets are copies of the XmlNs whose +next+ points at the parent element,
# exactly like xmlXPathNodeSetDupNs.
#
# Public API (libxml2-shaped):
#   Context.new(doc)                        xmlXPathNewContext; #node, #doc, #namespaces (XSLT),
#     #register_ns, #register_variable(_ns), #register_func(_ns) (callables taking (pctxt, nargs)),
#     #register_func_lookup / #register_variable_lookup (callables taking (data, name, ns_uri)),
#     #set_error_handler, #extra, #user_data, #context_size, #proximity_position, #function(_uri)
#   XPath.eval(str, ctx) / eval_expression   xmlXPathEval: value, or nil after reporting the error
#   XPath.ctxt_compile(ctx, str) -> CompExpr xmlXPathCtxtCompile (compiled expressions are cached
#   XPath.compiled_eval(comp, ctx)           and immutable); compiled_eval_to_boolean -> 1/0/-1
#   XPath.new_parser_context(str, ctx)      xmlXPathNewParserContext (XPointer): #eval_expr,
#     #parse_name, #parse_ncname, #cur_byte/#cur_offset/#base, #value_push/#value_pop/#value,
#     #pop_string/number/boolean/node_set, #xpath_err (xmlXPathErr), #xp_error (XP_ERROR), fn_*(nargs)
#   XPath.cmp_nodes, node_set_merge, node_set_sort, node_set_add*, cast_*, format_number,
#   string_eval_number, object_copy, new_value_tree, order_doc_elems
#
# The engine is split into:
#   xpath.rb             constants, node-set primitives, document order, casts, contexts
#   xpath/compiler.rb    the expression parser/compiler (xmlXPathCompileExpr & friends)
#   xpath/evaluator.rb   xmlXPathCompOpEval & friends, xmlXPathNodeCollectAndTest
#   xpath/functions.rb   the XPath 1.0 core function library (+ escape-uri)

module Nokogiri
  module Pure
    module XPath
      # xmlXPathObjectType
      UNDEFINED = 0
      NODESET = 1
      BOOLEAN = 2
      NUMBER = 3
      STRING = 4
      USERS = 8
      XSLT_TREE = 9

      # xmlXPathError
      EXPRESSION_OK = 0
      NUMBER_ERROR = 1
      UNFINISHED_LITERAL_ERROR = 2
      START_LITERAL_ERROR = 3
      VARIABLE_REF_ERROR = 4
      UNDEF_VARIABLE_ERROR = 5
      INVALID_PREDICATE_ERROR = 6
      EXPR_ERROR = 7
      UNCLOSED_ERROR = 8
      UNKNOWN_FUNC_ERROR = 9
      INVALID_OPERAND = 10
      INVALID_TYPE = 11
      INVALID_ARITY = 12
      INVALID_CTXT_SIZE = 13
      INVALID_CTXT_POSITION = 14
      MEMORY_ERROR = 15
      XPTR_SYNTAX_ERROR = 16
      XPTR_RESOURCE_ERROR = 17
      XPTR_SUB_RESOURCE_ERROR = 18
      UNDEF_PREFIX_ERROR = 19
      ENCODING_ERROR = 20
      INVALID_CHAR_ERROR = 21
      INVALID_CTXT = 22
      STACK_ERROR = 23
      FORBID_VARIABLE_ERROR = 24
      OP_LIMIT_EXCEEDED = 25
      RECURSION_LIMIT_EXCEEDED = 26

      # XML_XPATH_EXPRESSION_OK in xmlParserErrors
      XML_XPATH_EXPRESSION_OK = 1200
      XML_ERR_NO_MEMORY = 2

      ERROR_MESSAGES = [
        "Ok\n",
        "Number encoding\n",
        "Unfinished literal\n",
        "Start of literal\n",
        "Expected $ for variable reference\n",
        "Undefined variable\n",
        "Invalid predicate\n",
        "Invalid expression\n",
        "Missing closing curly brace\n",
        "Unregistered function\n",
        "Invalid operand\n",
        "Invalid type\n",
        "Invalid number of arguments\n",
        "Invalid context size\n",
        "Invalid context position\n",
        "Memory allocation error\n",
        "Syntax error\n",
        "Resource error\n",
        "Sub resource error\n",
        "Undefined namespace prefix\n",
        "Encoding error\n",
        "Char out of XML range\n",
        "Invalid or incomplete context\n",
        "Stack usage error\n",
        "Forbidden variable\n",
        "Operation limit exceeded\n",
        "Recursion limit exceeded\n",
        "?? Unknown error ??\n",
      ].freeze
      MAXERRNO = ERROR_MESSAGES.length - 1

      # xmlXPathFlags
      XML_XPATH_CHECKNS = 1 << 0
      XML_XPATH_NOVAR = 1 << 1

      XPATH_MAX_STEPS = 1_000_000
      XPATH_MAX_STACK_DEPTH = 1_000_000
      XPATH_MAX_NODESET_LENGTH = 10_000_000
      XPATH_MAX_RECURSION_DEPTH = 5000

      NAN = Float::NAN
      PINF = Float::INFINITY
      NINF = -Float::INFINITY

      INT_MAX = 2_147_483_647
      INT_MIN = -2_147_483_648

      # the static xmlXPathXMLNamespace (namespace axis always yields it first)
      XML_NAMESPACE = XmlNs.new(XML_XML_NAMESPACE, "xml")

      # XSLT result tree fragment value (XPATH_XSLT_TREE)
      class ValueTree < Array
        attr_accessor :boolval, :user
      end

      # XPATH_USERS value
      class UserObject
        attr_accessor :user

        def initialize(user = nil)
          @user = user
        end
      end

      # callables registered as XPath functions that have no side effects and don't depend on
      # the context position (see Compiler's descendant rewrite); glue code adds to it
      PURE_FUNCS = {}.compare_by_identity

      # XPATH_UNDEFINED value
      UNDEFINED_VALUE = Object.new.freeze

      # xmlXPathContext
      class Context
        attr_accessor :doc, :node, :var_hash, :func_hash, :namespaces, :context_size,
          :proximity_position, :xptr, :here, :origin, :ns_hash, :var_lookup_func,
          :var_lookup_data, :extra, :function, :function_uri, :func_lookup_func,
          :func_lookup_data, :tmp_ns_list, :user_data, :error, :last_error, :debug_node,
          :flags, :op_limit, :op_count, :depth, :user

        def initialize(doc)
          @doc = doc
          @node = nil
          @var_hash = nil
          @func_hash = nil
          @namespaces = nil
          @context_size = -1
          @proximity_position = -1
          @xptr = 0
          @here = nil
          @origin = nil
          @ns_hash = nil
          @var_lookup_func = nil
          @var_lookup_data = nil
          @extra = nil
          @function = nil
          @function_uri = nil
          @func_lookup_func = nil
          @func_lookup_data = nil
          @tmp_ns_list = nil
          @user_data = nil
          @error = nil
          @last_error = nil
          @debug_node = nil
          @flags = 0
          @op_limit = 0
          @op_count = 0
          @depth = 0
          @user = nil
          XPath.register_all_functions(self)
        end

        def ns_nr
          @namespaces ? @namespaces.length : 0
        end

        # xmlXPathRegisterFunc / xmlXPathRegisterFuncNS. +f+ is a callable taking (pctxt, nargs)
        # (or nil to unregister).
        def register_func(name, f = nil, &blk)
          register_func_ns(name, nil, f || blk)
        end

        def register_func_ns(name, ns_uri, f = nil, &blk)
          return -1 if name.nil?

          f ||= blk
          @func_hash = @func_hash ? @func_hash.dup : {} if @func_hash.nil? || @func_hash.frozen?
          key = [name, ns_uri]
          if f.nil?
            return @func_hash.delete(key) ? 0 : -1
          end

          @func_hash[key] = f
          0
        end

        # xmlXPathRegisterFuncLookup: +f+ is a callable taking (data, name, ns_uri) returning a
        # function (callable taking (pctxt, nargs)) or nil.
        def register_func_lookup(f, data = nil)
          @func_lookup_func = f
          @func_lookup_data = data
        end

        # xmlXPathFunctionLookup
        def function_lookup(name)
          function_lookup_ns(name, nil)
        end

        # xmlXPathFunctionLookupNS. With nokogiri's libxml2 patch 0019 ("xpath: Use separate
        # static hash table for standard functions") the XPath 1.0 core functions are looked up
        # first, in a static table, and can't be overridden.
        def function_lookup_ns(name, ns_uri)
          return nil if name.nil?

          if ns_uri.nil? && (sf = STANDARD_FUNCS[name])
            return sf
          end

          if (f = @func_lookup_func)
            ret = f.call(@func_lookup_data, name, ns_uri)
            return ret if ret
          end
          return nil if @func_hash.nil?

          @func_hash[[name, ns_uri]]
        end

        def registered_funcs_cleanup
          @func_hash = nil
        end

        # xmlXPathRegisterVariable / NS. +value+ is an XPath value (nil removes it).
        def register_variable(name, value)
          register_variable_ns(name, nil, value)
        end

        def register_variable_ns(name, ns_uri, value)
          return -1 if name.nil?

          @var_hash ||= {}
          key = [name, ns_uri]
          if value.nil?
            return @var_hash.delete(key) ? 0 : -1
          end

          @var_hash[key] = value
          0
        end

        # xmlXPathRegisterVariableLookup: +f+ takes (data, name, ns_uri) and returns a value or nil
        def register_variable_lookup(f, data = nil)
          @var_lookup_func = f
          @var_lookup_data = data
        end

        # xmlXPathVariableLookup
        def variable_lookup(name)
          if (f = @var_lookup_func)
            return f.call(@var_lookup_data, name, nil)
          end
          variable_lookup_ns(name, nil)
        end

        # xmlXPathVariableLookupNS
        def variable_lookup_ns(name, ns_uri)
          if (f = @var_lookup_func)
            ret = f.call(@var_lookup_data, name, ns_uri)
            return ret unless ret.nil?
          end
          return nil if @var_hash.nil? || name.nil?

          v = @var_hash[[name, ns_uri]]
          v.nil? ? nil : XPath.object_copy(v)
        end

        def registered_variables_cleanup
          @var_hash = nil
        end

        # xmlXPathRegisterNs
        def register_ns(prefix, ns_uri)
          return -1 if prefix.nil? || prefix.empty?

          @ns_hash = @ns_hash ? @ns_hash.dup : {} if @ns_hash.nil? || @ns_hash.frozen?
          if ns_uri.nil?
            return @ns_hash.delete(prefix) ? 0 : -1
          end

          @ns_hash[prefix.dup.freeze] = ns_uri.dup.freeze
          0
        end

        # xmlXPathNsLookup
        def ns_lookup(prefix)
          return nil if prefix.nil?
          return XML_XML_NAMESPACE if prefix == "xml"

          if (nss = @namespaces)
            nss.each do |ns|
              return ns.href if ns && ns.prefix == prefix
            end
          end
          @ns_hash&.[](prefix)
        end

        def registered_ns_cleanup
          @ns_hash = nil
        end

        # xmlXPathSetErrorHandler: +handler+ is a callable taking an XmlError
        def set_error_handler(handler, data = nil)
          @error = handler
          @user_data = data
        end
      end

      module_function

      # ------------------------------------------------------------------------------------------
      # value helpers
      # ------------------------------------------------------------------------------------------

      # the xmlXPathObjectType of a value
      def type_of(v)
        case v
        when ValueTree then XSLT_TREE
        when Array then NODESET
        when String then STRING
        when Float then NUMBER
        when true, false then BOOLEAN
        when UserObject then USERS
        else UNDEFINED
        end
      end

      def node_set?(v)
        v.is_a?(Array)
      end

      # xmlXPathNewNodeSet / xmlXPathNewValueTree
      def new_node_set(val)
        node_set_create(val)
      end

      def new_value_tree(val)
        t = ValueTree.new
        t << node_set_dup_ns(val.next, val) if val && val.type == NAMESPACE_DECL
        t << val if val && val.type != NAMESPACE_DECL
        t.boolval = false
        t
      end

      # xmlXPathObjectCopy
      def object_copy(val)
        case val
        when ValueTree
          t = ValueTree.new(node_set_merge(nil, val))
          t.boolval = false
          t.user = val.user
          t
        when Array then node_set_merge(nil, val)
        when UserObject then UserObject.new(val.user)
        else val
        end
      end

      # ------------------------------------------------------------------------------------------
      # errors
      # ------------------------------------------------------------------------------------------

      # xmlXPathErr for a parser context (+pctxt+ may be nil). Reports through the context's
      # error handler if set, else through the global structured handler.
      def report_error(context, code, base, offset)
        code = MAXERRNO if code < 0 || code > MAXERRNO
        err = XmlError.new(
          domain: Domain::XPATH,
          code: code + XML_XPATH_EXPRESSION_OK,
          message: ERROR_MESSAGES[code],
          level: Level::ERROR,
          str1: base,
          int1: offset,
          node: context&.debug_node,
        )
        if context
          context.last_error = err
          if (h = context.error)
            h.call(err)
            return err
          end
        end
        Errors.report(err)
      end

      # xmlXPathErrMemory
      def report_memory_error(context)
        err = XmlError.new(domain: Domain::XPATH, code: XML_ERR_NO_MEMORY, message: nil, level: Level::FATAL)
        if context
          context.last_error = err
          if (h = context.error)
            h.call(err)
            return err
          end
        end
        Errors.report(err)
      end

      # ------------------------------------------------------------------------------------------
      # number formatting / parsing
      # ------------------------------------------------------------------------------------------

      # xmlXPathIsInf
      def is_inf(val)
        if val.infinite?
          val > 0 ? 1 : -1
        else
          0
        end
      end

      # xmlXPathFormatNumber / xmlXPathCastNumberToString
      def format_number(number)
        if number.nan?
          return +"NaN"
        elsif number.infinite?
          return number > 0 ? +"Infinity" : +"-Infinity"
        elsif number == 0
          return +"0"
        elsif number > INT_MIN && number < INT_MAX && number == number.to_i
          return number.to_i.to_s
        end

        absolute_value = number.abs
        if (absolute_value > 1e9 || absolute_value < 1e-5) && absolute_value != 0.0
          # scientific notation: "%*.*e" with integer_place = DBL_DIG + EXPONENT_DIGITS + 1,
          # fraction_place = DBL_DIG - 1
          work = format("%21.14e", number)
          size = work.length
          size -= 1 while size > 0 && work[size] != "e"
        else
          if absolute_value > 0.0
            integer_place = Math.log10(absolute_value).to_i
            fraction_place = integer_place > 0 ? 15 - integer_place - 1 : 15 - integer_place
          else
            fraction_place = 1
          end
          work = format("%0.*f", fraction_place, number)
          size = work.length
        end
        # remove leading spaces
        lead = 0
        lead += 1 while work.getbyte(lead) == 0x20
        if lead > 0
          work = work[lead..]
          size -= lead
        end
        # remove fractional trailing zeroes
        after_fraction = size
        ptr = after_fraction - 1
        ptr -= 1 while work.getbyte(ptr) == 0x30
        ptr += 1 if work.getbyte(ptr) != 0x2E
        work[0, ptr] + work[after_fraction..]
      end

      def cast_number_to_string(val)
        format_number(val)
      end

      # xmlXPathStringEvalNumber
      def string_eval_number(str)
        return 0.0 if str.nil?

        len = str.bytesize
        cur = 0
        c = str.getbyte(cur)
        while c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
          cur += 1
          c = str.getbyte(cur)
        end
        isneg = false
        if c == 0x2D
          isneg = true
          cur += 1
          c = str.getbyte(cur)
        end
        return NAN if c != 0x2E && (c.nil? || c < 0x30 || c > 0x39)

        ret = 0.0
        ok = false
        while c && c >= 0x30 && c <= 0x39
          ret *= 10
          ok = true
          ret += (c - 0x30).to_f
          cur += 1
          c = str.getbyte(cur)
        end
        if c == 0x2E
          cur += 1
          c = str.getbyte(cur)
          return NAN if (c.nil? || c < 0x30 || c > 0x39) && !ok

          frac = 0
          fraction = 0.0
          while c == 0x30
            frac += 1
            cur += 1
            c = str.getbyte(cur)
          end
          max = frac + 20
          while c && c >= 0x30 && c <= 0x39 && frac < max
            fraction = fraction * 10 + (c - 0x30)
            frac += 1
            cur += 1
            c = str.getbyte(cur)
          end
          fraction /= 10.0**frac
          ret += fraction
          while c && c >= 0x30 && c <= 0x39
            cur += 1
            c = str.getbyte(cur)
          end
        end
        exponent = 0
        is_exponent_negative = false
        if c == 0x65 || c == 0x45
          cur += 1
          c = str.getbyte(cur)
          if c == 0x2D
            is_exponent_negative = true
            cur += 1
            c = str.getbyte(cur)
          elsif c == 0x2B
            cur += 1
            c = str.getbyte(cur)
          end
          while c && c >= 0x30 && c <= 0x39
            exponent = exponent * 10 + (c - 0x30) if exponent < 1_000_000
            cur += 1
            c = str.getbyte(cur)
          end
        end
        while c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
          cur += 1
          c = str.getbyte(cur)
        end
        return NAN if cur < len

        ret = -ret if isneg
        exponent = -exponent if is_exponent_negative
        ret * (10.0**exponent)
      end

      def cast_string_to_number(val)
        string_eval_number(val)
      end

      # ------------------------------------------------------------------------------------------
      # casts (public API variants; nil string means "memory error" in libxml2)
      # ------------------------------------------------------------------------------------------

      def cast_boolean_to_string(val)
        val ? +"true" : +"false"
      end

      # xmlXPathCastNodeToString (xmlNodeGetContent). Returns nil for nodes without content.
      def cast_node_to_string(node)
        Tree.node_get_content(node)
      end

      # xmlXPathCastNodeSetToString (sorts the set in place like libxml2)
      def cast_node_set_to_string(ns)
        return +"" if ns.nil? || ns.empty?

        node_set_sort(ns) if ns.length > 1
        cast_node_to_string(ns[0])
      end

      # xmlXPathCastToString
      def cast_to_string(val)
        case val
        when String then val
        when Array then cast_node_set_to_string(val)
        when Float then format_number(val)
        when true then +"true"
        when false then +"false"
        else +""
        end
      end

      def cast_boolean_to_number(val)
        val ? 1.0 : 0.0
      end

      def cast_node_to_number(node)
        return NAN if node.nil?

        s = cast_node_to_string(node)
        return NAN if s.nil?

        string_eval_number(s)
      end

      def cast_node_set_to_number(ns)
        return NAN if ns.nil?

        string_eval_number(cast_node_set_to_string(ns))
      end

      # xmlXPathCastToNumber
      def cast_to_number(val)
        case val
        when Float then val
        when String then string_eval_number(val)
        when Array then string_eval_number(cast_node_set_to_string(val))
        when true then 1.0
        when false then 0.0
        else NAN
        end
      end

      def cast_number_to_boolean(val)
        !(val.nan? || val == 0.0)
      end

      def cast_string_to_boolean(val)
        !(val.nil? || val.empty?)
      end

      def cast_node_set_to_boolean(ns)
        !(ns.nil? || ns.empty?)
      end

      # xmlXPathCastToBoolean
      def cast_to_boolean(val)
        case val
        when true, false then val
        when Array then !val.empty?
        when String then !val.empty?
        when Float then !(val.nan? || val == 0.0)
        else false
        end
      end

      def convert_string(val) = cast_to_string(val)
      def convert_number(val) = val.nil? ? 0.0 : cast_to_number(val)
      def convert_boolean(val) = val.nil? ? false : cast_to_boolean(val)

      # xmlXPathEvalPredicate (public, used by XSLT)
      def eval_predicate(context, res)
        case res
        when true, false then res
        when Float then res == context.proximity_position
        when Array then !res.empty?
        when String then !res.empty?
        else false
        end
      end

      # ------------------------------------------------------------------------------------------
      # node-set primitives
      # ------------------------------------------------------------------------------------------

      # xmlXPathNodeSetDupNs
      def node_set_dup_ns(node, ns)
        return nil if ns.nil? || ns.type != NAMESPACE_DECL
        return ns if node.nil? || node.type == NAMESPACE_DECL

        cur = XmlNs.new(ns.href&.dup, ns.prefix&.dup)
        cur.next = node
        cur
      end

      # xmlXPathNodeSetFreeNs: nothing to free in Ruby

      # xmlXPathNodeSetCreate
      def node_set_create(val = nil)
        return [] if val.nil?
        return [node_set_dup_ns(val.next, val)] if val.type == NAMESPACE_DECL

        [val]
      end

      # xmlXPathNodeSetContains
      def node_set_contains(cur, val)
        return false if cur.nil? || val.nil?

        if val.type == NAMESPACE_DECL
          cur.each do |n|
            next unless n.type == NAMESPACE_DECL
            return true if n.equal?(val)
            return true if val.next && n.next.equal?(val.next) && n.prefix == val.prefix
          end
        else
          cur.each { |n| return true if n.equal?(val) }
        end
        false
      end

      # xmlXPathNodeSetAddNs
      def node_set_add_ns(cur, node, ns)
        return -1 if cur.nil? || ns.nil? || node.nil? || ns.type != NAMESPACE_DECL || node.type != ELEMENT_NODE

        cur.each do |n|
          return 0 if n.type == NAMESPACE_DECL && n.next.equal?(node) && ns.prefix == n.prefix
        end
        cur << node_set_dup_ns(node, ns)
        0
      end

      # xmlXPathNodeSetAdd
      def node_set_add(cur, val)
        return -1 if cur.nil? || val.nil?

        cur.each { |n| return 0 if n.equal?(val) }
        cur << (val.type == NAMESPACE_DECL ? node_set_dup_ns(val.next, val) : val)
        0
      end

      # xmlXPathNodeSetAddUnique
      def node_set_add_unique(cur, val)
        return -1 if cur.nil? || val.nil?

        cur << (val.type == NAMESPACE_DECL ? node_set_dup_ns(val.next, val) : val)
        0
      end

      # xmlXPathNodeSetMerge(val1, val2): all nodes of val2 not already in val1 (as it was on entry)
      # are appended to val1 (created if nil). Returns val1.
      def node_set_merge(val1, val2)
        val1 ||= []
        return val1 if val2.nil? || val2.empty?

        if val1.empty?
          # nothing to check against (duplicates *within* val2 are kept, like libxml2)
          val2.each do |n2|
            val1 << (n2.type == NAMESPACE_DECL ? node_set_dup_ns(n2.next, n2) : n2)
          end
          return val1
        end

        if val1.length * val2.length <= 64
          init_nr = val1.length
          val2.each do |n2|
            skip = false
            j = 0
            while j < init_nr
              n1 = val1[j]
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
            next if skip

            val1 << (n2.type == NAMESPACE_DECL ? node_set_dup_ns(n2.next, n2) : n2)
          end
          return val1
        end

        seen, ns_seen = membership_tables(val1)
        val2.each do |n2|
          next if seen[n2]
          if n2.type == NAMESPACE_DECL
            next if ns_seen && ns_seen[[n2.next.__id__, n2.prefix]]

            val1 << node_set_dup_ns(n2.next, n2)
          else
            val1 << n2
          end
        end
        val1
      end

      # identity membership tables for fast duplicate checks
      def membership_tables(set)
        seen = {}.compare_by_identity
        ns_seen = nil
        set.each do |n|
          seen[n] = true
          if n.type == NAMESPACE_DECL
            ns_seen ||= {}
            ns_seen[[n.next.__id__, n.prefix]] = true
          end
        end
        [seen, ns_seen]
      end

      # xmlXPathNodeSetDel
      def node_set_del(cur, val)
        return if cur.nil? || val.nil?

        idx = cur.index { |n| n.equal?(val) }
        cur.delete_at(idx) if idx
      end

      # xmlXPathNodeSetRemove
      def node_set_remove(cur, val)
        return if cur.nil? || val >= cur.length

        cur.delete_at(val)
      end

      # ------------------------------------------------------------------------------------------
      # document order
      # ------------------------------------------------------------------------------------------

      # the document-order stamp set by xmlXPathOrderDocElems (stored in element->content as a
      # negative number), or nil
      def doc_order(node)
        c = node.content
        c.is_a?(Integer) && c < 0 ? -c : nil
      end

      # xmlXPathOrderDocElems
      def order_doc_elems(doc)
        return -1 if doc.nil?

        count = 0
        cur = doc.children
        while cur
          if cur.type == ELEMENT_NODE
            count += 1
            cur.content = -count
            if cur.children
              cur = cur.children
              next
            end
          end
          if cur.next
            cur = cur.next
            next
          end
          while true
            cur = cur.parent
            break if cur.nil?
            if cur.equal?(doc)
              cur = nil
              break
            end
            if cur.next
              cur = cur.next
              break
            end
          end
        end
        count
      end

      # xmlXPathCmpNodes: 1 if node1 is before node2 in document order, 0 if the same node, -1 if
      # after, -2 on error.
      def cmp_nodes(node1, node2)
        return -2 if node1.nil? || node2.nil?
        return 0 if node1.equal?(node2)

        attr1 = attr2 = false
        attr_node1 = attr_node2 = nil
        if node1.type == ATTRIBUTE_NODE
          attr1 = true
          attr_node1 = node1
          node1 = node1.parent
        end
        if node2.type == ATTRIBUTE_NODE
          attr2 = true
          attr_node2 = node2
          node2 = node2.parent
        end
        if node1.equal?(node2)
          if attr1 == attr2
            if attr1
              cur = attr_node2.prev
              while cur
                return 1 if cur.equal?(attr_node1)

                cur = cur.prev
              end
              return -1
            end
            return 0
          end
          return 1 if attr2

          return -1
        end
        # (in C a NULL attribute parent would crash; treat as error)
        return -2 if node1.nil? || node2.nil?
        return 1 if node1.type == NAMESPACE_DECL || node2.type == NAMESPACE_DECL
        return 1 if node1.equal?(node2.prev)
        return -1 if node1.equal?(node2.next)

        if node1.type == ELEMENT_NODE && node2.type == ELEMENT_NODE &&
            (l1 = doc_order(node1)) && (l2 = doc_order(node2)) && node1.doc.equal?(node2.doc)
          return 1 if l1 < l2
          return -1 if l1 > l2
        end

        depth2 = 0
        cur = node2
        while (par = cur.parent)
          return 1 if par.equal?(node1)

          depth2 += 1
          cur = par
        end
        root = cur
        depth1 = 0
        cur = node1
        while (par = cur.parent)
          return -1 if par.equal?(node2)

          depth1 += 1
          cur = par
        end
        return -2 unless root.equal?(cur)

        while depth1 > depth2
          depth1 -= 1
          node1 = node1.parent
        end
        while depth2 > depth1
          depth2 -= 1
          node2 = node2.parent
        end
        until node1.parent.equal?(node2.parent)
          node1 = node1.parent
          node2 = node2.parent
          return -2 if node1.nil? || node2.nil?
        end
        return 1 if node1.equal?(node2.prev)
        return -1 if node1.equal?(node2.next)

        if node1.type == ELEMENT_NODE && node2.type == ELEMENT_NODE &&
            (l1 = doc_order(node1)) && (l2 = doc_order(node2)) && node1.doc.equal?(node2.doc)
          return 1 if l1 < l2
          return -1 if l1 > l2
        end

        cur = node1.next
        while cur
          return 1 if cur.equal?(node2)

          cur = cur.next
        end
        -1
      end

      # xmlXPathCmpNodesExt (the comparison used for sorting node-sets)
      def cmp_nodes_ext(node1, node2)
        return -2 if node1.nil? || node2.nil?
        return 0 if node1 == node2

        misc = false
        precedence1 = precedence2 = 0
        misc_node1 = misc_node2 = nil

        t1 = node1.type
        case t1
        when ELEMENT_NODE
          if node2.type == ELEMENT_NODE
            # (doc_order inlined: stamps are negative Integers in content)
            c1 = node1.content
            if c1.is_a?(Integer) && c1 < 0 && (c2 = node2.content).is_a?(Integer) && c2 < 0 &&
                node1.doc.equal?(node2.doc)
              return 1 if c1 > c2
              return -1 if c1 < c2
            end
            return cmp_turtle(node1, node2)
          end
        when ATTRIBUTE_NODE
          precedence1 = 1
          misc_node1 = node1
          node1 = node1.parent
          misc = true
        when TEXT_NODE, CDATA_SECTION_NODE, COMMENT_NODE, PI_NODE
          misc_node1 = node1
          if node1.prev
            while true
              node1 = node1.prev
              if node1.type == ELEMENT_NODE
                precedence1 = 3
                break
              end
              if node1.prev.nil?
                precedence1 = 2
                node1 = node1.parent
                break
              end
            end
          else
            precedence1 = 2
            node1 = node1.parent
          end
          if node1.nil? || node1.type != ELEMENT_NODE || doc_order(node1).nil?
            node1 = misc_node1
            precedence1 = 0
          else
            misc = true
          end
        when NAMESPACE_DECL
          return 1
        end

        case node2.type
        when ATTRIBUTE_NODE
          precedence2 = 1
          misc_node2 = node2
          node2 = node2.parent
          misc = true
        when TEXT_NODE, CDATA_SECTION_NODE, COMMENT_NODE, PI_NODE
          misc_node2 = node2
          if node2.prev
            while true
              node2 = node2.prev
              if node2.type == ELEMENT_NODE
                precedence2 = 3
                break
              end
              if node2.prev.nil?
                precedence2 = 2
                node2 = node2.parent
                break
              end
            end
          else
            precedence2 = 2
            node2 = node2.parent
          end
          if node2.nil? || node2.type != ELEMENT_NODE || doc_order(node2).nil?
            node2 = misc_node2
            precedence2 = 0
          else
            misc = true
          end
        when NAMESPACE_DECL
          return 1
        end

        if misc
          if node1 == node2
            if precedence1 == precedence2
              cur = misc_node2.prev
              while cur
                return 1 if cur == misc_node1
                return -1 if cur.type == ELEMENT_NODE

                cur = cur.prev
              end
              return -1
            else
              return precedence1 < precedence2 ? 1 : -1
            end
          end
          if precedence2 == 3 && precedence1 > 1
            cur = node1.parent
            while cur
              return 1 if cur == node2

              cur = cur.parent
            end
          end
          if precedence1 == 3 && precedence2 > 1
            cur = node2.parent
            while cur
              return -1 if cur == node1

              cur = cur.parent
            end
          end
        end

        # (an attribute without parent would crash libxml2)
        return -2 if node1.nil? || node2.nil?

        if node1.type == ELEMENT_NODE && node2.type == ELEMENT_NODE &&
            (l1 = doc_order(node1)) && (l2 = doc_order(node2)) && node1.doc.equal?(node2.doc)
          return 1 if l1 < l2
          return -1 if l1 > l2
        end

        cmp_turtle(node1, node2)
      end

      # the "turtle_comparison" tail of xmlXPathCmpNodesExt
      def cmp_turtle(node1, node2)
        return 1 if node1 == node2.prev
        return -1 if node1 == node2.next

        # Nodes at the same depth (the common case when sorting the result of a location path):
        # climb both chains in lockstep to the first level where the parents coincide. Neither
        # node can then be an ancestor of the other, the roots are the same unless both chains
        # end without meeting, and the nodes reached are exactly the ones the depth-aligning loop
        # below stops at. Chains of different lengths take the general route.
        x = node1
        y = node2
        while true
          px = x.parent
          py = y.parent
          break if px == py

          if px.nil? || py.nil?
            x = nil
            break
          end
          x = px
          y = py
        end
        if x
          return -2 if px.nil?

          return 1 if x == y.prev
          return -1 if x == y.next

          if (c1 = x.content).is_a?(Integer) && c1 < 0 && x.type == ELEMENT_NODE && y.type == ELEMENT_NODE &&
              (c2 = y.content).is_a?(Integer) && c2 < 0 && x.doc.equal?(y.doc)
            return 1 if c1 > c2
            return -1 if c1 < c2
          end

          cur = x.next
          while cur
            return 1 if cur == y

            cur = cur.next
          end
          return -1
        end

        depth2 = 0
        cur = node2
        while (par = cur.parent)
          return 1 if par == node1

          depth2 += 1
          cur = par
        end
        root = cur
        depth1 = 0
        cur = node1
        while (par = cur.parent)
          return -1 if par == node2

          depth1 += 1
          cur = par
        end
        return -2 unless root == cur

        while depth1 > depth2
          depth1 -= 1
          node1 = node1.parent
        end
        while depth2 > depth1
          depth2 -= 1
          node2 = node2.parent
        end
        until node1.parent.equal?(node2.parent)
          node1 = node1.parent
          node2 = node2.parent
          return -2 if node1.nil? || node2.nil?
        end
        return 1 if node1 == node2.prev
        return -1 if node1 == node2.next

        if node1.type == ELEMENT_NODE && node2.type == ELEMENT_NODE &&
            (l1 = doc_order(node1)) && (l2 = doc_order(node2)) && node1.doc.equal?(node2.doc)
          return 1 if l1 < l2
          return -1 if l1 > l2
        end

        cur = node1.next
        while cur
          return 1 if cur == node2

          cur = cur.next
        end
        -1
      end

      # wrap_cmp: the comparator handed to timsort
      def wrap_cmp(x, y)
        res = cmp_nodes_ext(x, y)
        res == -2 ? res : -res
      end

      # xmlXPathNodeSetSort: libxml2's timsort (timsort.h) with xmlXPathCmpNodesExt
      def node_set_sort(set)
        return if set.nil?

        size = set.length
        return if size <= 1
        # (both sorts leave a sorted set alone, having compared each adjacent pair once)
        return set if presorted?(set)

        if size < 64
          binary_insertion_sort_start(set, 0, 1, size)
        else
          tim_sort(set, size)
        end
        set
      end

      # Is every adjacent pair of +set+ in order for wrap_cmp (<= 0)? Element pairs take
      # cmp_nodes_ext's element branch inline.
      def presorted?(set)
        i = 1
        n = set.length
        while i < n
          a = set[i - 1]
          b = set[i]
          i += 1
          if a && b && a.type == ELEMENT_NODE && b.type == ELEMENT_NODE
            next if a == b

            c1 = a.content
            if c1.is_a?(Integer) && c1 < 0 && (c2 = b.content).is_a?(Integer) && c2 < 0 && a.doc.equal?(b.doc)
              next if c1 > c2
              return false if c1 < c2
            end
            return false if cmp_turtle(a, b) == -1
          elsif wrap_cmp(a, b) > 0
            return false
          end
        end
        true
      end

      # BINARY_INSERTION_FIND on dst[base, size]
      def binary_insertion_find(dst, base, x, size)
        l = 0
        r = size - 1
        c = r >> 1
        if wrap_cmp(x, dst[base]) < 0
          return 0
        elsif wrap_cmp(x, dst[base + r]) > 0
          return r
        end

        cx = dst[base + c]
        while true
          val = wrap_cmp(x, cx)
          if val < 0
            return c if c - l <= 1

            r = c
          else
            return c + 1 if r - c <= 1

            l = c
          end
          c = l + ((r - l) >> 1)
          cx = dst[base + c]
        end
      end

      # BINARY_INSERTION_SORT_START on dst[base, size]
      def binary_insertion_sort_start(dst, base, start, size)
        i = start
        while i < size
          if wrap_cmp(dst[base + i - 1], dst[base + i]) <= 0
            i += 1
            next
          end
          x = dst[base + i]
          location = binary_insertion_find(dst, base, x, i)
          j = i - 1
          while j >= location
            dst[base + j + 1] = dst[base + j]
            break if j == 0

            j -= 1
          end
          dst[base + location] = x
          i += 1
        end
      end

      def compute_minrun(size)
        top_bit = size.bit_length
        shift = [top_bit, 6].max - 6
        minrun = size >> shift
        mask = (1 << shift) - 1
        (mask & size) != 0 ? minrun + 1 : minrun
      end

      def reverse_elements(dst, start, finish)
        while start < finish
          dst[start], dst[finish] = dst[finish], dst[start]
          start += 1
          finish -= 1
        end
      end

      def count_run(dst, start, size)
        return 1 if size - start == 1

        if start >= size - 2
          if wrap_cmp(dst[size - 2], dst[size - 1]) > 0
            dst[size - 2], dst[size - 1] = dst[size - 1], dst[size - 2]
          end
          return 2
        end
        curr = start + 2
        if wrap_cmp(dst[start], dst[start + 1]) <= 0
          last = size - 1
          while curr != last
            break if wrap_cmp(dst[curr - 1], dst[curr]) > 0

            curr += 1
          end
          curr - start
        else
          last = size - 1
          while curr != last
            break if wrap_cmp(dst[curr - 1], dst[curr]) <= 0

            curr += 1
          end
          reverse_elements(dst, start, curr - 1)
          curr - start
        end
      end

      def check_invariant(stack, stack_curr)
        return true if stack_curr < 2

        if stack_curr == 2
          a1 = stack[stack_curr - 2][1]
          b1 = stack[stack_curr - 1][1]
          return a1 > b1
        end
        a = stack[stack_curr - 3][1]
        b = stack[stack_curr - 2][1]
        c = stack[stack_curr - 1][1]
        !(a <= b + c || b <= c)
      end

      def tim_sort_merge(dst, stack, stack_curr)
        a = stack[stack_curr - 2][1]
        b = stack[stack_curr - 1][1]
        curr = stack[stack_curr - 2][0]
        if a < b
          storage = dst[curr, a]
          i = 0
          j = curr + a
          k = curr
          while k < curr + a + b
            if i < a && j < curr + a + b
              if wrap_cmp(storage[i], dst[j]) <= 0
                dst[k] = storage[i]
                i += 1
              else
                dst[k] = dst[j]
                j += 1
              end
            elsif i < a
              dst[k] = storage[i]
              i += 1
            else
              break
            end
            k += 1
          end
        else
          storage = dst[curr + a, b]
          i = b
          j = curr + a
          k = curr + a + b
          while k > curr
            k -= 1
            if i > 0 && j > curr
              if wrap_cmp(dst[j - 1], storage[i - 1]) > 0
                j -= 1
                dst[k] = dst[j]
              else
                i -= 1
                dst[k] = storage[i]
              end
            elsif i > 0
              i -= 1
              dst[k] = storage[i]
            else
              break
            end
          end
        end
      end

      def tim_sort_collapse(dst, stack, stack_curr, size)
        while true
          break if stack_curr <= 1

          if stack_curr == 2 && stack[0][1] + stack[1][1] == size
            tim_sort_merge(dst, stack, stack_curr)
            stack[0][1] += stack[1][1]
            stack_curr -= 1
            break
          elsif stack_curr == 2 && stack[0][1] <= stack[1][1]
            tim_sort_merge(dst, stack, stack_curr)
            stack[0][1] += stack[1][1]
            stack_curr -= 1
            break
          elsif stack_curr == 2
            break
          end

          b = stack[stack_curr - 3][1]
          c = stack[stack_curr - 2][1]
          d = stack[stack_curr - 1][1]
          if stack_curr >= 4
            a = stack[stack_curr - 4][1]
            abc = a <= b + c
          else
            abc = false
          end
          bcd = (b <= c + d) || abc
          cd = c <= d
          break if !bcd && !cd

          if bcd && !cd
            tim_sort_merge(dst, stack, stack_curr - 1)
            stack[stack_curr - 3][1] += stack[stack_curr - 2][1]
            stack[stack_curr - 2] = stack[stack_curr - 1]
            stack_curr -= 1
          else
            tim_sort_merge(dst, stack, stack_curr)
            stack[stack_curr - 2][1] += stack[stack_curr - 1][1]
            stack_curr -= 1
          end
        end
        stack_curr
      end

      # returns [continue?, stack_curr, curr]
      def tim_push_next(dst, size, minrun, run_stack, stack_curr, curr)
        len = count_run(dst, curr, size)
        run = minrun
        run = size - curr if run > size - curr
        if run > len
          binary_insertion_sort_start(dst, curr, len, run)
          len = run
        end
        run_stack[stack_curr] = [curr, len]
        stack_curr += 1
        curr += len
        if curr == size
          while stack_curr > 1
            tim_sort_merge(dst, run_stack, stack_curr)
            run_stack[stack_curr - 2][1] += run_stack[stack_curr - 1][1]
            stack_curr -= 1
          end
          return [false, stack_curr, curr]
        end
        [true, stack_curr, curr]
      end

      def tim_sort(dst, size)
        minrun = compute_minrun(size)
        run_stack = []
        stack_curr = 0
        curr = 0
        i = 0
        while i < 3
          cont, stack_curr, curr = tim_push_next(dst, size, minrun, run_stack, stack_curr, curr)
          return unless cont

          i += 1
        end
        while true
          unless check_invariant(run_stack, stack_curr)
            stack_curr = tim_sort_collapse(dst, run_stack, stack_curr, size)
            next
          end
          cont, stack_curr, curr = tim_push_next(dst, size, minrun, run_stack, stack_curr, curr)
          return unless cont
        end
      end

      # ------------------------------------------------------------------------------------------
      # string-value hashing used by the equality operators
      # ------------------------------------------------------------------------------------------

      def string_hash(str)
        return 0 if str.nil? || str.empty?

        b0 = str.getbyte(0)
        b1 = str.getbyte(1) || 0
        b0 + (b1 << 8)
      end

      # xmlXPathNodeValHash
      def node_val_hash(node)
        return 0 if node.nil?

        if node.type == DOCUMENT_NODE
          tmp = Tree.doc_get_root_element(node)
          node = tmp.nil? ? node.children : tmp
          return 0 if node.nil?
        end

        case node.type
        when COMMENT_NODE, PI_NODE, CDATA_SECTION_NODE, TEXT_NODE
          return string_hash(node.content)
        when NAMESPACE_DECL
          return string_hash(node.href)
        when ATTRIBUTE_NODE, ELEMENT_NODE
          tmp = node.children
        else
          return 0
        end
        len = 2
        ret = 0
        while tmp
          string = case tmp.type
          when CDATA_SECTION_NODE, TEXT_NODE then tmp.content
          end
          if string && !string.empty?
            return ret + (string.getbyte(0) << 8) if len == 1

            if string.bytesize == 1
              len = 1
              ret = string.getbyte(0)
            else
              return string.getbyte(0) + (string.getbyte(1) << 8)
            end
          end
          ch = tmp.children
          if ch && tmp.type != DTD_NODE && tmp.type != ENTITY_REF_NODE && ch.type != ENTITY_DECL
            tmp = ch
            next
          end
          break if tmp.equal?(node)

          if tmp.next
            tmp = tmp.next
            next
          end
          while true
            tmp = tmp.parent
            break if tmp.nil?
            if tmp.equal?(node)
              tmp = nil
              break
            end
            if tmp.next
              tmp = tmp.next
              break
            end
          end
        end
        ret
      end

      # ------------------------------------------------------------------------------------------
      # compiled-expression cache
      # ------------------------------------------------------------------------------------------

      COMPILE_CACHE = {}
      COMPILE_CACHE_MAX = 2048
      COMPILE_CACHE_LOCK = Mutex.new

      # Returns a CompExpr, or a CompileError describing the (first) error.
      def cached_compile(str, flags)
        key = flags == 0 ? str : "#{flags}\0#{str}"
        comp = COMPILE_CACHE[key]
        return comp if comp

        comp = Compiler.new(str, flags).compile
        COMPILE_CACHE_LOCK.synchronize do
          COMPILE_CACHE.clear if COMPILE_CACHE.size >= COMPILE_CACHE_MAX
          COMPILE_CACHE[key.frozen? ? key : key.dup.freeze] = comp
        end
        comp
      end
    end
  end
end

require_relative "xpath/compiler"
require_relative "xpath/evaluator"
require_relative "xpath/functions"
require_relative "xpath/fast_collect"
