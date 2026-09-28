# frozen_string_literal: true

# Port of libxslt 1.1.43 numbers.c: xsl:number formatting (xsltNumberFormat and its helpers)
# and the format-number() engine (xsltFormatNumberConversion / xsltFormatNumberPreSuffix).
#
# The C code walks NUL-terminated byte strings with raw pointers; this port works on binary
# (ASCII-8BIT) copies of the strings with integer byte offsets, where reading past the end
# yields 0 (the terminating NUL). All arithmetic is done on Ruby Floats, which are IEEE
# doubles exactly like the C code's, using helpers that reproduce C's fmod()/floor().

module Nokogiri
  module Pure
    module XSLT
      # static helpers of numbers.c
      module Numbers
        SYMBOL_QUOTE = 0x27 # '\''
        DEFAULT_TOKEN = 0x30 # '0'
        DEFAULT_SEPARATOR = "."
        MAX_TOKENS = 1024
        DBL_MAX_10_EXP = 308

        ALPHA_UPPER_LIST = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        ALPHA_LOWER_LIST = "abcdefghijklmnopqrstuvwxyz"

        # xsltFormatToken
        FormatToken = Struct.new(:separator, :token, :width)
        # xsltFormat
        Format = Struct.new(:start, :tokens, :end) do
          def n_tokens = tokens.length
        end
        # xsltFormatNumberInfo
        FormatNumberInfo = Struct.new(:integer_hash, :integer_digits, :frac_digits, :frac_hash,
          :group, :multiplier, :add_decimal, :is_multiplier_set, :is_negative_pattern)

        DEFAULT_TOKEN_REC = FormatToken.new(DEFAULT_SEPARATOR.b.freeze, DEFAULT_TOKEN, 1).freeze

        DIGIT_ZEROS = [0x0030, 0x0660, 0x06F0, 0x0966, 0x09E6, 0x0A66, 0x0AE6, 0x0B66,
                       0x0C66, 0x0CE6, 0x0D66, 0x0E50, 0x0ED0, 0x0F20].freeze

        module_function

        # ---- C string / double helpers -------------------------------------------------------

        # a binary copy of +str+ as C sees it (up to the first NUL), or nil
        def cstr(str)
          return nil if str.nil?

          s = str.b
          i = s.index("\0")
          i ? s.byteslice(0, i) : s
        end

        # *(s + i), with the implicit terminating NUL
        def bat(s, i)
          s.getbyte(i) || 0
        end

        # xmlStrlen
        def strlen(s)
          s.nil? ? 0 : s.bytesize
        end

        # C fmod(): exact remainder with the sign of the dividend
        def fmod(x, y)
          return Float::NAN if x.nan? || y.nan? || x.infinite? || y.zero?
          return x if y.infinite?

          y = y.abs
          x.negative? || (x.zero? && (1.0 / x).negative?) ? -((-x) % y) : x % y
        end

        # C floor()
        def floor(x)
          return x if x.nan? || x.infinite? || x.zero?

          r = x.floor.to_f
          r.zero? && x.negative? ? -0.0 : r
        end

        # (int) cast of a double known to be small
        def to_int(x)
          x.nan? ? -2_147_483_648 : x.to_i
        end

        # xmlUTF8Strsize(utf + i, 1)
        def utf8_size1(s, i)
          return 0 if s.nil?

          ch = bat(s, i)
          return 0 if ch == 0

          ptr = i + 1
          if (ch & 0x80) != 0
            while ((ch <<= 1) & 0x80) != 0
              break if bat(s, ptr) == 0

              ptr += 1
            end
          end
          ptr - i
        end

        # xmlStrncmp(a + ai, b + bi, len)
        def strncmp(a, ai, b, bi, len)
          return 0 if len <= 0
          return -1 if a.nil?
          return 1 if b.nil?

          loop do
            cb = bat(b, bi)
            tmp = bat(a, ai) - cb
            len -= 1
            return tmp if tmp != 0 || len == 0
            return 0 if cb == 0

            ai += 1
            bi += 1
          end
        end

        # xsltUTF8Charcmp(utf1 + i, utf2)
        def charcmp(utf1, i, utf2)
          len = utf8_size1(utf1, i)
          return -1 if len < 1

          strncmp(utf1, i, utf2, 0, len)
        end

        # xmlUTF8Strloc
        def utf8_strloc(utf, utfchar)
          return -1 if utf.nil? || utfchar.nil?

          size = utf8_size1(utfchar, 0)
          i = 0
          p = 0
          while (ch = bat(utf, p)) != 0
            return i if strncmp(utf, p, utfchar, 0, size) == 0

            p += 1
            if (ch & 0x80) != 0
              return -1 if (ch & 0xc0) != 0xc0

              while ((ch <<= 1) & 0x80) != 0
                b = bat(utf, p)
                p += 1
                return -1 if (b & 0xc0) != 0x80
              end
            end
            i += 1
          end
          -1
        end

        # xmlUTF8Strpos: byte offset of char +pos+, or nil
        def utf8_strpos(utf, pos)
          return nil if utf.nil? || pos < 0

          p = 0
          while pos > 0
            pos -= 1
            ch = bat(utf, p)
            p += 1
            return nil if ch == 0

            next unless (ch & 0x80) != 0
            return nil if (ch & 0xc0) != 0xc0

            while ((ch <<= 1) & 0x80) != 0
              b = bat(utf, p)
              p += 1
              return nil if (b & 0xc0) != 0x80
            end
          end
          p
        end

        # xsltGetUTF8CharZ(s + i, &len): [val, len]
        def get_utf8_char_z(s, i)
          c = bat(s, i)
          return [c, 1] if (c & 0x80) == 0

          c1 = bat(s, i + 1)
          return [-1, 0] if (c1 & 0xc0) != 0x80

          if (c & 0xe0) == 0xe0
            c2 = bat(s, i + 2)
            return [-1, 0] if (c2 & 0xc0) != 0x80

            if (c & 0xf0) == 0xf0
              c3 = bat(s, i + 3)
              return [-1, 0] if (c & 0xf8) != 0xf0 || (c3 & 0xc0) != 0x80

              [((c & 0x7) << 18) | ((c1 & 0x3f) << 12) | ((c2 & 0x3f) << 6) | (c3 & 0x3f), 4]
            else
              [((c & 0xf) << 12) | ((c1 & 0x3f) << 6) | (c2 & 0x3f), 3]
            end
          else
            [((c & 0x1f) << 6) | (c1 & 0x3f), 2]
          end
        end

        # xsltGetUTF8Char(str, &len) with len = xmlStrlen(str): [val, len] or [-1, 0]
        def get_utf8_char(s)
          return [-1, 0] if s.nil? || s.empty?

          c = s.getbyte(0)
          return [c, 1] if (c & 0x80) == 0

          avail = s.bytesize
          return [-1, 0] if avail < 2 || (s.getbyte(1) & 0xc0) != 0x80

          if (c & 0xe0) == 0xe0
            return [-1, 0] if avail < 3 || (s.getbyte(2) & 0xc0) != 0x80

            if (c & 0xf0) == 0xf0
              return [-1, 0] if (c & 0xf8) != 0xf0 || avail < 4 || (s.getbyte(3) & 0xc0) != 0x80

              [((c & 0x7) << 18) | ((s.getbyte(1) & 0x3f) << 12) | ((s.getbyte(2) & 0x3f) << 6) |
                (s.getbyte(3) & 0x3f), 4]
            else
              [((c & 0xf) << 12) | ((s.getbyte(1) & 0x3f) << 6) | (s.getbyte(2) & 0x3f), 3]
            end
          else
            [((c & 0x1f) << 6) | (s.getbyte(1) & 0x3f), 2]
          end
        end

        # xsltCopyCharMultiByte: the UTF-8 bytes written for +val+ (possibly none)
        def copy_char_multi_byte(val)
          return [] if val < 0
          return [val] if val < 0x80

          if val < 0x800
            out = [(val >> 6) | 0xC0]
            bits = 0
          elsif val < 0x10000
            out = [(val >> 12) | 0xE0]
            bits = 6
          elsif val < 0x110000
            out = [(val >> 18) | 0xF0]
            bits = 12
          else
            return []
          end
          while bits >= 0
            out << (((val >> bits) & 0x3F) | 0x80)
            bits -= 6
          end
          out
        end

        # xsltIsLetterDigit
        def letter_digit?(val)
          return false if val < 0

          XPath::Chars.letter?(val) || XPath::Chars.digit?(val)
        end

        # xsltIsDigitZero
        def digit_zero?(ch)
          DIGIT_ZEROS.include?(ch)
        end

        # IS_DIGIT_ONE
        def digit_one?(ch)
          digit_zero?(ch - 1)
        end

        # IS_SPECIAL(self, letter)
        def special?(sf, s, i)
          charcmp(s, i, sf.zero_digit) == 0 || charcmp(s, i, sf.digit) == 0 ||
            charcmp(s, i, sf.decimal_point) == 0 || charcmp(s, i, sf.grouping) == 0 ||
            charcmp(s, i, sf.pattern_separator) == 0
        end

        # ---- xsl:number ---------------------------------------------------------------------

        # xsltNumberFormatDecimal: appends to the binary String +buffer+. The C code builds the
        # digits backwards into a 500-byte stack buffer; +pointer+ tracks that position so the
        # "buffer size exceeded" truncation happens at exactly the same place.
        def format_decimal(buffer, number, digit_zero, width, digits_per_group,
                           grouping_character, grouping_character_len)
          chunks = [] # right to left
          pointer = 499 # &temp_string[sizeof(temp_string)] - 1, holding the NUL
          i = 0
          while pointer > 0
            break if i >= width && number.abs < 1.0

            if i > 0 && grouping_character != 0 && digits_per_group > 0 &&
                (i % digits_per_group) == 0
              if pointer - grouping_character_len < 0
                i = -1
                break
              end
              pointer -= grouping_character_len
              chunks << copy_char_multi_byte(grouping_character).pack("C*")
            end

            val = digit_zero + to_int(fmod(number, 10.0))
            if val < 0x80
              if pointer <= 0
                i = -1
                break
              end
              pointer -= 1
              chunks << (val & 0xFF).chr
            else
              bytes = copy_char_multi_byte(val)
              if pointer - bytes.length < 0
                i = -1
                break
              end
              pointer -= bytes.length
              chunks << bytes.pack("C*")
            end
            number /= 10.0
            i += 1
          end
          XSLT.generic_error("xsltNumberFormatDecimal: Internal buffer size exceeded\n") if i < 0
          s = chunks.reverse.join.b
          # xmlBufferCat stops at the first NUL (a zero-digit of "" yields NUL digits)
          nul = s.index("\0")
          buffer << (nul ? s.byteslice(0, nul) : s)
        end

        # xsltNumberFormatAlpha
        def format_alpha(data, buffer, number, is_upper)
          alpha_size = 26.0
          if number < 1.0
            format_decimal(buffer, number, 0x30, 1, data.digits_per_group,
                           data.grouping_character, data.grouping_character_len)
            return
          end

          alpha_list = is_upper ? ALPHA_UPPER_LIST : ALPHA_LOWER_LIST
          out = []
          i = 1
          while i < 65 # sizeof(temp_string) == 65
            number -= 1
            out << alpha_list[to_int(fmod(number, alpha_size))]
            number /= alpha_size
            break if number < 1.0

            i += 1
          end
          buffer << out.reverse.join
        end

        ROMAN_STEPS = [
          [1000.0, "M", true], [900.0, "CM", false], [500.0, "D", true], [400.0, "CD", false],
          [100.0, "C", true], [90.0, "XC", false], [50.0, "L", true], [40.0, "XL", false],
          [10.0, "X", true], [9.0, "IX", false], [5.0, "V", true], [4.0, "IV", false],
          [1.0, "I", true]
        ].freeze

        # xsltNumberFormatRoman
        def format_roman(data, buffer, number, is_upper)
          if number < 1.0 || number > 5000.0
            format_decimal(buffer, number, 0x30, 1, data.digits_per_group,
                           data.grouping_character, data.grouping_character_len)
            return
          end

          ROMAN_STEPS.each do |value, sym, repeat|
            sym = sym.downcase unless is_upper
            if repeat
              while number >= value
                buffer << sym
                number -= value
              end
            elsif number >= value
              buffer << sym
              number -= value
            end
          end
        end

        # xsltNumberFormatTokenize: returns a Format
        def tokenize(format)
          f = cstr(format) || "".b
          tokens = Format.new(nil, [], nil)
          ix = 0

          # initial non-alphanumeric token
          loop do
            val, len = get_utf8_char_z(f, ix)
            break if letter_digit?(val)
            break if bat(f, ix) == 0

            ix += len > 0 ? len : 1
          end
          tokens.start = f.byteslice(0, ix) if ix > 0

          while tokens.n_tokens < MAX_TOKENS
            break if bat(f, ix) == 0

            tok = FormatToken.new(nil, 0, 0)
            if tokens.n_tokens > 0
              tok.separator = tokens.end
              tokens.end = nil
            end

            val, len = get_utf8_char_z(f, ix)
            if digit_one?(val) || digit_zero?(val)
              tok.width = 1
              while digit_zero?(val)
                tok.width += 1
                ix += len
                val, len = get_utf8_char_z(f, ix)
              end
              if digit_one?(val)
                tok.token = val - 1
                ix += len
                val, len = get_utf8_char_z(f, ix)
              else
                tok.token = 0x30
                tok.width = 1
              end
            elsif val == 0x41 || val == 0x61 || val == 0x49 || val == 0x69 # A a I i
              tok.token = val
              ix += len
              val, len = get_utf8_char_z(f, ix)
            else
              tok.token = 0x30
              tok.width = 1
            end

            while letter_digit?(val)
              ix += len
              val, len = get_utf8_char_z(f, ix)
            end

            j = ix
            until letter_digit?(val)
              break if val == 0

              ix += len > 0 ? len : 1
              val, len = get_utf8_char_z(f, ix)
            end
            tokens.end = f.byteslice(j, ix - j) if ix > j
            tokens.tokens << tok
          end
          tokens
        end

        # xsltNumberFormatInsertNumbers: +numbers+ is in C array order (innermost first)
        def insert_numbers(data, numbers, tokens, buffer)
          numbers_max = numbers.length
          buffer << tokens.start if tokens.start

          numbers_max.times do |i|
            number = numbers[(numbers_max - 1) - i]
            number = floor(number + 0.5)
            if number < 0.0
              XSLT.transform_error(nil, nil, nil, "xsl-number : negative value\n")
              number = 0.0
            end
            token = if i < tokens.n_tokens
              tokens.tokens[i]
            elsif tokens.n_tokens > 0
              tokens.tokens[tokens.n_tokens - 1]
            else
              DEFAULT_TOKEN_REC
            end

            if i > 0
              buffer << (token.separator || DEFAULT_SEPARATOR)
            end

            if number.infinite?
              buffer << (number.negative? ? "-Infinity" : "Infinity")
            elsif number.nan?
              buffer << "NaN"
            else
              case token.token
              when 0x41 then format_alpha(data, buffer, number, true)
              when 0x61 then format_alpha(data, buffer, number, false)
              when 0x49 then format_roman(data, buffer, number, true)
              when 0x69 then format_roman(data, buffer, number, false)
              else
                if digit_zero?(token.token)
                  format_decimal(buffer, number, token.token, token.width, data.digits_per_group,
                                 data.grouping_character, data.grouping_character_len)
                end
              end
            end
          end

          buffer << tokens.end if tokens.end
        end

        # format an array of numbers (outermost first) with a format string; for unit tests
        def format_numbers(data, numbers, format)
          buf = +"".b
          insert_numbers(data, numbers.reverse, tokenize(format), buf)
          buf.force_encoding(Encoding::UTF_8)
        end

        # xsltTestCompMatchList as a Ruby boolean
        def match_list?(context, node, pat)
          r = XSLT.test_comp_match_list(context, node, pat)
          r == true || (r.is_a?(Integer) && r != 0)
        end

        # xsltTestCompMatchCount
        def test_comp_match_count(context, node, count_pat, cur)
          return match_list?(context, node, count_pat) if count_pat

          return false if node.type != cur.type
          return true if node.type == NAMESPACE_DECL
          return false if node.name != cur.name
          return true if node.ns.equal?(cur.ns)
          return false if node.ns.nil? || cur.ns.nil?

          node.ns.href == cur.ns.href
        end

        # xsltNumberFormatGetAnyLevel: returns the (single) count
        def get_any_level(context, node, count_pat, from_pat)
          cnt = 0
          cur = node
          while cur
            cnt += 1 if test_comp_match_count(context, cur, count_pat, node)
            break if from_pat && match_list?(context, cur, from_pat)
            break if cur.type == DOCUMENT_NODE || cur.type == HTML_DOCUMENT_NODE

            if cur.type == NAMESPACE_DECL
              cur = cur.next
            elsif cur.type == ATTRIBUTE_NODE
              cur = cur.parent
            else
              while cur.prev && (cur.prev.type == DTD_NODE || cur.prev.type == XINCLUDE_START ||
                                 cur.prev.type == XINCLUDE_END)
                cur = cur.prev
              end
              if cur.prev
                cur = cur.prev
                cur = cur.last while cur.last
              else
                cur = cur.parent
              end
            end
          end
          cnt.to_f
        end

        # xsltNumberFormatGetMultipleLevel: returns the counts, innermost first
        def get_multiple_level(context, node, count_pat, from_pat, max)
          array = []
          ancestor = node
          while ancestor && ancestor.type != DOCUMENT_NODE
            break if from_pat && match_list?(context, ancestor, from_pat)

            if test_comp_match_count(context, ancestor, count_pat, node)
              cnt = 1
              preceding = ancestor.type != NAMESPACE_DECL ? ancestor.prev : nil
              while preceding
                cnt += 1 if test_comp_match_count(context, preceding, count_pat, node)
                preceding = preceding.prev
              end
              array << cnt.to_f
              break if array.length >= max
            end

            if ancestor.type == NAMESPACE_DECL
              nxt = ancestor.next
              ancestor = nxt && nxt.type != NAMESPACE_DECL ? nxt : nil
            else
              ancestor = ancestor.parent
            end
          end
          array
        end

        # xsltNumberFormatGetValue: returns the number or nil
        def get_value(context, node, value)
          old_node = context.node
          pattern = +"number("
          pattern << value
          pattern << ")"
          context.node = node
          obj = XPath.eval_expression(pattern, context)
          number = nil
          unless obj.nil?
            number = obj.is_a?(Float) ? obj : XPath.cast_to_number(obj)
          end
          context.node = old_node
          number
        end

        # xsltFormatNumberPreSuffix: returns [count, new_pos]
        def pre_suffix(sf, f, pos, info)
          count = 0
          loop do
            return [count, pos] if bat(f, pos) == 0

            if bat(f, pos) == SYMBOL_QUOTE
              pos += 1
              return [-1, pos] if bat(f, pos) == 0
            elsif special?(sf, f, pos)
              return [count, pos]
            elsif charcmp(f, pos, sf.percent) == 0
              return [-1, pos] if info.is_multiplier_set

              info.multiplier = 100
              info.is_multiplier_set = true
            elsif charcmp(f, pos, sf.permille) == 0
              return [-1, pos] if info.is_multiplier_set

              info.multiplier = 1000
              info.is_multiplier_set = true
            end

            len = utf8_size1(f, pos)
            return [-1, pos] if len < 1

            count += len
            pos += len
          end
        end

        # xmlBufferAdd(buffer, str, xmlUTF8Strsize(str, 1))
        def add_first_char(buffer, str)
          return if str.nil?

          len = utf8_size1(str, 0)
          buffer << str.byteslice(0, len) if len > 0
        end

        # the prefix/suffix output loops of xsltFormatNumberConversion
        def add_affix(buffer, f, pos, length)
          j = 0
          while j < length
            pos += 1 if bat(f, pos) == SYMBOL_QUOTE
            len = utf8_size1(f, pos)
            break if len == 0 # cannot happen: the length was measured on the same bytes

            buffer << f.byteslice(pos, len)
            pos += len
            j += len
          end
        end

        # xsltFormatNumberConversion: returns [status, result]
        def format_number_conversion(self_fmt, format, number)
          status = XPath::EXPRESSION_OK
          f = cstr(format) || "".b
          if f.empty?
            XSLT.transform_error(nil, nil, nil,
                                 "xsltFormatNumberConversion : Invalid format (0-length)\n")
          end
          if number.nan?
            return [status, "NaN"] if self_fmt.nil? || self_fmt.no_number.nil?

            return [status, self_fmt.no_number.dup]
          end

          sf = Struct.new(:digit, :pattern_separator, :minus_sign, :infinity, :no_number,
                          :decimal_point, :grouping, :percent, :permille, :zero_digit)
            .new(cstr(self_fmt.digit), cstr(self_fmt.pattern_separator),
                 cstr(self_fmt.minus_sign), cstr(self_fmt.infinity), cstr(self_fmt.no_number),
                 cstr(self_fmt.decimal_point), cstr(self_fmt.grouping), cstr(self_fmt.percent),
                 cstr(self_fmt.permille), cstr(self_fmt.zero_digit))

          info = FormatNumberInfo.new(0, 0, 0, 0, -1, 1, false, false, false)
          delayed_multiplier = 0
          default_sign = false
          prefix = nil
          suffix = nil
          prefix_length = 0
          suffix_length = 0
          len = 0

          found_error = catch(:output_number) do
            tf = 0
            prefix = tf
            prefix_length, tf = pre_suffix(sf, f, tf, info)
            throw :output_number, true if prefix_length < 0

            self_grouping_len = strlen(sf.grouping)
            while bat(f, tf) != 0 && charcmp(f, tf, sf.decimal_point) != 0 &&
                charcmp(f, tf, sf.pattern_separator) != 0
              if delayed_multiplier != 0
                info.multiplier = delayed_multiplier
                info.is_multiplier_set = true
                delayed_multiplier = 0
              end
              if charcmp(f, tf, sf.digit) == 0
                throw :output_number, true if info.integer_digits > 0

                info.integer_hash += 1
                info.group += 1 if info.group >= 0
              elsif charcmp(f, tf, sf.zero_digit) == 0
                info.integer_digits += 1
                info.group += 1 if info.group >= 0
              elsif self_grouping_len > 0 && strncmp(f, tf, sf.grouping, 0, self_grouping_len) == 0
                info.group = 0
                tf += self_grouping_len
                next
              elsif charcmp(f, tf, sf.percent) == 0
                throw :output_number, true if info.is_multiplier_set

                delayed_multiplier = 100
              elsif charcmp(f, tf, sf.permille) == 0
                throw :output_number, true if info.is_multiplier_set

                delayed_multiplier = 1000
              else
                break
              end

              len = utf8_size1(f, tf)
              throw :output_number, true if len < 1

              tf += len
            end

            # fraction
            if bat(f, tf) != 0 && charcmp(f, tf, sf.decimal_point) == 0
              info.add_decimal = true
              len = utf8_size1(f, tf)
              throw :output_number, true if len < 1

              tf += len
            end

            while bat(f, tf) != 0
              if charcmp(f, tf, sf.zero_digit) == 0
                throw :output_number, true if info.frac_hash != 0

                info.frac_digits += 1
              elsif charcmp(f, tf, sf.digit) == 0
                info.frac_hash += 1
              elsif charcmp(f, tf, sf.percent) == 0
                throw :output_number, true if info.is_multiplier_set

                delayed_multiplier = 100
                len = utf8_size1(f, tf)
                throw :output_number, true if len < 1

                tf += len
                next
              elsif charcmp(f, tf, sf.permille) == 0
                throw :output_number, true if info.is_multiplier_set

                delayed_multiplier = 1000
                len = utf8_size1(f, tf)
                throw :output_number, true if len < 1

                tf += len
                next
              elsif charcmp(f, tf, sf.grouping) != 0
                break
              end
              len = utf8_size1(f, tf)
              throw :output_number, true if len < 1

              tf += len
              if delayed_multiplier != 0
                info.multiplier = delayed_multiplier
                delayed_multiplier = 0
                info.is_multiplier_set = true
              end
            end

            if delayed_multiplier != 0
              tf -= len
              delayed_multiplier = 0
            end

            suffix = tf
            suffix_length, tf = pre_suffix(sf, f, tf, info)
            if suffix_length < 0 ||
                (bat(f, tf) != 0 && charcmp(f, tf, sf.pattern_separator) != 0)
              throw :output_number, true
            end

            if number < 0
              j = utf8_strloc(f, sf.pattern_separator)
              if j < 0
                default_sign = true
              else
                tf = utf8_strpos(f, j + 1)
                info.is_negative_pattern = true
                info.is_multiplier_set = false

                nprefix = tf
                nprefix_length, tf = pre_suffix(sf, f, tf, info)
                throw :output_number, true if nprefix_length < 0

                while bat(f, tf) != 0
                  if charcmp(f, tf, sf.percent) == 0 || charcmp(f, tf, sf.permille) == 0
                    throw :output_number, true if info.is_multiplier_set

                    info.is_multiplier_set = true
                    delayed_multiplier = 1
                  elsif special?(sf, f, tf)
                    delayed_multiplier = 0
                  else
                    break
                  end
                  len = utf8_size1(f, tf)
                  throw :output_number, true if len < 1

                  tf += len
                end
                if delayed_multiplier != 0
                  info.is_multiplier_set = false
                  tf -= len
                end

                nsuffix = nil
                if bat(f, tf) != 0
                  nsuffix = tf
                  nsuffix_length, tf = pre_suffix(sf, f, tf, info)
                  throw :output_number, true if nsuffix_length < 0
                else
                  nsuffix_length = 0
                end
                throw :output_number, true if bat(f, tf) != 0

                if nprefix_length != prefix_length || nsuffix_length != suffix_length ||
                    (nprefix_length > 0 && strncmp(f, nprefix, f, prefix, prefix_length) != 0) ||
                    (nsuffix_length > 0 && strncmp(f, nsuffix, f, suffix, suffix_length) != 0)
                  prefix = nprefix
                  prefix_length = nprefix_length
                  suffix = nsuffix
                  suffix_length = nsuffix_length
                end
              end
            end
            false
          end

          # OUTPUT_NUMBER:
          if found_error
            XSLT.transform_error(nil, nil, nil,
                                 "xsltFormatNumberConversion : error in format string " \
                                 "'#{f.dup.force_encoding(Encoding::UTF_8)}', using default\n")
            default_sign = number < 0.0
            prefix_length = suffix_length = 0
            info.integer_hash = 0
            info.integer_digits = 1
            info.frac_digits = 1
            info.frac_hash = 4
            info.group = -1
            info.multiplier = 1
            info.add_decimal = true
          end

          number *= info.multiplier.to_f
          if number.infinite?
            result = +""
            result << (sf.minus_sign.nil? ? "-" : sf.minus_sign) if number < 0
            result << (sf.infinity.nil? ? "Infinity" : sf.infinity)
            return [status, result.force_encoding(Encoding::UTF_8)]
          end

          buffer = +"".b
          add_first_char(buffer, sf.minus_sign) if default_sign

          add_affix(buffer, f, prefix, prefix_length) if prefix_length > 0

          # round to n digits
          number = number.abs
          exp10 = info.frac_digits + info.frac_hash
          if exp10 > DBL_MAX_10_EXP
            if info.frac_digits > DBL_MAX_10_EXP
              info.frac_digits = DBL_MAX_10_EXP
              info.frac_hash = 0
            else
              info.frac_hash = DBL_MAX_10_EXP - info.frac_digits
            end
            exp10 = DBL_MAX_10_EXP
          end
          scale = 10.0**exp10
          number += 0.5 / scale
          number -= fmod(number, 1.0 / scale)

          zero0 = bat(sf.zero_digit || "".b, 0)
          # integer part
          if sf.grouping && bat(sf.grouping, 0) != 0
            gchar, glen = get_utf8_char(sf.grouping)
            format_decimal(buffer, floor(number), zero0, info.integer_digits, info.group, gchar, glen)
          else
            format_decimal(buffer, floor(number), zero0, info.integer_digits, info.group, 0x2C, 1)
          end

          # java treats '.#' like '.0', '.##' like '.0#', etc.
          if info.integer_digits + info.integer_hash + info.frac_digits == 0 && info.frac_hash > 0
            info.frac_digits += 1
            info.frac_hash -= 1
          end

          # leading zero
          if floor(number) == 0 && info.integer_digits + info.frac_digits == 0
            add_first_char(buffer, sf.zero_digit)
          end

          # fractional part
          if info.frac_digits + info.frac_hash == 0
            add_first_char(buffer, sf.decimal_point) if info.add_decimal
          else
            number -= floor(number)
            if number != 0 || info.frac_digits != 0
              add_first_char(buffer, sf.decimal_point)
              number = floor(scale * number + 0.5)
              j = info.frac_hash
              while j > 0
                break if fmod(number, 10.0) >= 1.0

                number /= 10.0
                j -= 1
              end
              format_decimal(buffer, floor(number), zero0, info.frac_digits + j, 0, 0, 0)
            end
          end

          add_affix(buffer, f, suffix, suffix_length) if suffix_length > 0

          [status, buffer.force_encoding(Encoding::UTF_8)]
        end
      end

      module_function

      # xsltFormatNumberConversion(self, format, number, &result): returns [status, result]
      def format_number_conversion(self_fmt, format, number)
        Numbers.format_number_conversion(self_fmt, format, number)
      end

      # xsltNumberFormat: convert one xsl:number instruction
      def number_format(ctxt, data, node)
        if !data.format.nil?
          tokens = Numbers.tokenize(data.format)
        else
          # the format needs to be recomputed each time
          return if !data.has_format || data.has_format == 0

          format = eval_attr_value_template(ctxt, data.node, "format", NAMESPACE)
          return if format.nil?

          tokens = Numbers.tokenize(format)
        end

        output = +"".b

        if data.value
          number = Numbers.get_value(ctxt.xpath_ctxt, node, data.value)
          Numbers.insert_numbers(data, [number], tokens, output) unless number.nil?
        elsif data.level
          case data.level
          when "single"
            array = Numbers.get_multiple_level(ctxt, node, data.count_pat, data.from_pat, 1)
            Numbers.insert_numbers(data, array, tokens, output) if array.length == 1
          when "multiple"
            array = Numbers.get_multiple_level(ctxt, node, data.count_pat, data.from_pat, 1024)
            Numbers.insert_numbers(data, array, tokens, output) unless array.empty?
          when "any"
            number = Numbers.get_any_level(ctxt, node, data.count_pat, data.from_pat)
            Numbers.insert_numbers(data, [number], tokens, output)
          end

          # count/from patterns may contain variable references: clear the match cache
          if respond_to?(:comp_match_clear_cache)
            comp_match_clear_cache(ctxt, data.count_pat) if data.count_pat
            comp_match_clear_cache(ctxt, data.from_pat) if data.from_pat
          end
        end

        copy_text_string(ctxt, ctxt.insert, output.force_encoding(Encoding::UTF_8), false)
      end
    end
  end
end
