# frozen_string_literal: true

module Nokogiri
  module Pure
    # Character helpers (libxml2's chvalid.h / parserInternals.c)
    module Encoding_
      module_function

      # decode one UTF-8 char from binary string +bytes+ at byte offset +i+.
      # returns [codepoint, length] or [nil, 1] if invalid.
      def utf8_char(bytes, i)
        c = bytes.getbyte(i)
        return [nil, 1] if c.nil?
        return [c, 1] if c < 0x80

        if c & 0xE0 == 0xC0
          len = 2
          val = c & 0x1F
        elsif c & 0xF0 == 0xE0
          len = 3
          val = c & 0x0F
        elsif c & 0xF8 == 0xF0
          len = 4
          val = c & 0x07
        else
          return [nil, 1]
        end
        1.upto(len - 1) do |k|
          b = bytes.getbyte(i + k)
          return [nil, 1] if b.nil? || b & 0xC0 != 0x80

          val = (val << 6) | (b & 0x3F)
        end
        return [nil, 1] if (len == 2 && val < 0x80) || (len == 3 && val < 0x800) || (len == 4 && val < 0x10000)

        [val, len]
      end

      def xml_char?(c)
        (c >= 0x20 && c <= 0xD7FF) || c == 0x9 || c == 0xA || c == 0xD ||
          (c >= 0xE000 && c <= 0xFFFD) || (c >= 0x10000 && c <= 0x10FFFF)
      end

      def blank?(c)
        c == 0x20 || c == 0x9 || c == 0xA || c == 0xD
      end
    end

    # URI helpers (subset of libxml2's uri.c)
    module URI_
      module_function

      URI_RE = %r{\A(?:([A-Za-z][A-Za-z0-9+.\-]*):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?\z}m

      def parse(str)
        m = URI_RE.match(str)
        return nil unless m

        { scheme: m[1], authority: m[2], path: m[3], query: m[4], fragment: m[5] }
      end

      def remove_dot_segments(path)
        input = path.dup
        output = []
        until input.empty?
          if input.start_with?("../")
            input = input[3..]
          elsif input.start_with?("./")
            input = input[2..]
          elsif input.start_with?("/./")
            input = input[2..]
          elsif input == "/."
            input = "/"
          elsif input.start_with?("/../")
            input = input[3..]
            output.pop
          elsif input == "/.."
            input = "/"
            output.pop
          elsif input == "." || input == ".."
            input = ""
          else
            idx = input.index("/", input.start_with?("/") ? 1 : 0)
            seg = idx ? input[0...idx] : input
            output << seg
            input = idx ? input[idx..] : ""
          end
        end
        output.join
      end

      def compose(u)
        s = +""
        s << u[:scheme] << ":" if u[:scheme]
        s << "//" << u[:authority] if u[:authority]
        s << u[:path].to_s
        s << "?" << u[:query] if u[:query]
        s << "#" << u[:fragment] if u[:fragment]
        s
      end

      # xmlBuildURI(URI, base): resolve +uri+ relative to +base+
      def build_uri(uri, base)
        return nil if uri.nil?
        return uri if base.nil? || base.empty?
        return base.dup if uri.empty? && false

        r = parse(uri)
        return uri if r.nil?
        return uri if r[:scheme]

        b = parse(base)
        return uri if b.nil?

        if b[:scheme].nil? && b[:authority].nil?
          # base is a plain path (e.g. a file name): libxml2 still merges paths
          b[:path] = b[:path].to_s
        end

        t = {}
        if r[:authority]
          t[:authority] = r[:authority]
          t[:path] = remove_dot_segments(r[:path])
          t[:query] = r[:query]
        else
          if r[:path].empty?
            t[:path] = b[:path]
            t[:query] = r[:query] || b[:query]
          else
            if r[:path].start_with?("/")
              t[:path] = remove_dot_segments(r[:path])
            else
              merged = if b[:authority] && b[:path].to_s.empty?
                "/" + r[:path]
              else
                bp = b[:path].to_s
                idx = bp.rindex("/")
                idx ? bp[0..idx] + r[:path] : r[:path]
              end
              t[:path] = merged.start_with?("/") || b[:authority] ? remove_dot_segments(merged) : remove_relative_dots(merged)
            end
            t[:query] = r[:query]
          end
          t[:authority] = b[:authority]
        end
        t[:scheme] = b[:scheme]
        t[:fragment] = r[:fragment]
        compose(t)
      end

      def remove_relative_dots(path)
        out = remove_dot_segments("/" + path)
        out.start_with?("/") ? out[1..] : out
      end
    end
  end
end
