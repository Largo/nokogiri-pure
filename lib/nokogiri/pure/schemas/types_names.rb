# frozen_string_literal: true

require_relative "../html_parser/chvalid"

# Helpers from other libxml2 files needed by xmlschemastypes.c / xmlschemas.c:
# - tree.c: xmlValidateNCName / xmlValidateQName / xmlValidateName / xmlValidateNMToken
#   (XML 1.0 4th edition character classes IS_LETTER / IS_DIGIT / IS_COMBINING / IS_EXTENDER)
# - uri.c: the RFC 3986 parser behind xmlParseURI (only the accept/reject verdict is needed)
# - xmlstring.c: xmlUTF8Strlen
module Nokogiri
  module Pure
    module Schemas
      module Types
        extend self

        # Regexp character classes built from libxml2's chvalid tables.
        module NameClasses
          def self.ranges_to_class(ranges)
            ranges.map do |r|
              r.begin == r.end ? format("\\u{%x}", r.begin) : format("\\u{%x}-\\u{%x}", r.begin, r.end)
            end.join
          end

          cv = HTMLParser::ChValid
          # IS_LETTER = IS_BASECHAR || IS_IDEOGRAPHIC
          LETTER = "A-Za-z\\u{c0}-\\u{d6}\\u{d8}-\\u{f6}\\u{f8}-\\u{ff}" +
            ranges_to_class(cv::BASE_CHAR) + "\\u{4e00}-\\u{9fa5}\\u{3007}\\u{3021}-\\u{3029}"
          DIGIT = "0-9" + ranges_to_class(cv::DIGIT)
          COMBINING = ranges_to_class(cv::COMBINING.select { |r| r.begin >= 0x100 })
          EXTENDER = "\\u{b7}" + ranges_to_class(cv::EXTENDER)
          NCSTART = "[#{LETTER}_]"
          NCCHAR = "[#{LETTER}#{DIGIT}._\\-#{COMBINING}#{EXTENDER}]"
          NAMESTART = "[#{LETTER}_:]"
          NAMECHAR = "[#{LETTER}#{DIGIT}._:\\-#{COMBINING}#{EXTENDER}]"
          SP = "[ \\t\\n\\r]*"

          NCNAME = Regexp.new("\\A#{NCSTART}#{NCCHAR}*\\z")
          NCNAME_SP = Regexp.new("\\A#{SP}#{NCSTART}#{NCCHAR}*#{SP}\\z")
          QNAME = Regexp.new("\\A#{NCSTART}#{NCCHAR}*(?::#{NCSTART}#{NCCHAR}*)?\\z")
          QNAME_SP = Regexp.new("\\A#{SP}#{NCSTART}#{NCCHAR}*(?::#{NCSTART}#{NCCHAR}*)?#{SP}\\z")
          NAME = Regexp.new("\\A#{NAMESTART}#{NAMECHAR}*\\z")
          NAME_SP = Regexp.new("\\A#{SP}#{NAMESTART}#{NAMECHAR}*#{SP}\\z")
          NMTOKEN = Regexp.new("\\A#{NAMECHAR}+\\z")
          NMTOKEN_SP = Regexp.new("\\A#{SP}#{NAMECHAR}+#{SP}\\z")
        end

        # Strings that are not valid UTF-8 are decoded like xmlStringCurrentChar would (invalid
        # bytes stop the name), which a regexp on a broken string cannot express: scrub them to
        # a non-name character.
        def name_subject(value)
          value = value.dup.force_encoding(Encoding::UTF_8) if value.encoding != Encoding::UTF_8
          value.valid_encoding? ? value : value.scrub("\u0000")
        end
        private :name_subject

        # xmlValidateNCName. Returns 0 if valid, 1 if not, -1 on API error.
        def validate_nc_name(value, space)
          return -1 if value.nil?

          re = space != 0 && space != false ? NameClasses::NCNAME_SP : NameClasses::NCNAME
          re.match?(name_subject(value)) ? 0 : 1
        end

        # xmlValidateQName
        def validate_q_name(value, space)
          return -1 if value.nil?

          re = space != 0 && space != false ? NameClasses::QNAME_SP : NameClasses::QNAME
          re.match?(name_subject(value)) ? 0 : 1
        end

        # xmlValidateName
        def validate_name(value, space)
          return -1 if value.nil?

          re = space != 0 && space != false ? NameClasses::NAME_SP : NameClasses::NAME
          re.match?(name_subject(value)) ? 0 : 1
        end

        # xmlValidateNMToken
        def validate_nm_token(value, space)
          return -1 if value.nil?

          re = space != 0 && space != false ? NameClasses::NMTOKEN_SP : NameClasses::NMTOKEN
          re.match?(name_subject(value)) ? 0 : 1
        end

        # xmlUTF8Strlen: number of characters, -1 on (detected) malformed UTF-8
        def utf8_strlen(utf)
          return -1 if utf.nil?
          return utf.length if utf.valid_encoding?

          ret = 0
          i = 0
          n = utf.bytesize
          while i < n
            c = utf.getbyte(i)
            if c & 0x80 != 0
              return -1 if ((utf.getbyte(i + 1) || 0) & 0xc0) != 0x80

              if (c & 0xe0) == 0xe0
                return -1 if ((utf.getbyte(i + 2) || 0) & 0xc0) != 0x80

                if (c & 0xf0) == 0xf0
                  return -1 if (c & 0xf8) != 0xf0 || ((utf.getbyte(i + 3) || 0) & 0xc0) != 0x80

                  i += 4
                else
                  i += 3
                end
              else
                i += 2
              end
            else
              i += 1
            end
            ret += 1
          end
          ret
        end

        # ---- uri.c: RFC 3986 parser (xmlParseURI with cleanup == 0) -------------------------
        # Every function takes the string and a byte index and returns [ret, new_index].

        URI_SUB_DELIM = Array.new(256, false).tap { |t| "!$&()*+,;='".each_byte { |b| t[b] = true } }.freeze
        URI_UNRESERVED = Array.new(256, false).tap do |t|
          ("A".."Z").each { |c| t[c.ord] = true }
          ("a".."z").each { |c| t[c.ord] = true }
          ("0".."9").each { |c| t[c.ord] = true }
          "-._~".each_byte { |b| t[b] = true }
        end.freeze
        URI_HEX = Array.new(256, false).tap { |t| "0123456789abcdefABCDEF".each_byte { |b| t[b] = true } }.freeze

        def uri_c(s, i) = s.getbyte(i) || 0

        # ISA_PCT_ENCODED
        def uri_pct_encoded(s, i)
          s.getbyte(i) == 0x25 && URI_HEX[uri_c(s, i + 1)] && URI_HEX[uri_c(s, i + 2)]
        end

        # ISA_PCHAR (with xmlIsUnreserved for cleanup == 0)
        def uri_pchar(s, i)
          c = uri_c(s, i)
          URI_UNRESERVED[c] || uri_pct_encoded(s, i) || URI_SUB_DELIM[c] || c == 0x3A || c == 0x40
        end

        # NEXT
        def uri_next(s, i) = s.getbyte(i) == 0x25 ? i + 3 : i + 1

        # xmlParse3986Scheme
        def parse3986_scheme(s, i)
          c = uri_c(s, i)
          return [1, i] unless (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)

          i += 1
          while (c = uri_c(s, i)) != 0 &&
              ((c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) ||
               c == 0x2B || c == 0x2D || c == 0x2E)
            i += 1
          end
          [0, i]
        end

        # xmlParse3986Fragment
        def parse3986_fragment(s, i)
          while uri_pchar(s, i) || (c = uri_c(s, i)) == 0x2F || c == 0x3F || c == 0x5B || c == 0x5D
            i = uri_next(s, i)
          end
          [0, i]
        end

        # xmlParse3986Query
        def parse3986_query(s, i)
          i = uri_next(s, i) while uri_pchar(s, i) || (c = uri_c(s, i)) == 0x2F || c == 0x3F
          [0, i]
        end

        # xmlParse3986Port
        def parse3986_port(s, i)
          c = uri_c(s, i)
          return [1, i] unless c >= 0x30 && c <= 0x39

          port = 0
          while (c = uri_c(s, i)) >= 0x30 && c <= 0x39
            digit = c - 0x30
            return [1, i] if port > 2_147_483_647 / 10

            port *= 10
            return [1, i] if port > 2_147_483_647 - digit

            port += digit
            i += 1
          end
          [0, i]
        end

        # xmlParse3986Userinfo
        def parse3986_userinfo(s, i)
          while URI_UNRESERVED[c = uri_c(s, i)] || uri_pct_encoded(s, i) || URI_SUB_DELIM[c] || c == 0x3A
            i = uri_next(s, i)
          end
          return [0, i] if uri_c(s, i) == 0x40

          [1, i]
        end

        # xmlParse3986DecOctet (with libxml2's quirks)
        def parse3986_dec_octet(s, i)
          d = ->(k) { (c = uri_c(s, k)) >= 0x30 && c <= 0x39 }
          return [1, i] unless d.(i)

          c0 = uri_c(s, i)
          c1 = uri_c(s, i + 1)
          if !d.(i + 1)
            i += 1
          elsif c0 != 0x30 && d.(i + 1) && !d.(i + 2)
            i += 2
          elsif c0 == 0x31 && d.(i + 1) && d.(i + 2)
            i += 3
          elsif c0 == 0x32 && c1 >= 0x30 && c1 <= 0x34 && d.(i + 2)
            i += 3
          elsif c0 == 0x32 && c1 == 0x35 && uri_c(s, i + 2) >= 0x30 && c1 <= 0x35
            i += 3
          else
            return [1, i]
          end
          [0, i]
        end

        # xmlParse3986Host
        def parse3986_host(s, i)
          start = i
          if uri_c(s, i) == 0x5B
            i += 1
            i += 1 while (c = uri_c(s, i)) != 0x5D && c != 0
            return [1, i] if uri_c(s, i) != 0x5D

            return [0, i + 1]
          end
          c = uri_c(s, i)
          if c >= 0x30 && c <= 0x39
            # try to parse an IPv4 (as in libxml2, the third octet is looked for at the '.')
            ok = catch(:not_ipv4) do
              r, i = parse3986_dec_octet(s, i)
              throw :not_ipv4, false if r != 0 || uri_c(s, i) != 0x2E

              i += 1
              r, i = parse3986_dec_octet(s, i)
              throw :not_ipv4, false if r != 0 || uri_c(s, i) != 0x2E

              r, i = parse3986_dec_octet(s, i)
              throw :not_ipv4, false if r != 0 || uri_c(s, i) != 0x2E

              r, i = parse3986_dec_octet(s, i)
              throw :not_ipv4, false if r != 0

              true
            end
            return [0, i] if ok

            i = start
          end
          # then this should be a hostname which can be empty
          i = uri_next(s, i) while URI_UNRESERVED[c = uri_c(s, i)] || uri_pct_encoded(s, i) || URI_SUB_DELIM[c]
          [0, i]
        end

        # xmlParse3986Authority
        def parse3986_authority(s, i)
          ret, cur = parse3986_userinfo(s, i)
          if ret != 0 || uri_c(s, cur) != 0x40
            cur = i
          else
            cur += 1
          end
          ret, cur = parse3986_host(s, cur)
          return [ret, cur] if ret != 0

          if uri_c(s, cur) == 0x3A
            cur += 1
            ret, cur = parse3986_port(s, cur)
            return [ret, cur] if ret != 0
          end
          [0, cur]
        end

        # xmlParse3986Segment
        def parse3986_segment(s, i, forbid, empty)
          if !uri_pchar(s, i) || uri_c(s, i) == forbid
            return [empty ? 0 : 1, i]
          end

          i = uri_next(s, i)
          i = uri_next(s, i) while uri_pchar(s, i) && uri_c(s, i) != forbid
          [0, i]
        end

        # xmlParse3986PathAbEmpty
        def parse3986_path_ab_empty(s, i)
          while uri_c(s, i) == 0x2F
            i += 1
            _, i = parse3986_segment(s, i, 0, true)
          end
          [0, i]
        end

        # xmlParse3986PathAbsolute
        def parse3986_path_absolute(s, i)
          return [1, i] if uri_c(s, i) != 0x2F

          i += 1
          ret, i = parse3986_segment(s, i, 0, false)
          if ret == 0
            while uri_c(s, i) == 0x2F
              i += 1
              _, i = parse3986_segment(s, i, 0, true)
            end
          end
          [0, i]
        end

        # xmlParse3986PathRootless
        def parse3986_path_rootless(s, i)
          ret, i = parse3986_segment(s, i, 0, false)
          return [ret, i] if ret != 0

          while uri_c(s, i) == 0x2F
            i += 1
            _, i = parse3986_segment(s, i, 0, true)
          end
          [0, i]
        end

        # xmlParse3986PathNoScheme
        def parse3986_path_no_scheme(s, i)
          ret, i = parse3986_segment(s, i, 0x3A, false)
          return [ret, i] if ret != 0

          while uri_c(s, i) == 0x2F
            i += 1
            _, i = parse3986_segment(s, i, 0, true)
          end
          [0, i]
        end

        # xmlParse3986HierPart
        def parse3986_hier_part(s, i)
          if uri_c(s, i) == 0x2F && uri_c(s, i + 1) == 0x2F
            i += 2
            ret, i = parse3986_authority(s, i)
            return [ret, i] if ret != 0

            return parse3986_path_ab_empty(s, i)
          elsif uri_c(s, i) == 0x2F
            ret, i = parse3986_path_absolute(s, i)
            return [ret, i] if ret != 0
          elsif uri_pchar(s, i)
            ret, i = parse3986_path_rootless(s, i)
            return [ret, i] if ret != 0
          end
          [0, i]
        end

        # the query / fragment / end-of-string tail shared by the URI and relative-ref parsers
        def parse3986_tail(s, i)
          if uri_c(s, i) == 0x3F
            _, i = parse3986_query(s, i + 1)
          end
          if uri_c(s, i) == 0x23
            _, i = parse3986_fragment(s, i + 1)
          end
          uri_c(s, i) != 0 ? 1 : 0
        end

        # xmlParse3986RelativeRef
        def parse3986_relative_ref(s)
          i = 0
          if uri_c(s, i) == 0x2F && uri_c(s, i + 1) == 0x2F
            ret, i = parse3986_authority(s, i + 2)
            return ret if ret != 0

            _, i = parse3986_path_ab_empty(s, i)
          elsif uri_c(s, i) == 0x2F
            ret, i = parse3986_path_absolute(s, i)
            return ret if ret != 0
          elsif uri_pchar(s, i)
            ret, i = parse3986_path_no_scheme(s, i)
            return ret if ret != 0
          end
          parse3986_tail(s, i)
        end

        # xmlParse3986URI
        def parse3986_uri(s)
          ret, i = parse3986_scheme(s, 0)
          return ret if ret != 0
          return 1 if uri_c(s, i) != 0x3A

          ret, i = parse3986_hier_part(s, i + 1)
          return ret if ret != 0

          parse3986_tail(s, i)
        end

        # xmlParse3986URIReference
        def parse3986_uri_reference(s)
          ret = parse3986_uri(s)
          return ret if ret <= 0

          parse3986_relative_ref(s)
        end

        # xmlParseURI(str) != NULL. Strings containing a NUL byte are cut there like in C.
        def parse_uri_ok(str)
          return false if str.nil?

          nul = str.index("\0")
          str = str.byteslice(0, nul) if nul
          parse3986_uri_reference(str) == 0
        end
      end
    end
  end
end
