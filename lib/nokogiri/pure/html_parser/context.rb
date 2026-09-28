# frozen_string_literal: true

# htmlParserCtxt (== xmlParserCtxt) for the HTML parser: the parser context, its single input
# stream (xmlParserInput + xmlParserInputBuffer, including incremental encoding conversion),
# error reporting (xmlCtxtVErr) and the name/node stacks.
#
# The input is kept as a binary String (@buf) holding UTF-8 (already converted) bytes, with @cur
# the read position -- libxml2's input->base/cur/end. Reading past the end yields 0, like libxml2's
# NUL terminated buffers.

module Nokogiri
  module Pure
    module HTMLParser
      # htmlParserOption / xmlParserOption bits
      PARSE_RECOVER = 1 << 0
      PARSE_NOENT = 1 << 1
      PARSE_NODEFDTD = 1 << 2
      PARSE_DTDLOAD = 1 << 2
      PARSE_DTDATTR = 1 << 3
      PARSE_DTDVALID = 1 << 4
      PARSE_NOERROR = 1 << 5
      PARSE_NOWARNING = 1 << 6
      PARSE_PEDANTIC = 1 << 7
      PARSE_NOBLANKS = 1 << 8
      PARSE_SAX1 = 1 << 9
      PARSE_XINCLUDE = 1 << 10
      PARSE_NONET = 1 << 11
      PARSE_NODICT = 1 << 12
      PARSE_NSCLEAN = 1 << 13
      PARSE_NOIMPLIED = 1 << 13
      PARSE_NOCDATA = 1 << 14
      PARSE_NOXINCNODE = 1 << 15
      PARSE_COMPACT = 1 << 16
      PARSE_OLD10 = 1 << 17
      PARSE_NOBASEFIX = 1 << 18
      PARSE_HUGE = 1 << 19
      PARSE_OLDSAX = 1 << 20
      PARSE_IGNORE_ENC = 1 << 21
      PARSE_BIG_LINES = 1 << 22
      PARSE_NO_XXE = 1 << 23

      # xmlParserErrors used by the HTML parser
      module Err
        OK = 0
        INTERNAL_ERROR = 1
        NO_MEMORY = 2
        DOCUMENT_EMPTY = 4
        DOCUMENT_END = 5
        INVALID_HEX_CHARREF = 6
        INVALID_DEC_CHARREF = 7
        INVALID_CHARREF = 8
        INVALID_CHAR = 9
        ENTITYREF_SEMICOL_MISSING = 23
        UNSUPPORTED_ENCODING = 32
        ATTRIBUTE_NOT_FINISHED = 40
        ATTRIBUTE_WITHOUT_VALUE = 41
        ATTRIBUTE_REDEFINED = 42
        LITERAL_NOT_STARTED = 43
        LITERAL_NOT_FINISHED = 44
        COMMENT_NOT_FINISHED = 45
        PI_NOT_STARTED = 46
        PI_NOT_FINISHED = 47
        DOCTYPE_NOT_FINISHED = 61
        SPACE_REQUIRED = 65
        NAME_REQUIRED = 68
        URI_REQUIRED = 70
        PUBID_REQUIRED = 71
        GT_REQUIRED = 73
        LTSLASH_REQUIRED = 74
        TAG_NAME_MISMATCH = 76
        INVALID_ENCODING = 81
        NAME_TOO_LONG = 110
        COMMENT_ABRUPTLY_ENDED = 112
        WAR_ENCODING_MISMATCH = 113
        RESOURCE_LIMIT = 114
        HTML_STRUCURE_ERROR = 800
        HTML_UNKNOWN_TAG = 801
        HTML_INCORRECTLY_OPENED_COMMENT = 802
        IO_UNKNOWN = 1500

        # xmlErrString (subset)
        STRINGS = {
          INTERNAL_ERROR => "Internal error",
          NO_MEMORY => "Out of memory",
          INVALID_ENCODING => "Invalid bytes in character encoding",
          RESOURCE_LIMIT => "Resource limit exceeded",
          UNSUPPORTED_ENCODING => "Unsupported encoding",
          IO_UNKNOWN => "Unknown IO error",
          INVALID_CHAR => "Char out of allowed range",
          85 => "chunk is not well balanced",
        }.freeze

        def self.string(code)
          STRINGS.fetch(code, "Unregistered error message")
        end
      end

      INPUT_CHUNK = 250
      MINLEN = 4000
      HTML_PARSER_BUFFER_SIZE = 100
      HTML_PARSER_BIG_BUFFER_SIZE = 1000
      MAX_TEXT_LENGTH = 10_000_000
      MAX_HUGE_LENGTH = 1_000_000_000
      MAX_NAME_LENGTH = 50_000
      MAX_ERRORS = 100

      # xmlParserInput flags
      INPUT_HAS_ENCODING = 1 << 0
      INPUT_AUTO_ENCODING = 7 << 1
      INPUT_AUTO_UTF8 = 1 << 1
      INPUT_AUTO_UTF16LE = 2 << 1
      INPUT_AUTO_UTF16BE = 3 << 1
      INPUT_AUTO_OTHER = 4 << 1
      INPUT_USES_ENC_DECL = 1 << 4
      INPUT_ENCODING_ERROR = 1 << 5
      INPUT_PROGRESSIVE = 1 << 6

      # xmlParserInputState (subset)
      PARSER_EOF = -1
      PARSER_START = 0
      PARSER_MISC = 1
      PARSER_PI = 2
      PARSER_DTD = 3
      PARSER_PROLOG = 4
      PARSER_COMMENT = 5
      PARSER_START_TAG = 6
      PARSER_CONTENT = 7
      PARSER_CDATA_SECTION = 8
      PARSER_END_TAG = 9
      PARSER_ENTITY_DECL = 10
      PARSER_ENTITY_VALUE = 11
      PARSER_ATTRIBUTE_VALUE = 12
      PARSER_SYSTEM_LITERAL = 13
      PARSER_EPILOG = 14
      PARSER_IGNORE = 15
      PARSER_PUBLIC_LITERAL = 16

      EMPTY_BUF = "".b.freeze

      # A stateful decoder for an encoding handler (the equivalent of an iconv descriptor):
      # converts raw bytes to UTF-8, stopping at the first invalid sequence. #convert returns
      # [utf8_bytes, consumed, status], status :ok or :error. Incomplete trailing sequences are
      # kept inside the converter (iconv leaves them in the raw buffer; the output is the same).
      # After an error every further conversion fails, like libxml2 re-feeding the bad bytes.
      class Decoder
        GLIBC_SJIS = ["SHIFT_JIS", "SHIFT-JIS", "SJIS", "MS_KANJI", "CSSHIFTJIS"].freeze

        def initialize(handler)
          @handler = handler
          @failed = false
          @ec = nil
          @renc = case handler.kind
          when :utf16, :utf16le then Encoding::UTF_16LE
          when :utf16be then Encoding::UTF_16BE
          when :latin1, :ascii, :utf8 then nil
          else handler.ruby_encoding
          end
          @sjis = GLIBC_SJIS.include?(handler.name.to_s.upcase)
          @c1_ok = @renc == Encoding::EUC_JP
        end

        C1_BYTES = ((0x80..0x8D).to_a + (0x90..0x9F).to_a).freeze

        def convert(raw)
          return ["".b, 0, :error] if @failed

          case @handler.kind
          when :latin1
            [raw.dup.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8).b, raw.bytesize, :ok]
          when :ascii
            idx = raw.index(/[\x80-\xFF]/n)
            if idx
              @failed = true
              [raw.byteslice(0, idx), idx, :error]
            else
              [raw.dup, raw.bytesize, :ok]
            end
          when :utf8
            [raw.dup, raw.bytesize, :ok]
          else
            convert_ruby(raw)
          end
        end

        private

        def convert_ruby(raw)
          if @ec.nil?
            begin
              @ec = Encoding::Converter.new(@renc, Encoding::UTF_8)
            rescue Encoding::ConverterNotFoundError, ArgumentError, TypeError
              @failed = true
              return ["".b, 0, :error]
            end
          end
          src = raw.dup.force_encoding(@renc)
          dst = +""
          res = @ec.primitive_convert(src, dst, nil, nil, partial_input: true)
          while res == :invalid_byte_sequence && @c1_ok
            # glibc's EUC-JP decodes the C1 bytes 0x80-0x8D/0x90-0x9F as U+0080..U+009F
            info = @ec.primitive_errinfo
            eb = info[3].to_s.b
            break unless eb.bytesize == 1 && C1_BYTES.include?(eb.getbyte(0))

            dst << "\xC2".b.force_encoding(dst.encoding) << eb.force_encoding(dst.encoding)
            src = (info[4].to_s.b + src.b).force_encoding(@renc)
            @ec = Encoding::Converter.new(@renc, Encoding::UTF_8)
            res = @ec.primitive_convert(src, dst, nil, nil, partial_input: true)
          end
          dst = dst.b
          # glibc's SHIFT_JIS maps the JIS X 0201 Roman bytes 0x5C/0x7E to U+00A5/U+203E
          dst = dst.gsub("\\".b, "\u00A5".b).gsub("~".b, "\u203E".b) if @sjis
          if res == :source_buffer_empty || res == :finished
            [dst, raw.bytesize, :ok]
          else # :invalid_byte_sequence, :undefined_conversion
            @failed = true
            info = @ec.primitive_errinfo
            left = info[3].to_s.bytesize + info[4].to_s.bytesize + src.bytesize
            [dst, raw.bytesize - left, :error]
          end
        end
      end

      NOT_ICONV_NAMES = [
        "646", "ASCII-8BIT", "BINARY", "BIG5-HKSCS:2008", "BIG5-UAO", "CESU-8", "CP50220", "CP50221",
        "CP51932", "CP65000", "CP65001", "CP720", "CP878", "CP951", "EUC-JIS-2004", "EMACS-MULE", "GB12345",
        "GB1988", "IBM720", "IBM737", "ISO-2022-JP-KDDI", "ISO2022-JP", "ISO2022-JP2", "MACJAPAN",
        "MACJAPANESE", "PCK", "SJIS-DOCOMO", "SJIS-KDDI", "SJIS-SOFTBANK", "UTF-8-HFS", "UTF-8-MAC",
        "UTF8-DOCOMO", "UTF8-KDDI", "UTF8-MAC", "UTF8-SOFTBANK", "EXTERNAL", "FILESYSTEM", "INTERNAL",
        "LOCALE", "MACCENTEURO", "MACCROATIAN", "MACGREEK", "MACICELAND", "MACROMAN", "MACROMANIA",
        "MACTHAI", "MACTURKISH", "MACUKRAINE", "STATELESS-ISO-2022-JP", "STATELESS-ISO-2022-JP-KDDI",
      ].map(&:b).freeze

      # xmlOpenCharEncodingHandler: returns [status, handler]; handler is nil for UTF-8.
      def self.open_encoding_handler(name)
        return [:unsupported, nil] if name.nil?

        up = name.b.upcase
        return [:ok, nil] if up == "UTF-8" || up == "UTF8"
        # names Ruby knows but glibc's iconv (the native gem's converter) doesn't
        return [:unsupported, nil] if NOT_ICONV_NAMES.include?(up)

        h = Enc.find_handler(name.dup.force_encoding(Encoding::UTF_8))
        return [:unsupported, nil] if h.nil? || h.kind == :html
        return [:ok, nil] if h.kind == :utf8

        [:ok, h]
      rescue StandardError
        [:unsupported, nil]
      end

      # xmlLookupCharEncodingHandler for the xmlCharEncoding values we can meet
      def self.lookup_encoding_handler(enc)
        case enc
        when :utf8, :none, :ascii_ok then nil
        when :utf16le then Enc::Handler.new("UTF-16LE", :utf16le, Encoding::UTF_16LE)
        when :utf16be then Enc::Handler.new("UTF-16BE", :utf16be, Encoding::UTF_16BE)
        when :latin1 then Enc::Handler.new("ISO-8859-1", :latin1, Encoding::ISO_8859_1)
        when :ucs4le then Enc::Handler.new("UCS-4LE", :ruby, Encoding::UTF_32LE)
        when :ucs4be then Enc::Handler.new("UCS-4BE", :ruby, Encoding::UTF_32BE)
        end
      end

      class Context
        attr_reader :sax, :user_data
        attr_accessor :my_doc, :node, :node_tab, :name, :name_tab, :html, :depth,
          :options, :recovery, :keep_blanks, :disable_sax, :well_formed, :err_no, :instate,
          :encoding, :linenumbers, :record_info, :pedantic, :replace_entities, :validate,
          :dict_names, :loadsubset, :nb_errors, :nb_warnings, :error_handler, :valid,
          :input_flags, :filename, :line, :col, :cur, :encoder, :check_index,
          :end_check_state, :node_infos, :input_id, :space_tab, :standalone, :version,
          :last_error, :has_input, :_private
        attr_reader :sax_flags, :buf

        def buf=(buf)
          @buf = buf
          @scanner = nil
        end

        def initialize(sax = nil, user_data = nil)
          @dict_names = 1
          @sax = sax || SAX2Handler::DEFAULT
          @user_data = sax.nil? ? self : (user_data || self)
          @ignorable_whitespace_noop = false
          @cdata_block_disabled = false
          update_sax
          @version = nil
          @encoding = nil
          @standalone = -1
          @instate = PARSER_START
          @node_tab = []
          @node = nil
          @name_tab = []
          @name = nil
          @node_infos = []
          @my_doc = nil
          @well_formed = 1
          @replace_entities = 0
          @linenumbers = 0
          @keep_blanks = 1
          @html = 1
          @record_info = 0
          @validate = 0
          @valid = 1
          @check_index = 0
          @end_check_state = 0
          @options = 0
          @recovery = 0
          @pedantic = 0
          @disable_sax = 0
          @err_no = 0
          @nb_errors = 0
          @nb_warnings = 0
          @depth = 0
          @loadsubset = 0
          @error_handler = nil
          @input_id = 1
          @last_error = nil
          reset_input
        end

        def reset_input
          @has_input = false
          @buf = +"".b
          @scanner = nil
          @cur = 0
          @line = 1
          @col = 1
          @input_flags = 0
          @filename = nil
          @encoder = nil
          @decoder = nil
          @raw = +"".b
          @buf_error = 0
          @readcb = nil
          @readcb_eof = false
          @consumed = 0
          @buf_generation = 0
          @base = 0
          @clen = 0
          @input_pushed = true
        end

        SAX_FLAG_IVARS = %i[characters cdata_block ignorable_whitespace start_element end_element comment
          processing_instruction internal_subset start_document end_document set_document_locator serror
          error warning].to_h { |k| [k, :"@sax_#{k}"] }.freeze

        # recompute which SAX callbacks are "non-NULL"
        def update_sax
          s = @sax
          @sax_flags = {
            characters: s.respond_to?(:characters),
            cdata_block: !@cdata_block_disabled && s.respond_to?(:cdata_block),
            ignorable_whitespace: s.respond_to?(:ignorable_whitespace),
            start_element: s.respond_to?(:start_element),
            end_element: s.respond_to?(:end_element),
            comment: s.respond_to?(:comment),
            processing_instruction: s.respond_to?(:processing_instruction),
            internal_subset: s.respond_to?(:internal_subset),
            start_document: s.respond_to?(:start_document),
            end_document: s.respond_to?(:end_document),
            set_document_locator: s.respond_to?(:set_document_locator),
            serror: s.respond_to?(:serror),
            error: s.respond_to?(:error),
            warning: s.respond_to?(:warning),
          }
          # the same flags as instance variables (@sax_characters, ...) for the hot paths
          @sax_flags.each { |k, v| instance_variable_set(SAX_FLAG_IVARS[k], v) }
          update_sax2
        end

        # is the default tree-building handler in use (its callbacks then run as sax2_* methods)?
        def update_sax2
          @sax2 = @sax.equal?(SAX2Handler::DEFAULT) && @user_data.equal?(self)
        end

        def user_data=(data)
          @user_data = data
          update_sax2 if @sax_flags
        end

        def sax=(s)
          @sax = s
          update_sax
        end

        def progressive?
          (@input_flags & INPUT_PROGRESSIVE) != 0
        end

        # PARSER_STOPPED
        def stopped?
          @disable_sax > 1
        end

        # ---- input setup ---------------------------------------------------

        # xmlNewInputMemory / xmlNewInputString + xmlNewInputInternal
        # Since libxml2 2.13 memory buffers are read through a read callback (xmlMemRead) in
        # MINLEN-sized chunks, exactly like IO input, which matters for encoding detection/errors.
        def push_memory_input(data, url = nil, encoding = nil)
          mem = data.b
          pos = 0
          reader = lambda do |len|
            chunk = mem.byteslice(pos, len)
            pos += chunk.bytesize if chunk
            chunk
          end
          push_io_input(reader, url, encoding)
        end

        # xmlNewInputIO: +reader+ is a callable taking a length and returning a String (<= len
        # bytes), nil/"" at EOF, or :error.
        def push_io_input(reader, url = nil, encoding = nil)
          reset_input
          @has_input = true
          @readcb = reader
          @filename = url
          if encoding
            # the input isn't pushed yet: errors carry no file/line/column
            @input_pushed = false
            switch_input_encoding_name(encoding)
            @input_pushed = true
          end
          self
        end

        # xmlNewInputPush (push parser): data arrives through append_push_data
        def push_push_input(url = nil, encoding = nil)
          reset_input
          @has_input = true
          @input_flags |= INPUT_PROGRESSIVE
          @filename = url
          if encoding
            @input_pushed = false
            switch_input_encoding_name(encoding)
            @input_pushed = true
          end
          self
        end

        def input_end
          @buf.bytesize
        end

        def consumed
          @consumed
        end

        # ---- byte access -----------------------------------------------------

        def byte_at(i)
          @buf.getbyte(i) || 0
        end

        def cur_byte
          @buf.getbyte(@cur) || 0
        end

        def nxt(n)
          @buf.getbyte(@cur + n) || 0
        end

        def upp(n)
          c = @buf.getbyte(@cur + n) || 0
          c >= 97 && c <= 122 ? c - 32 : c
        end

        def skip(n)
          @cur += n
          @col += n
        end

        # ---- input buffer growth / encoding conversion ------------------------

        # Would an xmlParserGrow at any position up to +end_pos+ be a no-op? Either none happens
        # (the parser only grows the input when fewer than INPUT_CHUNK bytes are left) or the
        # input can't grow any more, and then xmlParserGrow only checks the buffer size limit.
        # (The fast paths use this; near the end of a fully read input they still apply.)
        def grow_inert?(end_pos)
          return true if @buf.bytesize - end_pos >= INPUT_CHUNK
          return false if growable?

          end_pos - @base <= ((@options & PARSE_HUGE) != 0 ? MAX_HUGE_LENGTH : MAX_TEXT_LENGTH)
        end

        # can xmlParserGrow do anything for this input?
        def growable?
          return false if progressive? || !@has_input || @buf_error != 0
          return false if @encoder.nil? && (@readcb.nil? || @readcb_eof)
          return false if @readcb_eof && @raw.empty?

          true
        end

        # xmlParserGrow
        def grow
          return 0 unless @has_input
          return 0 if progressive?
          return 0 if @encoder.nil? && @readcb.nil?
          return -1 if @buf_error != 0

          max_length = (@options & PARSE_HUGE) != 0 ? MAX_HUGE_LENGTH : MAX_TEXT_LENGTH
          if @cur - @base > max_length
            fatal_err(Err::RESOURCE_LIMIT, "Buffer size limit exceeded, try XML_PARSE_HUGE\n")
            halt_parser
            return -1
          end
          return 0 if @buf.bytesize - @cur >= INPUT_CHUNK

          ret = buffer_grow(INPUT_CHUNK)
          ctxt_err_io(@buf_error, nil) if ret < 0
          ret
        end

        # SHRINK
        def shrink_macro
          if !progressive? && @cur - @base > 2 * INPUT_CHUNK && @buf.bytesize - @cur < 2 * INPUT_CHUNK
            parser_shrink
          end
        end

        LINE_LEN = 80

        # xmlParserShrink (the consumed data is kept; only input->base moves)
        def parser_shrink
          return unless @has_input
          return if !progressive? && @encoder.nil? && @readcb.nil?

          used = @cur - @base
          if used > INPUT_CHUNK
            res = used - LINE_LEN
            @base += res
            @consumed += res
          end
        end

        # xmlParserInputBufferGrow
        def buffer_grow(len)
          return -1 if @buf_error != 0

          len = MINLEN if len <= MINLEN && len != 4
          res = 0
          if @readcb
            data = @readcb_eof ? nil : @readcb.call(len)
            if data == :error
              @readcb_eof = true
              @buf_error = Err::IO_UNKNOWN
              return -1
            end
            if data.nil? || data.empty?
              @readcb_eof = true
              res = 0
            else
              data = data.b
              data = data.byteslice(0, len) if data.bytesize > len
              if @encoder
                @raw << data
              else
                @buf << data
              end
              res = data.bytesize
            end
          end
          if @encoder
            res = char_enc_input
            return -1 if res < 0
          end
          res
        end

        # xmlCharEncInput: convert @raw into @buf
        def char_enc_input
          return 0 if @raw.empty?

          @decoder ||= Decoder.new(@encoder)
          out, consumed, status = @decoder.convert(@raw)
          @raw = @raw.byteslice(consumed..) || +"".b
          @buf << out
          if status == :error && out.empty?
            @buf_error = Err::INVALID_ENCODING if @buf_error == 0
            return -1
          end
          out.bytesize
        end

        # xmlSwitchInputEncoding
        def switch_input_encoding(handler)
          return -1 unless @has_input

          @input_flags |= INPUT_HAS_ENCODING
          handler = nil if handler && handler.name.to_s.casecmp?("UTF-8")
          return 0 if @encoder.nil? && handler.nil?
          if @encoder
            @encoder = handler
            @decoder = nil
            return 0
          end
          @encoder = handler
          @decoder = nil
          unless @buf.empty?
            # move unprocessed content to the raw buffer and convert it
            processed = @cur
            @consumed += processed
            rest = bytes_at(@cur, @buf.bytesize - @cur)
            @raw = rest + @raw
            @buf = +"".b
            @scanner = nil
            @cur = 0
            @base = 0
            @buf_generation += 1
            nbchars = char_enc_input
            if nbchars < 0
              ctxt_err_io(@buf_error, nil)
              halt_parser
              return -1
            end
          end
          0
        end

        # xmlSwitchInputEncodingName
        def switch_input_encoding_name(encoding)
          return -1 if encoding.nil?

          status, handler = HTMLParser.open_encoding_handler(encoding)
          if status == :unsupported
            warning_msg(Err::UNSUPPORTED_ENCODING, "Unsupported encoding: #{encoding}\n", encoding, nil)
            return -1
          end
          switch_input_encoding(handler)
        end

        # xmlSwitchEncoding (by xmlCharEncoding symbol)
        def switch_encoding(enc)
          handler = HTMLParser.lookup_encoding_handler(enc)
          ret = switch_input_encoding(handler)
          @input_flags &= ~INPUT_HAS_ENCODING if ret >= 0 && enc == :none
          ret
        end

        # xmlDetectEncoding
        def detect_encoding
          return if grow < 0

          return if @buf.bytesize - @cur < 4

          b0 = byte_at(@cur)
          b1 = byte_at(@cur + 1)
          b2 = byte_at(@cur + 2)
          b3 = byte_at(@cur + 3)
          if (@input_flags & INPUT_HAS_ENCODING) != 0
            @cur += 3 if b0 == 0xEF && b1 == 0xBB && b2 == 0xBF
            return
          end
          enc = nil
          bom = 0
          auto = 0
          case b0
          when 0x00
            if b1 == 0 && b2 == 0 && b3 == 0x3C
              enc = :ucs4be
              auto = INPUT_AUTO_OTHER
            elsif b1 == 0x3C && b2 == 0 && b3 == 0x3F
              enc = :utf16be
              auto = INPUT_AUTO_UTF16BE
            end
          when 0x3C
            if b1 == 0
              if b2 == 0 && b3 == 0
                enc = :ucs4le
                auto = INPUT_AUTO_OTHER
              elsif b2 == 0x3F && b3 == 0
                enc = :utf16le
                auto = INPUT_AUTO_UTF16LE
              end
            end
          when 0xEF
            if b1 == 0xBB && b2 == 0xBF
              enc = :utf8
              auto = INPUT_AUTO_UTF8
              bom = 3
            end
          when 0xFE
            if b1 == 0xFF
              enc = :utf16be
              auto = INPUT_AUTO_UTF16BE
              bom = 2
            end
          when 0xFF
            if b1 == 0xFE
              enc = :utf16le
              auto = INPUT_AUTO_UTF16LE
              bom = 2
            end
          end
          @cur += bom if bom > 0
          if enc
            @input_flags |= auto
            switch_encoding(enc)
          end
        end

        # xmlSetDeclaredEncoding
        def set_declared_encoding(encoding)
          if (@input_flags & INPUT_HAS_ENCODING) == 0 && (@options & PARSE_IGNORE_ENC) == 0
            status, handler = HTMLParser.open_encoding_handler(encoding)
            if status != :ok
              fatal_err(Err::UNSUPPORTED_ENCODING, encoding)
              return
            end
            res = switch_input_encoding(handler)
            return if res != 0

            @input_flags |= INPUT_USES_ENC_DECL
          elsif (@input_flags & INPUT_AUTO_ENCODING) != 0
            allowed, auto_enc = case @input_flags & INPUT_AUTO_ENCODING
            when INPUT_AUTO_UTF8 then [["UTF-8", "UTF8"], "UTF-8"]
            when INPUT_AUTO_UTF16LE then [["UTF-16", "UTF-16LE", "UTF16"], "UTF-16LE"]
            when INPUT_AUTO_UTF16BE then [["UTF-16", "UTF-16BE", "UTF16"], "UTF-16BE"]
            end
            if allowed && allowed.none? { |a| HTMLParser.strcasecmp(encoding, a) == 0 }
              warning_msg(Err::WAR_ENCODING_MISMATCH,
                "Encoding '#{encoding}' doesn't match auto-detected '#{auto_enc}'\n", encoding, auto_enc)
              encoding = auto_enc
            end
          end
          @encoding = encoding
        end

        # xmlGetActualEncoding
        def actual_encoding
          if (@input_flags & INPUT_USES_ENC_DECL) != 0 || (@input_flags & INPUT_AUTO_ENCODING) != 0
            @encoding
          elsif @encoder
            @encoder.name
          elsif (@input_flags & INPUT_HAS_ENCODING) != 0
            "UTF-8"
          end
        end

        # ---- errors ------------------------------------------------------------

        # xmlCtxtVErr
        def ctxt_err(domain, code, level, str1, str2, str3, int1, msg, node = nil)
          return if stopped?

          done = false
          if level == Level::WARNING
            if @nb_warnings >= MAX_ERRORS
              done = true
            else
              @nb_warnings += 1
            end
          elsif @nb_errors >= MAX_ERRORS && (level < Level::FATAL || @well_formed == 0)
            done = true
          else
            @nb_errors += 1
          end

          unless done
            pushed = @has_input && @input_pushed
            err = XmlError.new(domain: domain, code: code, message: HTMLParser.to_utf8(msg), level: level,
              file: pushed ? @filename : nil, line: pushed ? @line : 0, str1: HTMLParser.to_utf8(str1),
              str2: HTMLParser.to_utf8(str2), str3: HTMLParser.to_utf8(str3), int1: int1,
              int2: pushed ? @col : 0, node: node)
            err.ctxt = self
            @last_error = err
            deliver_error(err, level, domain)
          end

          @err_no = code if level >= Level::ERROR
          if level == Level::FATAL
            @well_formed = 0
            @disable_sax = 1 if @recovery == 0
          end
          nil
        end

        def deliver_error(err, level, domain)
          allowed = (@options & PARSE_NOERROR) == 0 &&
            (level != Level::WARNING || (@options & PARSE_NOWARNING) == 0)
          if allowed && @error_handler
            @error_handler.call(err)
          elsif allowed && @sax_serror
            @sax.serror(@user_data, err)
          elsif Errors.handler
            Errors.report(err)
          elsif allowed && (domain == Domain::VALID || domain == Domain::DTD)
            # vctxt channel: xmlParserValidityError/Warning print to stderr; nothing to deliver
            nil
          elsif allowed
            if level == Level::WARNING
              @sax.warning(@user_data, err.message) if @sax_warning
            elsif @sax_error
              @sax.error(@user_data, err.message)
            end
          end
        end

        # htmlParseErr
        def html_err(code, msg, str1 = nil, str2 = nil)
          ctxt_err(Domain::HTML, code, Level::ERROR, str1, str2, nil, 0, msg)
        end

        # htmlParseErrInt
        def html_err_int(code, msg, val)
          ctxt_err(Domain::HTML, code, Level::ERROR, nil, nil, nil, val, msg)
        end

        # xmlCtxtErrIO
        def ctxt_err_io(code, uri)
          level = if code == Err::IO_UNKNOWN || code == 1524 || code == 1543 # UNKNOWN, ENOENT, NETWORK_ATTEMPT
            @validate == 0 ? Level::WARNING : Level::ERROR
          else
            Level::FATAL
          end
          errstr = Err.string(code)
          msg = uri.nil? ? "#{errstr}\n" : "failed to load \"#{uri}\": #{errstr}\n"
          ctxt_err(Domain::IO, code, level, uri, nil, nil, 0, msg)
        end

        # xmlFatalErr
        def fatal_err(code, info)
          errmsg = Err.string(code)
          if info.nil?
            ctxt_err(Domain::PARSER, code, Level::FATAL, nil, nil, nil, 0, "#{errmsg}\n")
          else
            ctxt_err(Domain::PARSER, code, Level::FATAL, info, nil, nil, 0, "#{errmsg}: #{info}\n")
          end
        end

        # xmlWarningMsg
        def warning_msg(code, msg, str1, str2)
          ctxt_err(Domain::PARSER, code, Level::WARNING, str1, str2, nil, 0, msg)
        end

        # xmlHaltParser
        def halt_parser
          @instate = PARSER_EOF
          @disable_sax = 2
        end

        # ---- stacks ------------------------------------------------------------

        # nodePush
        def node_push(value)
          max_depth = (@options & PARSE_HUGE) != 0 ? 2048 : 256
          if @node_tab.length > max_depth
            ctxt_err(Domain::PARSER, Err::RESOURCE_LIMIT, Level::FATAL, nil, nil, nil, @node_tab.length,
              "Excessive depth in document: #{@node_tab.length} use XML_PARSE_HUGE option\n")
            halt_parser
            return -1
          end
          @node_tab.push(value)
          @node = value
          @node_tab.length - 1
        end

        # nodePop
        def node_pop
          return nil if @node_tab.empty?

          ret = @node_tab.pop
          @node = @node_tab.last
          ret
        end

        def node_nr
          @node_tab.length
        end

        def name_nr
          @name_tab.length
        end

        # htmlnamePush
        def name_push(value)
          @html = 3 if @html < 3 && value == "head"
          @html = 10 if @html < 10 && value == "body"
          @name_tab.push(value)
          @name = value
          @name_tab.length - 1
        end

        # htmlnamePop
        def name_pop
          return nil if @name_tab.empty?

          ret = @name_tab.pop
          @name = @name_tab.last
          ret
        end

        # ---- options -----------------------------------------------------------

        # htmlCtxtUseOptions
        def use_options(options)
          if (options & PARSE_NOWARNING) != 0
            options -= PARSE_NOWARNING
            @options |= PARSE_NOWARNING
          end
          if (options & PARSE_NOERROR) != 0
            options -= PARSE_NOERROR
            @options |= PARSE_NOERROR
          end
          if (options & PARSE_PEDANTIC) != 0
            @pedantic = 1
            options -= PARSE_PEDANTIC
            @options |= PARSE_PEDANTIC
          else
            @pedantic = 0
          end
          if (options & PARSE_NOBLANKS) != 0
            @keep_blanks = 0
            @ignorable_whitespace_noop = true
            options -= PARSE_NOBLANKS
            @options |= PARSE_NOBLANKS
          else
            @keep_blanks = 1
          end
          if (options & PARSE_RECOVER) != 0
            @recovery = 1
            options -= PARSE_RECOVER
          else
            @recovery = 0
          end
          [PARSE_COMPACT, PARSE_HUGE, PARSE_NODEFDTD, PARSE_IGNORE_ENC, PARSE_NOIMPLIED].each do |bit|
            if (options & bit) != 0
              @options |= bit
              options -= bit
            end
          end
          @dict_names = 0
          @linenumbers = 1
          options
        end

        # xmlCtxtUseOptions (used by xmlParseInNodeContext even for HTML documents)
        def xml_use_options(options, keep_mask = 0)
          all_mask = PARSE_RECOVER | PARSE_NOENT | PARSE_DTDLOAD | PARSE_DTDATTR | PARSE_DTDVALID |
            PARSE_NOERROR | PARSE_NOWARNING | PARSE_PEDANTIC | PARSE_NOBLANKS | PARSE_SAX1 |
            PARSE_NONET | PARSE_NODICT | PARSE_NSCLEAN | PARSE_NOCDATA | PARSE_COMPACT |
            PARSE_OLD10 | PARSE_HUGE | PARSE_OLDSAX | PARSE_IGNORE_ENC | PARSE_BIG_LINES | PARSE_NO_XXE
          @options = (@options & keep_mask) | (options & all_mask)
          @recovery = (options & PARSE_RECOVER) != 0 ? 1 : 0
          @replace_entities = (options & PARSE_NOENT) != 0 ? 1 : 0
          @loadsubset = (options & PARSE_DTDLOAD) != 0 ? 2 : 0
          @loadsubset |= (options & PARSE_DTDATTR) != 0 ? 4 : 0
          @validate = (options & PARSE_DTDVALID) != 0 ? 1 : 0
          @pedantic = (options & PARSE_PEDANTIC) != 0 ? 1 : 0
          @keep_blanks = (options & PARSE_NOBLANKS) != 0 ? 0 : 1
          @dict_names = (options & PARSE_NODICT) != 0 ? 0 : 1
          @ignorable_whitespace_noop = true if (options & PARSE_NOBLANKS) != 0
          if (options & PARSE_NOCDATA) != 0
            @cdata_block_disabled = true
            update_sax
          end
          @linenumbers = 1
          options & ~all_mask
        end

        # ---- SAX dispatch helpers ------------------------------------------------

        def sax_characters(str)
          if @sax2
            sax2_text(str, TEXT_NODE)
          elsif @sax_characters
            @sax.characters(@user_data, str)
          end
        end

        def sax_ignorable_whitespace(str)
          return if @ignorable_whitespace_noop

          @sax.ignorable_whitespace(@user_data, str) if @sax_ignorable_whitespace
        end

        def sax_start_element(name, atts)
          if @sax2
            sax2_start_element(name, atts)
          elsif @sax_start_element
            @sax.start_element(@user_data, name, atts)
          end
        end

        def sax_end_element(name)
          if @sax2
            node_pop
          elsif @sax_end_element
            @sax.end_element(@user_data, name)
          end
        end

        # the SAX locator (xmlSAX2GetLineNumber / GetColumnNumber)
        def locator_line
          @line
        end

        def locator_column
          @col
        end
      end

      module_function

      def to_utf8(s)
        return nil if s.nil?

        s = s.to_s
        return s if s.encoding == Encoding::UTF_8 && s.frozen?

        s.dup.force_encoding(Encoding::UTF_8)
      end
    end
  end
end
