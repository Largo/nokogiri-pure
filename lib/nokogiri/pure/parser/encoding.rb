# frozen_string_literal: true

# Input-side character encoding support for the XML parser (libxml2 encoding.c input handlers,
# xmlOpenCharEncodingHandler, iconv emulated with Ruby's transcoders) and UTF-8 sanitizing.

module Nokogiri
  module Pure
    module Parser
      # An input xmlCharEncodingHandler. +name+ is what libxml2 reports as handler->name.
      class InputHandler
        attr_reader :name, :ruby_encoding, :kind

        def initialize(name, ruby_encoding, kind = :ruby)
          @name = name
          @ruby_encoding = ruby_encoding
          @kind = kind
        end

        def new_decoder
          Decoder.new(self)
        end
      end

      # Stateful decoder: raw bytes -> UTF-8, stopping at the first invalid sequence (like
      # xmlCharEncInput). Returns [output, error] where error is nil, :invalid or :incomplete.
      class Decoder
        def initialize(handler)
          @handler = handler
          @conv = nil
          @dead = false
        end

        # UTF16LEToUTF8 / UTF16BEToUTF8: a high surrogate must be followed by a low one (else
        # error); lone low surrogates pass through as (invalid) 3-byte UTF-8.
        def decode_utf16(src, le, flush)
          s = (@pending16 || "".b) + src.b
          @pending16 = nil
          n = s.bytesize & ~1
          fmt = le ? "v*" : "n*"
          units = s.byteslice(0, n).unpack(fmt)
          out = [].pack("x0").b
          i = 0
          cnt = units.size
          buf = []
          while i < cnt
            c = units[i]
            if (c & 0xFC00) == 0xD800
              if i + 1 >= cnt
                break
              end
              d = units[i + 1]
              if (d & 0xFC00) == 0xDC00
                c = (((c & 0x3FF) << 10) | (d & 0x3FF)) + 0x10000
                i += 2
              else
                out << buf.pack("U*").b unless buf.empty?
                @dead = true
                return [out, :error]
              end
            else
              i += 1
            end
            if (c & 0xF800) == 0xD800
              out << buf.pack("U*").b unless buf.empty?
              buf.clear
              out << [0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F)].pack("C*")
            else
              buf << c
            end
          end
          out << buf.pack("U*").b unless buf.empty?
          rest = s.byteslice(i * 2, s.bytesize - i * 2)
          if rest && !rest.empty?
            if flush
              return [out, :partial]
            else
              @pending16 = rest
            end
          end
          [out, :ok]
        end

        # are there bytes of an incomplete sequence buffered in the converter?
        def pending?
          return !@pending16.nil? && !@pending16.empty? if @handler.kind == :utf16le || @handler.kind == :utf16be
          return false if @dead || @conv.nil?

          dst = +""
          r = @conv.primitive_convert(+"".b, dst, nil, nil)
          @dead = true
          r == :incomplete_input
        rescue StandardError
          false
        end

        # Convert +src+ (binary). +flush+ = true means no more input will follow.
        # Returns [utf8_output, status] with status :ok, :error (invalid bytes, output stops before
        # them), or :partial (trailing incomplete sequence kept back / at EOF).
        def convert(src, flush)
          return ["".dup.force_encoding(Encoding::UTF_8), :error] if @dead

          case @handler.kind
          when :utf16le, :utf16be
            decode_utf16(src, @handler.kind == :utf16le, flush)
          when :table
            tbl = @handler.ruby_encoding
            out = +""
            src.each_byte do |b|
              ch = tbl[b]
              if ch.nil?
                @dead = true
                return [out, :error]
              end
              out << ch
            end
            [out, :ok]
          when :latin1
            [src.dup.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8), :ok]
          else
            @conv ||= Encoding::Converter.new(@handler.ruby_encoding, Encoding::UTF_8)
            dst = +""
            s = src.b
            res = @conv.primitive_convert(s, dst, nil, nil, partial_input: !flush)
            dst.force_encoding(Encoding::UTF_8)
            case res
            when :finished, :source_buffer_empty
              [dst, :ok]
            when :incomplete_input
              @dead = true
              [dst, :partial]
            else
              @dead = true
              [dst, :error]
            end
          end
        rescue Encoding::ConverterNotFoundError, ArgumentError
          @dead = true
          ["".dup.force_encoding(Encoding::UTF_8), :error]
        end
      end

      module EncodingSupport
        module_function

        # libxml2 built-in (non-iconv) input handlers, matched case-insensitively
        BUILTIN = {
          "UTF-16LE" => ["UTF-16LE", Encoding::UTF_16LE, :utf16le],
          "UTF-16BE" => ["UTF-16BE", Encoding::UTF_16BE, :utf16be],
          "UTF-16" => ["UTF-16", Encoding::UTF_16LE, :utf16le],
          "ISO-8859-1" => ["ISO-8859-1", Encoding::ISO_8859_1, :latin1],
          "ASCII" => ["ASCII", Encoding::US_ASCII, :ruby],
          "US-ASCII" => ["US-ASCII", Encoding::US_ASCII, :ruby],
        }.freeze

        # iconv (glibc) names that Ruby doesn't know under the same name
        ICONV_ALIASES = {
          "L1" => "ISO-8859-1", "LATIN1" => "ISO-8859-1", "ISO_8859-1" => "ISO-8859-1",
          "ISO8859-1" => "ISO-8859-1", "ISO88591" => "ISO-8859-1", "ISO_8859_1" => "ISO-8859-1",
          "LATIN2" => "ISO-8859-2", "L2" => "ISO-8859-2",
          "UTF16" => "UTF-16", "UTF16LE" => "UTF-16LE", "UTF16BE" => "UTF-16BE",
          "UTF32" => "UTF-32", "UCS2" => "UTF-16BE", "UCS-2" => "UTF-16BE", "UCS-2BE" => "UTF-16BE",
          "UCS-2LE" => "UTF-16LE", "ISO-10646-UCS-2" => "UTF-16BE", "UNICODE" => "UTF-16",
          "UCS4" => "UTF-32BE", "UCS-4" => "UTF-32BE", "ISO-10646-UCS-4" => "UTF-32BE",
          "UCS-4BE" => "UTF-32BE", "UCS-4LE" => "UTF-32LE",
          "SJIS" => "Shift_JIS", "SHIFT-JIS" => "Shift_JIS", "MS_KANJI" => "Shift_JIS",
          "EBCDIC-US" => "IBM037", "IBM-037" => "IBM037", "CP037" => "IBM037", "EBCDIC-CP-US" => "IBM037",
          "WINDOWS-31J" => "Windows-31J", "CP932" => "Windows-31J",
          "EUCJP" => "EUC-JP", "EUC_JP" => "EUC-JP",
          "ASCII" => "US-ASCII", "ANSI_X3.4-1968" => "US-ASCII",
        }.freeze

        def ruby_encoding_for(name)
          up = name.upcase
          target = ICONV_ALIASES[up]
          enc = begin
            Encoding.find(target || name)
          rescue ArgumentError
            nil
          end
          if enc.nil?
            alt = up.tr("_", "-")
            enc = begin
              Encoding.find(ICONV_ALIASES[alt] || alt)
            rescue ArgumentError
              nil
            end
          end
          return nil if enc.nil?
          return nil if enc == Encoding::UTF_7 || (enc.dummy? && !%w[UTF-16 UTF-32 ISO-2022-JP].include?(enc.name))

          enc = Encoding::UTF_16LE if enc == Encoding::UTF_16 # "UTF-16" without BOM: libxml2/iconv read LE
          enc = Encoding::UTF_32BE if enc == Encoding::UTF_32
          enc
        end

        # xmlOpenCharEncodingHandler(name, 0): returns [code, handler]; handler nil means UTF-8
        def open_handler(name)
          return [ErrCode::ERR_ARGUMENT, nil] if name.nil?

          up = name.upcase
          return [0, nil] if up == "UTF-8" || up == "UTF8"

          if (target = Pure::Enc.get_alias(name))
            name = target
            up = name.upcase
            return [0, nil] if up == "UTF-8" || up == "UTF8"
          end
          if (b = BUILTIN[up])
            return [0, InputHandler.new(b[0], b[1], b[2])]
          end

          key = up.delete("-_")
          key = "IBM#{key[2..]}" if key.start_with?("CP")
          if (tbl = EBCDIC_TABLES[key])
            return [0, InputHandler.new(name, tbl, :table)]
          end
          enc = ruby_encoding_for(name)
          return [ErrCode::ERR_UNSUPPORTED_ENCODING, nil] if enc.nil?
          return [0, nil] if enc == Encoding::UTF_8

          kind = enc == Encoding::ISO_8859_1 ? :latin1 : :ruby
          [0, InputHandler.new(name, enc, kind)]
        end

        # xmlLookupCharEncodingHandler for the encodings xmlDetectEncoding can find
        def lookup_handler(enc)
          case enc
          when :utf16le then InputHandler.new("UTF-16LE", Encoding::UTF_16LE, :utf16le)
          when :utf16be then InputHandler.new("UTF-16BE", Encoding::UTF_16BE, :utf16be)
          when :ucs4be then InputHandler.new("UCS-4", Encoding::UTF_32BE)
          when :ucs4le then InputHandler.new("UCS-4", Encoding::UTF_32LE)
          when :ebcdic then InputHandler.new("IBM-037", Encoding::IBM037)
          end
        end

        # libxml2's xmlCurrentChar decision for the (non-ASCII) byte at +i+ of binary +s+ whose
        # length is +n+: returns the sequence length, 0 for an invalid byte, -1 for a sequence cut by
        # the end of the buffer.
        def utf8_seq(s, i, n)
          c = s.getbyte(i)
          avail = n - i
          return -1 if avail < 2

          c1 = s.getbyte(i + 1)
          return 0 if (c1 & 0xC0) != 0x80

          if c < 0xE0
            return 0 if c < 0xC2

            2
          else
            return -1 if avail < 3

            c2 = s.getbyte(i + 2)
            return 0 if (c2 & 0xC0) != 0x80

            if c < 0xF0
              val = ((c & 0xF) << 12) | ((c1 & 0x3F) << 6) | (c2 & 0x3F)
              return 0 if val < 0x800 || (val >= 0xD800 && val < 0xE000)

              3
            else
              return -1 if avail < 4

              c3 = s.getbyte(i + 3)
              return 0 if (c3 & 0xC0) != 0x80

              val = ((c & 0x0F) << 18) | ((c1 & 0x3F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F)
              return 0 if val < 0x10000 || val >= 0x110000

              4
            end
          end
        end

        REPL = "�".b.freeze

        # Turn raw UTF-8 bytes into a valid UTF-8 string. Each invalid byte becomes U+FFFD; returns
        # [string, bad] where bad is a list of [buffer_offset, raw_byte, incomplete?] (offsets
        # relative to the returned string). If +holdback+, a trailing incomplete sequence is not
        # converted; the number of held back bytes is returned as the third element.
        def sanitize_utf8(raw, holdback)
          s = raw.b
          if s.dup.force_encoding(Encoding::UTF_8).valid_encoding?
            return [s.force_encoding(Encoding::UTF_8), nil, 0]
          end

          out = +"".b
          bad = []
          n = s.bytesize
          i = 0
          held = 0
          while i < n
            j = s.index(/[\x80-\xFF]/n, i)
            if j.nil?
              out << s.byteslice(i, n - i)
              break
            end
            out << s.byteslice(i, j - i) if j > i
            i = j
            l = utf8_seq(s, i, n)
            if l > 0
              out << s.byteslice(i, l)
              i += l
            elsif l < 0 && holdback
              held = n - i
              break
            else
              bad << [out.bytesize, s.getbyte(i), l < 0]
              out << REPL
              i += 1
            end
          end
          [out.force_encoding(Encoding::UTF_8), bad, held]
        end
      end
    end
  end
end
