# frozen_string_literal: true

# Progressive (push) parsing: htmlCreatePushParserCtxt / htmlParseChunk / htmlParseTryOrFinish,
# htmlParseLookupSequence / htmlParseLookupCommentEnd.

module Nokogiri
  module Pure
    module HTMLParser
      # xmlGetCharEncodingName for the values xmlParseCharEncoding can return
      CHAR_ENCODING_NAMES = {
        utf8: "UTF-8", utf16le: "UTF-16", utf16be: "UTF-16", ucs4le: "ISO-10646-UCS-4",
        ucs4be: "ISO-10646-UCS-4", ucs2: "ISO-10646-UCS-2", latin1: "ISO-8859-1",
        latin2: "ISO-8859-2", latin3: "ISO-8859-3", latin4: "ISO-8859-4", latin5: "ISO-8859-5",
        latin6: "ISO-8859-6", latin7: "ISO-8859-7", latin8: "ISO-8859-8", latin9: "ISO-8859-9",
        iso2022jp: "ISO-2022-JP", shift_jis: "Shift_JIS", euc_jp: "EUC-JP", ascii: nil,
      }.freeze

      # xmlParseCharEncoding: returns a symbol, :none for "", or :error
      def self.parse_char_encoding(name)
        return :none if name.nil?

        if (a = Enc.get_alias(name))
          name = a
        end
        up = name.b.upcase
        case up
        when "" then :none
        when "UTF-8", "UTF8" then :utf8
        when "UTF-16", "UTF16" then :utf16le
        when "ISO-10646-UCS-2", "UCS-2", "UCS2" then :ucs2
        when "ISO-10646-UCS-4", "UCS-4", "UCS4" then :ucs4le
        when "ISO-8859-1", "ISO-LATIN-1", "ISO LATIN 1" then :latin1
        when "ISO-8859-2", "ISO-LATIN-2", "ISO LATIN 2" then :latin2
        when "ISO-8859-3" then :latin3
        when "ISO-8859-4" then :latin4
        when "ISO-8859-5" then :latin5
        when "ISO-8859-6" then :latin6
        when "ISO-8859-7" then :latin7
        when "ISO-8859-8" then :latin8
        when "ISO-8859-9" then :latin9
        when "ISO-2022-JP" then :iso2022jp
        when "SHIFT_JIS" then :shift_jis
        when "EUC-JP" then :euc_jp
        else :error
        end
      end

      # htmlCreatePushParserCtxt(sax, user_data, chunk, size, filename, enc)
      def self.create_push_parser_ctxt(sax = nil, user_data = nil, chunk = nil, filename = nil, enc = :none)
        ctxt = Context.new(sax, user_data)
        encoding = CHAR_ENCODING_NAMES[enc]
        ctxt.push_push_input(filename, encoding)
        if chunk && !chunk.empty?
          res = ctxt.input_buffer_push(chunk.b)
          if res < 0
            ctxt.ctxt_err_io(ctxt.buf_error, nil)
            return nil
          end
        end
        ctxt
      end

      class Context
        attr_reader :buf_error

        # xmlParserInputBufferPush
        def input_buffer_push(data)
          return -1 if @buf_error != 0

          if @encoder
            @raw << data
            nbchars = char_enc_input
            return -1 if nbchars < 0

            nbchars
          else
            @buf << data
            data.bytesize
          end
        end

        # htmlParseChunk: returns the error code
        def parse_chunk(chunk, terminate)
          return Err::INTERNAL_ERROR unless @has_input
          return @err_no if stopped?

          if chunk && !chunk.empty?
            res = input_buffer_push(chunk.b)
            if res < 0
              html_err(@buf_error, "xmlParserInputBufferPush failed")
              halt_parser
              return @err_no
            end
          end
          parse_try_or_finish(terminate)
          if terminate
            @sax.end_document(@user_data) if @instate != PARSER_EOF && @sax_end_document
            @instate = PARSER_EOF
          end
          @err_no
        end

        DQUOTE = "\"".b.freeze
        DASH_DASH = "--".b.freeze
        LT_SLASH = "</".b.freeze
        ONE_BYTE = Array.new(256) { |i| i.chr.b.freeze }.freeze
        SQUOTE = "'".b.freeze
        # from an unquoted position: everything up to the next '>' outside of quotes, or up to an
        # unterminated quote
        GT_OUTSIDE_QUOTES = /(?:[^>"']++|"[^"]*+"|'[^']*+')*+/n

        # htmlParseLookupSequence (the byte loop done with String#byteindex; same result, same
        # check_index / end_check_state bookkeeping)
        def lookup_sequence(first, nxt_c, third, ignoreattrval)
          base = @check_index
          quote = @end_check_state
          cur = @cur
          buf = @buf
          len = buf.bytesize - cur
          if third != 0
            len -= 2
          elsif nxt_c != 0
            len -= 1
          end
          if base < len
            if ignoreattrval && first == 0x3E && nxt_c == 0 && third == 0
              # (len is the whole rest of the buffer here)
              if quote != 0
                i = buf.byteindex(quote == 0x22 ? DQUOTE : SQUOTE, cur + base)
                if i.nil?
                  base = len
                else
                  quote = 0
                  base = i - cur + 1
                end
              end
              if quote == 0 && base < len
                ss = scanner
                ss.pos = cur + base
                base += ss.skip(GT_OUTSIDE_QUOTES)
                if base < len
                  c = buf.getbyte(cur + base)
                  if c == 0x3E
                    @check_index = 0
                    @end_check_state = 0
                    return base
                  end
                  quote = c # an unterminated quote
                  base = len
                end
              end
            elsif ignoreattrval
              re = Regexp.new("[\"'#{Regexp.escape(first.chr)}]".b, Regexp::NOENCODING)
              while base < len
                if quote != 0
                  i = buf.byteindex(quote == 0x22 ? DQUOTE : SQUOTE, cur + base)
                  break if i.nil? || i - cur >= len

                  quote = 0
                  base = i - cur + 1
                  next
                end
                i = buf.byteindex(re, cur + base)
                break if i.nil? || i - cur >= len

                base = i - cur
                c = buf.getbyte(i)
                if c == 0x22 || c == 0x27
                  quote = c
                  base += 1
                  next
                end
                if third != 0
                  if (buf.getbyte(i + 1) || 0) != nxt_c || (buf.getbyte(i + 2) || 0) != third
                    base += 1
                    next
                  end
                elsif nxt_c != 0
                  if (buf.getbyte(i + 1) || 0) != nxt_c
                    base += 1
                    next
                  end
                end
                @check_index = 0
                @end_check_state = 0
                return base
              end
              base = len if base < len
            else
              needle = if third != 0
                [first, nxt_c, third].pack("C*")
              elsif nxt_c != 0
                first == 0x2D && nxt_c == 0x2D ? DASH_DASH : (first == 0x3C && nxt_c == 0x2F ? LT_SLASH : [first, nxt_c].pack("C*"))
              else
                ONE_BYTE[first]
              end
              i = buf.byteindex(needle, cur + base)
              if i && i - cur < len
                @check_index = 0
                @end_check_state = 0
                return i - cur
              end
              base = len
            end
          end
          @check_index = base < 0 ? 0 : base
          @end_check_state = quote
          -1
        end

        # htmlParseLookupCommentEnd
        def lookup_comment_end
          mark = 0
          loop do
            mark = lookup_sequence(0x2D, 0x2D, 0, false)
            break if mark < 0

            if nxt(mark + 2) == 0x3E || (nxt(mark + 2) == 0x21 && nxt(mark + 3) == 0x3E)
              @check_index = 0
              break
            end
            offset = nxt(mark + 2) == 0x21 ? 3 : 2
            if mark + offset >= @buf.bytesize - @cur
              @check_index = mark
              return -1
            end
            @check_index = mark + 1
          end
          mark
        end

        def doctype_at_cur?
          upp(2) == 0x44 && upp(3) == 0x4F && upp(4) == 0x43 && upp(5) == 0x54 &&
            upp(6) == 0x59 && upp(7) == 0x50 && upp(8) == 0x45
        end

        def push_end_document
          auto_close_on_end
          if @name_tab.empty? && @instate != PARSER_EOF
            @instate = PARSER_EOF
            @sax.end_document(@user_data) if @sax_end_document
          end
        end

        # htmlParseTryOrFinish
        def parse_try_or_finish(terminate)
          terminate = terminate ? true : false
          avail = 0
          catch(:done) do
            until stopped?
              avail = @buf.bytesize - @cur
              push_end_document if avail == 0 && terminate
              throw :done if avail < 1

              cur = @buf.getbyte(@cur)
              if cur == 0
                skip(1)
                next
              end

              case @instate
              # (the frequent states first)
              when PARSER_START_TAG
                throw :done if avail < 1
                if avail < 2
                  throw :done unless terminate
                  nx = 0x20
                else
                  nx = @buf.getbyte(@cur + 1) || 0
                end
                if cur != 0x3C
                  @instate = PARSER_CONTENT
                  next
                end
                if nx == 0x2F
                  @instate = PARSER_END_TAG
                  @check_index = 0
                  next
                end
                throw :done if !terminate && lookup_sequence(0x3E, 0, 0, true) < 0

                failed = parse_start_tag
                name = @name
                if failed == -1 || name.nil?
                  next_char if cur_byte == 0x3E
                  next
                end

                info = HTMLParser.tag_lookup(name)
                html_err(Err::HTML_UNKNOWN_TAG, "Tag #{name} invalid\n", name) if info.nil?

                c = @buf.getbyte(@cur) || 0
                if c == 0x2F && nxt(1) == 0x3E
                  skip(2)
                  sax_end_element(name)
                  name_pop
                  @instate = PARSER_CONTENT
                  next
                end

                if c == 0x3E
                  if (@input_flags & INPUT_PROGRESSIVE) != 0
                    # NEXT (xmlParserGrow does nothing for push input)
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
                  @instate = PARSER_CONTENT
                  next
                end

                if info && info.empty != 0
                  sax_end_element(name)
                  name_pop
                end
                @instate = PARSER_CONTENT
              when PARSER_CONTENT
                if avail == 1 && terminate
                  cur = cur_byte
                  if cur != 0x3C && cur != 0x26
                    chr = cur.chr.force_encoding(Encoding::UTF_8)
                    if blank_ch?(cur)
                      if @keep_blanks != 0
                        sax_characters(chr)
                      else
                        sax_ignorable_whitespace(chr)
                      end
                    else
                      check_paragraph
                      sax_characters(chr)
                    end
                    @check_index = 0
                    @cur += 1
                    next
                  end
                end
                throw :done if avail < 2
                nx = @buf.getbyte(@cur + 1) || 0
                if @name == "script" || @name == "style"
                  unless terminate
                    idx = lookup_sequence(0x3C, 0x2F, 0, false)
                    throw :done if idx < 0
                    val = nxt(idx + 2)
                    if val == 0
                      @check_index = idx
                      throw :done
                    end
                  end
                  parse_script
                  if cur == 0x3C && nx == 0x2F
                    @instate = PARSER_END_TAG
                    @check_index = 0
                    next
                  end
                elsif cur == 0x3C && nx == 0x21
                  throw :done if avail < 4
                  if doctype_at_cur?
                    throw :done if !terminate && lookup_sequence(0x3E, 0, 0, true) < 0
                    html_err(Err::HTML_STRUCURE_ERROR, "Misplaced DOCTYPE declaration\n", "DOCTYPE")
                    parse_doctype_decl
                  elsif nxt(2) == 0x2D && nxt(3) == 0x2D
                    throw :done if !terminate && lookup_comment_end < 0
                    parse_comment
                    @instate = PARSER_CONTENT
                  else
                    throw :done if !terminate && lookup_sequence(0x3E, 0, 0, false) < 0
                    skip_bogus_comment
                  end
                elsif cur == 0x3C && nx == 0x3F
                  throw :done if !terminate && lookup_sequence(0x3E, 0, 0, false) < 0
                  parse_pi
                  @instate = PARSER_CONTENT
                elsif cur == 0x3C && nx == 0x2F
                  @instate = PARSER_END_TAG
                  @check_index = 0
                  next
                elsif cur == 0x3C && ascii_letter?(nx)
                  throw :done if !terminate && nx == 0
                  @instate = PARSER_START_TAG
                  @check_index = 0
                  next
                elsif cur == 0x3C
                  sax_characters(+"<") if @disable_sax == 0
                  next_char
                else
                  throw :done if !terminate && lookup_sequence(0x3C, 0, 0, false) < 0
                  @check_index = 0
                  while @disable_sax <= 1 && cur != 0x3C && @cur < @buf.bytesize
                    if cur == 0x26
                      parse_reference
                    else
                      parse_char_data_internal(0)
                    end
                    cur = @buf.getbyte(@cur) || 0
                  end
                end
              when PARSER_END_TAG
                throw :done if avail < 2
                throw :done if !terminate && lookup_sequence(0x3E, 0, 0, false) < 0
                parse_end_tag
                @instate = @name_tab.empty? ? PARSER_EPILOG : PARSER_CONTENT
                @check_index = 0
              when PARSER_EOF
                throw :done
              when PARSER_START
                if (@input_flags & INPUT_HAS_ENCODING) == 0 && bytes_at(@cur, 4) == "<?xm"
                  switch_encoding(:utf8)
                end
                cur = cur_byte
                if blank_ch?(cur)
                  skip_blanks
                  avail = @buf.bytesize - @cur
                end
                @sax.set_document_locator(@user_data, self) if @sax_set_document_locator
                @sax.start_document(@user_data) if @sax_start_document && @disable_sax == 0
                cur = cur_byte
                nx = nxt(1)
                if cur == 0x3C && nx == 0x21 && doctype_at_cur?
                  throw :done if !terminate && lookup_sequence(0x3E, 0, 0, true) < 0
                  parse_doctype_decl
                  @instate = PARSER_PROLOG
                else
                  @instate = PARSER_MISC
                end
              when PARSER_MISC
                skip_blanks
                avail = @buf.bytesize - @cur
                throw :done if avail < 1
                if avail < 2
                  throw :done unless terminate
                  nx = 0x20
                else
                  nx = nxt(1)
                end
                cur = cur_byte
                if cur == 0x3C && nx == 0x21 && nxt(2) == 0x2D && nxt(3) == 0x2D
                  throw :done if !terminate && lookup_comment_end < 0
                  parse_comment
                  @instate = PARSER_MISC
                elsif cur == 0x3C && nx == 0x3F
                  throw :done if !terminate && lookup_sequence(0x3E, 0, 0, false) < 0
                  parse_pi
                  @instate = PARSER_MISC
                elsif cur == 0x3C && nx == 0x21 && doctype_at_cur?
                  throw :done if !terminate && lookup_sequence(0x3E, 0, 0, true) < 0
                  parse_doctype_decl
                  @instate = PARSER_PROLOG
                elsif cur == 0x3C && nx == 0x21 && avail < 9
                  throw :done
                else
                  @instate = PARSER_CONTENT
                end
              when PARSER_PROLOG
                skip_blanks
                avail = @buf.bytesize - @cur
                throw :done if avail < 2
                cur = cur_byte
                nx = nxt(1)
                if cur == 0x3C && nx == 0x21 && nxt(2) == 0x2D && nxt(3) == 0x2D
                  throw :done if !terminate && lookup_comment_end < 0
                  parse_comment
                  @instate = PARSER_PROLOG
                elsif cur == 0x3C && nx == 0x3F
                  throw :done if !terminate && lookup_sequence(0x3E, 0, 0, false) < 0
                  parse_pi
                  @instate = PARSER_PROLOG
                elsif cur == 0x3C && nx == 0x21 && avail < 4
                  throw :done
                else
                  @instate = PARSER_CONTENT
                end
              when PARSER_EPILOG
                avail = @buf.bytesize - @cur
                throw :done if avail < 1
                cur = cur_byte
                if blank_ch?(cur)
                  parse_char_data
                  throw :done
                end
                throw :done if avail < 2
                nx = nxt(1)
                if cur == 0x3C && nx == 0x21 && nxt(2) == 0x2D && nxt(3) == 0x2D
                  throw :done if !terminate && lookup_comment_end < 0
                  parse_comment
                  @instate = PARSER_EPILOG
                elsif cur == 0x3C && nx == 0x3F
                  throw :done if !terminate && lookup_sequence(0x3E, 0, 0, false) < 0
                  parse_pi
                  @instate = PARSER_EPILOG
                elsif cur == 0x3C && nx == 0x21 && avail < 4
                  throw :done
                else
                  @err_no = Err::DOCUMENT_END
                  @well_formed = 0
                  @instate = PARSER_EOF
                  @sax.end_document(@user_data) if @sax_end_document
                  throw :done
                end
              else
                html_err(Err::INTERNAL_ERROR, "HPP: internal error\n")
                @instate = PARSER_EOF
              end
            end
          end
          # done:
          push_end_document if avail == 0 && terminate
          if (@options & PARSE_NODEFDTD) == 0 && @my_doc &&
              (terminate || @instate == PARSER_EOF || @instate == PARSER_EPILOG)
            if Tree.get_int_subset(@my_doc).nil?
              Tree.create_int_subset(@my_doc, "html", "-//W3C//DTD HTML 4.0 Transitional//EN",
                "http://www.w3.org/TR/REC-html40/loose.dtd")
            end
          end
          0
        end
      end
    end
  end
end
