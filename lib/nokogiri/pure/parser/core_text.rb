# frozen_string_literal: true

module Nokogiri
  module Pure
    module Parser
      # xmlSBuf
      class SBuf
        attr_reader :str, :code

        def initialize(max)
          @str = +""
          @max = max
          @code = 0
        end

        def add(s)
          if @max - @str.bytesize < s.bytesize
            @code = ErrCode::ERR_RESOURCE_LIMIT if @code == 0
            return
          end
          @str << s
        end

        def add_char(c)
          if @max - @str.bytesize < 4
            @code = ErrCode::ERR_RESOURCE_LIMIT if @code == 0
            return
          end
          @str << (c < 0x80 ? c.chr : (Ctxt.raw_utf8(c)))
        end

        def size
          @str.bytesize
        end

        def chop!
          @str = @str.byteslice(0, @str.bytesize - 1)
        end

        def empty?
          @str.empty?
        end
      end

      class Ctxt
        TEST_CHAR_DATA_RE = /[\t\x20-\x25\x27-\x3B\x3D-\x5C\x5E-\x7F]+/
        NEWLINES_RE = /\n+/
        SPACES_RE = / +/
        # complex char data: anything but markup delimiters, CR, controls, U+FFFE/F, U+FFFD
        CHAR_DATA_COMPLEX_RE = /[^<&\]\r\x00-\x08\x0B\x0C\x0E-\x1F�￾￿]+/
        ATT_PLAIN_DQ_RE = /[^"&<\x00-\x1F\u0080-\u{10FFFF}]+/
        ATT_PLAIN_SQ_RE = /[^'&<\x00-\x1F\u0080-\u{10FFFF}]+/
        ATT_MB_RE = /[\u0080-￼\u{10000}-\u{10FFFF}]+/
        COMMENT_FAST_RE = /[\t\x20-\x2C\x2E-\x7F]+/
        GENERIC_TEXT_RE = /[^\r\x00-\x08\x0B\x0C\x0E-\x1F�￾￿]+/

        # xmlParserEntityCheck
        def parser_entity_check(extra)
          inp = @input
          entity = inp.entity
          return 0 if entity && (entity.flags & ENT_CHECKED) != 0

          consumed = inp.consumed + @cur + @sizeentities
          if entity
            entity.expanded_size = [entity.expanded_size + extra + XML_ENT_FIXED_COST, ULONG_MAX].min
            expanded = entity.expanded_size
          else
            @sizeentcopy = [@sizeentcopy + extra + XML_ENT_FIXED_COST, ULONG_MAX].min
            expanded = @sizeentcopy
          end
          if expanded > XML_PARSER_ALLOWED_EXPANSION &&
              (expanded >= ULONG_MAX || expanded / @max_ampl > consumed)
            fatal_err_msg(ErrCode::ERR_RESOURCE_LIMIT,
              "Maximum entity amplification factor exceeded, see xmlCtxtSetMaxAmplification.\n")
            halt
            return 1
          end
          0
        end

        # xmlCheckLanguageID
        def self.check_language_id(lang)
          return false if lang.nil?

          s = lang.b
          i = 0
          at = ->(k) { s.getbyte(k) || 0 }
          alpha = ->(c) { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
          digit = ->(c) { c >= 0x30 && c <= 0x39 }
          c0 = at.(0)
          if (c0 == 0x69 || c0 == 0x49 || c0 == 0x78 || c0 == 0x58) && at.(1) == 0x2D
            i = 2
            i += 1 while alpha.(at.(i))
            return at.(i) == 0
          end
          nxt = 0
          nxt += 1 while alpha.(at.(nxt))
          if nxt >= 4
            return false if nxt > 8 || at.(nxt) != 0

            return true
          end
          return false if nxt < 2
          return true if at.(nxt) == 0
          return false if at.(nxt) != 0x2D

          state = :after_lang
          loop do
            case state
            when :after_lang
              nxt += 1
              cur = nxt
              if digit.(at.(nxt))
                state = :region_m49
                next
              end
              nxt += 1 while alpha.(at.(nxt))
              len = nxt - cur
              if len == 4 then state = :script
              elsif len == 2 then state = :region
              elsif len >= 5 && len <= 8 then state = :variant
              elsif len != 3 then return false
              else
                return true if at.(nxt) == 0
                return false if at.(nxt) != 0x2D

                nxt += 1
                cur = nxt
                if digit.(at.(nxt))
                  state = :region_m49
                  next
                end
                nxt += 1 while alpha.(at.(nxt))
                len = nxt - cur
                if len == 2 then state = :region
                elsif len >= 5 && len <= 8 then state = :variant
                elsif len != 4 then return false
                else state = :script
                end
              end
            when :script
              return true if at.(nxt) == 0
              return false if at.(nxt) != 0x2D

              nxt += 1
              cur = nxt
              if digit.(at.(nxt))
                state = :region_m49
                next
              end
              nxt += 1 while alpha.(at.(nxt))
              len = nxt - cur
              if len >= 5 && len <= 8 then state = :variant
              elsif len != 2 then return false
              else state = :region
              end
            when :region
              return true if at.(nxt) == 0
              return false if at.(nxt) != 0x2D

              nxt += 1
              cur = nxt
              nxt += 1 while alpha.(at.(nxt))
              len = nxt - cur
              return false if len < 5 || len > 8

              state = :variant
            when :variant
              return true if at.(nxt) == 0
              return false if at.(nxt) != 0x2D

              return true
            when :region_m49
              if digit.(at.(nxt + 1)) && digit.(at.(nxt + 2))
                nxt += 3
                state = :region
              else
                return false
              end
            end
          end
        end

        # ---- character references ---------------------------------------------------------------

        # xmlParseCharRef
        def parse_char_ref
          val = 0
          count = 0
          if cur_byte == 0x26 && nxt(1) == 0x23 && nxt(2) == 0x78
            skip(3)
            grow
            while cur_byte != 0x3B && !stopped?
              if count > 20
                count = 0
                grow
              end
              count += 1
              c = cur_byte
              if c >= 0x30 && c <= 0x39
                val = val * 16 + (c - 0x30)
              elsif c >= 0x61 && c <= 0x66 && count < 20
                val = val * 16 + (c - 0x61) + 10
              elsif c >= 0x41 && c <= 0x46 && count < 20
                val = val * 16 + (c - 0x41) + 10
              else
                fatal_err(ErrCode::ERR_INVALID_HEX_CHARREF)
                val = 0
                break
              end
              val = 0x110000 if val > 0x110000
              next_char
              count += 1
            end
            if cur_byte == 0x3B
              @col += 1
              @cur += 1
            end
          elsif cur_byte == 0x26 && nxt(1) == 0x23
            skip(2)
            grow
            while cur_byte != 0x3B
              if count > 20
                count = 0
                grow
              end
              count += 1
              c = cur_byte
              if c >= 0x30 && c <= 0x39
                val = val * 10 + (c - 0x30)
              else
                fatal_err(ErrCode::ERR_INVALID_DEC_CHARREF)
                val = 0
                break
              end
              val = 0x110000 if val > 0x110000
              next_char
              count += 1
            end
            if cur_byte == 0x3B
              @col += 1
              @cur += 1
            end
          else
            skip(1) if cur_byte == 0x26
            fatal_err(ErrCode::ERR_INVALID_CHARREF)
          end

          if val >= 0x110000
            fatal_err_msg_int(ErrCode::ERR_INVALID_CHAR,
              "xmlParseCharRef: character reference out of bounds\n", val)
            val = 0xFFFD
          elsif !Chars.char?(val)
            fatal_err_msg_int(ErrCode::ERR_INVALID_CHAR, "xmlParseCharRef: invalid xmlChar value #{val}\n", val)
          end
          val
        end

        # xmlParseStringCharRef: parse "&#...;" in binary string +s+ at +pos+; returns [val, newpos]
        def parse_string_char_ref(s, pos)
          val = 0
          c = s.getbyte(pos) || 0
          if c == 0x26 && s.getbyte(pos + 1) == 0x23 && s.getbyte(pos + 2) == 0x78
            pos += 3
            c = s.getbyte(pos) || 0
            while c != 0x3B
              if c >= 0x30 && c <= 0x39
                val = val * 16 + (c - 0x30)
              elsif c >= 0x61 && c <= 0x66
                val = val * 16 + (c - 0x61) + 10
              elsif c >= 0x41 && c <= 0x46
                val = val * 16 + (c - 0x41) + 10
              else
                fatal_err(ErrCode::ERR_INVALID_HEX_CHARREF)
                val = 0
                break
              end
              val = 0x110000 if val > 0x110000
              pos += 1
              c = s.getbyte(pos) || 0
            end
            pos += 1 if c == 0x3B
          elsif c == 0x26 && s.getbyte(pos + 1) == 0x23
            pos += 2
            c = s.getbyte(pos) || 0
            while c != 0x3B
              if c >= 0x30 && c <= 0x39
                val = val * 10 + (c - 0x30)
              else
                fatal_err(ErrCode::ERR_INVALID_DEC_CHARREF)
                val = 0
                break
              end
              val = 0x110000 if val > 0x110000
              pos += 1
              c = s.getbyte(pos) || 0
            end
            pos += 1 if c == 0x3B
          else
            fatal_err(ErrCode::ERR_INVALID_CHARREF)
            return [0, pos]
          end

          if val >= 0x110000
            fatal_err_msg_int(ErrCode::ERR_INVALID_CHAR,
              "xmlParseStringCharRef: character reference out of bounds\n", val)
          elsif Chars.char?(val)
            return [val, pos]
          else
            fatal_err_msg_int(ErrCode::ERR_INVALID_CHAR,
              "xmlParseStringCharRef: invalid xmlChar value #{val}\n", val)
          end
          [0, pos]
        end

        # ---- blanks heuristic --------------------------------------------------------------------

        # areBlanks
        def are_blanks(str, blank_chars)
          return false if @sax.ignorable_whitespace.equal?(@sax.characters)

          sp = space
          return false if sp == 1 || sp == -2
          return false if blank_chars == 0 && str.match?(NOT_BLANK_RE)

          node = @node
          return false if node.nil?

          if (doc = @my_doc)
            prefix = node.ns&.prefix
            elem_decl = doc.int_subset&.elements&.[]([node.name, prefix])
            elem_decl = doc.ext_subset&.elements&.[]([node.name, prefix]) if elem_decl.nil? && doc.ext_subset
            if elem_decl
              return true if elem_decl.etype == ELEMENT_TYPE_ELEMENT
              return false if elem_decl.etype == ELEMENT_TYPE_ANY || elem_decl.etype == ELEMENT_TYPE_MIXED
            end
          end

          c = cur_byte
          return false if c != 0x3C && c != 0x0D
          return false if node.children.nil? && c == 0x3C && nxt(1) == 0x2F

          last_child = node.last
          if last_child.nil?
            return false if node.type != ELEMENT_NODE && node.content
          elsif last_child.type == TEXT_NODE
            return false
          elsif node.children && node.children.type == TEXT_NODE
            return false
          end
          true
        end

        # ---- names --------------------------------------------------------------------------------

        def name_start_char?(c)
          option?(PARSE_OLD10) ? Chars.old_name_start_char?(c) : Chars.name_start_char?(c)
        end

        def name_char?(c)
          option?(PARSE_OLD10) ? Chars.old_name_char?(c) : Chars.name_char?(c)
        end

        # xmlParseName
        def parse_name
          grow
          max_length = option?(PARSE_HUGE) ? XML_MAX_TEXT_LENGTH : XML_MAX_NAME_LENGTH
          c = @buf.getbyte(@cur)
          if c && ((c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x5F || c == 0x3A)
            @ss.pos = @cur
            n = @ss.skip(ASCII_NAME_RE)
            nc = @buf.getbyte(@cur + n)
            if nc && nc > 0 && nc < 0x80
              if n > max_length
                fatal_err(ErrCode::ERR_NAME_TOO_LONG, "Name")
                return nil
              end
              ret = -@buf.byteslice(@cur, n)
              @cur += n
              @col += n
              return ret
            end
          end
          parse_name_complex
        end

        # xmlParseNameComplex
        def parse_name_complex
          max_length = option?(PARSE_HUGE) ? XML_MAX_TEXT_LENGTH : XML_MAX_NAME_LENGTH
          start = @cur
          if option?(PARSE_OLD10)
            c = cur_char
            return nil if c == 0x20 || c == 0x3E || c == 0x2F || !Chars.old_name_start_char?(c)

            start = @cur
            nextl(@cl)
            c = cur_char
            while c != 0x20 && c != 0x3E && c != 0x2F && Chars.old_name_char?(c)
              nextl(@cl)
              c = cur_char
            end
          else
            # fast regexp scan, then the char at the end (may be U+FFFD / special)
            c = cur_char
            return nil if c == 0x20 || c == 0x3E || c == 0x2F || !Chars.name_start_char?(c)

            start = @cur
            nextl(@cl)
            loop do
              @ss.pos = @cur
              n = @ss.skip(NAME_CHARS_RE)
              if n && n > 0
                advance_name(n)
              end
              c = cur_char
              break unless c != 0x20 && c != 0x3E && c != 0x2F && Chars.name_char?(c)

              nextl(@cl)
            end
          end
          len = @cur - start
          # a "\r\n" after the name made xmlCurrentChar skip the "\r"
          len -= 1 if @buf.getbyte(@cur) == 0x0A && @cur > start && @buf.getbyte(@cur - 1) == 0x0D
          if len > max_length
            fatal_err(ErrCode::ERR_NAME_TOO_LONG, "Name")
            return nil
          end
          name_slice(start, len)
        end

        # the name at [start, start+len) of the buffer; replaced invalid bytes are put back raw like
        # libxml2 (which accepts U+FFFD, the value xmlCurrentChar returns for them, as a name char)
        def name_slice(start, len)
          bad = @input.bad
          if bad && bad.any? { |b| b[0] >= start && b[0] < start + len }
            out = +"".b
            i = start
            e = start + len
            while i < e
              if (b = bad.find { |x| x[0] == i })
                out << b[1].chr
                i += 3
              else
                out << @buf.getbyte(i).chr
                i += 1
              end
            end
            return -out.force_encoding(Encoding::UTF_8)
          end
          -@buf.byteslice(start, len)
        end

        # advance over +n+ bytes counting one column per byte (NEXTL(1) loops)
        def advance_bytes(n)
          return if n <= 0

          seg = @buf.byteslice(@cur, n)
          last_nl = seg.byterindex("\n")
          if last_nl
            @line += seg.count("\n")
            @col = n - last_nl
          else
            @col += n
          end
          @cur += n
        end

        # advance over a run of name chars (no newlines)
        def advance_name(n)
          seg = @buf.byteslice(@cur, n)
          @col += seg.length
          @cur += n
        end

        # xmlParseNCName: returns the name or nil
        def parse_ncname
          max_length = option?(PARSE_HUGE) ? XML_MAX_TEXT_LENGTH : XML_MAX_NAME_LENGTH
          c = @buf.getbyte(@cur)
          if c && ((c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x5F)
            @ss.pos = @cur
            n = @ss.skip(ASCII_NCNAME_RE)
            if @cur + n < @end
              nc = @buf.getbyte(@cur + n)
              if nc > 0 && nc < 0x80
                if n > max_length
                  fatal_err(ErrCode::ERR_NAME_TOO_LONG, "NCName")
                  return nil
                end
                ret = -@buf.byteslice(@cur, n)
                @cur += n
                @col += n
                return ret
              end
            end
          end
          parse_ncname_complex
        end

        # xmlParseNCNameComplex
        def parse_ncname_complex
          max_length = option?(PARSE_HUGE) ? XML_MAX_TEXT_LENGTH : XML_MAX_NAME_LENGTH
          start = @cur
          c = cur_char
          return nil if c == 0x20 || c == 0x3E || c == 0x2F || !name_start_char?(c) || c == 0x3A

          start = @cur
          if option?(PARSE_OLD10)
            while c != 0x20 && c != 0x3E && c != 0x2F && name_char?(c) && c != 0x3A
              nextl(@cl)
              c = cur_char
            end
          else
            nextl(@cl)
            loop do
              @ss.pos = @cur
              n = @ss.skip(NCNAME_CHARS_RE)
              advance_name(n) if n && n > 0
              c = cur_char
              break unless c != 0x20 && c != 0x3E && c != 0x2F && Chars.name_char?(c) && c != 0x3A

              nextl(@cl)
            end
          end
          len = @cur - start
          len -= 1 if @buf.getbyte(@cur) == 0x0A && @cur > start && @buf.getbyte(@cur - 1) == 0x0D
          if len > max_length
            fatal_err(ErrCode::ERR_NAME_TOO_LONG, "NCName")
            return nil
          end
          name_slice(start, len)
        end

        # xmlParseNameAndCompare: returns true on match, else the parsed name (or nil)
        def parse_name_and_compare(other)
          grow
          ob = other.b
          n = ob.bytesize
          if @buf.byteslice(@cur, n)&.b == ob
            c = @buf.getbyte(@cur + n) || 0
            if c == 0x3E || Chars.blank?(c)
              @col += n
              @cur += n
              return true
            end
          end
          ret = parse_name
          return true if ret == other

          ret
        end

        # xmlStringCurrentChar: [codepoint, length] of the char at +pos+ of binary +s+ (0 if invalid)
        def string_cur_char(s, pos)
          c = s.getbyte(pos)
          return [0, 0] if c.nil?
          return [c, 1] if c < 0x80

          l = EncodingSupport.utf8_seq(s, pos, s.bytesize)
          return [0, 0] if l <= 0

          v = s.byteslice(pos, l).force_encoding(Encoding::UTF_8).ord
          [v, l]
        end

        # xmlParseStringName: name from binary string +s+ at +pos+ -> [name, newpos]
        def parse_string_name(s, pos)
          max_length = option?(PARSE_HUGE) ? XML_MAX_TEXT_LENGTH : XML_MAX_NAME_LENGTH
          c, l = string_cur_char(s, pos)
          return [nil, pos] unless name_start_char?(c)

          start = pos
          pos += l
          loop do
            c, l = string_cur_char(s, pos)
            break unless name_char?(c)

            pos += l
            if pos - start > max_length
              fatal_err(ErrCode::ERR_NAME_TOO_LONG, "NCName")
              return [nil, pos]
            end
          end
          [s.byteslice(start, pos - start).force_encoding(Encoding::UTF_8), pos]
        end

        # xmlParseNmtoken
        def parse_nmtoken
          max_length = option?(PARSE_HUGE) ? XML_MAX_TEXT_LENGTH : XML_MAX_NAME_LENGTH
          start = @cur
          out = +""
          c = cur_char
          while name_char?(c)
            out << utf8_chr(c)
            nextl(@cl)
            if out.bytesize >= XML_MAX_NAMELEN
              c = cur_char
              while name_char?(c)
                out << utf8_chr(c)
                if out.bytesize > max_length
                  fatal_err(ErrCode::ERR_NAME_TOO_LONG, "NmToken")
                  return nil
                end
                nextl(@cl)
                c = cur_char
              end
              return out
            end
            c = cur_char
          end
          _ = start
          return nil if out.empty?
          if out.bytesize > max_length
            fatal_err(ErrCode::ERR_NAME_TOO_LONG, "NmToken")
            return nil
          end
          out
        end

        # ---- literals --------------------------------------------------------------------------

        # xmlParseSystemLiteral
        def parse_system_literal
          max_length = option?(PARSE_HUGE) ? XML_MAX_TEXT_LENGTH : XML_MAX_NAME_LENGTH
          c = cur_byte
          if c == 0x22
            next_char
            stop = 0x22
          elsif c == 0x27
            next_char
            stop = 0x27
          else
            fatal_err(ErrCode::ERR_LITERAL_NOT_STARTED)
            return nil
          end
          buf = +""
          cur = cur_char
          while Chars.char?(cur) && cur != stop
            buf << utf8_chr(cur)
            if buf.bytesize > max_length
              fatal_err(ErrCode::ERR_NAME_TOO_LONG, "SystemLiteral")
              return nil
            end
            nextl(@cl)
            cur = cur_char
          end
          if !Chars.char?(cur)
            fatal_err(ErrCode::ERR_LITERAL_NOT_FINISHED)
          else
            next_char
          end
          buf
        end

        # xmlParsePubidLiteral
        def parse_pubid_literal
          max_length = option?(PARSE_HUGE) ? XML_MAX_TEXT_LENGTH : XML_MAX_NAME_LENGTH
          c = cur_byte
          if c == 0x22
            next_char
            stop = 0x22
          elsif c == 0x27
            next_char
            stop = 0x27
          else
            fatal_err(ErrCode::ERR_LITERAL_NOT_STARTED)
            return nil
          end
          buf = +""
          cur = cur_byte
          while Chars.pubid_char?(cur) && cur != stop && !stopped?
            buf << cur.chr
            if buf.bytesize > max_length
              fatal_err(ErrCode::ERR_NAME_TOO_LONG, "Public ID")
              return nil
            end
            next_char
            cur = cur_byte
          end
          if cur != stop
            fatal_err(ErrCode::ERR_LITERAL_NOT_FINISHED)
          else
            nextl(1)
          end
          buf
        end

        # xmlParseExternalID: returns [uri, public_id]
        def parse_external_id(strict)
          uri = nil
          public_id = nil
          if cmp?("SYSTEM")
            skip(6)
            if skip_blanks == 0
              fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after 'SYSTEM'\n")
            end
            uri = parse_system_literal
            fatal_err(ErrCode::ERR_URI_REQUIRED) if uri.nil?
          elsif cmp?("PUBLIC")
            skip(6)
            if skip_blanks == 0
              fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after 'PUBLIC'\n")
            end
            public_id = parse_pubid_literal
            fatal_err(ErrCode::ERR_PUBID_REQUIRED) if public_id.nil?
            if strict
              if skip_blanks == 0
                fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Space required after the Public Identifier\n")
              end
            else
              return [nil, public_id] if skip_blanks == 0
              return [nil, public_id] if cur_byte != 0x27 && cur_byte != 0x22
            end
            uri = parse_system_literal
            fatal_err(ErrCode::ERR_URI_REQUIRED) if uri.nil?
          end
          [uri, public_id]
        end

        # ---- character data -----------------------------------------------------------------------

        def sax_characters(str)
          cb = @sax.characters
          cb&.call(@user_data, str)
        end

        # deliver char data (the areBlanks dispatch shared by the char data parsers)
        def deliver_chars(str, blank_chars)
          sax = @sax
          if are_blanks(str, blank_chars)
            sax.ignorable_whitespace&.call(@user_data, str)
          else
            sax.characters&.call(@user_data, str)
            self.space = -2 if space == -1
          end
        end

        # xmlParseCharDataInternal
        def parse_char_data_internal(partial)
          line = @line
          col = @col
          grow
          inp = @cur
          buf = @buf
          ss = @ss
          sax = @sax
          loop do
            # get_more_space
            loop do
              if buf.getbyte(inp) == 0x20
                ss.pos = inp
                n = ss.skip(SPACES_RE)
                inp += n
                @col += n
              end
              if buf.getbyte(inp) == 0x0A
                ss.pos = inp
                n = ss.skip(NEWLINES_RE)
                @line += n
                @col = 1
                inp += n
                next
              end
              break
            end
            if buf.getbyte(inp) == 0x3C
              nbchar = inp - @cur
              if nbchar > 0
                tmp = buf.byteslice(@cur, nbchar)
                @cur = inp
                if @disable_sax == 0 && !sax.ignorable_whitespace.equal?(sax.characters)
                  if are_blanks(tmp, 1)
                    sax.ignorable_whitespace&.call(@user_data, tmp)
                  else
                    sax.characters&.call(@user_data, tmp)
                    self.space = -2 if space == -1
                  end
                elsif @disable_sax == 0
                  sax.characters&.call(@user_data, tmp)
                end
              end
              return
            end

            # get_more
            loop do
              ss.pos = inp
              n = ss.skip(TEST_CHAR_DATA_RE)
              if n
                inp += n
                @col += n
              end
              c = buf.getbyte(inp)
              if c == 0x0A
                ss.pos = inp
                n = ss.skip(NEWLINES_RE)
                @line += n
                @col = 1
                inp += n
                next
              end
              if c == 0x5D
                if buf.getbyte(inp + 1) == 0x5D && buf.getbyte(inp + 2) == 0x3E
                  fatal_err(ErrCode::ERR_MISPLACED_CDATA_END)
                  @cur = inp + 1
                  return
                end
                inp += 1
                @col += 1
                next
              end
              break
            end
            nbchar = inp - @cur
            if nbchar > 0
              if @disable_sax == 0 && !sax.ignorable_whitespace.equal?(sax.characters) &&
                  Chars.blank?(buf.getbyte(@cur))
                tmp = buf.byteslice(@cur, nbchar)
                @cur = inp
                if are_blanks(tmp, 0)
                  sax.ignorable_whitespace&.call(@user_data, tmp)
                else
                  sax.characters&.call(@user_data, tmp)
                  self.space = -2 if space == -1
                end
                line = @line
                col = @col
              elsif @disable_sax == 0
                sax.characters&.call(@user_data, buf.byteslice(@cur, nbchar))
                line = @line
                col = @col
              end
            end
            @cur = inp
            c = buf.getbyte(inp)
            if c == 0x0D
              if buf.getbyte(inp + 1) == 0x0A
                @cur = inp + 1
                inp += 2
                @line += 1
                @col = 1
                c = buf.getbyte(inp)
                break unless c && ((c >= 0x20 && c <= 0x7F) || c == 0x09 || c == 0x0A)

                next
              end
            end
            return if c == 0x3C || c == 0x26

            grow
            inp = @cur
            c = buf.getbyte(inp)
            break unless c && ((c >= 0x20 && c <= 0x7F) || c == 0x09 || c == 0x0A)
          end
          @line = line
          @col = col
          parse_char_data_complex(partial)
        end

        # xmlParseCharDataComplex
        def parse_char_data_complex(partial)
          out = +""
          cur = cur_char
          while cur != 0x3C && cur != 0x26 && Chars.char?(cur)
            if cur == 0x5D && nxt(1) == 0x5D && nxt(2) == 0x3E
              fatal_err(ErrCode::ERR_MISPLACED_CDATA_END)
            end
            out << (cur < 0x80 ? cur.chr : cur.chr(Encoding::UTF_8))
            nextl(@cl)
            if out.bytesize >= XML_PARSER_BIG_BUFFER_SIZE
              emit_complex_chars(out)
              out = +""
            end
            @ss.pos = @cur
            n = @ss.skip(CHAR_DATA_COMPLEX_RE)
            if n
              out << @buf.byteslice(@cur, n)
              advance_text(n)
              while out.bytesize >= XML_PARSER_BIG_BUFFER_SIZE
                cut = XML_PARSER_BIG_BUFFER_SIZE
                cut += 1 while cut < out.bytesize && (out.getbyte(cut) & 0xC0) == 0x80
                piece = out.byteslice(0, cut)
                out = out.byteslice(cut, out.bytesize - cut)
                emit_complex_chars(piece)
              end
            end
            cur = cur_char
          end
          emit_complex_chars(out) unless out.empty?

          if @cur < @end
            if cur == 0 && cur_byte != 0
              if partial == 0
                b = bad_byte_at(@cur)
                byte = b ? b[1] : cur_byte
                fatal_err_msg_int(ErrCode::ERR_INVALID_CHAR,
                  format("Incomplete UTF-8 sequence starting with %02X\n", byte), byte)
                if b
                  @col += 1
                  @cur += 3
                else
                  nextl(1)
                end
              end
            elsif cur != 0x3C && cur != 0x26
              fatal_err_msg_int(ErrCode::ERR_INVALID_CHAR, "PCDATA invalid Char value #{cur}\n", cur)
              nextl(@cl)
            end
          end
        end

        def emit_complex_chars(str)
          return if @disable_sax != 0

          sax = @sax
          if are_blanks(str, 0)
            sax.ignorable_whitespace&.call(@user_data, str)
          else
            sax.characters&.call(@user_data, str)
            self.space = -2 if !sax.characters.equal?(sax.ignorable_whitespace) && space == -1
          end
        end

        # ---- comments ------------------------------------------------------------------------------

        # xmlParseCommentComplex
        def parse_comment_complex(buf)
          max_length = option?(PARSE_HUGE) ? XML_MAX_HUGE_LENGTH : XML_MAX_TEXT_LENGTH
          buf ||= +""
          q = cur_char
          ql = @cl
          if q == 0
            fatal_err_msg_str(ErrCode::ERR_COMMENT_NOT_FINISHED, "Comment not terminated\n", nil)
            return
          end
          unless Chars.char?(q)
            fatal_err_msg_int(ErrCode::ERR_INVALID_CHAR, "xmlParseComment: invalid xmlChar value #{q}\n", q)
            return
          end
          nextl(ql)
          r = cur_char
          rl = @cl
          if r == 0
            fatal_err_msg_str(ErrCode::ERR_COMMENT_NOT_FINISHED, "Comment not terminated\n", nil)
            return
          end
          unless Chars.char?(r)
            fatal_err_msg_int(ErrCode::ERR_INVALID_CHAR, "xmlParseComment: invalid xmlChar value #{r}\n", r)
            return
          end
          nextl(rl)
          cur = cur_char
          l = @cl
          if cur == 0
            fatal_err_msg_str(ErrCode::ERR_COMMENT_NOT_FINISHED, "Comment not terminated\n", nil)
            return
          end
          while Chars.char?(cur) && (cur != 0x3E || r != 0x2D || q != 0x2D)
            fatal_err(ErrCode::ERR_HYPHEN_IN_COMMENT) if r == 0x2D && q == 0x2D
            buf << (q < 0x80 ? q.chr : q.chr(Encoding::UTF_8))
            if buf.bytesize > max_length
              fatal_err_msg_str(ErrCode::ERR_COMMENT_NOT_FINISHED, "Comment too big found", nil)
              return
            end
            q = r
            r = cur
            nextl(l)
            cur = cur_char
            l = @cl
          end
          if cur == 0
            fatal_err_msg_str(ErrCode::ERR_COMMENT_NOT_FINISHED,
              "Comment not terminated \n<!--#{trunc50(buf)}\n", buf)
          elsif !Chars.char?(cur)
            fatal_err_msg_int(ErrCode::ERR_INVALID_CHAR, "xmlParseComment: invalid xmlChar value #{cur}\n", cur)
          else
            next_char
            if @disable_sax == 0 && (cb = @sax.comment)
              cb.call(@user_data, buf)
            end
          end
        end

        # "%.50s"
        def trunc50(s)
          return s if s.bytesize <= 50

          s.b.byteslice(0, 50).force_encoding(Encoding::UTF_8)
        end

        # xmlParseComment
        def parse_comment
          return if cur_byte != 0x3C || nxt(1) != 0x21

          skip(2)
          return if cur_byte != 0x2D || nxt(1) != 0x2D

          skip(2)
          grow
          max_length = option?(PARSE_HUGE) ? XML_MAX_HUGE_LENGTH : XML_MAX_TEXT_LENGTH
          buf = nil
          b = @buf
          ss = @ss
          inp = @cur
          if b.getbyte(inp) == 0x0A
            ss.pos = inp
            n = ss.skip(NEWLINES_RE)
            @line += n
            @col = 1
            inp += n
          end
          loop do
            # get_more
            loop do
              ss.pos = inp
              n = ss.skip(COMMENT_FAST_RE)
              if n
                inp += n
                @col += n
              end
              if b.getbyte(inp) == 0x0A
                ss.pos = inp
                n = ss.skip(NEWLINES_RE)
                @line += n
                @col = 1
                inp += n
                next
              end
              break
            end
            nbchar = inp - @cur
            if nbchar > 0
              buf ||= +""
              buf << b.byteslice(@cur, nbchar)
            end
            if buf && buf.bytesize > max_length
              fatal_err_msg_str(ErrCode::ERR_COMMENT_NOT_FINISHED, "Comment too big found", nil)
              return
            end
            @cur = inp
            if b.getbyte(inp) == 0x0D && b.getbyte(inp + 1) == 0x0A
              @cur = inp + 1
              inp += 2
              @line += 1
              @col = 1
              next
            end
            grow
            inp = @cur
            if b.getbyte(inp) == 0x2D
              if b.getbyte(inp + 1) == 0x2D
                if b.getbyte(inp + 2) == 0x3E
                  skip(3)
                  if @disable_sax == 0 && (cb = @sax.comment)
                    cb.call(@user_data, buf || +"")
                  end
                  return
                end
                if buf
                  fatal_err_msg_str(ErrCode::ERR_HYPHEN_IN_COMMENT,
                    "Double hyphen within comment: <!--#{trunc50(buf)}\n", buf)
                else
                  fatal_err_msg_str(ErrCode::ERR_HYPHEN_IN_COMMENT, "Double hyphen within comment\n", nil)
                end
                inp += 1
                @col += 1
              end
              inp += 1
              @col += 1
              next
            end
            break
          end
          parse_comment_complex(buf)
        end
      end
    end
  end
end
