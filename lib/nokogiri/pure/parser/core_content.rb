# frozen_string_literal: true

module Nokogiri
  module Pure
    module Parser
      # an attribute collected by xmlParseStartTag2: [localname, prefix, uri/nsIndex, value, alloc]
      Att = Struct.new(:name, :prefix, :ns, :value, :alloc)

      class Ctxt
        # xmlCtxtInitializeLate
        def initialize_late
          if !option?(PARSE_SAX1) && @sax.initialized == SAX2::XML_SAX2_MAGIC &&
              (@sax.start_element_ns || @sax.end_element_ns || (@sax.start_element.nil? && @sax.end_element.nil?))
            @sax2 = 1
          end
        end

        # ---- SAX1 start/end tags -----------------------------------------------------------------

        # xmlParseAttribute (SAX1): returns [name, value]
        def parse_attribute
          grow
          name = parse_name
          if name.nil?
            fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "error parsing attribute name\n")
            return [nil, nil]
          end
          skip_blanks
          if cur_byte == 0x3D
            next_char
            skip_blanks
            val = parse_att_value
          else
            fatal_err_msg_str(ErrCode::ERR_ATTRIBUTE_WITHOUT_VALUE,
              "Specification mandates value for attribute #{name}\n", name)
            return [name, nil]
          end
          if @pedantic != 0 && name == "xml:lang"
            unless Ctxt.check_language_id(val)
              warning_msg(ErrCode::WAR_LANG_VALUE, "Malformed value for xml:lang : #{val}\n", val, nil)
            end
          end
          if name == "xml:space"
            if val == "default"
              self.space = 0
            elsif val == "preserve"
              self.space = 1
            else
              warning_msg(ErrCode::WAR_SPACE_VALUE,
                "Invalid value \"#{val}\" for xml:space : \"default\" or \"preserve\" expected\n", val, nil)
            end
          end
          [name, val]
        end

        # xmlParseStartTag (SAX1)
        def parse_start_tag
          return nil if cur_byte != 0x3C

          next1
          name = parse_name
          if name.nil?
            fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "xmlParseStartTag: invalid element name\n")
            return nil
          end
          atts = []
          skip_blanks
          grow
          while cur_byte != 0x3E && (cur_byte != 0x2F || nxt(1) != 0x3E) && Chars.byte_char?(cur_byte) && !stopped?
            attname, attvalue = parse_attribute
            break if attname.nil?

            if attvalue
              dup = false
              atts.each_slice(2) do |n, _|
                if n == attname
                  err_attribute_dup(nil, attname)
                  dup = true
                  break
                end
              end
              atts << attname << attvalue unless dup
            end
            grow
            break if cur_byte == 0x3E || (cur_byte == 0x2F && nxt(1) == 0x3E)

            if skip_blanks == 0
              fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "attributes construct error\n")
            end
            grow
          end
          if @disable_sax == 0 && (cb = @sax.start_element)
            cb.call(@user_data, name, atts.empty? ? nil : atts)
          end
          name
        end

        # xmlParseEndTag1
        def parse_end_tag1(line)
          grow
          if cur_byte != 0x3C || nxt(1) != 0x2F
            fatal_err_msg(ErrCode::ERR_LTSLASH_REQUIRED, "xmlParseEndTag: '</' not found\n")
            return
          end
          skip(2)
          name = parse_name_and_compare(@name)
          grow
          skip_blanks
          if !Chars.byte_char?(cur_byte) || cur_byte != 0x3E
            fatal_err(ErrCode::ERR_GT_REQUIRED)
          else
            next1
          end
          if name != true
            name = "unparsable" if name.nil?
            fatal_err_msg_str_int_str(ErrCode::ERR_TAG_NAME_MISMATCH,
              "Opening and ending tag mismatch: #{@name} line #{line} and #{name}\n", @name, line, name)
          end
          if @disable_sax == 0 && (cb = @sax.end_element)
            cb.call(@user_data, @name)
          end
          name_pop
          space_pop
        end

        # ---- SAX2 start/end tags ------------------------------------------------------------------

        # xmlParseQNameHashed: returns [localname, prefix] (localname nil on failure)
        def parse_qname
          grow
          start = @cur
          l = parse_ncname
          p = nil
          is_ncname = false
          if l
            is_ncname = true
            if cur_byte == 0x3A
              next_char
              p = l
              l = parse_ncname
            end
          end
          if l.nil? || cur_byte == 0x3A
            l = nil
            p = nil
            return [nil, nil] if !is_ncname && cur_byte != 0x3A

            parse_nmtoken
            l = name_slice(start, @cur - start)
            ns_err(ErrCode::NS_ERR_QNAME, "Failed to parse QName '#{l}'\n", l)
          end
          [l, p]
        end

        # xmlParseQNameAndCompare
        def parse_qname_and_compare(name, prefix)
          return parse_name_and_compare(name) if prefix.nil?

          grow
          pb = prefix.b
          nb = name.b
          if @buf.byteslice(@cur, pb.bytesize)&.b == pb && @buf.getbyte(@cur + pb.bytesize) == 0x3A
            off = @cur + pb.bytesize + 1
            if @buf.byteslice(off, nb.bytesize)&.b == nb
              c = @buf.getbyte(off + nb.bytesize) || 0
              if c == 0x3E || Chars.blank?(c)
                @col += off + nb.bytesize - @cur
                @cur = off + nb.bytesize
                return true
              end
            end
          end
          ret, prefix2 = parse_qname
          return nil if ret.nil?
          return true if ret == name && prefix == prefix2

          ret
        end

        # xmlParseAttribute2: returns [name, prefix, value, alloc]
        def parse_attribute2(pref, elem)
          grow
          name, prefix = parse_qname
          if name.nil?
            fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "error parsing attribute name\n")
            return [nil, nil, nil, false]
          end
          normalize = false
          if @atts_special
            efull = pref ? "#{pref}:#{elem}" : elem
            afull = prefix ? "#{prefix}:#{name}" : name
            type = @atts_special[[efull, afull]]
            normalize = true if type && type != 0
          end
          skip_blanks
          if cur_byte == 0x3D
            next_char
            skip_blanks
            is_namespace = (prefix.nil? && name == "xmlns") || prefix == "xmlns"
            val, alloc = parse_att_value_internal(normalize, is_namespace)
            return [name, prefix, nil, false] if val.nil?
          else
            fatal_err_msg_str(ErrCode::ERR_ATTRIBUTE_WITHOUT_VALUE,
              "Specification mandates value for attribute #{name}\n", name)
            return [name, prefix, nil, false]
          end
          if prefix == "xml"
            if @pedantic != 0 && name == "lang"
              unless Ctxt.check_language_id(val)
                warning_msg(ErrCode::WAR_LANG_VALUE, "Malformed value for xml:lang : #{val}\n", val, nil)
              end
            end
            if name == "space"
              if val == "default"
                self.space = 0
              elsif val == "preserve"
                self.space = 1
              else
                warning_msg(ErrCode::WAR_SPACE_VALUE,
                  "Invalid value \"#{val}\" for xml:space : \"default\" or \"preserve\" expected\n", val, nil)
              end
            end
          end
          [name, prefix, val, alloc]
        end

        XMLNS_NAMESPACE = "http://www.w3.org/2000/xmlns/"

        # lookup in the (name, uri) -> index table of xmlParseStartTag2 (linear while small)
        def seen_lookup(names, uris, idx, name, uri)
          if names.size > 16
            h = @seen_hash
            if h.nil? || @seen_hash_n != names.size || !@seen_hash_names.equal?(names)
              h = @seen_hash = {}
              names.each_with_index { |n, k| h[[n, uris[k]]] ||= idx[k] }
              @seen_hash_names = names
              @seen_hash_n = names.size
            end
            return h[[name, uri]]
          end
          k = 0
          while k < names.size
            return idx[k] if names[k] == name && uris[k] == uri

            k += 1
          end
          nil
        end

        def seen_add(names, uris, idx, name, uri, i)
          names << name
          uris << uri
          idx << i
          if @seen_hash && @seen_hash_names.equal?(names)
            @seen_hash[[name, uri]] ||= i
            @seen_hash_n = names.size
          end
        end

        # xmlParseStartTag2: returns [localname, prefix, uri, nb_ns] (localname nil on failure)
        def parse_start_tag2
          return [nil, nil, nil, 0] if cur_byte != 0x3C

          next1
          nb_ns = 0
          ns_start_element
          localname, prefix = parse_qname
          if localname.nil?
            fatal_err_msg(ErrCode::ERR_NAME_REQUIRED, "StartTag: invalid element name\n")
            return [nil, nil, nil, 0]
          end
          skip_blanks
          grow
          atts = []
          while true
            c = cur_byte
            break unless c != 0x3E && (c != 0x2F || nxt(1) != 0x3E) && Chars.byte_char?(c) && !stopped?

            attname, aprefix, attvalue, alloc = parse_attribute2(prefix, localname)
            break if attname.nil?

            if attvalue
              if attname == "xmlns" && aprefix.nil?
                uri = attvalue
                ok = true
                unless uri.empty?
                  parsed = URIParser.parse(uri)
                  if parsed.nil?
                    ns_err(ErrCode::WAR_NS_URI, "xmlns: '#{uri}' is not a valid URI\n", uri)
                  elsif parsed.scheme.nil?
                    ns_warn(ErrCode::WAR_NS_URI_RELATIVE, "xmlns: URI #{uri} is not absolute\n", uri)
                  end
                  if uri == XML_XML_NAMESPACE
                    if attname != "xml"
                      ns_err(ErrCode::NS_ERR_XML_NAMESPACE, "xml namespace URI cannot be the default namespace\n")
                    end
                    ok = false
                  elsif uri == XMLNS_NAMESPACE
                    ns_err(ErrCode::NS_ERR_XML_NAMESPACE, "reuse of the xmlns namespace name is forbidden\n")
                    ok = false
                  end
                end
                nb_ns += 1 if ok && ns_push(nil, -uri, nil, 0) > 0
              elsif aprefix == "xmlns"
                uri = attvalue
                if attname == "xml"
                  if uri != XML_XML_NAMESPACE
                    ns_err(ErrCode::NS_ERR_XML_NAMESPACE, "xml namespace prefix mapped to wrong URI\n")
                  end
                elsif uri == XML_XML_NAMESPACE
                  ns_err(ErrCode::NS_ERR_XML_NAMESPACE, "xml namespace URI mapped to wrong prefix\n") if attname != "xml"
                elsif attname == "xmlns"
                  ns_err(ErrCode::NS_ERR_XML_NAMESPACE, "redefinition of the xmlns prefix is forbidden\n")
                elsif uri == XMLNS_NAMESPACE
                  ns_err(ErrCode::NS_ERR_XML_NAMESPACE, "reuse of the xmlns namespace name is forbidden\n")
                elsif uri.empty?
                  ns_err(ErrCode::NS_ERR_XML_NAMESPACE, "xmlns:#{attname}: Empty XML namespace is not allowed\n",
                    attname)
                else
                  parsed = URIParser.parse(uri)
                  if parsed.nil?
                    ns_err(ErrCode::WAR_NS_URI, "xmlns:#{attname}: '#{uri}' is not a valid URI\n", attname, uri)
                  elsif @pedantic != 0 && parsed.scheme.nil?
                    ns_warn(ErrCode::WAR_NS_URI_RELATIVE, "xmlns:#{attname}: URI #{uri} is not absolute\n", attname, uri)
                  end
                  nb_ns += 1 if ns_push(attname, -uri, nil, 0) > 0
                end
              else
                atts << Att.new(attname, aprefix, nil, attvalue, alloc)
              end
            end

            grow
            c = cur_byte
            break if c == 0x3E || (c == 0x2F && nxt(1) == 0x3E)

            if skip_blanks == 0
              fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "attributes construct error\n")
              break
            end
            grow
          end

          nratts = atts.length
          nb_total_def = 0
          defaults = @atts_default && @atts_default[[localname, prefix]]
          if defaults
            defaults.each do |attr|
              if attr.name == "xmlns" && attr.prefix.nil?
                parser_entity_check(attr.expanded_size)
                nb_ns += 1 if ns_push(nil, attr.value, nil, 1) > 0
              elsif attr.prefix == "xmlns"
                parser_entity_check(attr.expanded_size)
                nb_ns += 1 if ns_push(attr.name, attr.value, nil, 1) > 0
              else
                nb_total_def += 1
              end
            end
          end

          # resolve attribute namespaces
          atts.each do |a|
            if a.prefix.nil?
              a.ns = NS_INDEX_EMPTY
            elsif a.prefix == "xml"
              a.ns = NS_INDEX_XML
            else
              ns_index = ns_lookup(a.prefix)
              if ns_index == INT_MAX || ns_index < @min_ns_index
                ns_err(ErrCode::NS_ERR_UNDEFINED_NAMESPACE,
                  "Namespace prefix #{a.prefix} for #{a.name} on #{localname} is not defined\n",
                  a.prefix, a.name, localname)
                ns_index = NS_INDEX_EMPTY
              end
              a.ns = ns_index
            end
          end

          max_atts = nratts + nb_total_def
          num_dup_err = 0
          num_ns_err = 0
          # the attribute hash of xmlParseStartTag2: (name, namespace URI) -> first index
          seen_names = nil
          seen_uris = nil
          seen_idx = nil
          if max_atts > 1
            seen_names = []
            seen_uris = []
            seen_idx = []
            i = 0
            while i < nratts
              a = atts[i]
              an = a.ns
              if an == NS_INDEX_EMPTY
                if a.prefix
                  i += 1
                  next
                end
                nsuri = nil
              elsif an == NS_INDEX_XML
                nsuri = XML_XML_NAMESPACE
              else
                nsuri = @ns_tab[an][1]
              end
              name = a.name
              res = seen_lookup(seen_names, seen_uris, seen_idx, name, nsuri)
              if res
                if a.prefix == atts[res].prefix
                  err_attribute_dup(a.prefix, a.name)
                  num_dup_err += 1
                else
                  ns_err(ErrCode::NS_ERR_ATTRIBUTE_REDEFINED,
                    "Namespaced Attribute #{a.name} in '#{nsuri}' redefined\n", a.name, nsuri)
                  num_ns_err += 1
                end
              else
                seen_add(seen_names, seen_uris, seen_idx, name, nsuri, i)
              end
              i += 1
            end
          end

          nbdef = 0
          if defaults
            defaults.each do |attr|
              attname = attr.name
              aprefix = attr.prefix
              next if attname == "xmlns" && aprefix.nil?
              next if aprefix == "xmlns"

              if aprefix.nil?
                ns_index = NS_INDEX_EMPTY
                nsuri = nil
              elsif aprefix == "xml"
                ns_index = NS_INDEX_XML
                nsuri = XML_XML_NAMESPACE
              else
                ns_index = ns_lookup(aprefix)
                if ns_index == INT_MAX || ns_index < @min_ns_index
                  ns_err(ErrCode::NS_ERR_UNDEFINED_NAMESPACE,
                    "Namespace prefix #{aprefix} for #{attname} on #{localname} is not defined\n",
                    aprefix, attname, localname)
                  ns_index = NS_INDEX_EMPTY
                  nsuri = nil
                else
                  nsuri = @ns_tab[ns_index][1]
                end
              end
              if max_atts > 1
                res = seen_lookup(seen_names, seen_uris, seen_idx, attname, nsuri)
                if res
                  next if aprefix == atts[res].prefix

                  ns_err(ErrCode::NS_ERR_ATTRIBUTE_REDEFINED,
                    "Namespaced Attribute #{attname} in '#{nsuri}' redefined\n", attname, nsuri)
                else
                  seen_add(seen_names, seen_uris, seen_idx, attname, nsuri, atts.length)
                end
              end
              parser_entity_check(attr.expanded_size)
              atts << Att.new(attname, aprefix, ns_index, attr.value, :default)
              if @standalone == 1 && attr.external != 0
                validity_error(ErrCode::DTD_STANDALONE_DEFAULTED,
                  "standalone: attribute #{attname} on #{localname} defaulted from external subset\n",
                  attname, localname)
              end
              nbdef += 1
            end
          end

          if num_dup_err == 0 && num_ns_err > 1
            qseen = {}
            atts.each_with_index do |a, j|
              break if j >= nratts
              next if a.prefix.nil?

              key = [a.name, a.prefix]
              if qseen.key?(key)
                err_attribute_dup(a.prefix, a.name)
              else
                qseen[key] = j
              end
            end
          end

          # reconstruct URIs
          atts.each do |a|
            a.ns = if a.ns == INT_MAX
              nil
            elsif a.ns == INT_MAX - 1
              XML_XML_NAMESPACE
            else
              @ns_tab[a.ns][1]
            end
          end

          uri = ns_lookup_uri(prefix)
          if prefix && uri.nil?
            ns_err(ErrCode::NS_ERR_UNDEFINED_NAMESPACE, "Namespace prefix #{prefix} on #{localname} is not defined\n",
              prefix, localname)
          end

          if @disable_sax == 0 && (cb = @sax.start_element_ns)
            namespaces = nb_ns > 0 ? @ns_tab[(@ns_tab.length - nb_ns)..] : []
            cb.call(@user_data, localname, prefix, uri, nb_ns, namespaces, atts.length, nbdef, atts)
          end
          [localname, prefix, uri, nb_ns]
        end

        # xmlParseEndTag2
        def parse_end_tag2(tag)
          grow
          if cur_byte != 0x3C || nxt(1) != 0x2F
            fatal_err(ErrCode::ERR_LTSLASH_REQUIRED)
            return
          end
          skip(2)
          name = if tag.prefix.nil?
            parse_name_and_compare(@name)
          else
            parse_qname_and_compare(@name, tag.prefix)
          end
          grow
          skip_blanks
          if !Chars.byte_char?(cur_byte) || cur_byte != 0x3E
            fatal_err(ErrCode::ERR_GT_REQUIRED)
          else
            next1
          end
          if name != true
            name = "unparsable" if name.nil?
            fatal_err_msg_str_int_str(ErrCode::ERR_TAG_NAME_MISMATCH,
              "Opening and ending tag mismatch: #{@name} line #{tag.line} and #{name}\n", @name, tag.line, name)
          end
          if @disable_sax == 0 && (cb = @sax.end_element_ns)
            cb.call(@user_data, @name, tag.prefix, tag.uri)
          end
          space_pop
          ns_pop(tag.ns_nr) if tag.ns_nr != 0
        end

        # xmlParseCDSect
        def parse_cdsect
          max_length = option?(PARSE_HUGE) ? XML_MAX_HUGE_LENGTH : XML_MAX_TEXT_LENGTH
          return if cur_byte != 0x3C || nxt(1) != 0x21 || nxt(2) != 0x5B

          skip(3)
          return unless cmp?("CDATA[")

          skip(6)
          r = cur_char
          unless Chars.char?(r)
            fatal_err(ErrCode::ERR_CDATA_NOT_FINISHED)
            return
          end
          nextl(@cl)
          s = cur_char
          unless Chars.char?(s)
            fatal_err(ErrCode::ERR_CDATA_NOT_FINISHED)
            return
          end
          nextl(@cl)
          # buf holds everything seen so far, including the two pending chars (libxml2's r and s)
          buf = +""
          buf << utf8_chr(r) << utf8_chr(s)
          pending = [r, s]
          while true
            if pending[0] == 0x5D && pending[1] == 0x5D && cur_byte == 0x3E
              break
            end
            @ss.pos = @cur
            n = @ss.skip(CDATA_PLAIN_RE)
            n = cap_run(n) if n && @input.pending_error
            n = nil if n == 0
            if n
              seg = @buf.byteslice(@cur, n)
              buf << seg
              advance_text(n)
              if n >= 2
                pending = [seg[-2].ord, seg[-1].ord]
              else
                pending = [pending[1], seg.ord]
              end
              next
            end
            c = cur_char
            unless Chars.char?(c)
              content = buf_without_last_chars(buf, 2)
              if content.bytesize > max_length
                fatal_err_msg(ErrCode::ERR_CDATA_NOT_FINISHED, "CData section too big found\n")
                return
              end
              fatal_err_msg_str(ErrCode::ERR_CDATA_NOT_FINISHED,
                "CData section not finished\n#{trunc50(content)}\n", content)
              return
            end
            buf << utf8_chr(c)
            pending = [pending[1], c]
            nextl(@cl)
            if buf.bytesize > max_length + 8
              fatal_err_msg(ErrCode::ERR_CDATA_NOT_FINISHED, "CData section too big found\n")
              return
            end
          end
          nextl(1)
          buf = buf.byteslice(0, buf.bytesize - 2)
          if @disable_sax == 0
            if (cb = @sax.cdata_block)
              cb.call(@user_data, buf)
            elsif (cb = @sax.characters)
              cb.call(@user_data, buf)
            end
          end
        end
        CDATA_PLAIN_RE = /[^\]\r\x00-\x08\x0B\x0C\x0E-\x1F\uFFFD\uFFFE\uFFFF]+/

        def buf_without_last_chars(buf, n)
          chars = buf.length
          return +"" if chars <= n

          buf[0, chars - n]
        end

        # ---- content -------------------------------------------------------------------------------------

        # xmlParseContentInternal
        def parse_content_internal
          old_name_nr = name_nr
          old_space_nr = space_nr
          old_node_nr = node_nr
          grow
          while @cur < @end && !stopped?
            c = @buf.getbyte(@cur)
            if c == 0x3C
              c1 = @buf.getbyte(@cur + 1)
              if c1 == 0x3F
                parse_pi
              elsif c1 == 0x21 && cmp?("<![CDATA[")
                parse_cdsect
              elsif c1 == 0x21 && nxt(2) == 0x2D && nxt(3) == 0x2D
                parse_comment
              elsif c1 == 0x2F
                break if name_nr <= old_name_nr

                parse_element_end
              else
                parse_element_start
              end
            elsif c == 0x26
              parse_reference
            else
              parse_char_data_internal(0)
            end
            grow
          end

          if name_nr > old_name_nr && @cur >= @end && @well_formed != 0
            name = @name_tab[-1]
            line = @push_tab[name_nr - 1].line
            fatal_err_msg_str_int_str(ErrCode::ERR_TAG_NOT_FINISHED,
              "Premature end of data in tag #{name} line #{line}\n", name, line, nil)
          end
          node_pop while node_nr > old_node_nr
          while name_nr > old_name_nr
            tag = @push_tab[name_nr - 1]
            ns_pop(tag.ns_nr) if tag.ns_nr != 0
            name_pop
          end
          space_pop while space_nr > old_space_nr
        end

        # xmlParseContent
        def parse_content
          initialize_late
          parse_content_internal
          fatal_err(ErrCode::ERR_NOT_WELL_BALANCED) if @cur < @end
        end

        # xmlParseElement
        def parse_element
          return if parse_element_start != 0

          parse_content_internal
          if @cur >= @end
            if @well_formed != 0
              name = @name_tab[-1]
              line = @push_tab[name_nr - 1].line
              fatal_err_msg_str_int_str(ErrCode::ERR_TAG_NOT_FINISHED,
                "Premature end of data in tag #{name} line #{line}\n", name, line, nil)
            end
            return
          end
          parse_element_end
        end

        # xmlParseElementStart
        def parse_element_start
          max_depth = option?(PARSE_HUGE) ? 2048 : 256
          if name_nr > max_depth
            fatal_err_msg_int(ErrCode::ERR_RESOURCE_LIMIT,
              "Excessive depth in document: #{name_nr} use XML_PARSE_HUGE option\n", name_nr)
            halt
            return -1
          end
          if space_nr == 0
            space_push(-1)
          elsif space == -2
            space_push(-1)
          else
            space_push(space)
          end
          line = @line
          prefix = nil
          uri = nil
          nb_ns = 0
          if @sax2 != 0
            name, prefix, uri, nb_ns = parse_start_tag2
          else
            name = parse_start_tag
          end
          if name.nil?
            space_pop
            return -1
          end
          name_ns_push(name, prefix, uri, line, nb_ns)
          cur = @node

          if @validate != 0 && @well_formed != 0 && @my_doc && @node && @node.equal?(@my_doc.children)
            @valid &= Valid.validate_root(@vctxt, @my_doc)
          end

          if cur_byte == 0x2F && nxt(1) == 0x3E
            skip(2)
            if @sax2 != 0
              if @disable_sax == 0 && (cb = @sax.end_element_ns)
                cb.call(@user_data, name, prefix, uri)
              end
            elsif @disable_sax == 0 && (cb = @sax.end_element)
              cb.call(@user_data, name)
            end
            name_pop
            space_pop
            ns_pop(nb_ns) if nb_ns > 0
            _ = cur
            return 1
          end
          if cur_byte == 0x3E
            next1
          else
            fatal_err_msg_str_int_str(ErrCode::ERR_GT_REQUIRED,
              "Couldn't find end of Start Tag #{name} line #{line}\n", name, line, nil)
            node_pop
            name_pop
            space_pop
            ns_pop(nb_ns) if nb_ns > 0
            return -1
          end
          0
        end

        # xmlParseElementEnd
        def parse_element_end
          if name_nr <= 0
            skip(2) if cur_byte == 0x3C && nxt(1) == 0x2F
            return
          end
          if @sax2 != 0
            parse_end_tag2(@push_tab[name_nr - 1])
            name_pop
          else
            parse_end_tag1(0)
          end
        end

        # ---- XML declaration -------------------------------------------------------------------------

        # xmlParseVersionNum
        def parse_version_num
          c = cur_byte
          return nil unless c >= 0x30 && c <= 0x39

          buf = (+"") << c.chr
          next_char
          c = cur_byte
          return nil if c != 0x2E

          buf << "."
          next_char
          c = cur_byte
          while c >= 0x30 && c <= 0x39
            buf << c.chr
            next_char
            c = cur_byte
          end
          buf
        end

        # xmlParseVersionInfo
        def parse_version_info
          version = nil
          if cmp?("version")
            skip(7)
            skip_blanks
            if cur_byte != 0x3D
              fatal_err(ErrCode::ERR_EQUAL_REQUIRED)
              return nil
            end
            next_char
            skip_blanks
            q = cur_byte
            if q == 0x22 || q == 0x27
              next_char
              version = parse_version_num
              if cur_byte != q
                fatal_err(ErrCode::ERR_STRING_NOT_CLOSED)
              else
                next_char
              end
            else
              fatal_err(ErrCode::ERR_STRING_NOT_STARTED)
            end
          end
          version
        end

        # xmlParseEncName
        def parse_enc_name
          max_length = option?(PARSE_HUGE) ? XML_MAX_TEXT_LENGTH : XML_MAX_NAME_LENGTH
          c = cur_byte
          if (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
            buf = (+"") << c.chr
            next_char
            c = cur_byte
            while (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) ||
                c == 0x2E || c == 0x5F || c == 0x2D
              buf << c.chr
              if buf.bytesize > max_length
                fatal_err(ErrCode::ERR_NAME_TOO_LONG, "EncName")
                return nil
              end
              next_char
              c = cur_byte
            end
            buf
          else
            fatal_err(ErrCode::ERR_ENCODING_NAME)
            nil
          end
        end

        # xmlParseEncodingDecl
        def parse_encoding_decl
          skip_blanks
          return nil unless cmp?("encoding")

          skip(8)
          skip_blanks
          if cur_byte != 0x3D
            fatal_err(ErrCode::ERR_EQUAL_REQUIRED)
            return nil
          end
          next_char
          skip_blanks
          q = cur_byte
          encoding = nil
          if q == 0x22 || q == 0x27
            next_char
            encoding = parse_enc_name
            if cur_byte != q
              fatal_err(ErrCode::ERR_STRING_NOT_CLOSED)
              return nil
            else
              next_char
            end
          else
            fatal_err(ErrCode::ERR_STRING_NOT_STARTED)
          end
          return nil if encoding.nil?

          set_declared_encoding(encoding)
          @encoding
        end

        # xmlParseSDDecl
        def parse_sd_decl
          standalone = -2
          skip_blanks
          if cmp?("standalone")
            skip(10)
            skip_blanks
            if cur_byte != 0x3D
              fatal_err(ErrCode::ERR_EQUAL_REQUIRED)
              return standalone
            end
            next_char
            skip_blanks
            q = cur_byte
            if q == 0x27 || q == 0x22
              next_char
              if cur_byte == 0x6E && nxt(1) == 0x6F
                standalone = 0
                skip(2)
              elsif cur_byte == 0x79 && nxt(1) == 0x65 && nxt(2) == 0x73
                standalone = 1
                skip(3)
              else
                fatal_err(ErrCode::ERR_STANDALONE_VALUE)
              end
              if cur_byte != q
                fatal_err(ErrCode::ERR_STRING_NOT_CLOSED)
              else
                next_char
              end
            else
              fatal_err(ErrCode::ERR_STRING_NOT_STARTED)
            end
          end
          standalone
        end

        # xmlParseXMLDecl
        def parse_xml_decl
          @standalone = -2
          skip(5)
          unless Chars.blank?(cur_byte)
            fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Blank needed after '<?xml'\n")
          end
          skip_blanks
          version = parse_version_info
          if version.nil?
            fatal_err(ErrCode::ERR_VERSION_MISSING)
          else
            if version != XML_DEFAULT_VERSION
              if option?(PARSE_OLD10)
                fatal_err_msg_str(ErrCode::ERR_UNKNOWN_VERSION, "Unsupported version '#{version}'\n", version)
              elsif version.start_with?("1.")
                warning_msg(ErrCode::WAR_UNKNOWN_VERSION, "Unsupported version '#{version}'\n", version, nil)
              else
                fatal_err_msg_str(ErrCode::ERR_UNKNOWN_VERSION, "Unsupported version '#{version}'\n", version)
              end
            end
            @version = version
          end
          unless Chars.blank?(cur_byte)
            if cur_byte == 0x3F && nxt(1) == 0x3E
              skip(2)
              return
            end
            fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Blank needed here\n")
          end
          parse_encoding_decl
          if @encoding && !Chars.blank?(cur_byte)
            if cur_byte == 0x3F && nxt(1) == 0x3E
              skip(2)
              return
            end
            fatal_err_msg(ErrCode::ERR_SPACE_REQUIRED, "Blank needed here\n")
          end
          grow
          skip_blanks
          @standalone = parse_sd_decl
          skip_blanks
          if cur_byte == 0x3F && nxt(1) == 0x3E
            skip(2)
          elsif cur_byte == 0x3E
            fatal_err(ErrCode::ERR_XMLDECL_NOT_FINISHED)
            next_char
          else
            fatal_err(ErrCode::ERR_XMLDECL_NOT_FINISHED)
            while !stopped? && (c = cur_byte) != 0
              next_char
              break if c == 0x3E
            end
          end
        end

        # xmlParseMisc
        def parse_misc
          until stopped?
            skip_blanks
            grow
            if cur_byte == 0x3C && nxt(1) == 0x3F
              parse_pi
            elsif cmp?("<!--")
              parse_comment
            else
              break
            end
          end
        end

        # xmlFinishDocument
        def finish_document
          if (cb = @sax.end_document)
            cb.call(@user_data)
          end
          doc = @my_doc
          if doc
            if @well_formed != 0
              doc.doc_properties |= 1 # XML_DOC_WELLFORMED
              doc.doc_properties |= 4 if @valid != 0 # DTDVALID
              doc.doc_properties |= 2 if @ns_well_formed != 0 # NSVALID
            end
            doc.doc_properties |= 8 if option?(PARSE_OLD10)
            @my_doc = nil if doc.version == SAX_COMPAT_MODE
          end
        end

        # xmlParseDocument
        def parse_document
          return -1 if @input.nil?

          grow
          initialize_late
          if (cb = @sax.set_document_locator)
            cb.call(@user_data, nil)
          end
          detect_encoding
          if cur_byte == 0 && at_end? || (cur_byte == 0)
            fatal_err(ErrCode::ERR_DOCUMENT_EMPTY)
            return -1
          end
          grow
          if cmp?("<?xml") && Chars.blank?(nxt(5))
            parse_xml_decl
            skip_blanks
          else
            @version = XML_DEFAULT_VERSION.dup
          end
          if @disable_sax == 0 && (cb = @sax.start_document)
            cb.call(@user_data)
          end
          parse_misc
          grow
          if cmp?("<!DOCTYPE")
            @in_subset = 1
            parse_doctype_decl
            parse_internal_subset if cur_byte == 0x5B
            @in_subset = 2
            if @disable_sax == 0 && (cb = @sax.external_subset)
              cb.call(@user_data, @int_sub_name, @ext_sub_system, @ext_sub_uri)
            end
            @in_subset = 0
            clean_special_attr
            parse_misc
          end
          grow
          if cur_byte != 0x3C
            if @well_formed != 0
              fatal_err_msg(ErrCode::ERR_DOCUMENT_EMPTY, "Start tag expected, '<' not found\n")
            end
          else
            parse_element
            parse_misc
            if @cur < @end
              fatal_err(ErrCode::ERR_DOCUMENT_END) if @well_formed != 0
            elsif @input.decoder && @input.buf_error == 0 && @input.pending_error.nil? && @input.trailing_partial
              fatal_err_msg(ErrCode::ERR_INVALID_CHAR, "Truncated multi-byte sequence at EOF\n")
            end
          end
          @instate = XML_PARSER_EOF
          finish_document
          if @well_formed == 0
            @valid = 0
            return -1
          end
          0
        end

        # xmlParseExtParsedEnt
        def parse_ext_parsed_ent
          return -1 if @input.nil?

          initialize_late
          detect_encoding
          fatal_err(ErrCode::ERR_DOCUMENT_EMPTY) if cur_byte == 0
          grow
          if cmp?("<?xml") && Chars.blank?(nxt(5))
            parse_xml_decl
            skip_blanks
          else
            @version = XML_DEFAULT_VERSION.dup
          end
          if @disable_sax == 0 && (cb = @sax.start_document)
            cb.call(@user_data)
          end
          @options &= ~PARSE_DTDVALID
          @validate = 0
          @depth = 0
          parse_content_internal
          fatal_err(ErrCode::ERR_NOT_WELL_BALANCED) if @cur < @end
          @sax.end_document&.call(@user_data)
          return -1 if @well_formed == 0

          0
        end

        # ---- entity content ------------------------------------------------------------------------

        # xmlCtxtParseContent
        def ctxt_parse_content(input, has_text_decl, build_tree)
          root_name = "#root"
          root = nil
          list = nil
          root = Tree.new_doc_node(@my_doc, nil, root_name, nil) if build_tree
          return nil if push_input(input) < 0

          name_ns_push(root_name, nil, nil, 0, 0)
          space_push(-1)
          node_push(root) if build_tree
          if has_text_decl
            detect_encoding
            if cmp?("<?xml") && Chars.blank?(nxt(5))
              parse_text_decl
              if @version == "1.0" && @input.version != "1.0"
                fatal_err_msg(ErrCode::ERR_VERSION_MISMATCH, "Version mismatch between document and entity\n")
              end
            end
          end
          parse_content_internal
          fatal_err(ErrCode::ERR_NOT_WELL_BALANCED) if @cur < @end
          if @well_formed != 0 || (@recovery != 0 && @err_no != ErrCode::ERR_NO_MEMORY)
            if root
              cur = root.children
              list = cur
              while cur
                cur.parent = nil
                cur = cur.next
              end
              root.children = nil
              root.last = nil
            end
          end
          @cur = @end
          node_pop if build_tree
          name_pop
          space_pop
          input_pop
          list
        end

        # xmlCtxtParseEntity
        def ctxt_parse_entity(ent)
          is_external = ent.etype == EXTERNAL_GENERAL_PARSED_ENTITY
          build_tree = !@node.nil?
          if (ent.flags & ENT_EXPANDING) != 0
            fatal_err(ErrCode::ERR_ENTITY_LOOP)
            halt
            ent.flags |= ENT_PARSED | ENT_CHECKED
            return
          end
          input = new_entity_input_stream(ent)
          if input.nil?
            ent.flags |= ENT_PARSED | ENT_CHECKED
            return
          end
          old_min_ns_index = @min_ns_index
          @min_ns_index = ns_nr if build_tree
          old_nodelen = @nodelen
          old_nodemem = @nodemem
          @nodelen = 0
          @nodemem = 0
          ent.flags |= ENT_EXPANDING
          list = ctxt_parse_content(input, is_external, build_tree)
          ent.flags &= ~ENT_EXPANDING
          @min_ns_index = old_min_ns_index
          @nodelen = old_nodelen
          @nodemem = old_nodemem
          consumed = input.consumed + input.buf.bytesize
          if (ent.flags & ENT_CHECKED) == 0
            ent.expanded_size = [ent.expanded_size + consumed, ULONG_MAX].min
          end
          if (ent.flags & ENT_PARSED) == 0
            @sizeentities = [@sizeentities + consumed, ULONG_MAX].min if is_external
            ent.children = list
            while list
              list.parent = ent
              Tree.set_tree_doc(list, ent.doc) if !list.doc.equal?(ent.doc)
              ent.last = list if list.next.nil?
              list = list.next
            end
          end
          ent.flags |= ENT_PARSED | ENT_CHECKED
        end
      end
    end
  end
end
