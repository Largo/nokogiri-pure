# frozen_string_literal: true

# Character classes and scanning regexps used by the XML parser (libxml2 parser.c / chvalid.h).
#
# The parser works on a UTF-8 String (bytes from the input converted to UTF-8, invalid bytes
# replaced by U+FFFD) through a StringScanner, so most of these are Regexps anchored at the
# scanner position.

module Nokogiri
  module Pure
    module Parser
      INPUT_CHUNK = 250
      LINE_LEN = 80
      XML_MAX_TEXT_LENGTH = 10_000_000
      XML_MAX_HUGE_LENGTH = 1_000_000_000
      XML_MAX_NAME_LENGTH = 50_000
      XML_MAX_LOOKUP_LIMIT = 10_000_000
      XML_MAX_NAMELEN = 100
      XML_PARSER_BUFFER_SIZE = 100
      XML_PARSER_BIG_BUFFER_SIZE = 300
      XML_PARSER_ALLOWED_EXPANSION = 1_000_000
      XML_ENT_FIXED_COST = 20
      XML_MAX_AMPLIFICATION_DEFAULT = 5
      XML_MAX_URI_LENGTH = 2000
      INT_MAX = 2_147_483_647
      ULONG_MAX = 18_446_744_073_709_551_615

      # xmlParserOption
      PARSE_RECOVER = 1 << 0
      PARSE_NOENT = 1 << 1
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

      # ctxt->loadsubset bits
      XML_DETECT_IDS = 2
      XML_COMPLETE_ATTRS = 4
      XML_SKIP_IDS = 8

      # input->flags
      XML_INPUT_HAS_ENCODING = 1 << 0
      XML_INPUT_AUTO_ENCODING = 7 << 1
      XML_INPUT_AUTO_UTF8 = 1 << 1
      XML_INPUT_AUTO_UTF16LE = 2 << 1
      XML_INPUT_AUTO_UTF16BE = 3 << 1
      XML_INPUT_AUTO_OTHER = 4 << 1
      XML_INPUT_USES_ENC_DECL = 1 << 4
      XML_INPUT_ENCODING_ERROR = 1 << 5
      XML_INPUT_PROGRESSIVE = 1 << 6

      # entity->flags (private/entities.h)
      XML_ENT_PARSED = 1 << 0
      XML_ENT_CHECKED = 1 << 1
      XML_ENT_VALIDATED = 1 << 2
      XML_ENT_EXPANDING = 1 << 3

      # xmlParserInputState
      XML_PARSER_EOF = -1
      XML_PARSER_START = 0
      XML_PARSER_MISC = 1
      XML_PARSER_PI = 2
      XML_PARSER_DTD = 3
      XML_PARSER_PROLOG = 4
      XML_PARSER_COMMENT = 5
      XML_PARSER_START_TAG = 6
      XML_PARSER_CONTENT = 7
      XML_PARSER_CDATA_SECTION = 8
      XML_PARSER_END_TAG = 9
      XML_PARSER_ENTITY_DECL = 10
      XML_PARSER_ENTITY_VALUE = 11
      XML_PARSER_ATTRIBUTE_VALUE = 12
      XML_PARSER_SYSTEM_LITERAL = 13
      XML_PARSER_EPILOG = 14
      XML_PARSER_IGNORE = 15
      XML_PARSER_PUBLIC_LITERAL = 16
      XML_PARSER_XML_DECL = 17

      SAX_COMPAT_MODE = "SAX compatibility mode document"
      XML_DEFAULT_VERSION = "1.0"

      NS_INDEX_EMPTY = INT_MAX
      NS_INDEX_XML = INT_MAX - 1

      module Chars
        module_function

        def blank?(c)
          c == 0x20 || c == 0x9 || c == 0xA || c == 0xD
        end

        # IS_CHAR
        def char?(c)
          if c < 0x100
            c == 0x9 || c == 0xA || c == 0xD || c >= 0x20
          else
            (c <= 0xD7FF) || (c >= 0xE000 && c <= 0xFFFD) || (c >= 0x10000 && c <= 0x10FFFF)
          end
        end

        # IS_BYTE_CHAR
        def byte_char?(c)
          c >= 0x20 || c == 0x9 || c == 0xA || c == 0xD
        end

        PUBID = Array.new(256, false).tap do |t|
          "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 \r\n-'()+,./:=?;!*#@$_%".each_byte { |b| t[b] = true }
        end.freeze

        def pubid_char?(c)
          PUBID[c]
        end

        # XML 1.0 5th edition NameStartChar / NameChar: ASCII by table, the rest as case/when range
        # lists (a long || chain nests too deep for ruby.wasm's compiler)
        NAME_START_ASCII = Array.new(128) { |c|
          (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x5F || c == 0x3A
        }.freeze
        NAME_CHAR_ASCII = Array.new(128) { |c|
          NAME_START_ASCII[c] || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2E
        }.freeze

        def name_start_char?(c)
          return NAME_START_ASCII[c] if c < 0x80 && c >= 0

          case c
          when 0xC0..0xD6, 0xD8..0xF6, 0xF8..0x2FF, 0x370..0x37D, 0x37F..0x1FFF, 0x200C..0x200D,
            0x2070..0x218F, 0x2C00..0x2FEF, 0x3001..0xD7FF, 0xF900..0xFDCF, 0xFDF0..0xFFFD, 0x10000..0xEFFFF
            true
          else
            false
          end
        end

        def name_char?(c)
          return NAME_CHAR_ASCII[c] if c < 0x80 && c >= 0

          case c
          when 0xB7, 0xC0..0xD6, 0xD8..0xF6, 0xF8..0x2FF, 0x300..0x36F, 0x370..0x37D, 0x37F..0x1FFF,
            0x200C..0x200D, 0x203F..0x2040, 0x2070..0x218F, 0x2C00..0x2FEF, 0x3001..0xD7FF,
            0xF900..0xFDCF, 0xFDF0..0xFFFD, 0x10000..0xEFFFF
            true
          else
            false
          end
        end

        def chvalid
          @chvalid ||= begin
            require_relative "../html_parser/chvalid"
            HTMLParser::ChValid
          rescue LoadError, NameError
            nil
          end
        end

        # XML 1.0 4th edition (XML_PARSE_OLD10) classes
        def letter?(c)
          cv = chvalid
          return ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c >= 0xC0) unless cv

          cv.letter?(c)
        end

        def digit?(c)
          cv = chvalid
          return c >= 0x30 && c <= 0x39 unless cv

          cv.digit?(c)
        end

        def combining?(c)
          cv = chvalid
          cv ? cv.combining?(c) : false
        end

        def extender?(c)
          cv = chvalid
          cv ? cv.extender?(c) : c == 0xB7
        end

        def old_name_start_char?(c)
          letter?(c) || c == 0x5F || c == 0x3A
        end

        def old_name_char?(c)
          letter?(c) || digit?(c) || c == 0x2E || c == 0x2D || c == 0x5F || c == 0x3A ||
            combining?(c) || extender?(c)
        end
      end

      # U+FFFD is always excluded from bulk scans: it may stand for an invalid input byte, which
      # must be reported when the parser reaches it.
      NAME_START_RE = /[:A-Z_a-zÀ-ÖØ-öø-˿Ͱ-ͽͿ-῿‌-‍⁰-↏Ⰰ-⿯、-퟿豈-﷏ﷰ-￼\u{10000}-\u{EFFFF}]/
      NAME_CHARS_RE = /[-.0-9:A-Z_a-z·À-ÖØ-öø-ͽͿ-῿‌-‍‿-⁀⁰-↏Ⰰ-⿯、-퟿豈-﷏ﷰ-￼\u{10000}-\u{EFFFF}]*/
      NCNAME_CHARS_RE = /[-.0-9A-Z_a-z·À-ÖØ-öø-ͽͿ-῿‌-‍‿-⁀⁰-↏Ⰰ-⿯、-퟿豈-﷏ﷰ-￼\u{10000}-\u{EFFFF}]*/
      ASCII_NAME_RE = /[A-Za-z_:][-A-Za-z0-9_:.]*/
      ASCII_NCNAME_RE = /[A-Za-z_][-A-Za-z0-9_.]*/
      BLANKS_RE = /[ \t\n\r]+/
      NOT_BLANK_RE = /[^ \t\n\r]/
    end
  end
end
