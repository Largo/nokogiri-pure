# frozen_string_literal: true

# Port of libexslt 1.1.43 (exslt.c + exslt.h): the EXSLT extension modules for the pure-Ruby
# XSLT engine. One file per C file under exslt/:
#
#   common.rb    exsl:node-set, exsl:object-type, exsl:document
#   math.rb      math:*
#   sets.rb      set:*
#   functions.rb func:function / func:result
#   strings.rb   str:*
#   date.rb      date:*
#   saxon.rb     saxon:expression/eval/evaluate/line-number/systemId
#   dynamic.rb   dyn:evaluate / dyn:map
#
# crypto.c is not ported: Nokogiri's libexslt is built without EXSLT_CRYPTO_ENABLED, so
# function-available('crypto:md5') is false there.
#
# Extension functions are Method objects taking (pctxt, nargs) like xmlXPathFunction. They are
# registered with the XSLT core through XSLT.register_ext_module_function & friends by
# EXSLT.register_all (exsltRegisterAll).

require_relative "internals"

module Nokogiri
  module Pure
    module XSLT
      module EXSLT
        # exsltLibraryVersion / exsltLibexsltVersion / exsltLibxsltVersion / exsltLibxmlVersion
        LIBRARY_VERSION = "824"
        LIBEXSLT_VERSION = 824
        LIBXSLT_VERSION = 10_143
        LIBXML_VERSION = 21_309

        COMMON_NAMESPACE = "http://exslt.org/common"
        CRYPTO_NAMESPACE = "http://exslt.org/crypto"
        MATH_NAMESPACE = "http://exslt.org/math"
        SETS_NAMESPACE = "http://exslt.org/sets"
        FUNCTIONS_NAMESPACE = "http://exslt.org/functions"
        STRINGS_NAMESPACE = "http://exslt.org/strings"
        DATE_NAMESPACE = "http://exslt.org/dates-and-times"
        DYNAMIC_NAMESPACE = "http://exslt.org/dynamic"
        SAXON_NAMESPACE = "http://icl.com/saxon"

        LONG_MAX = (2**63) - 1
        LONG_MIN = -(2**63)
        INT_MAX = (2**31) - 1

        module_function

        # exsltRegisterAll
        def register_all
          common_register
          math_register
          sets_register
          func_register
          str_register
          date_register
          saxon_register
          dyn_register
        end

        # ---- C arithmetic helpers ------------------------------------------------------------

        # C integer division (truncates toward zero)
        def cdiv(a, b)
          q = a.abs / b.abs
          (a < 0) ^ (b < 0) ? -q : q
        end

        # C integer remainder (sign of the dividend)
        def cmod(a, b)
          a - (b * cdiv(a, b))
        end

        # ---- xmlstring.c byte-level helpers --------------------------------------------------
        #
        # These operate on binary (ASCII-8BIT) strings, treating the end of the string (and an
        # embedded NUL) like C's terminating NUL byte.

        def byte_at(s, i)
          s.getbyte(i) || 0
        end

        def to_utf8(bytes)
          bytes.force_encoding(::Encoding::UTF_8)
        end

        # xmlUTF8Strsize(s + pos, len): byte size of the first +len+ characters
        def utf8_strsize(s, pos, len)
          return 0 if len <= 0

          ptr = pos
          while len > 0
            len -= 1
            ch = byte_at(s, ptr)
            break if ch == 0

            ptr += 1
            next if ch & 0x80 == 0

            while ((ch <<= 1) & 0x80) != 0
              break if byte_at(s, ptr) == 0

              ptr += 1
            end
          end
          ret = ptr - pos
          ret > INT_MAX ? 0 : ret
        end

        # xmlUTF8Strlen: number of characters, or -1 for malformed UTF-8
        def utf8_strlen(s)
          return -1 if s.nil?

          ret = 0
          i = 0
          while (c = byte_at(s, i)) != 0
            if c & 0x80 != 0
              return -1 if byte_at(s, i + 1) & 0xc0 != 0x80

              if c & 0xe0 == 0xe0
                return -1 if byte_at(s, i + 2) & 0xc0 != 0x80

                if c & 0xf0 == 0xf0
                  return -1 if c & 0xf8 != 0xf0 || byte_at(s, i + 3) & 0xc0 != 0x80

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
          ret > INT_MAX ? 0 : ret
        end

        # xmlUTF8Size(s + pos)
        def utf8_size(s, pos)
          c = byte_at(s, pos)
          return 1 if c < 0x80
          return -1 if c & 0x40 == 0

          len = 2
          mask = 0x20
          while mask != 0
            return len if c & mask == 0

            len += 1
            mask >>= 1
          end
          -1
        end

        # xmlStrncmp(a + ai, b + bi, len)
        def strncmp(a, ai, b, bi, len)
          return 0 if len <= 0

          loop do
            c2 = byte_at(b, bi)
            tmp = byte_at(a, ai) - c2
            len -= 1
            return tmp if tmp != 0 || len == 0
            return 0 if c2 == 0

            ai += 1
            bi += 1
          end
        end

        # xmlUTF8Charcmp(a + ai, b + bi)
        def utf8_charcmp(a, ai, b, bi)
          strncmp(a, ai, b, bi, utf8_size(a, ai))
        end

        # xmlStrncasecmp(a + ai, b + bi, len) (ASCII case folding, like libxml2's casemap)
        def strncasecmp(a, ai, b, bi, len)
          return 0 if len <= 0

          loop do
            c2 = byte_at(b, bi)
            tmp = casemap(byte_at(a, ai)) - casemap(c2)
            len -= 1
            return tmp if tmp != 0 || len == 0
            return 0 if c2 == 0

            ai += 1
            bi += 1
          end
        end

        def casemap(c)
          c >= 0x41 && c <= 0x5A ? c + 32 : c
        end

        # xmlUTF8Strndup(s, len): the first +len+ characters (binary string)
        def utf8_strndup(s, len)
          return nil if s.nil? || len < 0

          s.byteslice(0, utf8_strsize(s, 0, len))
        end

        # the C string (up to the first NUL) of a binary string
        def cstr(s)
          i = s.index("\0".b)
          i ? s.byteslice(0, i) : s
        end

        # libxml2 keeps the XPath recursion depth in ctxt->context->depth; the pure evaluator
        # tracks it in the parser context while evaluating. Nested evaluations started by an
        # extension function (dyn:evaluate, dyn:map, saxon:eval) must continue from the live
        # depth, so copy it into the context. Returns the previous context depth.
        def sync_xpath_depth(ctxt)
          saved = ctxt.context.depth
          if ctxt.instance_variable_defined?(:@depth)
            live = ctxt.instance_variable_get(:@depth)
            ctxt.context.depth = live if live.is_a?(Integer)
          end
          saved
        end

        # xmlXPathStackIsNodeSet
        def stack_is_node_set?(ctxt)
          ctxt.value.is_a?(Array)
        end

        # xmlXPathWrapNodeSet: the popped node-set of a NODESET/XSLT_TREE object, as a plain
        # node-set value (a ValueTree popped with xmlXPathPopNodeSet becomes a node-set)
        def plain_node_set(ns)
          return [] if ns.nil?

          ns.instance_of?(Array) ? ns : Array.new(ns)
        end
      end
    end
  end
end

require_relative "exslt/common"
require_relative "exslt/math"
require_relative "exslt/sets"
require_relative "exslt/functions"
require_relative "exslt/strings"
require_relative "exslt/date"
require_relative "exslt/saxon"
require_relative "exslt/dynamic"
