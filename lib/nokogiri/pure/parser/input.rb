# frozen_string_literal: true

module Nokogiri
  module Pure
    module Parser
      # xmlParserInput + xmlParserInputBuffer.
      #
      # +buf+ holds the input converted to UTF-8 (a valid UTF-8 String: undecodable bytes of UTF-8
      # input are replaced by U+FFFD, with their positions recorded in +bad+ so the parser can
      # report them when it reaches them, like xmlCurrentChar). While an input is the current one,
      # the parser keeps cur/line/col in its own registers; they are stored back here when another
      # input is pushed on top of it.
      class Input
        attr_accessor :buf, :cur, :line, :col, :flags, :entity, :filename, :id, :version,
          :consumed, :raw, :raw_done, :decoder, :bad, :pending_error, :buf_error, :trailing_partial,
          :eof, :held, :free_base, :encoder_name, :io, :io_error

        def initialize
          @buf = +""
          @cur = 0
          @line = 1
          @col = 1
          @flags = 0
          @entity = nil
          @filename = nil
          @id = 0
          @version = nil
          @consumed = 0
          @raw = nil
          @raw_done = 0
          @decoder = nil
          @bad = nil
          @pending_error = nil
          @buf_error = 0
          @trailing_partial = false
          @eof = true
          @held = 0
          @encoder_name = nil
          @io = nil
          @io_error = nil
        end

        def encoder?
          !@decoder.nil?
        end

        # load raw bytes (identity UTF-8 mode, nothing converted yet)
        def set_raw(bytes, eof: true)
          @raw = bytes.b
          @raw_done = 0
          @eof = eof
          @buf = +""
          fill
        end

        # Convert pending raw bytes into buf
        def fill
          return if @raw.nil?

          rest = @raw.bytesize - @raw_done
          return if rest <= 0 && !(@eof && @decoder)

          chunk = @raw_done.zero? && rest == @raw.bytesize ? @raw : @raw.byteslice(@raw_done, rest)
          if @decoder
            out, status = @decoder.convert(chunk, @eof)
            if status == :ok
              @raw_done += rest
            elsif status == :partial
              @raw_done += rest
              @trailing_partial = true
            else
              @raw_done = @raw.bytesize
              @pending_error = ErrCode::ERR_INVALID_ENCODING
            end
            append(out)
          else
            str, bad, held = EncodingSupport.sanitize_utf8(chunk, !@eof)
            base = @buf.bytesize
            if bad
              @bad ||= []
              bad.each { |b| @bad << [b[0] + base, b[1], b[2]] }
            end
            @raw_done += rest - held
            @held = held
            append(str)
          end
        end

        def append(str)
          if @buf.empty?
            @buf = str.frozen? ? str.dup : str
          else
            @buf << str
          end
        end

        # raw offset corresponding to buffer offset +pos+ (identity mode only)
        def raw_offset(pos)
          return pos if @bad.nil? || @bad.empty?

          n = 0
          @bad.each { |b| n += 1 if b[0] < pos }
          pos - 2 * n
        end

        # xmlSwitchInputEncoding with content already buffered: re-decode from +pos+ on.
        def switch_decoder(handler, pos, raw_skip = 0)
          q = raw_offset(pos) + raw_skip
          @buf = @buf.byteslice(0, pos)
          @bad = @bad&.select { |b| b[0] < pos }
          @bad = nil if @bad && @bad.empty?
          @decoder = handler.new_decoder
          @encoder_name = handler.name
          @raw_done = q
          @held = 0
          fill
        end

        # the bad-byte record at +pos+ if any
        def bad_at(pos)
          return nil if @bad.nil?

          @bad.find { |b| b[0] == pos }
        end
      end
    end
  end
end
