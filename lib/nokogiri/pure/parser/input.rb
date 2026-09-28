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
          :eof, :held, :free_base, :encoder_name, :io, :io_error, :windows, :raw_chunks

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
          @windows = nil
          @raw_chunks = nil
        end

        READ_CHUNK = 4000

        # raw offsets where libxml2's successive 4000-byte reads end (xmlParserInputBufferGrow)
        def raw_boundaries
          return @raw_boundaries if @raw_boundaries

          total = @raw ? @raw.bytesize : @buf.bytesize
          out = []
          if @raw_chunks
            acc = 0
            @raw_chunks.each do |n|
              acc += n
              out << acc if acc < total
            end
          else
            q = READ_CHUNK
            while q < total
              out << q
              q += READ_CHUNK
            end
          end
          @raw_boundaries = out
        end

        # buffer offset for raw offset +q+ in identity (UTF-8) mode
        def buf_offset(q)
          return q if @bad.nil? || @bad.empty?

          n = 0
          @bad.each { |b| n += 1 if b[0] - 2 * n < q }
          q + 2 * n
        end

        # buffer offsets where the reads end (pull mode)
        def compute_windows
          @windows = raw_boundaries.map { |q| buf_offset(q) }
        end

        # first read boundary at least INPUT_CHUNK bytes after +pos+ (else the buffer end)
        def window_limit(pos)
          w = @windows
          return @buf.bytesize if w.nil?

          target = pos + INPUT_CHUNK
          i = w.bsearch_index { |x| x >= target }
          i ? w[i] : @buf.bytesize
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
          @raw_boundaries = nil
          fill
          compute_windows if eof
        end

        # Convert pending raw bytes into buf
        def fill
          return if @raw.nil?

          rest = @raw.bytesize - @raw_done
          return if rest <= 0 && !(@eof && @decoder)

          chunk = @raw_done.zero? && rest == @raw.bytesize ? @raw : @raw.byteslice(@raw_done, rest)
          if @decoder && @eof && @windows && !@raw_boundaries.empty?
            fill_windowed
            return
          end
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

        # decode the rest of raw read-chunk by read-chunk, recording where each read ends in buf
        def fill_windowed
          bounds = raw_boundaries.select { |q| q > @raw_done }
          @windows = @windows.select { |w| w < @buf.bytesize }
          start = @raw_done
          (bounds + [@raw.bytesize]).each_with_index do |q, i|
            last = i == bounds.size
            piece = @raw.byteslice(start, q - start)
            out, status = @decoder.convert(piece, last)
            append(out)
            start = q
            if status == :error
              @raw_done = @raw.bytesize
              @pending_error = ErrCode::ERR_INVALID_ENCODING
              return
            elsif status == :partial
              @trailing_partial = true
            end
            @windows << @buf.bytesize unless last
          end
          @raw_done = @raw.bytesize
        end

        def append(str)
          str = str.force_encoding(Encoding::UTF_8)
          unless str.valid_encoding?
            str, bad, = EncodingSupport.sanitize_utf8(str, false)
            if bad
              base = @buf.bytesize
              @bad ||= []
              bad.each { |b| @bad << [b[0] + base, b[1], b[2]] }
            end
          end
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
          @windows = @windows&.select { |w| w < pos }
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
