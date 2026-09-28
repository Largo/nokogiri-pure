# frozen_string_literal: true

module Nokogiri
  module Pure
    module XPath
      # The XPath 1.0 core function library (xpath.c: xmlXPath*Function), implemented as
      # ParserContext methods taking +nargs+. Each registered function is a callable taking
      # (parser_context, nargs), like xmlXPathFunction.
      class ParserContext
        # xmlXPathLastFunction
        def fn_last(nargs)
          check_arity(nargs, 0)
          cs = @context.context_size
          xp_error(INVALID_CTXT_SIZE) if cs < 0
          @value_tab.push(cs.to_f)
        end

        # xmlXPathPositionFunction
        def fn_position(nargs)
          check_arity(nargs, 0)
          pp = @context.proximity_position
          xp_error(INVALID_CTXT_POSITION) if pp < 0
          @value_tab.push(pp.to_f)
        end

        # xmlXPathCountFunction
        def fn_count(nargs)
          check_arity(nargs, 1)
          xp_error(INVALID_TYPE) unless @value_tab.last.is_a?(Array)
          cur = @value_tab.pop
          @value_tab.push(cur.length.to_f)
        end

        # xmlXPathGetElementsByIds
        def get_elements_by_ids(doc, ids)
          ret = []
          return ret if ids.nil?

          s = ids.b
          len = s.bytesize
          start = 0
          cur = 0
          cur += 1 while cur < len && blank_byte?(s.getbyte(cur))
          while cur < len
            cur += 1 while cur < len && !blank_byte?(s.getbyte(cur))
            id = s.byteslice(start, cur - start).force_encoding(::Encoding::UTF_8)
            attr = Tree.get_id(doc, id)
            if attr
              elem = if attr.type == ATTRIBUTE_NODE
                attr.parent
              elsif attr.type == ELEMENT_NODE
                attr
              end
              XPath.node_set_add(ret, elem) if elem
            end
            cur += 1 while cur < len && blank_byte?(s.getbyte(cur))
            start = cur
          end
          ret
        end

        def blank_byte?(c)
          c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        end

        # xmlXPathIdFunction
        def fn_id(nargs)
          check_arity(nargs, 1)
          obj = @value_tab.pop
          xp_error(INVALID_OPERAND) if obj.nil?
          doc = @context.doc
          if obj.is_a?(Array)
            ret = []
            obj.each do |node|
              tokens = node_to_string(node)
              ns = get_elements_by_ids(doc, tokens)
              XPath.node_set_merge(ret, ns)
            end
            @value_tab.push(ret)
            return
          end
          tokens = cast_to_string_internal(obj)
          @value_tab.push(get_elements_by_ids(doc, tokens))
        end

        # xmlXPathLocalNameFunction
        def fn_local_name(nargs)
          if nargs == 0
            @value_tab.push(XPath.node_set_create(@context.node))
            nargs = 1
          end
          check_arity(nargs, 1)
          xp_error(INVALID_TYPE) unless @value_tab.last.is_a?(Array)
          cur = @value_tab.pop
          if cur.empty?
            @value_tab.push(+"")
          else
            node = cur[0]
            case node.type
            when ELEMENT_NODE, ATTRIBUTE_NODE, PI_NODE
              nm = node.name
              @value_tab.push(nm.start_with?(" ") ? +"" : nm.dup)
            when NAMESPACE_DECL
              @value_tab.push(node.prefix ? node.prefix.dup : +"")
            else
              @value_tab.push(+"")
            end
          end
        end

        # xmlXPathNamespaceURIFunction
        def fn_namespace_uri(nargs)
          if nargs == 0
            @value_tab.push(XPath.node_set_create(@context.node))
            nargs = 1
          end
          check_arity(nargs, 1)
          xp_error(INVALID_TYPE) unless @value_tab.last.is_a?(Array)
          cur = @value_tab.pop
          if cur.empty?
            @value_tab.push(+"")
          else
            node = cur[0]
            case node.type
            when ELEMENT_NODE, ATTRIBUTE_NODE
              ns = node.ns
              @value_tab.push(ns.nil? ? +"" : (ns.href || "").dup)
            else
              @value_tab.push(+"")
            end
          end
        end

        # xmlXPathNameFunction
        def fn_name(nargs)
          if nargs == 0
            @value_tab.push(XPath.node_set_create(@context.node))
            nargs = 1
          end
          check_arity(nargs, 1)
          xp_error(INVALID_TYPE) unless @value_tab.last.is_a?(Array)
          cur = @value_tab.pop
          if cur.empty?
            @value_tab.push(+"")
          else
            node = cur[0]
            case node.type
            when ELEMENT_NODE, ATTRIBUTE_NODE
              nm = node.name
              ns = node.ns
              if nm.start_with?(" ")
                @value_tab.push(+"")
              elsif ns.nil? || ns.prefix.nil?
                @value_tab.push(nm.dup)
              else
                @value_tab.push("#{ns.prefix}:#{nm}")
              end
            else
              @value_tab.push(XPath.node_set_create(node))
              fn_local_name(1)
            end
          end
        end

        # xmlXPathStringFunction
        def fn_string(nargs)
          if nargs == 0
            @value_tab.push(node_to_string(@context.node))
            return
          end
          check_arity(nargs, 1)
          cur = @value_tab.pop
          xp_error(INVALID_OPERAND) if cur.nil?
          cur = cast_to_string_internal(cur) unless cur.is_a?(String)
          @value_tab.push(cur)
        end

        # xmlUTF8Strlen
        def utf8_strlen(s)
          return s.length if s.encoding == ::Encoding::UTF_8 && s.valid_encoding?

          b = s.b
          i = 0
          n = 0
          len = b.bytesize
          while i < len
            c = b.getbyte(i)
            if c & 0x80 != 0
              return -1 if ((b.getbyte(i + 1) || 0) & 0xc0) != 0x80

              if c & 0xe0 == 0xe0
                return -1 if ((b.getbyte(i + 2) || 0) & 0xc0) != 0x80

                if c & 0xf0 == 0xf0
                  return -1 if (c & 0xf8) != 0xf0 || ((b.getbyte(i + 3) || 0) & 0xc0) != 0x80

                  i += 4
                else
                  i += 3
                end
              else
                i += 2
              end
            else
              i += 1
            end
            n += 1
          end
          n
        end

        # xmlXPathStringLengthFunction
        def fn_string_length(nargs)
          if nargs == 0
            node = @context.node
            if node.nil?
              @value_tab.push(0.0)
            else
              @value_tab.push(utf8_strlen(node_to_string(node)).to_f)
            end
            return
          end
          check_arity(nargs, 1)
          cast_top_to_string
          check_type_string
          cur = @value_tab.pop
          @value_tab.push(utf8_strlen(cur).to_f)
        end

        # xmlXPathConcatFunction
        def fn_concat(nargs)
          check_arity(nargs, 2) if nargs < 2
          cast_top_to_string
          cur = @value_tab.pop
          return if cur.nil? || !cur.is_a?(String)

          nargs -= 1
          parts = [cur]
          while nargs > 0
            cast_top_to_string
            newobj = @value_tab.pop
            xp_error(INVALID_TYPE) if newobj.nil? || !newobj.is_a?(String)
            parts << newobj
            nargs -= 1
          end
          parts.reverse!
          @value_tab.push(utf8_concat(parts))
        end

        def utf8_concat(parts)
          s = +""
          parts.each { |p| s << p.b }
          s.force_encoding(::Encoding::UTF_8)
        end

        # xmlXPathContainsFunction
        def fn_contains(nargs)
          check_arity(nargs, 2)
          cast_top_to_string
          check_type_string
          needle = @value_tab.pop
          cast_top_to_string
          hay = @value_tab.pop
          xp_error(INVALID_TYPE) if hay.nil? || !hay.is_a?(String)
          @value_tab.push(CONTAINS_PREDICATE.call(hay, needle))
        end

        # xmlXPathStartsWithFunction
        def fn_starts_with(nargs)
          check_arity(nargs, 2)
          cast_top_to_string
          check_type_string
          needle = @value_tab.pop
          cast_top_to_string
          hay = @value_tab.pop
          xp_error(INVALID_TYPE) if hay.nil? || !hay.is_a?(String)
          @value_tab.push(STARTS_WITH_PREDICATE.call(hay, needle))
        end

        # xmlXPathSubstringFunction
        def fn_substring(nargs)
          check_arity(nargs, 2) if nargs < 2
          check_arity(nargs, 3) if nargs > 3
          le = 0.0
          if nargs == 3
            cast_top_to_number
            check_type_number
            le = @value_tab.pop
          end
          cast_top_to_number
          check_type_number
          inn = @value_tab.pop
          cast_top_to_string
          check_type_string
          str = @value_tab.pop

          i = 1
          j = INT_MAX
          if !(inn < INT_MAX)
            i = INT_MAX
          elsif inn >= 1.0
            i = inn.to_i
            i += 1 if inn - c_floor(inn) >= 0.5
          end
          if nargs == 3
            rin = c_floor(inn)
            rin += 1.0 if inn - rin >= 0.5
            rle = c_floor(le)
            rle += 1.0 if le - rle >= 0.5
            en = rin + rle
            if !(en >= 1.0)
              j = 1
            elsif en < INT_MAX
              j = en.to_i
            end
          end
          i -= 1
          j -= 1
          if i < j && i < utf8_strlen(str)
            @value_tab.push(utf8_sub(str, i, j - i))
          else
            @value_tab.push(+"")
          end
        end

        # xmlUTF8Strsub
        def utf8_sub(str, start, len)
          if str.encoding == ::Encoding::UTF_8 && str.valid_encoding?
            return str[start, len] || +""
          end

          b = str.b
          i = 0
          pos = 0
          while i < start
            c = b.getbyte(pos)
            return +"" if c.nil?

            pos += utf8_size(c)
            i += 1
          end
          stop = pos
          n = 0
          while n < len && (c = b.getbyte(stop))
            stop += utf8_size(c)
            n += 1
          end
          b.byteslice(pos, stop - pos).force_encoding(::Encoding::UTF_8)
        end

        def utf8_size(c)
          if c & 0x80 == 0 then 1
          elsif c & 0xe0 == 0xc0 then 2
          elsif c & 0xf0 == 0xe0 then 3
          else 4
          end
        end

        # xmlXPathSubstringBeforeFunction
        def fn_substring_before(nargs)
          check_arity(nargs, 2)
          cast_top_to_string
          find = @value_tab.pop
          cast_top_to_string
          str = @value_tab.pop
          sb = str.b
          point = sb.index(find.b)
          result = point.nil? ? +"" : sb.byteslice(0, point)
          @value_tab.push(result.force_encoding(::Encoding::UTF_8))
        end

        # xmlXPathSubstringAfterFunction
        def fn_substring_after(nargs)
          check_arity(nargs, 2)
          cast_top_to_string
          find = @value_tab.pop
          cast_top_to_string
          str = @value_tab.pop
          sb = str.b
          fb = find.b
          point = sb.index(fb)
          result = point.nil? ? +"" : sb.byteslice(point + fb.bytesize, sb.bytesize)
          @value_tab.push(result.force_encoding(::Encoding::UTF_8))
        end

        NORMALIZED_RE = /\A[^ \t\n\r]+(?: [^ \t\n\r]+)*\z/n
        NON_BLANK_RE = /[^ \t\n\r]+/n

        # xmlXPathNormalizeFunction
        def fn_normalize_space(nargs)
          if nargs == 0
            @value_tab.push(node_to_string(@context.node))
            nargs = 1
          end
          check_arity(nargs, 1)
          cast_top_to_string
          check_type_string
          source = @value_tab.last
          return if source.empty?

          # (IS_BLANK_CH runs collapse to one space; leading/trailing blanks go)
          t = source.b.tr("\t\n\r", "   ")
          t.squeeze!(" ")
          t.delete_prefix!(" ")
          t.delete_suffix!(" ")
          @value_tab[-1] = t.force_encoding(::Encoding::UTF_8)
        end

        # xmlXPathTranslateFunction
        def fn_translate(nargs)
          check_arity(nargs, 3)
          cast_top_to_string
          to = @value_tab.pop
          cast_top_to_string
          from = @value_tab.pop
          cast_top_to_string
          str = @value_tab.pop

          to_chars = utf8_chars(to)
          map = {}
          utf8_chars(from).each_with_index { |ch, idx| map[ch] = idx unless map.key?(ch) }
          max = to_chars.length
          target = +"".b
          b = str.b
          i = 0
          len = b.bytesize
          while i < len
            ch = b.getbyte(i)
            size = 1
            if ch & 0x80 != 0
              if ch & 0xc0 != 0xc0
                xpath_err(INVALID_CHAR_ERROR)
                break
              end
              bad = false
              c2 = ch
              k = 1
              while ((c2 <<= 1) & 0x80) != 0
                nb = b.getbyte(i + k)
                if nb.nil? || (nb & 0xc0) != 0x80
                  bad = true
                  break
                end
                k += 1
              end
              if bad
                xpath_err(INVALID_CHAR_ERROR)
                break
              end
              size = k
            end
            chs = b.byteslice(i, size)
            offset = map[chs]
            if offset
              target << to_chars[offset] if offset < max
            else
              target << chs
            end
            i += size
          end
          @value_tab.push(target.force_encoding(::Encoding::UTF_8))
        end

        # split into UTF-8 characters (as binary strings), stopping at invalid bytes
        def utf8_chars(s)
          b = s.b
          out = []
          i = 0
          len = b.bytesize
          while i < len
            size = utf8_size(b.getbyte(i))
            out << b.byteslice(i, size)
            i += size
          end
          out
        end

        # xmlXPathBooleanFunction
        def fn_boolean(nargs)
          check_arity(nargs, 1)
          cur = @value_tab.pop
          xp_error(INVALID_OPERAND) if cur.nil?
          cur = XPath.cast_to_boolean(cur) unless cur == true || cur == false
          @value_tab.push(cur)
        end

        # xmlXPathNotFunction
        def fn_not(nargs)
          check_arity(nargs, 1)
          cast_top_to_boolean
          check_type_boolean
          @value_tab[-1] = !@value_tab[-1]
        end

        def fn_true(nargs)
          check_arity(nargs, 0)
          @value_tab.push(true)
        end

        def fn_false(nargs)
          check_arity(nargs, 0)
          @value_tab.push(false)
        end

        # xmlXPathLangFunction
        def fn_lang(nargs)
          check_arity(nargs, 1)
          cast_top_to_string
          check_type_string
          lang = @value_tab.pop.b
          cur = @context.node
          the_lang = nil
          while cur && !cur.is_a?(XmlNs)
            the_lang = Tree.node_get_attr_value(cur, "lang", XML_XML_NAMESPACE)
            break if the_lang

            cur = cur.parent
          end
          ret = false
          if the_lang
            tl = the_lang.b
            ok = true
            i = 0
            while i < lang.bytesize
              if ascii_upcase(lang.getbyte(i)) != ascii_upcase(tl.getbyte(i) || 0)
                ok = false
                break
              end
              i += 1
            end
            if ok
              c = tl.getbyte(i)
              ret = true if c.nil? || c == 0x2D
            end
          end
          @value_tab.push(ret)
        end

        def ascii_upcase(c)
          c >= 0x61 && c <= 0x7A ? c - 32 : c
        end

        # xmlXPathNumberFunction
        def fn_number(nargs)
          if nargs == 0
            node = @context.node
            if node.nil?
              @value_tab.push(0.0)
            else
              @value_tab.push(XPath.string_eval_number(simple_string_value(node) || node_to_string(node)))
            end
            return
          end
          check_arity(nargs, 1)
          cur = @value_tab.pop
          cur = cast_to_number_internal(cur) unless cur.is_a?(Float)
          @value_tab.push(cur)
        end

        # xmlXPathSumFunction
        def fn_sum(nargs)
          check_arity(nargs, 1)
          xp_error(INVALID_TYPE) unless @value_tab.last.is_a?(Array)
          cur = @value_tab.pop
          res = 0.0
          i = 0
          while i < cur.length
            res += node_to_number(cur[i])
            i += 1
          end
          @value_tab.push(res)
        end

        def c_floor(x)
          return x if x.nan? || x.infinite? || x == 0

          x.floor.to_f
        end

        def c_ceil(x)
          return x if x.nan? || x.infinite? || x == 0

          r = x.ceil.to_f
          r == 0 && x < 0 ? -0.0 : r
        end

        # xmlXPathFloorFunction
        def fn_floor(nargs)
          check_arity(nargs, 1)
          cast_top_to_number
          check_type_number
          @value_tab[-1] = c_floor(@value_tab[-1])
        end

        # xmlXPathCeilingFunction
        def fn_ceiling(nargs)
          check_arity(nargs, 1)
          cast_top_to_number
          check_type_number
          @value_tab[-1] = c_ceil(@value_tab[-1])
        end

        # xmlXPathRoundFunction
        def fn_round(nargs)
          check_arity(nargs, 1)
          cast_top_to_number
          check_type_number
          f = @value_tab[-1]
          if f >= -0.5 && f < 0.5
            @value_tab[-1] = f * 0.0
          else
            rounded = c_floor(f)
            rounded += 1.0 if f - rounded >= 0.5
            @value_tab[-1] = rounded
          end
        end

        ESCAPE_URI_UNRESERVED = begin
          t = Array.new(256, false)
          ("A".."Z").each { |c| t[c.ord] = true }
          ("a".."z").each { |c| t[c.ord] = true }
          ("0".."9").each { |c| t[c.ord] = true }
          "-_.!~*'()".each_byte { |c| t[c] = true }
          t.freeze
        end
        ESCAPE_URI_RESERVED = begin
          t = Array.new(256, false)
          ";/?:@&=+$,".each_byte { |c| t[c] = true }
          t.freeze
        end

        def hex_byte?(c)
          c && ((c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) || (c >= 0x30 && c <= 0x39))
        end

        # xmlXPathEscapeUriFunction
        def fn_escape_uri(nargs)
          check_arity(nargs, 2)
          escape_reserved = pop_boolean
          cast_top_to_string
          str = @value_tab.pop
          b = str.b
          target = +"".b
          i = 0
          len = b.bytesize
          while i < len
            c = b.getbyte(i)
            if ESCAPE_URI_UNRESERVED[c] ||
                (c == 0x25 && hex_byte?(b.getbyte(i + 1)) && hex_byte?(b.getbyte(i + 2))) ||
                (!escape_reserved && ESCAPE_URI_RESERVED[c])
              target << c
            else
              target << format("%%%X%X", c >> 4, c & 0xF)
            end
            i += 1
          end
          @value_tab.push(target.force_encoding(::Encoding::UTF_8))
        end
      end

      # Two-argument functions that cast both arguments to strings and push a boolean computed
      # from them alone, as callables (hay, needle): ParserContext#eval_function computes calls
      # whose arguments are a context step and a string literal directly. The glue registers
      # nokogiri-builtin:css-class here.
      STRING_PREDICATES = {}.compare_by_identity

      # the byte-wise tests of contains() / starts-with() (two valid UTF-8 strings compare the
      # same character-wise)
      def self.utf8_pair?(a, b)
        a.encoding == ::Encoding::UTF_8 && b.encoding == ::Encoding::UTF_8 && a.valid_encoding? &&
          b.valid_encoding?
      end

      CONTAINS_PREDICATE = lambda do |hay, needle|
        utf8_pair?(hay, needle) ? hay.include?(needle) : !hay.b.index(needle.b).nil?
      end
      STARTS_WITH_PREDICATE = lambda do |hay, needle|
        utf8_pair?(hay, needle) ? hay.start_with?(needle) : hay.b.start_with?(needle.b)
      end
      # the same for the standard functions (by method name)
      STD_STRING_PREDICATES = {
        fn_contains: CONTAINS_PREDICATE,
        fn_starts_with: STARTS_WITH_PREDICATE,
      }.freeze

      FN = {}
      STANDARD_FN_METHODS = {
        "boolean" => :fn_boolean,
        "ceiling" => :fn_ceiling,
        "count" => :fn_count,
        "concat" => :fn_concat,
        "contains" => :fn_contains,
        "id" => :fn_id,
        "false" => :fn_false,
        "floor" => :fn_floor,
        "last" => :fn_last,
        "lang" => :fn_lang,
        "local-name" => :fn_local_name,
        "not" => :fn_not,
        "name" => :fn_name,
        "namespace-uri" => :fn_namespace_uri,
        "normalize-space" => :fn_normalize_space,
        "number" => :fn_number,
        "position" => :fn_position,
        "round" => :fn_round,
        "string" => :fn_string,
        "string-length" => :fn_string_length,
        "starts-with" => :fn_starts_with,
        "substring" => :fn_substring,
        "substring-before" => :fn_substring_before,
        "substring-after" => :fn_substring_after,
        "sum" => :fn_sum,
        "true" => :fn_true,
        "translate" => :fn_translate,
      }.freeze

      # ParserContext#call_std(name, nargs): calls the core function method +name+ (a
      # STANDARD_FN_METHODS value) through a case on the name, see FastCollect.run
      ParserContext.class_eval <<~RUBY, __FILE__, __LINE__ + 1
        def call_std(m, nargs)
          case m
          #{STANDARD_FN_METHODS.values.uniq.map { |f| "when :#{f} then #{f}(nargs)" }.join("\n")}
          else raise ArgumentError, "unknown core function \#{m}"
          end
        end
      RUBY
      {
        "boolean" => :fn_boolean,
        "ceiling" => :fn_ceiling,
        "count" => :fn_count,
        "concat" => :fn_concat,
        "contains" => :fn_contains,
        "id" => :fn_id,
        "false" => :fn_false,
        "floor" => :fn_floor,
        "last" => :fn_last,
        "lang" => :fn_lang,
        "local-name" => :fn_local_name,
        "not" => :fn_not,
        "name" => :fn_name,
        "namespace-uri" => :fn_namespace_uri,
        "normalize-space" => :fn_normalize_space,
        "number" => :fn_number,
        "position" => :fn_position,
        "round" => :fn_round,
        "string" => :fn_string,
        "string-length" => :fn_string_length,
        "starts-with" => :fn_starts_with,
        "substring" => :fn_substring,
        "substring-before" => :fn_substring_before,
        "substring-after" => :fn_substring_after,
        "sum" => :fn_sum,
        "true" => :fn_true,
        "translate" => :fn_translate,
        "escape-uri" => :fn_escape_uri,
      }.each do |name, meth|
        FN[name] = Kernel.eval("->(ctxt, nargs) { ctxt.#{meth}(nargs) }", binding, __FILE__, __LINE__) # rubocop:disable Security/Eval
      end
      FN.freeze

      ESCAPE_URI_NS = "http://www.w3.org/2002/08/xquery-functions"

      # xmlXPathStandardFunctions (static table, nokogiri libxml2 patch 0019)
      STANDARD_FUNCS = FN.reject { |name, _| name == "escape-uri" }.freeze

      # the function table xmlXPathRegisterAllFunctions installs, as [name, ns_uri] => callable
      DEFAULT_FUNCS = { ["escape-uri", ESCAPE_URI_NS] => FN["escape-uri"] }.freeze

      module_function

      # xmlXPathRegisterAllFunctions
      def register_all_functions(ctxt)
        ctxt.func_hash = DEFAULT_FUNCS
      end
    end
  end
end
