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
          :eof, :held, :free_base, :encoder_name, :io, :io_error, :windows, :raw_chunks,
          :scanner # a StringScanner over buf kept by the parser between input switches

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
          @scanner = nil
          reset_window_cache
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

        # buffer offset for raw offset +q+ in identity (UTF-8) mode (every replaced byte grew
        # from 1 to 3 bytes)
        def buf_offset(q)
          bad = @bad
          return q if bad.nil? || bad.empty?

          k = (0...bad.size).bsearch { |i| bad[i][0] - 2 * i >= q } || bad.size
          q + 2 * k
        end

        # buffer offsets where the reads end (pull mode)
        def compute_windows
          reset_window_cache
          @win_idx = 0
          @windows = raw_boundaries.map { |q| buf_offset(q) }
        end

        # first read boundary at least INPUT_CHUNK bytes after +pos+ (else the buffer end)
        def window_limit(pos)
          # cached: the result is w[i] for every pos in (w[i-1] - INPUT_CHUNK, w[i] - INPUT_CHUNK]
          return @wl_lim if pos <= @wl_hi && pos > @wl_lo

          w = @windows
          return @buf.bytesize if w.nil?

          target = pos + INPUT_CHUNK
          i = @win_idx || 0
          i = 0 if i > 0 && w[i - 1] >= target
          i += 1 while i < w.size && w[i] < target
          @win_idx = i
          return @buf.bytesize if i >= w.size

          @wl_lo = i > 0 ? w[i - 1] - INPUT_CHUNK : -1
          @wl_hi = w[i] - INPUT_CHUNK
          @wl_lim = w[i]
        end

        def reset_window_cache
          @wl_hi = -1
          @wl_lo = 0
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
          reset_window_cache
          @win_idx = 0
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
            reset_window_cache
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
          bad = @bad
          return pos if bad.nil? || bad.empty?

          n = bad.bsearch_index { |b| b[0] >= pos } || bad.size
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
          reset_window_cache
          @win_idx = 0
          fill
        end

        # the bad-byte record at +pos+ if any
        def bad_at(pos)
          bad = @bad
          return nil if bad.nil?

          b = bad.bsearch { |x| x[0] >= pos }
          b && b[0] == pos ? b : nil
        end

        # first bad-byte record in [s, e)
        def bad_in_range(s, e)
          bad = @bad
          return nil if bad.nil?

          b = bad.bsearch { |x| x[0] >= s }
          b && b[0] < e ? b : nil
        end
      end
    end
  end
end
