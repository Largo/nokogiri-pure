# frozen_string_literal: true

# Small helpers shared by the gumbo port: ascii.c, string_buffer.c, tag_lookup, char_ref.

module Nokogiri
  module Pure
    module Gumbo
      # _gumbo_ascii_table classes, as boolean lookup tables indexed by code point (0..127).
      ASCII_CNTRL = Array.new(128) { |c| c <= 0x1f }.freeze
      ASCII_SPACE = Array.new(128) { |c| [0x09, 0x0a, 0x0c, 0x0d, 0x20].include?(c) }.freeze
      ASCII_ALPHA = Array.new(128) { |c| (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) }.freeze
      ASCII_ALNUM = Array.new(128) { |c| ASCII_ALPHA[c] || (c >= 0x30 && c <= 0x39) }.freeze
      ASCII_XDIGIT = Array.new(128) { |c| (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }.freeze

      # Byte-indexed (0..255) version of ASCII_ALNUM, for scanning raw input.
      BYTE_ALNUM = Array.new(256) { |c| c < 128 && ASCII_ALNUM[c] }.freeze

      TAG_LOOKUP = {}.tap do |h|
        TAG_NAMES.each_with_index do |name, i|
          next if name.empty?

          h[name] = i
        end
        h.freeze
      end

      module Util
        module_function

        def ascii_isspace(c)
          c >= 0 && c < 128 && ASCII_SPACE[c]
        end

        def ascii_isalpha(c)
          c >= 0 && c < 128 && ASCII_ALPHA[c]
        end

        def ascii_isalnum(c)
          c >= 0 && c < 128 && ASCII_ALNUM[c]
        end

        def ascii_tolower(c)
          c >= 0x41 && c <= 0x5a ? c | 32 : c
        end

        # gumbo_string_buffer_append_codepoint
        def append_codepoint(buf, c)
          if c < 0x80
            buf << c
          elsif c <= 0x7ff
            buf << (0xc0 | (c >> 6)) << (0x80 | (c & 0x3f))
          elsif c <= 0xffff
            buf << (0xe0 | (c >> 12)) << (0x80 | ((c >> 6) & 0x3f)) << (0x80 | (c & 0x3f))
          else
            buf << (0xf0 | ((c >> 18) & 0xff)) << (0x80 | ((c >> 12) & 0x3f)) <<
              (0x80 | ((c >> 6) & 0x3f)) << (0x80 | (c & 0x3f))
          end
          buf
        end

        # gumbo_tagn_enum: ASCII case-insensitive lookup of a tag name.
        def tagn_enum(name)
          TAG_LOOKUP[name] || TAG_LOOKUP[name.downcase(:ascii)] || TAG_UNKNOWN
        end

        # gumbo_ascii_strcasecmp(a, b) == 0 (C strings: compare up to the first NUL).
        def ascii_strcaseeq(a, b)
          a = a.byteslice(0, a.index("\0")) if a.include?("\0")
          b = b.byteslice(0, b.index("\0")) if b.include?("\0")
          a.bytesize == b.bytesize && a.casecmp(b) == 0
        end

        # match_named_char_ref: length of the longest named character reference that is a prefix
        # of input[pos...stop], together with its code point(s); nil if there is none.
        def match_named_char_ref(input, pos, stop)
          i = pos
          max = pos + 32
          max = stop if stop < max
          i += 1 while i < max && BYTE_ALNUM[input.getbyte(i)]
          len = i - pos
          return nil if len == 0

          if i < stop && input.getbyte(i) == 0x3b # ';'
            v = NAMED_CHAR_REFS[input.byteslice(pos, len + 1)]
            return [len + 1, v] if v
          end
          len = 6 if len > 6 # the longest legacy (semicolon-less) name
          while len > 0
            v = NAMED_CHAR_REFS[input.byteslice(pos, len)]
            return [len, v] if v

            len -= 1
          end
          nil
        end
      end
    end
  end
end
