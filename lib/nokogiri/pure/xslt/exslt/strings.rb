# frozen_string_literal: true

# Port of libexslt/strings.c: str:tokenize/split/encode-uri/decode-uri/padding/align/concat/
# replace. The algorithms work on the UTF-8 bytes exactly like the C code (including its
# quirks, e.g. str:split with an empty delimiter splits into single *bytes*, and str:split
# matches the delimiter ASCII-case-insensitively).

module Nokogiri
  module Pure
    module XSLT
      module EXSLT
        TOKEN_NAME = -"token"

        module_function

        # adds a <token> element holding +content+ (binary) to +container+ and the node-set
        def str_add_token(container, ret, content)
          # xmlNewDocRawNode(container, NULL, "token", content) + xmlAddChild(container, node),
          # linked directly (an element appended to a document never merges with a sibling)
          node = XmlNode.new(ELEMENT_NODE, TOKEN_NAME, container)
          text = XmlNode.new(TEXT_NODE, STRING_TEXT, container)
          text.content = to_utf8(content)
          text.parent = node
          node.children = node.last = text
          node.parent = container
          if (prev = container.last)
            prev.next = node
            node.prev = prev
          else
            container.children = node
          end
          container.last = node
          ret << node
        end

        # the tokens (binary strings) of str:tokenize(s, d); s and d are binary C strings
        def str_tokenize_tokens(s, d)
          # fast path: for well-formed UTF-8 the C loop splits on whole characters
          if s.dup.force_encoding(::Encoding::UTF_8).valid_encoding? &&
              d.dup.force_encoding(::Encoding::UTF_8).valid_encoding?
            su = s.dup.force_encoding(::Encoding::UTF_8)
            return su.each_char.map(&:b) if d.empty?

            chars = d.dup.force_encoding(::Encoding::UTF_8).each_char.map { |c| Regexp.escape(c) }
            re = Regexp.new("(?:#{chars.join("|")})")
            return su.split(re).reject(&:empty?).map(&:b)
          end
          str_tokenize_tokens_bytewise(s, d)
        end

        # the byte-level loop of exsltStrTokenizeFunction
        def str_tokenize_tokens_bytewise(s, d)
          toks = []
          len = s.bytesize
          cur = 0
          token = 0
          while cur < len
            clen = utf8_strsize(s, cur, 1)
            if d.empty? # empty string case
              toks << s.byteslice(cur, clen)
              token = cur + clen
            else
              dl = 0
              while dl < d.bytesize
                if utf8_charcmp(s, cur, d, dl) == 0
                  if cur == token
                    # discard empty tokens
                    token = cur + clen
                    break
                  end
                  toks << s.byteslice(token, cur - token)
                  token = cur + clen
                  break
                end
                dl += utf8_strsize(d, dl, 1)
              end
            end
            cur += clen
          end
          toks << s.byteslice(token, len - token) if token != cur
          toks
        end

        # the tokens (binary strings) of str:split(s, d); s and d are binary C strings
        def str_split_tokens(s, d)
          return s.each_byte.map(&:chr) if d.empty? # (single bytes, like the C code)

          # fast path: xmlStrncasecmp folds ASCII only, like a case-insensitive binary regexp
          re = Regexp.new(Regexp.escape(d), Regexp::IGNORECASE | Regexp::NOENCODING)
          s.split(re).reject(&:empty?)
        end

        # the byte-level loop of exsltStrSplitFunction
        def str_split_tokens_bytewise(s, d)
          toks = []
          delimiter_length = d.bytesize
          len = s.bytesize
          cur = 0
          token = 0
          while cur < len
            if delimiter_length == 0
              if cur != token
                toks << s.byteslice(token, cur - token)
                token += 1
              end
            elsif strncasecmp(s, cur, d, 0, delimiter_length) == 0
              if cur == token
                # discard empty tokens
                cur = cur + delimiter_length - 1
                token = cur + 1
                cur += 1
                next
              end
              toks << s.byteslice(token, cur - token)
              cur = cur + delimiter_length - 1
              token = cur + 1
            end
            cur += 1
          end
          toks << s.byteslice(token, cur - token) if token != cur
          toks
        end

        # exsltStrTokenizeFunction
        def str_tokenize_function(ctxt, nargs)
          if nargs < 1 || nargs > 2
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          if nargs == 2
            delimiters = ctxt.pop_string
            return if ctxt.error != XPath::EXPRESSION_OK
          else
            delimiters = "\t\r\n "
          end
          return if delimiters.nil?

          str = ctxt.pop_string
          return if ctxt.error != XPath::EXPRESSION_OK || str.nil?

          ret = nil
          # Return a result tree fragment
          tctxt = XSLT.xpath_get_transform_context(ctxt)
          if tctxt.nil?
            XSLT.transform_error(nil, nil, nil, "exslt:tokenize : internal error tctxt == NULL\n")
          else
            container = XSLT.create_rvt(tctxt)
            if container
              XSLT.register_local_rvt(tctxt, container)
              ret = []
              str_tokenize_tokens(cstr(str.b), cstr(delimiters.b)).each do |tok|
                str_add_token(container, ret, tok)
              end
            end
          end

          ctxt.value_push(ret || [])
        end

        # exsltStrSplitFunction
        def str_split_function(ctxt, nargs)
          if nargs < 1 || nargs > 2
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          if nargs == 2
            delimiter = ctxt.pop_string
            return if ctxt.error != XPath::EXPRESSION_OK
          else
            delimiter = " "
          end
          return if delimiter.nil?

          d = cstr(delimiter.b)
          delimiter_length = d.bytesize

          str = ctxt.pop_string
          return if ctxt.error != XPath::EXPRESSION_OK || str.nil?

          ret = nil
          # Return a result tree fragment
          tctxt = XSLT.xpath_get_transform_context(ctxt)
          if tctxt.nil?
            XSLT.transform_error(nil, nil, nil, "exslt:tokenize : internal error tctxt == NULL\n")
          else
            container = XSLT.create_rvt(tctxt)
            if container
              XSLT.register_local_rvt(tctxt, container)
              ret = []
              str_split_tokens(cstr(str.b), d).each { |tok| str_add_token(container, ret, tok) }
            end
          end

          ctxt.value_push(ret || [])
        end

        URI_ESCAPE_ALL = "-_.!~*'()".b.freeze
        URI_ESCAPE_RESERVED = "-_.!~*'();/?:@&=+$,[]".b.freeze

        # IS_UNRESERVED (uri.c)
        def uri_unreserved?(c)
          (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) ||
            c == 0x2D || c == 0x5F || c == 0x2E || c == 0x21 || c == 0x7E || c == 0x2A ||
            c == 0x27 || c == 0x28 || c == 0x29
        end

        HEX_UPPER = "0123456789ABCDEF"

        # xmlURIEscapeStr (binary in, binary out)
        def uri_escape_str(str, list)
          return nil if str.nil?

          ret = +"".b
          str.each_byte do |ch|
            break if ch == 0

            if ch != 0x40 && !uri_unreserved?(ch) && !list.include?(ch.chr)
              ret << "%" << HEX_UPPER[ch >> 4] << HEX_UPPER[ch & 0xF]
            else
              ret << ch
            end
          end
          ret
        end

        def hex_digit?(c)
          (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)
        end

        def hex_value(c)
          if c <= 0x39
            c - 0x30
          elsif c >= 0x61
            c - 0x61 + 10
          else
            c - 0x41 + 10
          end
        end

        # xmlURIUnescapeString(str, 0, NULL) (binary in, binary out)
        def uri_unescape_string(str)
          return nil if str.nil?

          len = str.bytesize
          ret = +"".b
          i = 0
          while len > 0
            c = str.getbyte(i)
            if len > 2 && c == 0x25 && hex_digit?(str.getbyte(i + 1)) && hex_digit?(str.getbyte(i + 2))
              ret << ((hex_value(str.getbyte(i + 1)) * 16) + hex_value(str.getbyte(i + 2)))
              i += 3
              len -= 3
            else
              ret << c
              i += 1
              len -= 1
            end
          end
          ret
        end

        # xmlCheckUTF8
        def check_utf8(utf)
          return false if utf.nil?

          i = 0
          while (c = byte_at(utf, i)) != 0
            if c & 0x80 == 0x00
              ix = 1
            elsif c & 0xe0 == 0xc0
              return false if byte_at(utf, i + 1) & 0xc0 != 0x80

              ix = 2
            elsif c & 0xf0 == 0xe0
              return false if byte_at(utf, i + 1) & 0xc0 != 0x80 || byte_at(utf, i + 2) & 0xc0 != 0x80

              ix = 3
            elsif c & 0xf8 == 0xf0
              return false if byte_at(utf, i + 1) & 0xc0 != 0x80 || byte_at(utf, i + 2) & 0xc0 != 0x80 ||
                byte_at(utf, i + 3) & 0xc0 != 0x80

              ix = 4
            else
              return false
            end
            i += ix
          end
          true
        end

        # the optional encoding argument of str:encode-uri/decode-uri: only "UTF-8" is supported
        def str_utf8_encoding_arg?(tmp)
          t = tmp.b
          utf8_strlen(t) == 5 && cstr(t) == "UTF-8".b
        end

        # exsltStrEncodeUriFunction
        def str_encode_uri_function(ctxt, nargs)
          if nargs < 2 || nargs > 3
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          if nargs >= 3
            # check for UTF-8 if encoding was explicitly given; we don't support anything else yet
            unless str_utf8_encoding_arg?(ctxt.pop_string)
              ctxt.value_push(+"")
              return
            end
          end

          escape_all = ctxt.pop_boolean
          str = cstr(ctxt.pop_string.b)
          str_len = utf8_strlen(str)

          if str_len <= 0
            XSLT.generic_error("exsltStrEncodeUriFunction: invalid UTF-8\n") if str_len < 0
            ctxt.value_push(+"")
            return
          end

          ret = uri_escape_str(str, escape_all ? URI_ESCAPE_ALL : URI_ESCAPE_RESERVED)
          ctxt.value_push(to_utf8(ret))
        end

        # exsltStrDecodeUriFunction
        def str_decode_uri_function(ctxt, nargs)
          if nargs < 1 || nargs > 2
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          if nargs >= 2
            unless str_utf8_encoding_arg?(ctxt.pop_string)
              ctxt.value_push(+"")
              return
            end
          end

          str = cstr(ctxt.pop_string.b)
          str_len = utf8_strlen(str)

          if str_len <= 0
            XSLT.generic_error("exsltStrDecodeUriFunction: invalid UTF-8\n") if str_len < 0
            ctxt.value_push(+"")
            return
          end

          ret = uri_unescape_string(str)
          unless check_utf8(ret)
            # FIXME: instead of throwing away the whole URI, we should only discard the invalid
            # sequence(s). How to do that?
            ctxt.value_push(+"")
            return
          end

          ctxt.value_push(to_utf8(cstr(ret)))
        end

        # exsltStrPaddingFunction
        def str_padding_function(ctxt, nargs)
          if nargs < 1 || nargs > 2
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          str = nil
          str_len = 0
          if nargs == 2
            str = cstr(ctxt.pop_string.b)
            str_len = utf8_strlen(str)
          end

          floatval = ctxt.pop_number

          if str_len <= 0
            if str_len < 0
              XSLT.generic_error("exsltStrPaddingFunction: invalid UTF-8\n")
              ctxt.value_push(+"")
              return
            end
            str = " ".b
            str_len = 1
          end

          number = if floatval.nan? || floatval < 0.0
            0
          elsif floatval >= 100_000.0
            100_000
          else
            floatval.to_i
          end

          if number <= 0
            ctxt.value_push(+"")
            return
          end

          buf = +"".b
          while number >= str_len
            buf << str
            number -= str_len
          end
          buf << str.byteslice(0, utf8_strsize(str, 0, number)) if number > 0

          ctxt.value_push(to_utf8(buf))
        end

        # exsltStrAlignFunction
        def str_align_function(ctxt, nargs)
          if nargs < 2 || nargs > 3
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          alignment = nargs == 3 ? ctxt.pop_string : nil
          padding = cstr(ctxt.pop_string.b)
          str = cstr(ctxt.pop_string.b)

          str_l = utf8_strlen(str)
          padding_l = utf8_strlen(padding)

          if str_l < 0 || padding_l < 0
            XSLT.generic_error("exsltStrAlignFunction: invalid UTF-8\n")
            ctxt.value_push(+"")
            return
          end

          if str_l == padding_l
            ctxt.value_push(to_utf8(str))
            return
          end

          if str_l > padding_l
            ret = utf8_strndup(str, padding_l)
          elsif alignment == "right"
            ret = utf8_strndup(padding, padding_l - str_l) + str
          elsif alignment == "center"
            left = cdiv(padding_l - str_l, 2)
            ret = utf8_strndup(padding, left) + str
            right_start = utf8_strsize(padding, 0, left + str_l)
            ret << padding.byteslice(right_start..)
          else
            str_s = utf8_strsize(padding, 0, str_l)
            ret = str + padding.byteslice(str_s..)
          end

          ctxt.value_push(to_utf8(ret))
        end

        # exsltStrConcatFunction
        def str_concat_function(ctxt, nargs)
          if nargs != 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          unless stack_is_node_set?(ctxt)
            ctxt.xpath_err(XPath::INVALID_TYPE)
            return
          end

          obj = ctxt.value_pop
          if obj.empty?
            ctxt.value_push(+"")
            return
          end

          buf = +""
          obj.each { |node| buf << XPath.cast_node_to_string(node) }
          ctxt.value_push(buf)
        end

        # exsltStrReturnString: a node-set holding one text node in a new RVT
        def str_return_string(ctxt, str)
          tctxt = XSLT.xpath_get_transform_context(ctxt)
          container = XSLT.create_rvt(tctxt)
          if container.nil?
            ctxt.xpath_err(XPath::MEMORY_ERROR)
            return -1
          end
          XSLT.register_local_rvt(tctxt, container)

          text_node = Tree.new_text(to_utf8(str))
          Tree.add_child(container, text_node)
          ctxt.value_push(XPath.node_set_create(text_node))
          0
        end

        # the replace loop of exsltStrReplaceFunction (binary strings in and out)
        def str_replace_bytes(string, search, replace, slen, rlen, n, i_empty, fast: true)
          if fast && n == 1 && slen[0] > 0 && i_empty < 0 &&
              string.dup.force_encoding(::Encoding::UTF_8).valid_encoding? &&
              search[0].dup.force_encoding(::Encoding::UTF_8).valid_encoding?
            # fast path: matches of a well-formed search string start on character boundaries
            rep = rlen[0] > 0 ? replace[0] : "".b
            return string.gsub(search[0]) { rep }
          end

          buf = +"".b
          src = 0
          start = 0
          len = string.bytesize
          while src < len
            max_len = 0
            i_match = 0
            c = string.getbyte(src)
            n.times do |i|
              si = search[i]
              if slen[i] > max_len && c == si.getbyte(0) && strncmp(string, src, si, 0, slen[i]) == 0
                i_match = i
                max_len = slen[i]
              end
            end

            if max_len == 0
              if i_empty >= 0 && start < src
                buf << string.byteslice(start, src - start) << replace[i_empty]
                start = src
              end
              src += utf8_strsize(string, src, 1)
            else
              buf << string.byteslice(start, src - start) if start < src
              buf << replace[i_match] if rlen[i_match] > 0
              src += slen[i_match]
              start = src
            end
          end

          buf << string.byteslice(start, src - start) if start < src
          buf
        end

        # exsltStrReplaceFunction
        def str_replace_function(ctxt, nargs)
          if nargs != 3
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          replace_str = replace_set = nil
          search_str = search_set = nil

          # get replace argument
          if stack_is_node_set?(ctxt)
            replace_set = ctxt.pop_node_set
          else
            replace_str = cstr(ctxt.pop_string.b)
          end
          return if ctxt.error != XPath::EXPRESSION_OK

          # get search argument
          if stack_is_node_set?(ctxt)
            search_set = ctxt.pop_node_set
            n = search_set ? search_set.length : 0
          else
            search_str = cstr(ctxt.pop_string.b)
            n = 1
          end
          return if ctxt.error != XPath::EXPRESSION_OK

          # get string argument
          string = ctxt.pop_string
          return if ctxt.error != XPath::EXPRESSION_OK

          string = cstr(string.b)

          # check for empty search node list
          if n <= 0
            str_return_string(ctxt, string)
            return
          end

          search = Array.new(n)
          replace = Array.new(n)
          slen = Array.new(n)
          rlen = Array.new(n)
          search[0] = search_str if search_set.nil?

          # process arguments
          i_empty = -1
          n.times do |i|
            search[i] = cstr(XPath.cast_node_to_string(search_set[i]).b) if search_set
            slen[i] = search[i] ? search[i].bytesize : 0
            i_empty = i if i_empty < 0 && slen[i] == 0

            replace[i] = if replace_set
              i < replace_set.length ? cstr(XPath.cast_node_to_string(replace_set[i]).b) : nil
            else
              i == 0 ? replace_str : nil
            end
            rlen[i] = replace[i].nil? ? 0 : replace[i].bytesize
          end

          i_empty = -1 if i_empty >= 0 && rlen[i_empty] == 0

          # replace operation
          buf = str_replace_bytes(string, search, replace, slen, rlen, n, i_empty)

          # create result node set
          str_return_string(ctxt, buf)
        end

        STR_FUNCTIONS = [
          ["tokenize", :str_tokenize_function],
          ["split", :str_split_function],
          ["encode-uri", :str_encode_uri_function],
          ["decode-uri", :str_decode_uri_function],
          ["padding", :str_padding_function],
          ["align", :str_align_function],
          ["concat", :str_concat_function],
          ["replace", :str_replace_function],
        ].freeze

        # exsltStrRegister
        def str_register
          STR_FUNCTIONS.each do |name, fn|
            XSLT.register_ext_module_function(name, STRINGS_NAMESPACE, method(fn))
          end
        end

        # exsltStrXpathCtxtRegister (tokenize, split and replace need a transform context and
        # are not registered)
        def str_xpath_ctxt_register(ctxt, prefix)
          xpath_ctxt_register(ctxt, prefix, STRINGS_NAMESPACE,
            STR_FUNCTIONS.reject { |n, _| %w[tokenize split replace].include?(n) })
        end
      end
    end
  end
end
