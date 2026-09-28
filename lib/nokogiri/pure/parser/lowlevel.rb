# frozen_string_literal: true

module Nokogiri
  module Pure
    module Parser
      # Low level input access (parserInternals.c: xmlCurrentChar, xmlNextChar, xmlParserGrow,
      # encoding detection/switching) and the parser.c macros (RAW, NXT, SKIP, NEXTL, ...).
      class Ctxt
        REPLACEMENT_CHAR = 0xFFFD

        # RAW / CUR
        def cur_byte
          @buf.getbyte(@cur) || 0
        end

        # NXT(n)
        def nxt(n)
          @buf.getbyte(@cur + n) || 0
        end

        def at_end?
          @cur >= @end
        end

        # CMPn(CUR_PTR, ...)
        def cmp?(str)
          @buf.byteslice(@cur, str.bytesize) == str
        end

        # SKIP(val)
        def skip(n)
          @cur += n
          @col += n
        end

        # NEXT1
        def next1
          @col += 1
          @cur += 1
        end

        # NEXTL(l)
        def nextl(l)
          if @buf.getbyte(@cur) == 0x0A
            @line += 1
            @col = 1
          else
            @col += 1
          end
          @cur += l
        end

        # GROW: report a pending input conversion error once the parser gets close to it
        def grow
          inp = @input
          if inp.pending_error && (@end - @cur) < INPUT_CHUNK && !progressive?
            code = inp.pending_error
            inp.pending_error = nil
            inp.buf_error = code
            err_io(code, nil)
            return -1
          end
          0
        end

        def progressive?
          (@input.flags & XML_INPUT_PROGRESSIVE) != 0
        end

        # report the encoding error of a replaced byte at +pos+ (once per input)
        def report_bad_byte
          inp = @input
          if (inp.flags & XML_INPUT_ENCODING_ERROR) == 0
            err_io(ErrCode::ERR_INVALID_ENCODING, nil)
            inp.flags |= XML_INPUT_ENCODING_ERROR
          end
        end

        # Is the U+FFFD at +pos+ a replacement for an invalid input byte? returns the record.
        def bad_byte_at(pos)
          bad = @input.bad
          return nil if bad.nil?

          bad.find { |b| b[0] == pos }
        end

        # decode the (valid UTF-8) char at byte offset +pos+ of the buffer: [codepoint, length]
        def decode_at(pos)
          c = @buf.getbyte(pos)
          if c < 0xE0
            [((c & 0x1F) << 6) | (@buf.getbyte(pos + 1) & 0x3F), 2]
          elsif c < 0xF0
            [((c & 0x0F) << 12) | ((@buf.getbyte(pos + 1) & 0x3F) << 6) | (@buf.getbyte(pos + 2) & 0x3F), 3]
          else
            [((c & 0x07) << 18) | ((@buf.getbyte(pos + 1) & 0x3F) << 12) |
              ((@buf.getbyte(pos + 2) & 0x3F) << 6) | (@buf.getbyte(pos + 3) & 0x3F), 4]
          end
        end

        # xmlCurrentChar: returns the current char, its byte length in @cl.
        # A "\r\n" pair is returned as "\n" of length 1 with the "\r" already skipped.
        def cur_char
          c = @buf.getbyte(@cur)
          if c.nil?
            @cl = 0
            return 0
          end
          if c < 0x80
            if c < 0x20
              if c == 0x0D
                @cur += 1 if @buf.getbyte(@cur + 1) == 0x0A
                @cl = 1
                return 0x0A
              elsif c == 0
                @cl = 1
                fatal_err(ErrCode::ERR_INVALID_CHAR, "Char 0x0 out of allowed range\n")
                return 0
              end
            end
            @cl = 1
            return c
          end
          v, l = decode_at(@cur)
          if v == REPLACEMENT_CHAR && (b = bad_byte_at(@cur))
            if b[2]
              # incomplete sequence at the end of the input
              @cl = 0
              return 0
            end
            report_bad_byte
          end
          @cl = l
          v
        end

        # xmlNextChar
        def next_char
          c = @buf.getbyte(@cur)
          return if c.nil?

          if c < 0x80
            if c == 0x0A
              @cur += 1
              @line += 1
              @col = 1
            elsif c == 0x0D
              @cur += @buf.getbyte(@cur + 1) == 0x0A ? 2 : 1
              @line += 1
              @col = 1
            else
              @cur += 1
              @col += 1
            end
          else
            @col += 1
            v, l = decode_at(@cur)
            if v == REPLACEMENT_CHAR && bad_byte_at(@cur)
              report_bad_byte
            end
            @cur += l
          end
        end

        # xmlCopyChar for a codepoint (surrogates are encoded like libxml2 does, as invalid UTF-8)
        def utf8_chr(c)
          return c.chr if c < 0x80

          c.chr(Encoding::UTF_8)
        rescue RangeError
          Ctxt.raw_utf8(c)
        end

        def self.raw_utf8(c)
          if c < 0x800
            [0xC0 | (c >> 6), 0x80 | (c & 0x3F)]
          elsif c < 0x10000
            [0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F)]
          else
            [0xF0 | (c >> 18), 0x80 | ((c >> 12) & 0x3F), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F)]
          end.pack("C*").force_encoding(Encoding::UTF_8)
        end

        # xmlSkipBlankChars
        def skip_blanks
          @ss.pos = @cur
          n = @ss.skip(BLANKS_RE)
          return 0 if n.nil?

          s = @cur
          e = s + n
          nl = 0
          last_nl = nil
          i = s
          while i < e
            if @buf.getbyte(i) == 0x0A
              nl += 1
              last_nl = i
            end
            i += 1
          end
          if nl > 0
            @line += nl
            @col = 1 + (e - last_nl - 1)
          else
            @col += n
          end
          @cur = e
          n
        end

        # advance over +n+ bytes of (valid UTF-8) text, updating line/col like NEXTL per char:
        # every "\n" starts a new line, other chars (including a lone "\r") count one column.
        def advance_text(n)
          return if n <= 0

          seg = @buf.byteslice(@cur, n)
          last_nl = seg.byterindex("\n")
          if last_nl
            @line += seg.count("\n")
            @col = 1 + seg.byteslice(last_nl + 1, n - last_nl - 1).length
          else
            @col += seg.length
          end
          @cur += n
        end

        # ---- encoding detection / switching (parserInternals.c) ---------------------------------

        # xmlSwitchInputEncoding
        def switch_input_encoding(input, handler)
          input.flags |= XML_INPUT_HAS_ENCODING
          handler = nil if handler && handler.name.casecmp?("UTF-8")
          return 0 if handler.nil? && input.decoder.nil?
          if input.decoder
            # switching encodings during parsing: only the name changes
            return 0
          end
          return 0 if handler.nil?

          pos = input.equal?(@input) ? @cur : input.cur
          before = input.buf.bytesize
          input.switch_decoder(handler, pos, @bom_skip || 0)
          if input.equal?(@input)
            refresh_buffer
          end
          if input.pending_error && input.buf.bytesize <= pos && before >= pos
            # nothing could be converted
            input.pending_error = nil
            input.buf_error = ErrCode::ERR_INVALID_ENCODING
            err_io(ErrCode::ERR_INVALID_ENCODING, nil)
            halt
            return -1
          end
          0
        end

        # xmlSwitchInputEncodingName
        def switch_input_encoding_name(input, encoding)
          return -1 if encoding.nil?

          res, handler = EncodingSupport.open_handler(encoding)
          if res == ErrCode::ERR_UNSUPPORTED_ENCODING
            warning_msg(ErrCode::ERR_UNSUPPORTED_ENCODING, "Unsupported encoding: #{encoding}\n", encoding, nil)
            return -1
          elsif res != 0
            fatal_err(res, encoding)
            return -1
          end
          switch_input_encoding(input, handler)
        end

        # xmlSwitchEncodingName
        def switch_encoding_name(encoding)
          switch_input_encoding_name(@input, encoding)
        end

        # xmlSwitchEncoding(ctxt, enc) for the encodings found by xmlDetectEncoding
        def switch_encoding(enc)
          handler = case enc
          when :utf8, :none then nil
          when :ebcdic then detect_ebcdic
          else EncodingSupport.lookup_handler(enc)
          end
          ret = switch_input_encoding(@input, handler)
          if ret >= 0 && enc == :none
            @input.flags &= ~XML_INPUT_HAS_ENCODING
          end
          ret
        end

        # xmlDetectEBCDIC
        def detect_ebcdic
          raw = @input.raw ? @input.raw.byteslice(@input.raw_offset(@cur), 200) : @buf.byteslice(@cur, 200)
          out = begin
            raw.dup.force_encoding(Encoding::IBM037).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
          rescue StandardError
            ""
          end
          if (m = out.match(/\A[^>]*?encoding\s*=\s*(["'])([A-Za-z0-9._-]*)\1/))
            res, h = EncodingSupport.open_handler(m[2])
            return h if res == 0 && h
          end
          EncodingSupport.lookup_handler(:ebcdic)
        end

        # xmlDetectEncoding
        def detect_encoding
          return if grow < 0 && false
          return if @end - @cur < 4

          inp = @input
          if inp.raw && inp.decoder.nil?
            q = inp.raw_offset(@cur)
            rb = inp.raw
            return if rb.bytesize - q < 4

            b0 = rb.getbyte(q)
            b1 = rb.getbyte(q + 1)
            b2 = rb.getbyte(q + 2)
            b3 = rb.getbyte(q + 3)
          else
            b0 = @buf.getbyte(@cur)
            b1 = @buf.getbyte(@cur + 1)
            b2 = @buf.getbyte(@cur + 2)
            b3 = @buf.getbyte(@cur + 3)
          end
          if (@input.flags & XML_INPUT_HAS_ENCODING) != 0
            @cur += 3 if b0 == 0xEF && b1 == 0xBB && b2 == 0xBF
            return
          end

          enc = :none
          bom_size = 0
          auto_flag = 0
          case b0
          when 0x00
            if b1 == 0x00 && b2 == 0x00 && b3 == 0x3C
              enc = :ucs4be
              auto_flag = XML_INPUT_AUTO_OTHER
            elsif b1 == 0x3C && b2 == 0x00 && b3 == 0x3F
              enc = :utf16be
              auto_flag = XML_INPUT_AUTO_UTF16BE
            end
          when 0x3C
            if b1 == 0x00
              if b2 == 0x00 && b3 == 0x00
                enc = :ucs4le
                auto_flag = XML_INPUT_AUTO_OTHER
              elsif b2 == 0x3F && b3 == 0x00
                enc = :utf16le
                auto_flag = XML_INPUT_AUTO_UTF16LE
              end
            end
          when 0x4C
            if b1 == 0x6F && b2 == 0xA7 && b3 == 0x94
              enc = :ebcdic
              auto_flag = XML_INPUT_AUTO_OTHER
            end
          when 0xEF
            if b1 == 0xBB && b2 == 0xBF
              enc = :utf8
              auto_flag = XML_INPUT_AUTO_UTF8
              bom_size = 3
            end
          when 0xFE
            if b1 == 0xFF
              enc = :utf16be
              auto_flag = XML_INPUT_AUTO_UTF16BE
              bom_size = 2
            end
          when 0xFF
            if b1 == 0xFE
              enc = :utf16le
              auto_flag = XML_INPUT_AUTO_UTF16LE
              bom_size = 2
            end
          end

          if enc != :none
            @input.flags |= auto_flag
            if enc == :utf8
              @cur += bom_size
              switch_encoding(enc)
            else
              @bom_skip = bom_size
              switch_encoding(enc)
              @bom_skip = 0
            end
          end
        end

        # xmlSetDeclaredEncoding
        def set_declared_encoding(encoding)
          if (@input.flags & XML_INPUT_HAS_ENCODING) == 0 && !option?(PARSE_IGNORE_ENC)
            res, handler = EncodingSupport.open_handler(encoding)
            if res != 0
              fatal_err(res, encoding)
              return
            end
            res = switch_input_encoding(@input, handler)
            return if res != 0

            @input.flags |= XML_INPUT_USES_ENC_DECL
          elsif (@input.flags & XML_INPUT_AUTO_ENCODING) != 0
            allowed = nil
            auto_enc = nil
            case @input.flags & XML_INPUT_AUTO_ENCODING
            when XML_INPUT_AUTO_UTF8
              allowed = %w[UTF-8 UTF8]
              auto_enc = "UTF-8"
            when XML_INPUT_AUTO_UTF16LE
              allowed = %w[UTF-16 UTF-16LE UTF16]
              auto_enc = "UTF-16LE"
            when XML_INPUT_AUTO_UTF16BE
              allowed = %w[UTF-16 UTF-16BE UTF16]
              auto_enc = "UTF-16BE"
            end
            if allowed && allowed.none? { |a| a.casecmp?(encoding) }
              warning_msg(ErrCode::WAR_ENCODING_MISMATCH,
                "Encoding '#{encoding}' doesn't match auto-detected '#{auto_enc}'\n", encoding, auto_enc)
              encoding = auto_enc.dup
            end
          end
          @encoding = encoding
        end

        # xmlGetActualEncoding
        def actual_encoding
          flags = @input.flags
          if (flags & XML_INPUT_USES_ENC_DECL) != 0 || (flags & XML_INPUT_AUTO_ENCODING) != 0
            @encoding
          elsif @input.decoder
            @input.encoder_name
          elsif (flags & XML_INPUT_HAS_ENCODING) != 0
            "UTF-8"
          end
        end
      end
    end
  end
end
