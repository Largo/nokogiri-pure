# frozen_string_literal: true

require_relative "chars"

module Nokogiri
  module Pure
    module XPath
      # xmlXPathOp
      OP_END = 0
      OP_AND = 1
      OP_OR = 2
      OP_EQUAL = 3
      OP_CMP = 4
      OP_PLUS = 5
      OP_MULT = 6
      OP_UNION = 7
      OP_ROOT = 8
      OP_NODE = 9
      OP_COLLECT = 10
      OP_VALUE = 11
      OP_VARIABLE = 12
      OP_FUNCTION = 13
      OP_ARG = 14
      OP_PREDICATE = 15
      OP_FILTER = 16
      OP_SORT = 17

      # xmlXPathAxisVal
      AXIS_ANCESTOR = 1
      AXIS_ANCESTOR_OR_SELF = 2
      AXIS_ATTRIBUTE = 3
      AXIS_CHILD = 4
      AXIS_DESCENDANT = 5
      AXIS_DESCENDANT_OR_SELF = 6
      AXIS_FOLLOWING = 7
      AXIS_FOLLOWING_SIBLING = 8
      AXIS_NAMESPACE = 9
      AXIS_PARENT = 10
      AXIS_PRECEDING = 11
      AXIS_PRECEDING_SIBLING = 12
      AXIS_SELF = 13

      # xmlXPathTestVal
      NODE_TEST_NONE = 0
      NODE_TEST_TYPE = 1
      NODE_TEST_PI = 2
      NODE_TEST_ALL = 3
      NODE_TEST_NS = 4
      NODE_TEST_NAME = 5

      # xmlXPathTypeVal
      NODE_TYPE_NODE = 0
      NODE_TYPE_COMMENT = COMMENT_NODE
      NODE_TYPE_TEXT = TEXT_NODE
      NODE_TYPE_PI = PI_NODE

      AXIS_NAMES = {
        "ancestor" => AXIS_ANCESTOR,
        "ancestor-or-self" => AXIS_ANCESTOR_OR_SELF,
        "attribute" => AXIS_ATTRIBUTE,
        "child" => AXIS_CHILD,
        "descendant" => AXIS_DESCENDANT,
        "descendant-or-self" => AXIS_DESCENDANT_OR_SELF,
        "following" => AXIS_FOLLOWING,
        "following-sibling" => AXIS_FOLLOWING_SIBLING,
        "namespace" => AXIS_NAMESPACE,
        "parent" => AXIS_PARENT,
        "preceding" => AXIS_PRECEDING,
        "preceding-sibling" => AXIS_PRECEDING_SIBLING,
        "self" => AXIS_SELF,
      }.freeze

      # nokogiri libxml2 patch 0009-allow-wildcard-namespaces
      WILDCARD_PREFIX = "*"

      # xmlXPathStepOp. +c1+/+c2+ are the resolved children (steps[ch1], steps[ch2]).
      class Op
        attr_accessor :op, :ch1, :ch2, :value, :value2, :value3, :value4, :value5, :c1, :c2,
          :index, :positional, :max_pos, :last_fn, :first_one, :plan,
          :dos_op, :impure, :std_fn

        def initialize(op, ch1, ch2, value, value2, value3, value4, value5)
          @op = op
          @ch1 = ch1
          @ch2 = ch2
          @value = value
          @value2 = value2
          @value3 = value3
          @value4 = value4
          @value5 = value5
          @c1 = nil
          @c2 = nil
        end
      end

      # xmlXPathCompExpr
      class CompExpr
        attr_accessor :steps, :last, :expr, :root

        def initialize
          @steps = []
          @last = -1
          @expr = nil
          @root = nil
        end

        def nb_step = @steps.length

        # resolve ch1/ch2 indices into object references and precompute per-op facts
        def link!
          @steps.each_with_index do |op, i|
            op.index = i
            op.c1 = op.ch1 >= 0 ? @steps[op.ch1] : nil
            op.c2 = op.ch2 >= 0 ? @steps[op.ch2] : nil
          end
          @steps.each { |op| XPath.precompute_op(self, op) }
          @steps.each { |op| XPath.precompute_dos_rewrite(op) if op.op == OP_COLLECT }
          @root = @last >= 0 ? @steps[@last] : nil
          self
        end
      end

      # a failed compilation, cached so that it can be re-reported
      CompileError = Struct.new(:code, :offset)

      # precompute the static facts xmlXPathCompOpEval checks at every evaluation
      def self.precompute_op(comp, op)
        case op.op
        when OP_COLLECT
          op.plan = FastCollect.plan_for(op.value, op.value2, op.value3, op.value4, op.value5)
          # xmlXPathIsPositionalPredicate on the first predicate
          if (pred = op.c2)
            max = positional_predicate(pred)
            if max
              op.positional = true
              op.max_pos = max
            end
          end
        when OP_FUNCTION
          # standard functions are looked up first in a static table (patch 0019): static binding
          op.std_fn = STANDARD_FN_METHODS[op.value4] if op.value5.nil?
        when OP_PREDICATE, OP_FILTER
          c1 = op.c1
          c2 = op.c2
          if c1 && c2
            if (c1.op == OP_SORT || c1.op == OP_FILTER) && c2.op == OP_VALUE
              v = c2.value4
              op.first_one = true if v.is_a?(Float) && v == 1.0
            end
            if c1.op == OP_SORT && c2.op == OP_SORT
              f = c2.c1
              if f && f.op == OP_FUNCTION && f.value5.nil? && f.value == 0 && f.value4 == "last"
                op.last_fn = true
              end
            end
          end
        end
      end

      # Static result types of the standard functions (used by the rewrite below)
      FUNC_TYPES = {}.tap do |h|
        %w[boolean not true false contains starts-with lang].each { |n| h[n] = :boolean }
        %w[string concat substring substring-before substring-after normalize-space translate
           local-name name namespace-uri].each { |n| h[n] = :string }
        %w[count sum number floor ceiling round string-length last position].each { |n| h[n] = :number }
        h["id"] = :nodeset
      end.freeze

      def self.static_type(op)
        case op.op
        when OP_EQUAL, OP_CMP, OP_AND, OP_OR then :boolean
        when OP_PLUS, OP_MULT then :number
        when OP_VALUE then op.value4.is_a?(Float) ? :number : :string
        when OP_COLLECT, OP_ROOT, OP_NODE, OP_UNION then :nodeset
        when OP_SORT then op.c1 ? static_type(op.c1) : :unknown
        when OP_FILTER then op.c1 && static_type(op.c1) == :nodeset ? :nodeset : :unknown
        when OP_FUNCTION
          # prefixed functions qualify only if they turn out to be the nokogiri builtins, which
          # return booleans (checked at evaluation time)
          op.value5.nil? ? (FUNC_TYPES[op.value4] || :unknown) : :boolean
        else :unknown
        end
      end

      # Is +op+ free of context-position dependencies (at the top level, +top+) and of calls to
      # functions with possible side effects? Prefixed function ops are collected in +impure+.
      def self.position_free?(op, top, impure)
        return true if op.nil?

        case op.op
        when OP_FUNCTION
          if op.value5.nil?
            return false unless STANDARD_FUNCS.key?(op.value4)
            return false if top && (op.value4 == "last" || op.value4 == "position")
          else
            impure << op
          end
          position_free?(op.c1, top, impure)
        when OP_COLLECT, OP_FILTER
          position_free?(op.c1, top, impure) && position_free?(op.c2, false, impure)
        else
          position_free?(op.c1, top, impure) && position_free?(op.c2, top, impure)
        end
      end

      # "descendant-or-self::node()/child::x[p]" with position-independent, non-numeric
      # predicates selects the same nodes as "descendant::x[p]" (libxml2 only rewrites it when
      # there is no predicate, because of positional predicates). The result order before the
      # final sort differs, but every node-set result that is observed gets sorted.
      def self.precompute_dos_rewrite(op)
        return unless op.value == AXIS_CHILD && (dos = op.c1) && (pred = op.c2)
        return unless dos.op == OP_COLLECT && dos.value == AXIS_DESCENDANT_OR_SELF && dos.c2.nil? &&
          dos.value2 == NODE_TEST_TYPE && dos.value3 == NODE_TYPE_NODE && dos.c1

        impure = []
        p = pred
        while p
          return unless p.op == OP_PREDICATE && p.c2

          type = static_type(p.c2)
          return if type == :number || type == :unknown
          return unless position_free?(p.c2, true, impure)

          p = p.c1
        end
        d = Op.new(OP_COLLECT, dos.ch1, op.ch2, AXIS_DESCENDANT, op.value2, op.value3, op.value4, op.value5)
        d.c1 = dos.c1
        d.c2 = pred
        d.index = op.index
        d.plan = FastCollect.plan_for(AXIS_DESCENDANT, op.value2, op.value3, op.value4, op.value5)
        op.dos_op = d
        op.impure = impure.empty? ? nil : impure
      end

      # xmlXPathIsPositionalPredicate: returns maxPos or nil
      def self.positional_predicate(op)
        return nil if op.op != OP_PREDICATE && op.op != OP_FILTER

        expr_op = op.c2
        return nil if expr_op.nil?

        if expr_op.op == OP_VALUE && expr_op.value4.is_a?(Float)
          floatval = expr_op.value4
          if floatval > INT_MIN && floatval < INT_MAX
            max_pos = floatval.to_i
            return max_pos if floatval == max_pos.to_f
          end
        end
        nil
      end

      # The expression compiler: xmlXPathCompileExpr and friends, operating on the bytes of the
      # expression. Errors abort compilation (only the first error is ever reported).
      class Compiler
        def initialize(str, flags = 0)
          @str = str
          @s = str.b
          @pos = 0
          @flags = flags
          @depth = 0
          @comp = CompExpr.new
        end

        # xmlXPathEvalExpr's compile phase: returns a linked CompExpr or a CompileError
        def compile
          err = catch(:xpath_compile_error) do
            compile_expr(true)
            # check for trailing characters
            xp_error(EXPR_ERROR) if cur != 0
            nil
          end
          return err if err

          comp = @comp
          optimize_expression(comp.steps[comp.last], 0) if comp.nb_step > 1 && comp.last >= 0
          comp.expr = @str
          comp.link!
        end

        # For parser-context users (XPointer): run one of the name scanners at byte offset +pos+.
        # Returns [name_or_nil, new_pos, error_or_nil].
        def scan_at(pos, what)
          @pos = pos
          name = nil
          err = catch(:xpath_compile_error) do
            name = what == :name ? parse_name : parse_ncname
            nil
          end
          [name, @pos, err]
        end

        private

        def xp_error(code)
          throw :xpath_compile_error, CompileError.new(code, @pos)
        end

        # xmlXPathParseName
        def parse_name
          start = @pos
          i = start
          c = @s.getbyte(i) || 0
          if ascii_letter?(c) || c == 0x5F || c == 0x3A
            i += 1
            c = @s.getbyte(i) || 0
            while ascii_letter?(c) || ascii_digit?(c) || c == 0x5F || c == 0x2D || c == 0x3A || c == 0x2E
              i += 1
              c = @s.getbyte(i) || 0
            end
            if c > 0 && c < 0x80
              count = i - start
              if count > 50_000
                @pos = i
                xp_error(EXPR_ERROR)
              end
              @pos = i
              return utf8_str(@s.byteslice(start, count))
            end
          end
          parse_name_complex(true)
        end

        def cur
          @s.getbyte(@pos) || 0
        end

        def nxt(n)
          @s.getbyte(@pos + n) || 0
        end

        def skip(n)
          @pos += n
        end

        def next_ch
          @pos += 1 if @pos < @s.bytesize
        end

        def blank?(c)
          c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        end

        def skip_blanks
          while (c = @s.getbyte(@pos)) && (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D)
            @pos += 1
          end
        end

        def ascii_digit?(c)
          c >= 0x30 && c <= 0x39
        end

        def ascii_letter?(c)
          (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
        end

        # xmlXPathCompExprAdd
        def add(ch1, ch2, op, value, value2, value3, value4, value5)
          comp = @comp
          if comp.steps.length >= XPATH_MAX_STEPS
            xp_error(MEMORY_ERROR)
          end
          comp.last = comp.steps.length
          comp.steps << Op.new(op, ch1, ch2, value, value2, value3, value4, value5)
          comp.last
        end

        def push_long_expr(op, val, val2, val3, val4, val5)
          add(@comp.last, -1, op, val, val2, val3, val4, val5)
        end

        def push_unary_expr(op, ch, val, val2)
          add(ch, -1, op, val, val2, 0, nil, nil)
        end

        def push_binary_expr(op, ch1, ch2, val, val2)
          add(ch1, ch2, op, val, val2, 0, nil, nil)
        end

        def push_leave_expr(op, val, val2)
          add(-1, -1, op, val, val2, 0, nil, nil)
        end

        def utf8_str(bytes)
          bytes.force_encoding(::Encoding::UTF_8)
        end

        # xmlXPathCurrentChar: returns [codepoint, len]
        def current_char
          c = cur
          if c & 0x80 != 0
            c1 = nxt(1)
            return encoding_error if c1 & 0xc0 != 0x80

            if c & 0xe0 == 0xe0
              c2 = nxt(2)
              return encoding_error if c2 & 0xc0 != 0x80

              if c & 0xf0 == 0xf0
                c3 = nxt(3)
                return encoding_error if c & 0xf8 != 0xf0 || c3 & 0xc0 != 0x80

                len = 4
                val = (c & 0x7) << 18
                val |= (c1 & 0x3f) << 12
                val |= (c2 & 0x3f) << 6
                val |= c3 & 0x3f
              else
                len = 3
                val = (c & 0xf) << 12
                val |= (c1 & 0x3f) << 6
                val |= c2 & 0x3f
              end
            else
              len = 2
              val = (c & 0x1f) << 6
              val |= c1 & 0x3f
            end
            xp_error(INVALID_CHAR_ERROR) unless Chars.char?(val)
            [val, len]
          else
            [c, 1]
          end
        end

        def encoding_error
          xp_error(ENCODING_ERROR)
        end

        # xmlXPathParseNCName
        def parse_ncname
          start = @pos
          i = start
          c = @s.getbyte(i) || 0
          if ascii_letter?(c) || c == 0x5F
            i += 1
            c = @s.getbyte(i) || 0
            while ascii_letter?(c) || ascii_digit?(c) || c == 0x5F || c == 0x2E || c == 0x2D
              i += 1
              c = @s.getbyte(i) || 0
            end
            if c == 0x20 || c == 0x3E || c == 0x2F || c == 0x5B || c == 0x5D || c == 0x3A ||
                c == 0x40 || c == 0x2A
              count = i - start
              return nil if count == 0

              @pos = i
              return utf8_str(@s.byteslice(start, count))
            end
          end
          parse_name_complex(false)
        end

        # xmlXPathParseQName: returns [name, prefix]
        def parse_qname
          prefix = nil
          ret = parse_ncname
          if ret && cur == 0x3A
            prefix = ret
            next_ch
            ret = parse_ncname
          end
          [ret, prefix]
        end

        # xmlXPathParseNameComplex
        def parse_name_complex(qualified)
          c, l = current_char
          if c == 0x20 || c == 0x3E || c == 0x2F || c == 0x5B || c == 0x5D || c == 0x40 || c == 0x2A ||
              (!Chars.letter?(c) && c != 0x5F && (!qualified || c != 0x3A))
            return nil
          end

          start = @pos
          len = 0
          while c != 0x20 && c != 0x3E && c != 0x2F &&
              (Chars.letter?(c) || Chars.digit?(c) || c == 0x2E || c == 0x2D || c == 0x5F ||
               (qualified && c == 0x3A) || Chars.combining?(c) || Chars.extender?(c))
            len += l
            @pos += l
            c, l = current_char
            if len >= 100 # XML_MAX_NAMELEN
              xp_error(EXPR_ERROR) if len > 50_000 # XML_MAX_NAME_LENGTH
              while Chars.letter?(c) || Chars.digit?(c) || c == 0x2E || c == 0x2D || c == 0x5F ||
                  (qualified && c == 0x3A) || Chars.combining?(c) || Chars.extender?(c)
                xp_error(EXPR_ERROR) if len + 10 > 50_000 * 2 && len > 50_000
                len += l
                @pos += l
                c, l = current_char
              end
              return utf8_str(@s.byteslice(start, len))
            end
          end
          return nil if len == 0

          utf8_str(@s.byteslice(start, len))
        end

        # xmlXPathScanName: scan a name without moving the cursor
        def scan_name
          save = @pos
          c, l = current_char
          if c == 0x20 || c == 0x3E || c == 0x2F || (!Chars.letter?(c) && c != 0x5F && c != 0x3A)
            return nil
          end

          while c != 0x20 && c != 0x3E && c != 0x2F &&
              (Chars.letter?(c) || Chars.digit?(c) || c == 0x2E || c == 0x2D || c == 0x5F ||
               c == 0x3A || Chars.combining?(c) || Chars.extender?(c))
            @pos += l
            c, l = current_char
          end
          ret = @s.byteslice(save, @pos - save)
          @pos = save
          ret
        end

        # xmlXPathCompNumber
        def comp_number
          c = cur
          xp_error(NUMBER_ERROR) if c != 0x2E && !ascii_digit?(c)

          ret = 0.0
          ok = false
          while ascii_digit?(c = cur)
            ret *= 10
            ok = true
            next_ch
            ret += (c - 0x30).to_f
          end
          if cur == 0x2E
            next_ch
            xp_error(NUMBER_ERROR) if !ascii_digit?(cur) && !ok

            frac = 0
            fraction = 0.0
            while cur == 0x30
              frac += 1
              next_ch
            end
            max = frac + 20
            while ascii_digit?(c = cur) && frac < max
              fraction = fraction * 10 + (c - 0x30)
              frac += 1
              next_ch
            end
            fraction /= 10.0**frac
            ret += fraction
            next_ch while ascii_digit?(cur)
          end
          c = cur
          if c == 0x65 || c == 0x45
            next_ch
            exponent = 0
            is_exponent_negative = false
            if cur == 0x2D
              is_exponent_negative = true
              next_ch
            elsif cur == 0x2B
              next_ch
            end
            while ascii_digit?(c = cur)
              exponent = exponent * 10 + (c - 0x30) if exponent < 1_000_000
              next_ch
            end
            exponent = -exponent if is_exponent_negative
            ret *= 10.0**exponent
          end
          push_long_expr(OP_VALUE, NUMBER, 0, 0, ret, nil)
        end

        # xmlXPathParseLiteral
        def parse_literal
          c = cur
          if c == 0x22 || c == 0x27
            quote = c
          else
            xp_error(START_LITERAL_ERROR)
          end
          next_ch
          q = @pos
          while cur != quote
            xp_error(UNFINISHED_LITERAL_ERROR) if cur == 0
            ch, len = get_utf8_char(@pos)
            xp_error(INVALID_CHAR_ERROR) if ch < 0 || !Chars.char?(ch)
            @pos += len
          end
          ret = utf8_str(@s.byteslice(q, @pos - q))
          next_ch
          ret
        end

        # xmlGetUTF8Char (with *len = 4)
        def get_utf8_char(i)
          c = @s.getbyte(i) || 0
          return [c, 1] if c < 0x80

          c1 = @s.getbyte(i + 1) || 0
          return [-1, 0] if c1 & 0xc0 != 0x80

          if c < 0xe0
            return [-1, 0] if c < 0xc2

            return [((c & 0x1f) << 6) | (c1 & 0x3f), 2]
          end
          c2 = @s.getbyte(i + 2) || 0
          return [-1, 0] if c2 & 0xc0 != 0x80

          if c < 0xf0
            v = ((c & 0xf) << 12) | ((c1 & 0x3f) << 6) | (c2 & 0x3f)
            return [-1, 0] if v < 0x800 || (v >= 0xd800 && v < 0xe000)

            return [v, 3]
          end
          c3 = @s.getbyte(i + 3) || 0
          return [-1, 0] if c3 & 0xc0 != 0x80

          v = ((c & 0x7) << 18) | ((c1 & 0x3f) << 12) | ((c2 & 0x3f) << 6) | (c3 & 0x3f)
          return [-1, 0] if v < 0x10000 || v >= 0x110000

          [v, 4]
        end

        # xmlXPathCompLiteral
        def comp_literal
          ret = parse_literal
          push_long_expr(OP_VALUE, STRING, 0, 0, ret.freeze, nil)
        end

        # xmlXPathCompVariableReference
        def comp_variable_reference
          skip_blanks
          xp_error(VARIABLE_REF_ERROR) if cur != 0x24
          next_ch
          name, prefix = parse_qname
          xp_error(VARIABLE_REF_ERROR) if name.nil?
          @comp.last = -1
          push_long_expr(OP_VARIABLE, 0, 0, 0, name.freeze, prefix&.freeze)
          skip_blanks
          xp_error(FORBID_VARIABLE_ERROR) if (@flags & XML_XPATH_NOVAR) != 0
        end

        def node_type?(name)
          name == "node" || name == "text" || name == "comment" || name == "processing-instruction"
        end

        # xmlXPathCompFunctionCall
        def comp_function_call
          name, prefix = parse_qname
          xp_error(EXPR_ERROR) if name.nil?
          skip_blanks
          xp_error(EXPR_ERROR) if cur != 0x28
          next_ch
          skip_blanks
          # Optimization for count(): we don't need the node-set to be sorted.
          sort = !(prefix.nil? && name == "count")
          nbargs = 0
          @comp.last = -1
          if cur != 0x29
            while cur != 0
              op1 = @comp.last
              @comp.last = -1
              compile_expr(sort)
              push_binary_expr(OP_ARG, op1, @comp.last, 0, 0)
              nbargs += 1
              break if cur == 0x29

              xp_error(EXPR_ERROR) if cur != 0x2C
              next_ch
              skip_blanks
            end
          end
          push_long_expr(OP_FUNCTION, nbargs, 0, 0, name.freeze, prefix&.freeze)
          next_ch
          skip_blanks
        end

        # xmlXPathCompPrimaryExpr
        def comp_primary_expr
          skip_blanks
          c = cur
          if c == 0x24
            comp_variable_reference
          elsif c == 0x28
            next_ch
            skip_blanks
            compile_expr(true)
            xp_error(EXPR_ERROR) if cur != 0x29
            next_ch
            skip_blanks
          elsif ascii_digit?(c) || (c == 0x2E && ascii_digit?(nxt(1)))
            comp_number
          elsif c == 0x27 || c == 0x22
            comp_literal
          else
            comp_function_call
          end
          skip_blanks
        end

        # xmlXPathCompFilterExpr
        def comp_filter_expr
          comp_primary_expr
          skip_blanks
          while cur == 0x5B
            comp_predicate(true)
            skip_blanks
          end
        end

        # xmlXPathCompPathExpr
        def comp_path_expr
          lc = true
          skip_blanks
          c = cur
          if c == 0x24 || c == 0x28 || ascii_digit?(c) || c == 0x27 || c == 0x22 ||
              (c == 0x2E && ascii_digit?(nxt(1)))
            lc = false
          elsif c == 0x2A || c == 0x2F || c == 0x40 || c == 0x2E
            lc = true
          else
            skip_blanks
            name = scan_name
            if name && name.include?("::")
              lc = true
            elsif name
              len = name.bytesize
              while (n = nxt(len)) != 0
                if n == 0x2F
                  lc = true
                  break
                elsif blank?(n)
                  # ignore blanks
                elsif n == 0x3A
                  lc = true
                  break
                elsif n == 0x28
                  # Node Type or Function
                  lc = node_type?(name)
                  break
                elsif n == 0x5B
                  lc = true
                  break
                elsif n == 0x3C || n == 0x3E || n == 0x3D
                  lc = true
                  break
                else
                  lc = true
                  break
                end
                len += 1
              end
              lc = true if nxt(len) == 0
            else
              xp_error(EXPR_ERROR)
            end
          end

          if lc
            if cur == 0x2F
              push_leave_expr(OP_ROOT, 0, 0)
            else
              push_leave_expr(OP_NODE, 0, 0)
            end
            comp_location_path
          else
            comp_filter_expr
            if cur == 0x2F && nxt(1) == 0x2F
              skip(2)
              skip_blanks
              push_long_expr(OP_COLLECT, AXIS_DESCENDANT_OR_SELF, NODE_TEST_TYPE, NODE_TYPE_NODE, nil, nil)
              comp_relative_location_path
            elsif cur == 0x2F
              comp_relative_location_path
            end
          end
          skip_blanks
        end

        # xmlXPathCompUnionExpr
        def comp_union_expr
          comp_path_expr
          skip_blanks
          while cur == 0x7C
            op1 = @comp.last
            push_leave_expr(OP_NODE, 0, 0)
            next_ch
            skip_blanks
            comp_path_expr
            push_binary_expr(OP_UNION, op1, @comp.last, 0, 0)
            skip_blanks
          end
        end

        # xmlXPathCompUnaryExpr
        def comp_unary_expr
          minus = false
          found = false
          skip_blanks
          while cur == 0x2D
            minus = !minus
            found = true
            next_ch
            skip_blanks
          end
          comp_union_expr
          if found
            push_unary_expr(OP_PLUS, @comp.last, minus ? 2 : 3, 0)
          end
        end

        # xmlXPathCompMultiplicativeExpr
        def comp_multiplicative_expr
          comp_unary_expr
          skip_blanks
          loop do
            c = cur
            if c == 0x2A
              op = 0
              op1 = @comp.last
              next_ch
            elsif c == 0x64 && nxt(1) == 0x69 && nxt(2) == 0x76
              op = 1
              op1 = @comp.last
              skip(3)
            elsif c == 0x6D && nxt(1) == 0x6F && nxt(2) == 0x64
              op = 2
              op1 = @comp.last
              skip(3)
            else
              break
            end
            skip_blanks
            comp_unary_expr
            push_binary_expr(OP_MULT, op1, @comp.last, op, 0)
            skip_blanks
          end
        end

        # xmlXPathCompAdditiveExpr
        def comp_additive_expr
          comp_multiplicative_expr
          skip_blanks
          while (c = cur) == 0x2B || c == 0x2D
            op1 = @comp.last
            plus = c == 0x2B ? 1 : 0
            next_ch
            skip_blanks
            comp_multiplicative_expr
            push_binary_expr(OP_PLUS, op1, @comp.last, plus, 0)
            skip_blanks
          end
        end

        # xmlXPathCompRelationalExpr
        def comp_relational_expr
          comp_additive_expr
          skip_blanks
          while (c = cur) == 0x3C || c == 0x3E
            op1 = @comp.last
            inf = c == 0x3C ? 1 : 0
            strict = nxt(1) == 0x3D ? 0 : 1
            next_ch
            next_ch if strict == 0
            skip_blanks
            comp_additive_expr
            push_binary_expr(OP_CMP, op1, @comp.last, inf, strict)
            skip_blanks
          end
        end

        # xmlXPathCompEqualityExpr
        def comp_equality_expr
          comp_relational_expr
          skip_blanks
          while (c = cur) == 0x3D || (c == 0x21 && nxt(1) == 0x3D)
            op1 = @comp.last
            eq = c == 0x3D ? 1 : 0
            next_ch
            next_ch if eq == 0
            skip_blanks
            comp_relational_expr
            push_binary_expr(OP_EQUAL, op1, @comp.last, eq, 0)
            skip_blanks
          end
        end

        # xmlXPathCompAndExpr
        def comp_and_expr
          comp_equality_expr
          skip_blanks
          while cur == 0x61 && nxt(1) == 0x6E && nxt(2) == 0x64
            op1 = @comp.last
            skip(3)
            skip_blanks
            comp_equality_expr
            push_binary_expr(OP_AND, op1, @comp.last, 0, 0)
            skip_blanks
          end
        end

        # xmlXPathCompileExpr
        def compile_expr(sort)
          xp_error(RECURSION_LIMIT_EXCEEDED) if @depth >= XPATH_MAX_RECURSION_DEPTH
          @depth += 10

          comp_and_expr
          skip_blanks
          while cur == 0x6F && nxt(1) == 0x72
            op1 = @comp.last
            skip(2)
            skip_blanks
            comp_and_expr
            push_binary_expr(OP_OR, op1, @comp.last, 0, 0)
            skip_blanks
          end
          if sort && @comp.steps[@comp.last].op != OP_VALUE
            push_unary_expr(OP_SORT, @comp.last, 0, 0)
          end
          @depth -= 10
        end

        # xmlXPathCompPredicate
        def comp_predicate(filter)
          op1 = @comp.last
          skip_blanks
          xp_error(INVALID_PREDICATE_ERROR) if cur != 0x5B
          next_ch
          skip_blanks
          @comp.last = -1
          compile_expr(filter)
          xp_error(INVALID_PREDICATE_ERROR) if cur != 0x5D
          if filter
            push_binary_expr(OP_FILTER, op1, @comp.last, 0, 0)
          else
            push_binary_expr(OP_PREDICATE, op1, @comp.last, 0, 0)
          end
          next_ch
          skip_blanks
        end

        # xmlXPathCompNodeTest: returns [test, type, prefix, name]
        def comp_node_test(name)
          type = 0
          prefix = nil
          skip_blanks
          if name.nil? && cur == 0x2A
            next_ch
            # nokogiri libxml2 patch 0009 (wildcard namespaces): "*:name"
            return [NODE_TEST_ALL, 0, nil, nil] if cur != 0x3A

            name = WILDCARD_PREFIX
          end

          name ||= parse_ncname
          xp_error(EXPR_ERROR) if name.nil?

          blanks = blank?(cur)
          skip_blanks
          if cur == 0x28
            next_ch
            type = case name
            when "comment" then NODE_TYPE_COMMENT
            when "node" then NODE_TYPE_NODE
            when "processing-instruction" then NODE_TYPE_PI
            when "text" then NODE_TYPE_TEXT
            else xp_error(EXPR_ERROR)
            end
            test = NODE_TEST_TYPE
            skip_blanks
            if type == NODE_TYPE_PI
              name = nil
              if cur != 0x29
                name = parse_literal
                test = NODE_TEST_PI
                skip_blanks
              end
            end
            xp_error(UNCLOSED_ERROR) if cur != 0x29
            next_ch
            return [test, type, nil, name]
          end
          test = NODE_TEST_NAME
          if !blanks && cur == 0x3A
            next_ch
            prefix = name
            if cur == 0x2A
              next_ch
              return [NODE_TEST_ALL, 0, prefix, nil]
            end
            name = parse_ncname
            xp_error(EXPR_ERROR) if name.nil?
          end
          [test, type, prefix, name]
        end

        # xmlXPathCompStep
        def comp_step
          skip_blanks
          if cur == 0x2E && nxt(1) == 0x2E
            skip(2)
            skip_blanks
            push_long_expr(OP_COLLECT, AXIS_PARENT, NODE_TEST_TYPE, NODE_TYPE_NODE, nil, nil)
          elsif cur == 0x2E
            next_ch
            skip_blanks
          else
            name = nil
            if cur == 0x2A
              if nxt(1) == 0x3A
                next_ch
                name = WILDCARD_PREFIX
              end
              axis = AXIS_CHILD
            else
              name = parse_ncname
              if name
                axis = AXIS_NAMES[name] || 0
                if axis != 0
                  skip_blanks
                  if cur == 0x3A && nxt(1) == 0x3A
                    skip(2)
                    name = nil
                  else
                    # an element name can conflict with an axis one :-\
                    axis = AXIS_CHILD
                  end
                else
                  axis = AXIS_CHILD
                end
              elsif cur == 0x40
                next_ch
                axis = AXIS_ATTRIBUTE
              else
                axis = AXIS_CHILD
              end
            end

            test, type, prefix, name = comp_node_test(name)
            return if test == 0

            # (XML_XPATH_CHECKNS is never set by nokogiri; it needs a context to check against)

            op1 = @comp.last
            @comp.last = -1
            skip_blanks
            comp_predicate(false) while cur == 0x5B
            add(op1, @comp.last, OP_COLLECT, axis, test, type, prefix&.freeze, name&.freeze)
          end
        end

        # xmlXPathCompRelativeLocationPath
        def comp_relative_location_path
          skip_blanks
          if cur == 0x2F && nxt(1) == 0x2F
            skip(2)
            skip_blanks
            push_long_expr(OP_COLLECT, AXIS_DESCENDANT_OR_SELF, NODE_TEST_TYPE, NODE_TYPE_NODE, nil, nil)
          elsif cur == 0x2F
            next_ch
            skip_blanks
          end
          comp_step
          skip_blanks
          while cur == 0x2F
            if cur == 0x2F && nxt(1) == 0x2F
              skip(2)
              skip_blanks
              push_long_expr(OP_COLLECT, AXIS_DESCENDANT_OR_SELF, NODE_TEST_TYPE, NODE_TYPE_NODE, nil, nil)
              comp_step
            elsif cur == 0x2F
              next_ch
              skip_blanks
              comp_step
            end
            skip_blanks
          end
        end

        # xmlXPathCompLocationPath
        def comp_location_path
          skip_blanks
          if cur != 0x2F
            comp_relative_location_path
          else
            while cur == 0x2F
              if cur == 0x2F && nxt(1) == 0x2F
                skip(2)
                skip_blanks
                push_long_expr(OP_COLLECT, AXIS_DESCENDANT_OR_SELF, NODE_TEST_TYPE, NODE_TYPE_NODE, nil, nil)
                comp_relative_location_path
              elsif cur == 0x2F
                next_ch
                skip_blanks
                c = cur
                if c != 0 && (ascii_letter?(c) || c >= 0x80 || c == 0x5F || c == 0x2E || c == 0x40 || c == 0x2A)
                  comp_relative_location_path
                end
              end
            end
          end
        end

        # xmlXPathOptimizeExpression
        def optimize_expression(op, depth)
          steps = @comp.steps
          if op.op == OP_COLLECT && op.ch1 != -1 && op.ch2 == -1
            prevop = steps[op.ch1]
            if prevop.op == OP_COLLECT && prevop.value == AXIS_DESCENDANT_OR_SELF && prevop.ch2 == -1 &&
                prevop.value2 == NODE_TEST_TYPE && prevop.value3 == NODE_TYPE_NODE
              case op.value
              when AXIS_CHILD, AXIS_DESCENDANT
                op.ch1 = prevop.ch1
                op.value = AXIS_DESCENDANT
              when AXIS_SELF, AXIS_DESCENDANT_OR_SELF
                op.ch1 = prevop.ch1
                op.value = AXIS_DESCENDANT_OR_SELF
              end
            end
          end
          return if op.op == OP_VALUE
          return if depth >= XPATH_MAX_RECURSION_DEPTH

          optimize_expression(steps[op.ch1], depth + 1) if op.ch1 != -1
          optimize_expression(steps[op.ch2], depth + 1) if op.ch2 != -1
        end
      end
    end
  end
end
