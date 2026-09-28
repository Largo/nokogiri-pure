# frozen_string_literal: true

# The pull parser proper: a line-by-line port of libxml2 2.13.9 HTMLparser.c (htmlParseDocument
# and everything below it). Function names in comments refer to the C originals.

module Nokogiri
  module Pure
    module HTMLParser
      class Context
        # ---- character level helpers (macros of HTMLparser.c / parserInternals.c) ----

        def blank_ch?(c)
          c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        end

        def ascii_letter?(c)
          (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
        end

        def ascii_digit?(c)
          c >= 0x30 && c <= 0x39
        end

        # GROW
        def grow_macro
          grow if !progressive? && @buf.bytesize - @cur < INPUT_CHUNK
        end

        # NEXTL(l)
        def nextl(l)
          if @buf.getbyte(@cur) == 10
            @line += 1
            @col = 1
          else
            @col += 1
          end
          @cur += l
        end

        # NEXT == xmlNextChar
        def next_char
          avail = @buf.bytesize - @cur
          if avail < INPUT_CHUNK
            grow
            return if @cur >= @buf.bytesize

            avail = @buf.bytesize - @cur
          end
          c = @buf.getbyte(@cur)
          if c < 0x80
            if c == 10
              @cur += 1
              @line += 1
              @col = 1
            elsif c == 13
              @cur += (@buf.getbyte(@cur + 1) == 10 ? 2 : 1)
              @line += 1
              @col = 1
            else
              @cur += 1
              @col += 1
            end
            return
          end
          @col += 1
          ok = false
          c1 = @buf.getbyte(@cur + 1) || 0
          if avail >= 2 && (c1 & 0xC0) == 0x80
            if c < 0xE0
              if c >= 0xC2
                @cur += 2
                ok = true
              end
            else
              val = (c << 8) | c1
              c2 = @buf.getbyte(@cur + 2) || 0
              if avail >= 3 && (c2 & 0xC0) == 0x80
                if c < 0xF0
                  unless val < 0xE0A0 || (val >= 0xEDA0 && val < 0xEE00)
                    @cur += 3
                    ok = true
                  end
                else
                  c3 = @buf.getbyte(@cur + 3) || 0
                  if avail >= 4 && (c3 & 0xC0) == 0x80 && !(val < 0xF090 || val >= 0xF490)
                    @cur += 4
                    ok = true
                  end
                end
              end
            end
          end
          return if ok

          if (@input_flags & INPUT_ENCODING_ERROR) == 0
            ctxt_err_io(Err::INVALID_ENCODING, nil)
            @input_flags |= INPUT_ENCODING_ERROR
          end
          @cur += 1
        end

        # htmlFindEncoding
        def find_encoding
          return nil if (@input_flags & INPUT_HAS_ENCODING) != 0

          s = bytes_at(@cur, @buf.bytesize - @cur)
          return nil if s.nil?

          # C string search: stops at the first NUL byte
          nul = s.index("\0".b)
          s = s.byteslice(0, nul) if nul

          i = s.index(/HTTP-EQUIV/in)
          return nil unless i

          j = s.index(/CONTENT/in, i)
          return nil unless j

          k = s.index(/CHARSET=/in, j)
          return nil unless k

          k += 8
          m = s.byteslice(k..).match(%r{\A[A-Za-z0-9\-_:/]+}n)
          return nil unless m

          m[0]
        end

        # htmlCurrentChar: returns the code point, sets @clen
        def current_char
          grow if @buf.bytesize - @cur < INPUT_CHUNK
          if (@input_flags & INPUT_HAS_ENCODING) == 0
            c = @buf.getbyte(@cur) || 0
            if c < 0x80
              if c == 0
                if @cur < @buf.bytesize
                  html_err_int(Err::INVALID_CHAR, "Char 0x0 out of allowed range\n", 0)
                  @clen = 1
                  return 0x20
                end
                @clen = 0
                return 0
              end
              @clen = 1
              return c
            end
            guess = find_encoding
            if guess.nil?
              switch_encoding(:latin1)
            else
              switch_input_encoding_name(guess)
            end
            @input_flags |= INPUT_HAS_ENCODING
          end

          c = @buf.getbyte(@cur) || 0
          if c & 0x80 != 0
            avail = @buf.bytesize - @cur
            val = nil
            catch(:encoding_error) do
              throw :encoding_error if (c & 0x40) == 0

              c1 = @buf.getbyte(@cur + 1) || 0
              throw :encoding_error if avail < 2 || (c1 & 0xC0) != 0x80
              if (c & 0xE0) == 0xE0
                c2 = @buf.getbyte(@cur + 2) || 0
                throw :encoding_error if avail < 3 || (c2 & 0xC0) != 0x80
                if (c & 0xF0) == 0xF0
                  c3 = @buf.getbyte(@cur + 3) || 0
                  throw :encoding_error if (c & 0xF8) != 0xF0 || avail < 4 || (c3 & 0xC0) != 0x80
                  @clen = 4
                  v = ((c & 0x07) << 18) | ((c1 & 0x3F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F)
                  throw :encoding_error if v < 0x10000
                else
                  @clen = 3
                  v = ((c & 0x0F) << 12) | ((c1 & 0x3F) << 6) | (c2 & 0x3F)
                  throw :encoding_error if v < 0x800
                end
              else
                @clen = 2
                v = ((c & 0x1F) << 6) | (c1 & 0x3F)
                throw :encoding_error if v < 0x80
              end
              val = v
            end
            if val
              unless ChValid.char?(val)
                html_err_int(Err::INVALID_CHAR, format("Char 0x%X out of allowed range\n", val), val)
              end
              return val
            end
            # encoding_error:
            ctxt_err_io(Err::INVALID_ENCODING, nil)
            switch_encoding(:latin1) if (@input_flags & INPUT_HAS_ENCODING) == 0
            @clen = 1
            return @buf.getbyte(@cur) || 0
          end
          if c == 0
            if @cur < @buf.bytesize
              html_err_int(Err::INVALID_CHAR, "Char 0x0 out of allowed range\n", 0)
              @clen = 1
              return 0x20
            end
            @clen = 0
            return 0
          end
          @clen = 1
          c
        end

        # htmlSkipBlankChars
        def skip_blanks
          res = 0
          while blank_ch?(@buf.getbyte(@cur) || 0)
            if @buf.getbyte(@cur) == 10
              @line += 1
              @col = 1
            else
              @col += 1
            end
            @cur += 1
            grow if (@buf.getbyte(@cur) || 0) == 0
            res += 1
          end
          res
        end

        # COPY_BUF
        def copy_buf(l, out, v)
          if l == 1
            out << (v & 0xFF)
          else
            HTMLParser.utf8_append(out, v)
          end
        end

        # a copy of @buf[pos, len] that never shares @buf's memory (a shared substring or a
        # MatchData would make every later append to @buf copy the whole buffer)
        def bytes_at(pos, len)
          return +"".b if len <= 0 || pos >= @buf.bytesize

          @buf.unpack1("a#{len}", offset: pos)
        end

        # StringScanner-based anchored match at +pos+ (no MatchData on @buf); returns String or nil
        def scan_at(pos, re)
          ss = @scanner
          if ss.nil? || !ss.string.equal?(@buf)
            ss = @scanner = StringScanner.new(@buf)
          end
          ss.pos = pos
          ss.scan(re)
        end

        # a StringScanner over @buf (strings it returns are copies, never shared with @buf)
        def scanner
          ss = @scanner
          if ss.nil? || !ss.string.equal?(@buf)
            ss = @scanner = StringScanner.new(@buf)
          end
          ss
        end

        NAME_CACHE = {} # rubocop:disable Style/MutableConstant

        def cached_name(run)
          NAME_CACHE[run] || begin
            NAME_CACHE.clear if NAME_CACHE.size > 5000
            NAME_CACHE[run.freeze] = intern(run.downcase)
          end
        end

        def intern(bytes)
          -(bytes.dup.force_encoding(Encoding::UTF_8))
        end

        # ---- auto close / implied elements -----------------------------------

        # htmlAutoCloseOnClose
        def auto_close_on_close(newtag)
          priority = HTMLParser.get_end_priority(newtag)
          i = @name_tab.length - 1
          while i >= 0
            break if newtag == @name_tab[i]
            return if HTMLParser.get_end_priority(@name_tab[i]) > priority

            i -= 1
          end
          return if i < 0

          while newtag != @name
            info = HTMLParser.tag_lookup(@name)
            if info && info.end_tag == 3
              html_err(Err::TAG_NAME_MISMATCH, "Opening and ending tag mismatch: #{newtag} and #{@name}\n",
                newtag, @name)
            end
            sax_end_element(@name)
            name_pop
          end
        end

        # htmlAutoCloseOnEnd
        def auto_close_on_end
          return if @name_tab.empty?

          (@name_tab.length - 1).downto(0) do
            sax_end_element(@name)
            name_pop
          end
        end

        # htmlAutoClose
        def auto_close(newtag)
          return if newtag.nil?

          while @name && HTMLParser.check_auto_close(newtag, @name)
            sax_end_element(@name)
            name_pop
          end
        end

        # htmlCheckImplied
        def check_implied(newtag)
          return if (@options & PARSE_NOIMPLIED) != 0
          return if newtag == "html"

          if @name_tab.empty?
            name_push("html")
            sax_start_element("html", nil)
          end
          return if newtag == "body" || newtag == "head"

          if @name_tab.length <= 1 &&
              (newtag == "script" || newtag == "style" || newtag == "meta" || newtag == "link" ||
               newtag == "title" || newtag == "base")
            return if @html >= 3

            name_push("head")
            sax_start_element("head", nil)
          elsif newtag != "noframes" && newtag != "frame" && newtag != "frameset"
            return if @html >= 10
            return if @name_tab.any? { |n| n == "body" || n == "head" }

            name_push("body")
            sax_start_element("body", nil)
          end
        end

        # htmlCheckParagraph
        def check_paragraph
          tag = @name
          if tag.nil?
            auto_close("p")
            check_implied("p")
            name_push("p")
            sax_start_element("p", nil)
            return 1
          end
          if NO_CONTENT_ELEMENTS.include?(tag)
            auto_close("p")
            check_implied("p")
            name_push("p")
            sax_start_element("p", nil)
            return 1
          end
          0
        end

        # areBlanks
        def are_blanks(str)
          c0 = str.getbyte(0)
          return false if c0 && c0 != 0x20 && c0 != 0x0A && c0 != 0x09 && c0 != 0x0D
          return false unless str.match?(BLANK_RUN)

          c = @buf.getbyte(@cur) || 0
          return true if c == 0
          return false if c != 0x3C
          return true if @name.nil?
          return true if @name == "html"
          return true if @name == "head"

          if @name == "body" && @my_doc
            dtd = Tree.get_int_subset(@my_doc)
            if dtd && dtd.external_id &&
                (HTMLParser.strcasecmp(dtd.external_id, "-//W3C//DTD HTML 4.01//EN") == 0 ||
                 HTMLParser.strcasecmp(dtd.external_id, "-//W3C//DTD HTML 4//EN") == 0)
              return true
            end
          end

          return false if @node.nil?

          last = @node.last
          last = last.prev while last && last.type == COMMENT_NODE
          if last.nil?
            return false if @node.type != ELEMENT_NODE && !@node.content.nil?
            return false if ALLOW_PCDATA.include?(@name)
          elsif last.type == TEXT_NODE
            return false
          elsif ALLOW_PCDATA.include?(last.name)
            return false
          end
          true
        end

        # ---- names ---------------------------------------------------------------

        def html_name_char?(c)
          ascii_letter?(c) || ascii_digit?(c) || c == 0x3A || c == 0x2D || c == 0x5F || c == 0x2E
        end

        # htmlParseHTMLName
        def parse_html_name
          c = @buf.getbyte(@cur) || 0
          return nil if !ascii_letter?(c) && c != 0x5F && c != 0x3A && c != 0x2E

          if !growable? || @buf.bytesize - @cur > INPUT_CHUNK + HTML_PARSER_BUFFER_SIZE
            # fast path: no NEXT in the loop can trigger a buffer grow
            run = scan_at(@cur, /[A-Za-z0-9:_.\-]{1,100}/n)
            @cur += run.bytesize
            @col += run.bytesize
            return cached_name(run)
          end
          loc = +"".b
          i = 0
          while i < HTML_PARSER_BUFFER_SIZE && html_name_char?(c)
            loc << (c >= 0x41 && c <= 0x5A ? c + 0x20 : c)
            i += 1
            next_char
            c = @buf.getbyte(@cur) || 0
          end
          intern(loc)
        end

        # htmlParseHTMLName_nonInvasive
        def parse_html_name_non_invasive
          c = nxt(1)
          return nil if !ascii_letter?(c) && c != 0x5F && c != 0x3A

          run = scan_at(@cur + 1, /[A-Za-z0-9:_\-]{1,100}/n)
          return cached_name(run) if run

          loc = +"".b
          i = 0
          loop do
            break unless i < HTML_PARSER_BUFFER_SIZE

            c = nxt(1 + i)
            break unless ascii_letter?(c) || ascii_digit?(c) || c == 0x3A || c == 0x2D || c == 0x5F

            loc << (c >= 0x41 && c <= 0x5A ? c + 0x20 : c)
            i += 1
          end
          intern(loc)
        end

        # htmlParseName
        def parse_name
          grow_macro
          i = @cur
          c = @buf.getbyte(i) || 0
          if ascii_letter?(c) || c == 0x5F || c == 0x3A
            i += 1
            loop do
              c = @buf.getbyte(i) || 0
              break unless ascii_letter?(c) || ascii_digit?(c) || c == 0x5F || c == 0x2D || c == 0x3A || c == 0x2E

              i += 1
            end
            return nil if i == @buf.bytesize

            c = @buf.getbyte(i) || 0
            if c > 0 && c < 0x80
              count = i - @cur
              ret = intern(bytes_at(@cur, count))
              @cur = i
              @col += count
              return ret
            end
          end
          parse_name_complex
        end

        # htmlParseNameComplex
        def parse_name_complex
          max_length = (@options & PARSE_HUGE) != 0 ? MAX_TEXT_LENGTH : MAX_NAME_LENGTH
          gen = @buf_generation
          len = 0
          c = current_char
          l = @clen
          if c == 0x20 || c == 0x3E || c == 0x2F || (!ChValid.letter?(c) && c != 0x5F && c != 0x3A)
            return nil
          end

          while c != 0x20 && c != 0x3E && c != 0x2F &&
              (ChValid.letter?(c) || ChValid.digit?(c) || c == 0x2E || c == 0x2D || c == 0x5F ||
               c == 0x3A || ChValid.combining?(c) || ChValid.extender?(c))
            len += l
            if len > max_length
              html_err(Err::NAME_TOO_LONG, "name too long")
              return nil
            end
            nextl(l)
            c = current_char
            l = @clen
            return parse_name_complex if @buf_generation != gen
          end
          if @cur < len
            html_err(Err::INTERNAL_ERROR, "unexpected change of input buffer")
            return nil
          end
          intern(bytes_at(@cur - len, len))
        end

        # ---- attribute values, literals -------------------------------------------

        # htmlParseHTMLAttribute
        def parse_html_attribute(stop)
          max_length = (@options & PARSE_HUGE) != 0 ? MAX_HUGE_LENGTH : MAX_TEXT_LENGTH
          out = +"".b
          while !stopped?
            c = @buf.getbyte(@cur) || 0
            break if c == 0 || c == stop
            break if stop == 0 && c == 0x3E
            break if stop == 0 && blank_ch?(c)

            if c == 0x26
              if nxt(1) == 0x23
                v = parse_char_ref
                HTMLParser.utf8_append(out, v)
              else
                ent, name = parse_entity_ref
                if name.nil?
                  out << 0x26
                elsif ent.nil?
                  out << 0x26
                  out << name.b
                else
                  HTMLParser.utf8_append(out, ent.value)
                end
              end
            else
              # fast path for plain ASCII runs
              if (@buf.bytesize - @cur) > INPUT_CHUNK || !growable?
                run = if stop == 0
                  scan_at(@cur, /[^\x00&>\t\n\r \x80-\xFF]+/n)
                elsif stop == 0x22
                  scan_at(@cur, /[^\x00&"\n\x80-\xFF]+/n)
                else
                  scan_at(@cur, /[^\x00&'\n\x80-\xFF]+/n)
                end
                if run
                  lim = growable? ? @buf.bytesize - INPUT_CHUNK - @cur : run.bytesize
                  if lim > 0
                    run = run.byteslice(0, lim) if run.bytesize > lim
                    out << run
                    @cur += run.bytesize
                    @col += run.bytesize
                    if out.bytesize > max_length
                      html_err(Err::ATTRIBUTE_NOT_FINISHED, "attribute value too long\n")
                      return nil
                    end
                    next
                  end
                end
              end
              v = current_char
              l = @clen
              HTMLParser.utf8_append(out, v)
              nextl(l)
            end
            if out.bytesize > max_length
              html_err(Err::ATTRIBUTE_NOT_FINISHED, "attribute value too long\n")
              return nil
            end
          end
          nul = out.index("\0".b)
          out = out.byteslice(0, nul) if nul
          out.force_encoding(Encoding::UTF_8)
        end

        # htmlParseEntityRef: returns [entity_desc_or_nil, name_or_nil]
        def parse_entity_ref
          name_out = nil
          ent = nil
          if (@buf.getbyte(@cur) || 0) == 0x26
            next_char
            name = parse_name
            if name.nil?
              html_err(Err::NAME_REQUIRED, "htmlParseEntityRef: no name\n")
            else
              grow_macro
              if (@buf.getbyte(@cur) || 0) == 0x3B
                name_out = name
                ent = HTMLParser.entity_lookup(name)
                next_char if ent
              else
                html_err(Err::ENTITYREF_SEMICOL_MISSING, "htmlParseEntityRef: expecting ';'\n")
                name_out = name
              end
            end
          end
          [ent, name_out]
        end

        # htmlParseAttValue
        def parse_att_value
          c = @buf.getbyte(@cur) || 0
          if c == 0x22
            next_char
            ret = parse_html_attribute(0x22)
            if (@buf.getbyte(@cur) || 0) != 0x22
              html_err(Err::ATTRIBUTE_NOT_FINISHED, "AttValue: \" expected\n")
            else
              next_char
            end
          elsif c == 0x27
            next_char
            ret = parse_html_attribute(0x27)
            if (@buf.getbyte(@cur) || 0) != 0x27
              html_err(Err::ATTRIBUTE_NOT_FINISHED, "AttValue: ' expected\n")
            else
              next_char
            end
          else
            ret = parse_html_attribute(0)
            html_err(Err::ATTRIBUTE_WITHOUT_VALUE, "AttValue: no value found\n") if ret.nil?
          end
          ret
        end

        # htmlParseSystemLiteral
        def parse_system_literal
          c = @buf.getbyte(@cur) || 0
          if c != 0x22 && c != 0x27
            html_err(Err::LITERAL_NOT_STARTED, "SystemLiteral \" or ' expected\n")
            return nil
          end
          quote = c
          next_char
          start = @cur
          len = 0
          err = false
          while !stopped?
            c = @buf.getbyte(@cur) || 0
            break if c == 0 || c == quote

            unless c == 0x9 || c == 0xA || c == 0xD || c >= 0x20
              html_err_int(Err::INVALID_CHAR, format("Invalid char in SystemLiteral 0x%X\n", c), c)
              err = true
            end
            next_char
            len += 1
          end
          ret = nil
          if (@buf.getbyte(@cur) || 0) != quote
            html_err(Err::LITERAL_NOT_FINISHED, "Unfinished SystemLiteral\n")
          else
            ret = HTMLParser.to_utf8(bytes_at(start, len)) unless err
            next_char
          end
          ret
        end

        PUBID_CHARS = begin
          t = Array.new(256, false)
          ("a".."z").each { |ch| t[ch.ord] = true }
          ("A".."Z").each { |ch| t[ch.ord] = true }
          ("0".."9").each { |ch| t[ch.ord] = true }
          " \r\n-'()+,./:=?;!*#@$_%".each_byte { |b| t[b] = true }
          t.freeze
        end

        # htmlParsePubidLiteral
        def parse_pubid_literal
          c = @buf.getbyte(@cur) || 0
          if c != 0x22 && c != 0x27
            html_err(Err::LITERAL_NOT_STARTED, "PubidLiteral \" or ' expected\n")
            return nil
          end
          quote = c
          next_char
          start = @cur
          len = 0
          err = false
          while !stopped?
            c = @buf.getbyte(@cur) || 0
            break if c == 0 || c == quote

            unless PUBID_CHARS[c]
              html_err_int(Err::INVALID_CHAR, format("Invalid char in PubidLiteral 0x%X\n", c), c)
              err = true
            end
            len += 1
            next_char
          end
          ret = nil
          if (@buf.getbyte(@cur) || 0) != quote
            html_err(Err::LITERAL_NOT_FINISHED, "Unfinished PubidLiteral\n")
          else
            ret = HTMLParser.to_utf8(bytes_at(start, len)) unless err
            next_char
          end
          ret
        end

        # ---- script / character data -------------------------------------------

        def flush_script(buf)
          if @sax_cdata_block
            @sax.cdata_block(@user_data, buf.force_encoding(Encoding::UTF_8))
          elsif @sax_characters
            @sax.characters(@user_data, buf.force_encoding(Encoding::UTF_8))
          end
        end

        # htmlParseScript
        def parse_script
          buf = +"".b
          cur = current_char
          l = @clen
          while cur != 0
            if cur == 0x3C && nxt(1) == 0x2F
              if @recovery != 0
                if HTMLParser.strncasecmp_at(@name, @buf, @cur + 2)
                  break
                else
                  html_err(Err::TAG_NAME_MISMATCH, "Element #{@name.nil? ? "(null)" : @name} embeds close tag\n", @name)
                end
              elsif ascii_letter?(nxt(2))
                break
              end
            end
            if cur < 0x80 && cur != 0x3C && l == 1 && cur == @buf.getbyte(@cur) &&
                (cur >= 0x20 || cur == 0x9 || cur == 0xA || cur == 0xD) &&
                (run = scan_at(@cur, /[^<\x00-\x08\x0B\x0C\x0E-\x1F\x80-\xFF]+/n))
              # fast path: copy a run of plain ASCII
              lim = HTML_PARSER_BIG_BUFFER_SIZE - buf.bytesize
              lim = [lim, @buf.bytesize - INPUT_CHUNK - @cur].min if growable?
              lim = 1 if lim < 1
              run = run.byteslice(0, lim) if run.bytesize > lim
              buf << run
              advance_run(run)
            else
              if ChValid.char?(cur)
                copy_buf(l, buf, cur)
              else
                html_err_int(Err::INVALID_CHAR, format("Invalid char in CDATA 0x%X\n", cur), cur)
              end
              nextl(l)
            end
            if buf.bytesize >= HTML_PARSER_BIG_BUFFER_SIZE
              flush_script(buf)
              buf = +"".b
              shrink_macro
            end
            cur = current_char
            l = @clen
          end
          flush_script(buf) if !buf.empty? && @disable_sax == 0
        end

        # advance over a run of complete, valid chars already copied (NEXTL for each: a "\n" starts
        # a new line, every other char -- whatever its UTF-8 length -- is one column)
        CONT_BYTES = "\x80-\xBF".b.freeze

        def advance_run(run)
          n = run.count("\n")
          if n > 0
            @line += n
            last = run.rindex("\n")
            if run.ascii_only?
              @col = run.bytesize - last
            else
              tail = run.byteslice(last + 1, run.bytesize)
              @col = 1 + tail.bytesize - tail.count(CONT_BYTES)
            end
          else
            @col += run.ascii_only? ? run.bytesize : run.bytesize - run.count(CONT_BYTES)
          end
          @cur += run.bytesize
        end

        # one valid UTF-8 encoded char that htmlCurrentChar decodes without complaint and IS_CHAR
        # accepts (no surrogates, U+FFFE/U+FFFF or values above U+10FFFF)
        UTF8_CHAR_SRC = "[\xC2-\xDF][\x80-\xBF]|\xE0[\xA0-\xBF][\x80-\xBF]|[\xE1-\xEC\xEE][\x80-\xBF]{2}|" \
          "\xED[\x80-\x9F][\x80-\xBF]|\xEF(?:[\x80-\xBE][\x80-\xBF]|\xBF[\x80-\xBD])|" \
          "\xF0[\x90-\xBF][\x80-\xBF]{2}|[\xF1-\xF3][\x80-\xBF]{3}|\xF4[\x80-\x8F][\x80-\xBF]{2}"
        # runs of character data that htmlParseCharDataInternal copies char by char without errors
        TEXT_RUN_ASCII = /[^<&\x00-\x08\x0B\x0C\x0E-\x1F\x80-\xFF]+/n
        TEXT_RUN_UTF8 = Regexp.new(
          "(?:[\\x09\\x0A\\x0D\\x20-\\x25\\x27-\\x3B\\x3D-\\x7F]+|#{UTF8_CHAR_SRC})+".b, Regexp::NOENCODING
        )
        BLANK_RUN = /\A[ \t\n\r]*\z/n

        def deliver_chars(buf)
          return unless @disable_sax == 0

          blanks = are_blanks(buf)
          str = buf.force_encoding(Encoding::UTF_8)
          if blanks
            if @keep_blanks != 0
              @sax.characters(@user_data, str) if @sax_characters
            else
              sax_ignorable_whitespace(str)
            end
          else
            check_paragraph
            @sax.characters(@user_data, str) if @sax_characters
          end
        end

        # htmlParseCharDataInternal
        def parse_char_data_internal(readahead = 0)
          buf = +"".b
          buf << readahead if readahead != 0
          cur = current_char
          l = @clen
          while cur != 0x3C && cur != 0x26 && cur != 0 && @disable_sax <= 1
            # fast path: copy a run of chars that the loop below would copy one by one without
            # errors, up to the next flush point and before any char whose CUR_CHAR could grow
            # the input
            if (l >= 2 || (cur < 0x80 && cur == @buf.getbyte(@cur))) &&
                (run = scan_at(@cur, (@input_flags & INPUT_HAS_ENCODING) != 0 ? TEXT_RUN_UTF8 : TEXT_RUN_ASCII))
              lim = HTML_PARSER_BIG_BUFFER_SIZE - buf.bytesize
              if growable?
                g = @buf.bytesize - INPUT_CHUNK - @cur
                lim = g if g < lim
              end
              lim = 1 if lim < 1
              if run.bytesize > lim
                # the char straddling the limit is still copied before the flush
                lim += 1 while ((run.getbyte(lim) || 0) & 0xC0) == 0x80
                run = run.byteslice(0, lim)
              end
              buf << run
              advance_run(run)
            else
              if ChValid.char?(cur)
                copy_buf(l, buf, cur)
              else
                html_err_int(Err::INVALID_CHAR, format("Invalid char in CDATA 0x%X\n", cur), cur)
              end
              nextl(l)
            end
            if buf.bytesize >= HTML_PARSER_BIG_BUFFER_SIZE
              deliver_chars(buf)
              buf = +"".b
              shrink_macro
            end
            cur = current_char
            l = @clen
          end
          deliver_chars(buf) unless buf.empty?
        end

        # htmlParseCharData
        def parse_char_data
          parse_char_data_internal(0)
        end

        # ---- DOCTYPE, PI, comments, references ----------------------------------------

        # htmlParseExternalID: returns [uri, public_id]
        def parse_external_id
          uri = nil
          public_id = nil
          if upp(0) == 0x53 && upp(1) == 0x59 && upp(2) == 0x53 && upp(3) == 0x54 && upp(4) == 0x45 && upp(5) == 0x4D
            skip(6)
            html_err(Err::SPACE_REQUIRED, "Space required after 'SYSTEM'\n") unless blank_ch?(cur_byte)
            skip_blanks
            uri = parse_system_literal
            html_err(Err::URI_REQUIRED, "htmlParseExternalID: SYSTEM, no URI\n") if uri.nil?
          elsif upp(0) == 0x50 && upp(1) == 0x55 && upp(2) == 0x42 && upp(3) == 0x4C && upp(4) == 0x49 && upp(5) == 0x43
            skip(6)
            html_err(Err::SPACE_REQUIRED, "Space required after 'PUBLIC'\n") unless blank_ch?(cur_byte)
            skip_blanks
            public_id = parse_pubid_literal
            if public_id.nil?
              html_err(Err::PUBID_REQUIRED, "htmlParseExternalID: PUBLIC, no Public Identifier\n")
            end
            skip_blanks
            c = cur_byte
            uri = parse_system_literal if c == 0x22 || c == 0x27
          end
          [uri, public_id]
        end

        # htmlParsePI
        def parse_pi
          return unless cur_byte == 0x3C && nxt(1) == 0x3F

          state = @instate
          @instate = PARSER_PI
          skip(2)
          max_length = (@options & PARSE_HUGE) != 0 ? MAX_HUGE_LENGTH : MAX_TEXT_LENGTH
          target = parse_name
          if target
            if cur_byte == 0x3E
              skip(1)
              if @disable_sax == 0 && @sax_processing_instruction
                @sax.processing_instruction(@user_data, target, nil)
              end
              @instate = state
              return
            end
            buf = +"".b
            unless blank_ch?(cur_byte)
              html_err(Err::SPACE_REQUIRED, "ParsePI: PI #{target} space expected\n", target)
            end
            skip_blanks
            cur = current_char
            l = @clen
            while cur != 0 && cur != 0x3E
              if ChValid.char?(cur)
                copy_buf(l, buf, cur)
              else
                html_err_int(Err::INVALID_CHAR, format("Invalid char in processing instruction 0x%X\n", cur), cur)
              end
              if buf.bytesize > max_length
                html_err(Err::PI_NOT_FINISHED, "PI #{target} too long", target)
                @instate = state
                return
              end
              nextl(l)
              cur = current_char
              l = @clen
            end
            if cur != 0x3E
              html_err(Err::PI_NOT_FINISHED, "ParsePI: PI #{target} never end ...\n", target)
            else
              skip(1)
              if @disable_sax == 0 && @sax_processing_instruction
                @sax.processing_instruction(@user_data, target, buf.force_encoding(Encoding::UTF_8))
              end
            end
          else
            html_err(Err::PI_NOT_STARTED, "PI is not started correctly")
          end
          @instate = state
        end

        # htmlParseComment
        def parse_comment
          return if cur_byte != 0x3C || nxt(1) != 0x21 || nxt(2) != 0x2D || nxt(3) != 0x2D

          state = @instate
          @instate = PARSER_COMMENT
          skip(4)
          return @instate = state if fast_comment

          max_length = (@options & PARSE_HUGE) != 0 ? MAX_HUGE_LENGTH : MAX_TEXT_LENGTH
          buf = +"".b
          finished = catch(:done) do
            q = current_char
            ql = @clen
            throw :done, false if q == 0
            if q == 0x3E
              html_err(Err::COMMENT_ABRUPTLY_ENDED, "Comment abruptly ended")
              throw :done, 0x3E
            end
            nextl(ql)
            r = current_char
            rl = @clen
            throw :done, false if r == 0
            if q == 0x2D && r == 0x3E
              html_err(Err::COMMENT_ABRUPTLY_ENDED, "Comment abruptly ended")
              throw :done, 0x3E
            end
            nextl(rl)
            cur = current_char
            l = @clen
            while cur != 0 && (cur != 0x3E || r != 0x2D || q != 0x2D)
              nextl(l)
              nxtc = current_char
              nl = @clen
              if q == 0x2D && r == 0x2D && cur == 0x21 && nxtc == 0x3E
                html_err(Err::COMMENT_NOT_FINISHED, "Comment incorrectly closed by '--!>'")
                cur = 0x3E
                break
              end
              if ChValid.char?(q)
                copy_buf(ql, buf, q)
              else
                html_err_int(Err::INVALID_CHAR, format("Invalid char in comment 0x%X\n", q), q)
              end
              if buf.bytesize > max_length
                html_err(Err::COMMENT_NOT_FINISHED, "comment too long")
                @instate = state
                return
              end
              q = r
              ql = rl
              r = cur
              rl = l
              cur = nxtc
              l = nl
            end
            cur
          end
          if finished == 0x3E
            next_char
            if @sax_comment && @disable_sax == 0
              @sax.comment(@user_data, buf.force_encoding(Encoding::UTF_8))
            end
            @instate = state
            return
          end
          # unfinished:
          shown = buf.byteslice(0, 50)
          html_err(Err::COMMENT_NOT_FINISHED, "Comment not terminated \n<!--#{shown}\n".b, buf)
        end

        COMMENT_END = "-->".b.freeze
        COMMENT_BANG_END = "--!>".b.freeze
        # comment content the loop in htmlParseComment copies char by char without any error
        COMMENT_TEXT_ASCII = /[\t\n\r\x20-\x7F]*+/n
        COMMENT_TEXT_UTF8 = Regexp.new("(?:[\\t\\n\\r\\x20-\\x7F]++|#{UTF8_CHAR_SRC})*+".b, Regexp::NOENCODING)

        # htmlParseComment after "<!--" for a comment that is terminated by "-->" well inside the
        # buffer (so that no CUR_CHAR/NEXT can grow the input) and contains only chars that are
        # copied without errors. Returns false (having consumed nothing) otherwise.
        def fast_comment
          start = @cur
          buf = @buf
          c = buf.getbyte(start)
          return false if c.nil? || c == 0x3E || (c == 0x2D && buf.getbyte(start + 1) == 0x3E)

          e = buf.byteindex(COMMENT_END, start)
          return false if e.nil? || buf.bytesize - (e + 2) < INPUT_CHUNK

          bang = buf.byteindex(COMMENT_BANG_END, start)
          return false if bang && bang < e

          ss = scanner
          ss.pos = start
          len = ss.skip((@input_flags & INPUT_HAS_ENCODING) != 0 ? COMMENT_TEXT_UTF8 : COMMENT_TEXT_ASCII)
          return false if len < e - start

          ss.pos = start
          content = ss.peek(e - start) # (a copy: a substring would share @buf's memory)
          advance_run(content) # NEXTL over the content ...
          @cur += 3 # ... and over "--", NEXT over '>'
          @col += 3
          if @sax_comment && @disable_sax == 0
            @sax.comment(@user_data, content.force_encoding(Encoding::UTF_8))
          end
          true
        end

        # htmlParseCharRef
        def parse_char_ref
          val = 0
          if cur_byte == 0x26 && nxt(1) == 0x23 && (nxt(2) == 0x78 || nxt(2) == 0x58)
            skip(3)
            while (c = cur_byte) != 0x3B
              if c >= 0x30 && c <= 0x39
                val = val * 16 + (c - 0x30) if val < 0x110000
              elsif c >= 0x61 && c <= 0x66
                val = val * 16 + (c - 0x61) + 10 if val < 0x110000
              elsif c >= 0x41 && c <= 0x46
                val = val * 16 + (c - 0x41) + 10 if val < 0x110000
              else
                html_err(Err::INVALID_HEX_CHARREF, "htmlParseCharRef: missing semicolon\n")
                break
              end
              next_char
            end
            next_char if cur_byte == 0x3B
          elsif cur_byte == 0x26 && nxt(1) == 0x23
            skip(2)
            while (c = cur_byte) != 0x3B
              if c >= 0x30 && c <= 0x39
                val = val * 10 + (c - 0x30) if val < 0x110000
              else
                html_err(Err::INVALID_DEC_CHARREF, "htmlParseCharRef: missing semicolon\n")
                break
              end
              next_char
            end
            next_char if cur_byte == 0x3B
          else
            html_err(Err::INVALID_CHARREF, "htmlParseCharRef: invalid value\n")
          end
          if ChValid.char?(val)
            return val
          elsif val >= 0x110000
            html_err(Err::INVALID_CHAR, "htmlParseCharRef: value too large\n")
          else
            html_err_int(Err::INVALID_CHAR, "htmlParseCharRef: invalid xmlChar value #{val}\n", val)
          end
          0
        end

        # htmlParseDocTypeDecl
        def parse_doctype_decl
          skip(9)
          skip_blanks
          name = parse_name
          html_err(Err::NAME_REQUIRED, "htmlParseDocTypeDecl : no DOCTYPE name !\n") if name.nil?
          skip_blanks
          uri, external_id = parse_external_id
          skip_blanks
          if cur_byte != 0x3E
            html_err(Err::DOCTYPE_NOT_FINISHED, "DOCTYPE improperly terminated\n")
            next_char while cur_byte != 0 && cur_byte != 0x3E && !stopped?
          end
          next_char if cur_byte == 0x3E
          if @sax_internal_subset && @disable_sax == 0
            @sax.internal_subset(@user_data, name, external_id, uri)
          end
        end

        # htmlParseAttribute: returns [name, value]
        def parse_attribute
          name = parse_html_name
          if name.nil?
            html_err(Err::NAME_REQUIRED, "error parsing attribute name\n")
            return [nil, nil]
          end
          skip_blanks
          val = nil
          if cur_byte == 0x3D
            next_char
            skip_blanks
            val = parse_att_value
          end
          [name, val]
        end

        # htmlCheckEncoding
        def check_encoding(attvalue)
          return if attvalue.nil?

          s = attvalue.b
          idx = s.index(/charset/in)
          idx += 7 if idx
          if idx && blank_ch?(s.getbyte(idx) || 0)
            idx = s.index("=")
          end
          if idx && s.getbyte(idx) == 0x3D
            set_declared_encoding(HTMLParser.to_utf8(s.byteslice(idx + 1..)))
          end
        end

        # htmlCheckMeta
        def check_meta(atts)
          return if atts.nil?

          http = false
          content = nil
          i = 0
          while i < atts.length
            att = atts[i]
            value = atts[i + 1]
            i += 2
            next if value.nil?

            if HTMLParser.strcasecmp(att, "http-equiv") == 0 && HTMLParser.strcasecmp(value, "Content-Type") == 0
              http = true
            elsif HTMLParser.strcasecmp(att, "charset") == 0
              set_declared_encoding(value.dup)
            elsif HTMLParser.strcasecmp(att, "content") == 0
              content = value
            end
          end
          check_encoding(content) if http && content
        end

        # ---- tags ------------------------------------------------------------------

        # A complete attribute: a name directly followed by ="value", 'value' or an unquoted value
        # (without '&', NUL or newlines, ending before a blank or '>'), or by a char that neither
        # continues the name nor starts " = value" (then the value is NULL).
        ATTR_NAME_SRC = "([A-Za-z_:.][A-Za-z0-9:_.\\-]{0,99})"
        ATTR_FAST_ASCII = Regexp.new(
          "#{ATTR_NAME_SRC}(?:=(?:\"([^\\x00&\"\\n\\x80-\\xFF]*)\"|'([^\\x00&'\\n\\x80-\\xFF]*)'|" \
          "([^\\x00&>\\t\\n\\r \"'\\x80-\\xFF][^\\x00&>\\t\\n\\r \\x80-\\xFF]*)(?=[\\t\\n\\r >]))|" \
          "(?=[^A-Za-z0-9:_.\\-=\\t\\n\\r ]))".b, Regexp::NOENCODING
        )
        ATTR_FAST_UTF8 = Regexp.new(
          "#{ATTR_NAME_SRC}(?:=(?:\"((?:[^\\x00&\"\\n\\x80-\\xFF]|#{UTF8_CHAR_SRC})*)\"|" \
          "'((?:[^\\x00&'\\n\\x80-\\xFF]|#{UTF8_CHAR_SRC})*)'|" \
          "((?:[^\\x00&>\\t\\n\\r \"'\\x80-\\xFF]|#{UTF8_CHAR_SRC})(?:[^\\x00&>\\t\\n\\r \\x80-\\xFF]|#{UTF8_CHAR_SRC})*)" \
          "(?=[\\t\\n\\r >]))|(?=[^A-Za-z0-9:_.\\-=\\t\\n\\r ]))".b, Regexp::NOENCODING
        )

        TAG_NAME_FAST = /[A-Za-z_:.][A-Za-z0-9:_.\-]{0,99}/n

        # htmlParseStartTag: returns 0 on success, -1 on error, 1 if discarded
        def parse_start_tag
          return -1 unless @has_input
          return -1 if cur_byte != 0x3C

          ss = scanner
          ss.pos = @cur + 1
          if (len = ss.skip(TAG_NAME_FAST)) && @buf.bytesize - @cur - 1 - len >= INPUT_CHUNK
            # NEXT; GROW; htmlParseHTMLName without any input grow
            name = cached_name(ss.matched)
            @cur += len + 1
            @col += len + 1
          else
            next_char
            grow_macro
            name = parse_html_name
          end
          if name.nil?
            html_err(Err::NAME_REQUIRED, "htmlParseStartTag: invalid element name\n")
            next_char while cur_byte != 0 && cur_byte != 0x3E && !stopped?
            return -1
          end
          meta = name == "meta"

          auto_close(name)
          check_implied(name)

          discardtag = 0
          if !@name_tab.empty? && name == "html"
            html_err(Err::HTML_STRUCURE_ERROR, "htmlParseStartTag: misplaced <html> tag\n", name)
            discardtag = 1
            @depth += 1
          end
          if @name_tab.length != 1 && name == "head"
            html_err(Err::HTML_STRUCURE_ERROR, "htmlParseStartTag: misplaced <head> tag\n", name)
            discardtag = 1
            @depth += 1
          end
          if name == "body"
            @name_tab.each do |n|
              next unless n == "body"

              html_err(Err::HTML_STRUCURE_ERROR, "htmlParseStartTag: misplaced <body> tag\n", name)
              discardtag = 1
              @depth += 1
            end
          end

          atts = nil
          skip_blanks
          while (c = cur_byte) != 0 && c != 0x3E && (c != 0x2F || nxt(1) != 0x3E) && !stopped?
            grow_macro
            # fast path: a whole attribute that htmlParseAttribute would parse without errors,
            # entities, line breaks or input grows
            ss = scanner
            ss.pos = @cur
            if (len = ss.skip((@input_flags & INPUT_HAS_ENCODING) != 0 ? ATTR_FAST_UTF8 : ATTR_FAST_ASCII)) &&
                @buf.bytesize - @cur - len >= INPUT_CHUNK
              attname = cached_name(ss[1])
              attvalue = ss[2] || ss[3] || ss[4]
              if attvalue && !attvalue.ascii_only?
                @col += len - attvalue.count(CONT_BYTES)
              else
                @col += len
              end
              @cur += len
              attvalue&.force_encoding(Encoding::UTF_8)
            else
              attname, attvalue = parse_attribute
            end
            if attname
              dup = false
              if atts
                j = 0
                while j < atts.length
                  if atts[j] == attname
                    html_err(Err::ATTRIBUTE_REDEFINED, "Attribute #{attname} redefined\n", attname)
                    dup = true
                    break
                  end
                  j += 2
                end
              end
              unless dup
                atts ||= []
                atts << attname << attvalue
              end
            else
              while (c = cur_byte) != 0 && !blank_ch?(c) && c != 0x3E && (c != 0x2F || nxt(1) != 0x3E) && !stopped?
                next_char
              end
            end
            skip_blanks
          end

          check_meta(atts) if meta && atts

          if discardtag == 0
            name_push(name)
            sax_start_element(name, atts)
          end
          discardtag
        end

        # htmlParseEndTag: returns 1 if the current level should be closed
        END_TAG_FAST = %r{</([A-Za-z_:.][A-Za-z0-9:_.\-]{0,99})>}n

        def parse_end_tag
          # fast path: "</name>" closing the current element, far enough from the end of the
          # buffer that no NEXT can grow the input
          ss = scanner
          ss.pos = @cur
          if (len = ss.skip(END_TAG_FAST)) && @buf.bytesize - @cur - len >= INPUT_CHUNK
            name = cached_name(ss[1])
            if name == @name && (@depth <= 0 || (name != "html" && name != "body" && name != "head"))
              @cur += len
              @col += len
              sax_end_element(name)
              @node_infos.pop
              name_pop
              return 1
            end
          end

          if cur_byte != 0x3C || nxt(1) != 0x2F
            html_err(Err::LTSLASH_REQUIRED, "htmlParseEndTag: '</' not found\n")
            return 0
          end
          skip(2)
          name = parse_html_name
          return 0 if name.nil?

          skip_blanks
          if cur_byte != 0x3E
            html_err(Err::GT_REQUIRED, "End tag : expected '>'\n")
            next_char while !stopped? && cur_byte != 0 && cur_byte != 0x3E
          end
          next_char if cur_byte == 0x3E

          if @depth > 0 && (name == "html" || name == "body" || name == "head")
            @depth -= 1
            return 0
          end

          i = @name_tab.length - 1
          i -= 1 while i >= 0 && name != @name_tab[i]
          if i < 0
            html_err(Err::TAG_NAME_MISMATCH, "Unexpected end tag : #{name}\n", name)
            return 0
          end

          auto_close_on_close(name)

          if @name && @name != name
            html_err(Err::TAG_NAME_MISMATCH, "Opening and ending tag mismatch: #{name} and #{@name}\n", name, @name)
          end

          oldname = @name
          if oldname && oldname == name
            sax_end_element(name)
            @node_infos.pop
            name_pop
            1
          else
            0
          end
        end

        # htmlParseReference
        def parse_reference
          return if cur_byte != 0x26

          if nxt(1) == 0x23
            c = parse_char_ref
            return if c == 0

            out = +"".b
            HTMLParser.utf8_append(out, c)
            check_paragraph
            sax_characters(out.force_encoding(Encoding::UTF_8))
          else
            ent, name = parse_entity_ref
            if name.nil?
              check_paragraph
              sax_characters(+"&")
              return
            end
            if ent.nil? || !(ent.value > 0)
              check_paragraph
              if @sax_characters
                sax_characters(+"&")
                sax_characters(name.dup)
              end
            else
              out = +"".b
              HTMLParser.utf8_append(out, ent.value)
              check_paragraph
              sax_characters(out.force_encoding(Encoding::UTF_8))
            end
          end
        end

        # htmlParserFinishElementParsing
        def finish_element_parsing
          auto_close_on_end if cur_byte == 0
        end

        # htmlParseElementInternal
        def parse_element_internal
          return unless @has_input

          failed = parse_start_tag
          name = @name
          if failed == -1 || name.nil?
            next_char if cur_byte == 0x3E
            return
          end

          info = HTMLParser.tag_lookup(name)
          html_err(Err::HTML_UNKNOWN_TAG, "Tag #{name} invalid\n", name) if info.nil?

          c = @buf.getbyte(@cur) || 0
          if c == 0x2F && nxt(1) == 0x3E
            skip(2)
            sax_end_element(name)
            name_pop
            return
          end

          if c == 0x3E
            if @buf.bytesize - @cur >= INPUT_CHUNK
              # NEXT over '>' without a grow
              @cur += 1
              @col += 1
            else
              next_char
            end
          else
            html_err(Err::GT_REQUIRED, "Couldn't find end of Start Tag #{name}\n", name)
            if name == @name
              node_pop
              name_pop
            end
            finish_element_parsing
            return
          end

          if info && info.empty != 0
            sax_end_element(name)
            name_pop
          end
        end

        # htmlParseContentInternal (GROW/SHRINK/CUR/NXT inlined)
        def parse_content_internal
          depth = @name_tab.length
          current_node = depth <= 0 ? nil : @name
          while @disable_sax <= 1
            grow if @buf.bytesize - @cur < INPUT_CHUNK && (@input_flags & INPUT_PROGRESSIVE) == 0
            c = @buf.getbyte(@cur) || 0

            if c == 0x3C
              c1 = @buf.getbyte(@cur + 1) || 0
              if c1 == 0x2F
                if parse_end_tag == 1 && (current_node || @name_tab.empty?)
                  depth = @name_tab.length
                  current_node = depth <= 0 ? nil : @name
                end
                next
              elsif (c1 >= 0x61 && c1 <= 0x7A) || (c1 >= 0x41 && c1 <= 0x5A) || c1 == 0x5F || c1 == 0x3A
                name = parse_html_name_non_invasive
                if name.nil?
                  html_err(Err::NAME_REQUIRED, "htmlParseStartTag: invalid element name\n")
                  # (libxml2 has a no-op `while ((CUR == 0) && (CUR != '>')) NEXT;` here)
                  finish_element_parsing
                  current_node = @name
                  depth = @name_tab.length
                  next
                end
                if @name && HTMLParser.check_auto_close(name, @name)
                  auto_close(name)
                  next
                end
              end
            end

            if !@name_tab.empty? && depth >= @name_tab.length && current_node != @name
              finish_element_parsing
              current_node = @name
              depth = @name_tab.length
              next
            end

            c = @buf.getbyte(@cur) || 0
            if c != 0 && (current_node == "script" || current_node == "style")
              parse_script
            elsif c == 0x3C
              c1 = @buf.getbyte(@cur + 1) || 0
              if c1 == 0x21
                if upp(2) == 0x44 && upp(3) == 0x4F && upp(4) == 0x43 && upp(5) == 0x54 &&
                    upp(6) == 0x59 && upp(7) == 0x50 && upp(8) == 0x45
                  html_err(Err::HTML_STRUCURE_ERROR, "Misplaced DOCTYPE declaration\n", "DOCTYPE")
                  parse_doctype_decl
                elsif nxt(2) == 0x2D && nxt(3) == 0x2D
                  parse_comment
                else
                  skip_bogus_comment
                end
              elsif c1 == 0x3F
                parse_pi
              elsif (c1 >= 0x61 && c1 <= 0x7A) || (c1 >= 0x41 && c1 <= 0x5A)
                parse_element_internal
                current_node = @name
                depth = @name_tab.length
              else
                sax_characters(+"<") if @disable_sax == 0
                next_char
              end
            elsif c == 0x26
              parse_reference
            elsif c == 0
              auto_close_on_end
              break
            else
              parse_char_data_internal(0)
            end
            # SHRINK; GROW
            if (@input_flags & INPUT_PROGRESSIVE) == 0
              avail = @buf.bytesize - @cur
              parser_shrink if @cur - @base > 2 * INPUT_CHUNK && avail < 2 * INPUT_CHUNK
              grow if @buf.bytesize - @cur < INPUT_CHUNK
            end
          end
        end

        # htmlSkipBogusComment
        def skip_bogus_comment
          html_err(Err::HTML_INCORRECTLY_OPENED_COMMENT, "Incorrectly opened comment\n")
          until stopped?
            c = cur_byte
            break if c == 0

            next_char
            break if c == 0x3E
          end
        end

        def doctype_ahead?(off = 0)
          cur_byte == 0x3C && nxt(1) == 0x21 && upp(2) == 0x44 && upp(3) == 0x4F && upp(4) == 0x43 &&
            upp(5) == 0x54 && upp(6) == 0x59 && upp(7) == 0x50 && upp(8) == 0x45
        end

        # htmlParseDocument
        def parse_document
          return -1 unless @has_input

          @sax.set_document_locator(@user_data, self) if @sax_set_document_locator

          detect_encoding

          if (@input_flags & INPUT_HAS_ENCODING) == 0 && bytes_at(@cur, 4) == "<?xm"
            switch_encoding(:utf8)
          end

          skip_blanks
          html_err(Err::DOCUMENT_EMPTY, "Document is empty\n") if cur_byte == 0

          @sax.start_document(@user_data) if @sax_start_document && @disable_sax == 0

          while (cur_byte == 0x3C && nxt(1) == 0x21 && nxt(2) == 0x2D && nxt(3) == 0x2D) ||
              (cur_byte == 0x3C && nxt(1) == 0x3F)
            parse_comment
            parse_pi
            skip_blanks
          end

          parse_doctype_decl if doctype_ahead?
          skip_blanks

          while !stopped? &&
              ((cur_byte == 0x3C && nxt(1) == 0x21 && nxt(2) == 0x2D && nxt(3) == 0x2D) ||
               (cur_byte == 0x3C && nxt(1) == 0x3F))
            parse_comment
            parse_pi
            skip_blanks
          end

          parse_content_internal

          auto_close_on_end if cur_byte == 0

          @sax.end_document(@user_data) if @sax_end_document

          if (@options & PARSE_NODEFDTD) == 0 && @my_doc
            dtd = Tree.get_int_subset(@my_doc)
            if dtd.nil?
              Tree.create_int_subset(@my_doc, "html", "-//W3C//DTD HTML 4.0 Transitional//EN",
                "http://www.w3.org/TR/REC-html40/loose.dtd")
            end
          end
          @well_formed == 0 ? -1 : 0
        end

        # __htmlParseContent (used by xmlParseInNodeContext)
        def parse_content
          parse_content_internal
        end
      end

      module_function

      # xmlStrncasecmp(name, buf + pos, strlen(name)) == 0
      def strncasecmp_at(name, buf, pos)
        return false if name.nil?

        n = name.b
        i = 0
        while i < n.bytesize
          a = n.getbyte(i)
          b = buf.getbyte(pos + i) || 0
          a += 32 if a >= 65 && a <= 90
          b += 32 if b >= 65 && b <= 90
          return false if a != b

          i += 1
        end
        true
      end

      def utf8_append(out, c)
        if c < 0x80
          out << c
        elsif c < 0x800
          out << (((c >> 6) & 0x1F) | 0xC0) << ((c & 0x3F) | 0x80)
        elsif c < 0x10000
          out << (((c >> 12) & 0x0F) | 0xE0) << (((c >> 6) & 0x3F) | 0x80) << ((c & 0x3F) | 0x80)
        else
          out << (((c >> 18) & 0x07) | 0xF0) << (((c >> 12) & 0x3F) | 0x80) <<
            (((c >> 6) & 0x3F) | 0x80) << ((c & 0x3F) | 0x80)
        end
        out
      end
    end
  end
end
