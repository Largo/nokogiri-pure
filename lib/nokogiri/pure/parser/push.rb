# frozen_string_literal: true

module Nokogiri
  module Pure
    module Parser
      # Progressive parsing (parser.c xmlParseChunk / xmlParseTryOrFinish)
      class Ctxt
        # xmlParserInputBufferPush into the current (main) input
        def push_bytes(bytes, eof: false)
          inp = @input
          save_registers
          if inp.raw.nil?
            inp.raw = +"".b
          end
          inp.raw << bytes.b
          inp.eof = eof
          before = inp.buf.bytesize
          inp.fill
          refresh_buffer
          if inp.pending_error && inp.buf.bytesize == before
            code = inp.pending_error
            inp.pending_error = nil
            inp.buf_error = code
            err_io(code, nil)
            halt
            return -1
          end
          0
        end

        # byteindex of an ASCII +str+ from byte offset +start+ (which may be inside a char)
        def bindex(str, start)
          return nil if start > @end

          start += 1 while start < @end && (@buf.getbyte(start) & 0xC0) == 0x80
          @buf.byteindex(str, start)
        end

        # at the end of push input: an incomplete trailing UTF-8 sequence that was held back is
        # handed to the parser (xmlCurrentChar sees it as incomplete); for converted input, bytes
        # left in the decoder make "Truncated multi-byte sequence at EOF"
        def flush_held_bytes
          inp = @input
          return if inp.raw.nil?

          if inp.decoder
            inp.trailing_partial = true if inp.decoder.pending? && inp.pending_error.nil?
          elsif inp.held.to_i > 0
            save_registers
            inp.eof = true
            inp.fill
            refresh_buffer
          end
        end

        # xmlParseLookupChar
        def lookup_char(c)
          start = @check_index == 0 ? @cur + 1 : @cur + @check_index
          idx = bindex(c.chr, start)
          if idx.nil?
            @check_index = @end - @cur
            false
          else
            @check_index = 0
            true
          end
        end

        # xmlParseLookupString: returns the position of +str+ or nil
        def lookup_string(start_delta, str)
          start = @check_index == 0 ? @cur + start_delta : @cur + @check_index
          term = bindex(str, start)
          if term.nil?
            e = @end
            e = if e - start < str.bytesize
              start
            else
              e - (str.bytesize - 1)
            end
            @check_index = e - @cur
          else
            @check_index = 0
          end
          term
        end

        # xmlParseLookupCharData
        def lookup_char_data
          start = @cur + @check_index
          @ss.pos = start
          n = @ss.skip(/[^<&]*/)
          if start + n < @end
            @check_index = 0
            true
          else
            @check_index = @end - @cur
            false
          end
        end

        # xmlParseLookupGt
        def lookup_gt
          cur = @check_index == 0 ? @cur + 1 : @cur + @check_index
          state = @end_check_state
          b = @buf
          while cur < @end
            c = b.getbyte(cur)
            if state != 0
              state = 0 if c == state
            elsif c == 0x27 || c == 0x22
              state = c
            elsif c == 0x3E
              @check_index = 0
              @end_check_state = 0
              return true
            end
            cur += 1
          end
          @check_index = cur - @cur
          @end_check_state = state
          false
        end

        # xmlParseLookupInternalSubset
        def lookup_internal_subset
          cur = @check_index == 0 ? @cur + 1 : @cur + @check_index
          start = cur
          state = @end_check_state
          b = @buf
          while cur < @end
            c = b.getbyte(cur)
            if state == 0x2D
              if c == 0x2D && b.getbyte(cur + 1) == 0x2D && b.getbyte(cur + 2) == 0x3E
                state = 0
                cur += 3
                start = cur
                next
              end
            elsif state == 0x5D
              if c == 0x3E
                @check_index = 0
                @end_check_state = 0
                return true
              end
              if Chars.blank?(c)
                state = 0x20
              elsif c != 0x5D
                state = 0
                start = cur
                next
              end
            elsif state == 0x20
              if c == 0x3E
                @check_index = 0
                @end_check_state = 0
                return true
              end
              unless Chars.blank?(c)
                state = 0
                start = cur
                next
              end
            elsif state != 0
              if c == state
                state = 0
                start = cur + 1
              end
            elsif c == 0x3C
              if b.getbyte(cur + 1) == 0x21 && b.getbyte(cur + 2) == 0x2D && b.getbyte(cur + 3) == 0x2D
                state = 0x2D
                cur += 4
                start = cur
                next
              end
            elsif c == 0x22 || c == 0x27 || c == 0x5D
              state = c
            end
            cur += 1
          end
          if state == 0 || state == 0x2D
            cur = cur - start < 3 ? start : cur - 3
          end
          @check_index = cur - @cur
          @end_check_state = state
          false
        end

        # xmlCheckCdataPush on the buffer: returns the number of valid bytes (negative on error)
        def check_cdata_push(start, len, complete)
          s = @buf.byteslice(start, len)
          ix = 0
          while ix < len
            c = s.getbyte(ix)
            if c < 0x80
              return -ix unless c >= 0x20 || c == 0xA || c == 0xD || c == 0x9

              ix += 1
            else
              l = c >= 0xF0 ? 4 : (c >= 0xE0 ? 3 : 2)
              return (complete ? -ix : ix) if ix + l > len

              v, = decode_at(start + ix)
              return -ix unless Chars.char?(v)
              return -ix if v == REPLACEMENT_CHAR && bad_byte_at(start + ix)

              ix += l
            end
          end
          ix
        end

        # SKIPL
        def skipl(n)
          advance_bytes_lines(n)
        end

        def advance_bytes_lines(n)
          e = @cur + n
          while @cur < e
            if @buf.getbyte(@cur) == 0x0A
              @line += 1
              @col = 1
            else
              @col += 1
            end
            @cur += 1
          end
        end

        # xmlParserShrink for the push parser: drop consumed input (keeping LINE_LEN bytes)
        def push_shrink
          inp = @input
          return if @cur <= 4096 || !inp.equal?(@input_tab[0])

          drop = @cur - LINE_LEN
          drop -= 1 while drop > 0 && (@buf.getbyte(drop) & 0xC0) == 0x80
          if inp.raw
            if inp.decoder
              inp.raw = inp.raw.byteslice(inp.raw_done, inp.raw.bytesize - inp.raw_done)
              inp.raw_done = 0
            else
              rq = inp.raw_offset(drop)
              inp.raw = inp.raw.byteslice(rq, inp.raw.bytesize - rq)
              inp.raw_done -= rq
            end
          end
          if inp.bad
            inp.bad = inp.bad.filter_map { |b| b[0] >= drop ? [b[0] - drop, b[1], b[2]] : nil }
            inp.bad = nil if inp.bad.empty?
          end
          inp.buf = @buf.byteslice(drop, @buf.bytesize - drop)
          inp.consumed += drop
          @cur -= drop
          inp.cur = @cur
          @buf = inp.buf
          @ss = StringScanner.new(@buf)
          @end = @buf.bytesize
        end

        # xmlParseTryOrFinish
        def parse_try_or_finish(terminate)
          ret = 0
          push_shrink if @instate != XML_PARSER_START && @instate != XML_PARSER_XML_DECL
          while @disable_sax == 0
            avail = @end - @cur
            break if avail < 1

            case @instate
            when XML_PARSER_EOF
              break
            when XML_PARSER_START
              if @input.raw && @input.decoder.nil?
                avail = @input.raw.bytesize - @input.raw_offset(@cur)
              end
              break if !terminate && avail < 4
              ebcdic = if @input.raw && @input.decoder.nil?
                @input.raw.byteslice(@input.raw_offset(@cur), 4) == "\x4C\x6F\xA7\x94".b
              else
                cmp?("\x4C\x6F\xA7\x94".b)
              end
              break if ebcdic && !terminate && avail < 200

              detect_encoding
              @instate = XML_PARSER_XML_DECL
            when XML_PARSER_XML_DECL
              break if !terminate && avail < 2

              c = cur_byte
              n = nxt(1)
              if c == 0x3C && n == 0x3F
                break if !terminate && lookup_string(2, "?>").nil?

                if nxt(2) == 0x78 && nxt(3) == 0x6D && nxt(4) == 0x6C && Chars.blank?(nxt(5))
                  ret += 5
                  parse_xml_decl
                else
                  @version = XML_DEFAULT_VERSION.dup
                end
              else
                @version = XML_DEFAULT_VERSION.dup
              end
              @sax.set_document_locator&.call(@user_data, nil)
              if @disable_sax == 0 && (cb = @sax.start_document)
                cb.call(@user_data)
              end
              @instate = XML_PARSER_MISC
            when XML_PARSER_START_TAG
              line = @line
              break if !terminate && avail < 2

              if cur_byte != 0x3C
                fatal_err_msg(ErrCode::ERR_DOCUMENT_EMPTY, "Start tag expected, '<' not found")
                @instate = XML_PARSER_EOF
                finish_document
                break
              end
              break if !terminate && !lookup_gt

              if space_nr == 0 || space == -2
                space_push(-1)
              else
                space_push(space)
              end
              prefix = nil
              uri = nil
              nb_ns = 0
              if @sax2 != 0
                name = parse_start_tag2
                prefix = @tag_prefix
                uri = @tag_uri
                nb_ns = @tag_nb_ns
              else
                name = parse_start_tag
              end
              if name.nil?
                space_pop
                @instate = XML_PARSER_EOF
                finish_document
                break
              end
              if @validate != 0 && @well_formed != 0 && @my_doc && @node && @node.equal?(@my_doc.children)
                @valid &= Valid.validate_root(@vctxt, @my_doc)
              end
              if cur_byte == 0x2F && nxt(1) == 0x3E
                skip(2)
                if @sax2 != 0
                  if @disable_sax == 0 && (cb = @sax.end_element_ns)
                    cb.call(@user_data, name, prefix, uri)
                  end
                  ns_pop(nb_ns) if nb_ns > 0
                elsif @disable_sax == 0 && (cb = @sax.end_element)
                  cb.call(@user_data, name)
                end
                space_pop
              elsif cur_byte == 0x3E
                next_char
                name_ns_push(name, prefix, uri, line, nb_ns)
              else
                fatal_err_msg_str(ErrCode::ERR_GT_REQUIRED, "Couldn't find end of Start Tag #{name}\n", name)
                node_pop
                space_pop
                ns_pop(nb_ns) if nb_ns > 0
              end
              @instate = name_nr == 0 ? XML_PARSER_EPILOG : XML_PARSER_CONTENT
            when XML_PARSER_CONTENT
              c = cur_byte
              if c == 0x3C
                break if !terminate && avail < 2

                n = nxt(1)
                if n == 0x2F
                  @instate = XML_PARSER_END_TAG
                  next
                elsif n == 0x3F
                  break if !terminate && lookup_string(2, "?>").nil?

                  parse_pi
                  @instate = XML_PARSER_CONTENT
                  next
                elsif n == 0x21
                  break if !terminate && avail < 3

                  n = nxt(2)
                  if n == 0x2D
                    break if !terminate && avail < 4

                    if nxt(3) == 0x2D
                      break if !terminate && lookup_string(4, "-->").nil?

                      parse_comment
                      @instate = XML_PARSER_CONTENT
                      next
                    end
                  elsif n == 0x5B
                    break if !terminate && avail < 9

                    if cmp?("<![CDATA[")
                      skip(9)
                      @instate = XML_PARSER_CDATA_SECTION
                      next
                    end
                  end
                end
              elsif c == 0x26
                break if !terminate && !lookup_char(0x3B)

                parse_reference
                next
              else
                if avail < XML_PARSER_BIG_BUFFER_SIZE
                  break if !terminate && !lookup_char_data
                end
                @check_index = 0
                parse_char_data_internal(terminate ? 0 : 1)
                next
              end
              @instate = XML_PARSER_START_TAG
            when XML_PARSER_END_TAG
              break if !terminate && !lookup_char(0x3E)

              if @sax2 != 0
                parse_end_tag2(@push_tab[name_nr - 1])
                name_ns_pop
              else
                parse_end_tag1(0)
              end
              @instate = name_nr == 0 ? XML_PARSER_EPILOG : XML_PARSER_CONTENT
            when XML_PARSER_CDATA_SECTION
              term = if terminate
                bindex("]]>", @cur)
              else
                lookup_string(0, "]]>")
              end
              if term.nil?
                if terminate
                  size = @end - @cur
                else
                  break if avail < XML_PARSER_BIG_BUFFER_SIZE + 2

                  @check_index = 0
                  size = XML_PARSER_BIG_BUFFER_SIZE
                end
                tmp = check_cdata_push(@cur, size, false)
                if tmp <= 0
                  @cur += -tmp
                  return cdata_encoding_error
                end
                if @disable_sax == 0
                  data = @buf.byteslice(@cur, tmp)
                  if (cb = @sax.cdata_block)
                    cb.call(@user_data, data)
                  elsif (cb = @sax.characters)
                    cb.call(@user_data, data)
                  end
                end
                skipl(tmp)
              else
                base = term - @cur
                tmp = check_cdata_push(@cur, base, true)
                if tmp < 0 || tmp != base
                  @cur += -tmp
                  return cdata_encoding_error
                end
                if base == 0 && @sax.cdata_block && @disable_sax == 0
                  if @cur >= 9 && @buf.byteslice(@cur - 9, 9) == "<![CDATA["
                    @sax.cdata_block.call(@user_data, +"")
                  end
                elsif base > 0 && @disable_sax == 0
                  data = @buf.byteslice(@cur, base)
                  if (cb = @sax.cdata_block)
                    cb.call(@user_data, data)
                  elsif (cb = @sax.characters)
                    cb.call(@user_data, data)
                  end
                end
                skipl(base + 3)
                @instate = XML_PARSER_CONTENT
              end
            when XML_PARSER_MISC, XML_PARSER_PROLOG, XML_PARSER_EPILOG
              skip_blanks
              avail = @end - @cur
              break if avail < 1

              handled = false
              if cur_byte == 0x3C
                break if !terminate && avail < 2

                n = nxt(1)
                if n == 0x3F
                  break if !terminate && lookup_string(2, "?>").nil?

                  parse_pi
                  handled = true
                elsif n == 0x21
                  break if !terminate && avail < 3

                  if nxt(2) == 0x2D
                    break if !terminate && avail < 4

                    if nxt(3) == 0x2D
                      break if !terminate && lookup_string(4, "-->").nil?

                      parse_comment
                      handled = true
                    end
                  elsif @instate == XML_PARSER_MISC
                    break if !terminate && avail < 9

                    if cmp?("<!DOCTYPE")
                      break if !terminate && !lookup_gt

                      @in_subset = 1
                      parse_doctype_decl
                      if cur_byte == 0x5B
                        @instate = XML_PARSER_DTD
                      else
                        @in_subset = 2
                        if @disable_sax == 0 && (cb = @sax.external_subset)
                          cb.call(@user_data, @int_sub_name, @ext_sub_system, @ext_sub_uri)
                        end
                        @in_subset = 0
                        clean_special_attr
                        @instate = XML_PARSER_PROLOG
                      end
                      handled = true
                    end
                  end
                end
              end
              next if handled

              if @instate == XML_PARSER_EPILOG
                fatal_err(ErrCode::ERR_DOCUMENT_END) if @err_no == 0
                @instate = XML_PARSER_EOF
                finish_document
              else
                @instate = XML_PARSER_START_TAG
              end
            when XML_PARSER_DTD
              break if !terminate && !lookup_internal_subset

              parse_internal_subset
              @in_subset = 2
              if @disable_sax == 0 && (cb = @sax.external_subset)
                cb.call(@user_data, @int_sub_name, @ext_sub_system, @ext_sub_uri)
              end
              @in_subset = 0
              clean_special_attr
              @instate = XML_PARSER_PROLOG
            else
              fatal_err_msg(ErrCode::ERR_INTERNAL_ERROR, "PP: internal error\n")
              @instate = XML_PARSER_EOF
            end
          end
          ret
        end

        def cdata_encoding_error
          if (@input.flags & XML_INPUT_ENCODING_ERROR) == 0
            err_io(ErrCode::ERR_INVALID_ENCODING, nil)
            @input.flags |= XML_INPUT_ENCODING_ERROR
          end
          0
        end

        # xmlParseChunk: returns 0 or an error code
        def parse_chunk(chunk, terminate)
          return @err_no if @disable_sax != 0
          return ErrCode::ERR_INTERNAL_ERROR if @input.nil?

          @input.flags |= XML_INPUT_PROGRESSIVE
          initialize_late if @instate == XML_PARSER_START
          chunk = chunk&.b
          end_in_lf = false
          if chunk && !chunk.empty? && !terminate && chunk.getbyte(-1) == 0x0D
            end_in_lf = true
            chunk = chunk.byteslice(0, chunk.bytesize - 1)
          end
          if chunk && !chunk.empty?
            return @err_no if push_bytes(chunk, eof: false) < 0
          end
          flush_held_bytes if terminate

          parse_try_or_finish(terminate)

          cur_base = @cur
          max_length = option?(PARSE_HUGE) ? XML_MAX_HUGE_LENGTH : XML_MAX_LOOKUP_LIMIT
          if cur_base > max_length
            fatal_err(ErrCode::ERR_RESOURCE_LIMIT, "Buffer size limit exceeded, try XML_PARSE_HUGE\n")
            halt
          end
          return @err_no if @err_no != 0 && @disable_sax != 0

          if end_in_lf
            return @err_no if push_bytes("\r".b, eof: false) < 0
          end
          if terminate
            if @instate != XML_PARSER_EOF && @instate != XML_PARSER_EPILOG
              if name_nr > 0
                name = @name_tab[-1]
                line = @push_tab[name_nr - 1].line
                fatal_err_msg_str_int_str(ErrCode::ERR_TAG_NOT_FINISHED,
                  "Premature end of data in tag #{name} line #{line}\n", name, line, nil)
              elsif @instate == XML_PARSER_START
                fatal_err(ErrCode::ERR_DOCUMENT_EMPTY)
              else
                fatal_err_msg(ErrCode::ERR_DOCUMENT_EMPTY, "Start tag expected, '<' not found\n")
              end
            elsif @input.decoder && @input.buf_error == 0 && @input.trailing_partial
              fatal_err_msg(ErrCode::ERR_INVALID_CHAR, "Truncated multi-byte sequence at EOF\n")
            end
            if @instate != XML_PARSER_EOF
              @instate = XML_PARSER_EOF
              finish_document
            end
          end
          @well_formed == 0 ? @err_no : 0
        end
      end
    end
  end
end
