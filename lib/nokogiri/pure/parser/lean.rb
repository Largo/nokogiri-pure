# frozen_string_literal: true

module Nokogiri
  module Pure
    module Parser
      # Fused fast paths of the content loop (SAX2 parsing): a simple start tag and an end tag matching
      # the open element run xmlParseElementStart / xmlParseStartTag2 (resp. xmlParseElementEnd /
      # xmlParseEndTag2) in one method, and with the default tree-building handler also
      # xmlSAX2StartElementNs / xmlSAX2EndElementNs, with the same effects in the same order. They
      # return false, having changed nothing, whenever the general path is needed.
      class Ctxt
        # an ASCII QName directly followed by ">", "/>" or a space
        SIMPLE_TAG_NAME_RE = /[A-Za-z_][-A-Za-z0-9_.]*(?::[A-Za-z_][-A-Za-z0-9_.]*)?(?=\/?>| )/

        # the content loop may use the fused paths
        def lean_handler?
          @sax2 != 0
        end

        # "<name>" or "<name/>" at @cur
        def lean_start_tag
          return false if @disable_sax != 0 || @validate != 0 || @in_subset != 0 || @input.pending_error

          limit = (@options & PARSE_HUGE) != 0 ? 2048 : 256
          return false if @name_tab.length > limit || @node_tab.length > limit

          ss = @ss
          cur = @cur
          ss.pos = cur + 1
          n = ss.skip(SIMPLE_TAG_NAME_RE)
          return false if n.nil? || n > XML_MAX_NAME_LENGTH

          b = @buf
          qname = b.byteslice(cur + 1, n)
          if (colon = qname.byteindex(":"))
            # a prefix bound in scope (not "xml") to a non-empty URI
            prefix = qname.byteslice(0, colon)
            return false if prefix == "xml"

            idx = @ns_hash.fetch(prefix, INT_MAX)
            return false if idx == INT_MAX || idx < @min_ns_index || @ns_tab[idx][1].empty?

            lname = qname.byteslice(colon + 1, n - colon - 1)
          else
            lname = qname
          end
          # (no attribute defaulted from the DTD for this element)
          return false if @atts_default && @atts_default[[lname, prefix]]

          e = cur + 1 + n
          dcol = n + 1
          atts = nil
          if b.getbyte(e) == 0x20
            atts, e, dcol = lean_attributes(e, dcol, prefix, lname)
            return false if atts.nil?
          end
          # xmlParseElementStart: spacePush
          snr = @space_nr
          if snr == 0
            @space_tab[0] = -1
          else
            sp = @space_tab[snr - 1]
            @space_tab[snr] = sp == -2 ? -1 : sp
          end
          @space_nr = snr + 1
          line = @line
          # xmlParseStartTag2
          @ns_element_id += 1
          if colon
            prefix = -prefix
            name = -lname
            uri = @ns_tab[idx][1]
          else
            name = -qname
            idx = @ns_default_index
            if idx == INT_MAX || idx < @min_ns_index
              uri = nil
            else
              uri = @ns_tab[idx][1]
              uri = nil if uri.empty?
            end
          end
          lean_xml_space(atts) if atts && atts.include?("space")
          @cur = e
          @col += dcol
          cb = @sax.start_element_ns
          if cb.equal?(SAX2::START_ELEMENT_NS) && @user_data.equal?(self)
            lean_sax2_start(name, prefix, uri, idx, atts)
          elsif cb
            lean_custom_start(cb, name, prefix, uri, atts)
          end
          # nameNsPush
          (tab = @name_tab) << name
          @name = name
          if (st = @push_tab[tab.length - 1])
            st.prefix = prefix
            st.uri = uri
            st.line = line
            st.ns_nr = 0
          else
            @push_tab[tab.length - 1] = StartTag.new(prefix, uri, line, 0)
          end
          if b.getbyte(e) == 0x3E
            @cur = e + 1
            @col += 1
            return true
          end
          # "/>"
          @cur = e + 2
          @col += 2
          if @disable_sax == 0 && (cb = @sax.end_element_ns)
            if cb.equal?(SAX2::END_ELEMENT_NS) && @user_data.equal?(self)
              sax2_end_element_ns
            else
              cb.call(@user_data, name, prefix, uri)
            end
          end
          # namePop, spacePop
          tab.pop
          @name = tab[-1]
          if (snr = @space_nr) > 0
            @space_nr = snr - 1
            @space_tab[snr - 1] = -1
          end
          true
        end

        # xmlSAX2StartElementNs for a fused start tag (no namespaces, not validating)
        def lean_sax2_start(name, prefix, uri, idx, atts)
          ret = XmlNode.new(ELEMENT_NODE, name, @my_doc)
          @nodemem = -1
          sax2_append_child(ret)
          @node_tab << ret
          @node = ret
          if uri
            ns = idx == INT_MAX || idx < @min_ns_index ? nil : @ns_extra[idx][0]
            if ns
              ret.ns = ns
            elsif prefix
              Tree.new_ns(ret, nil, prefix)
              ctxt_err(nil, Domain::NAMESPACE, ErrCode::NS_ERR_UNDEFINED_NAMESPACE, Level::WARNING, prefix, nil,
                nil, 0, "Namespace prefix #{prefix} was not found\n")
            else
              Tree.new_ns(ret, nil, nil)
              ctxt_err(nil, Domain::NAMESPACE, ErrCode::NS_ERR_UNDEFINED_NAMESPACE, Level::WARNING, nil, nil,
                nil, 0, "Namespace default prefix was not found\n")
            end
          end
          if atts
            # the attributes, as xmlSAX2AttributeNs(name, prefix, value, not allocated) makes them
            prev = nil
            j = 0
            while j < atts.length
              apfx = atts[j + 1]
              attr = sax2_attribute_ns(-atts[j], apfx && -apfx, atts[j + 2], false)
              if prev.nil?
                ret.properties = attr
              else
                prev.next = attr
                attr.prev = prev
              end
              prev = attr
              j += 3
            end
          end
        end

        # the start_element_ns callback of another handler for a fused start tag
        def lean_custom_start(cb, name, prefix, uri, atts)
          if atts
            list = []
            j = 0
            while j < atts.length
              apfx = atts[j + 1]
              ns = if apfx.nil?
                nil
              elsif apfx == "xml"
                XML_XML_NAMESPACE
              else
                @ns_tab[@ns_hash[apfx]][1]
              end
              list << Att.new(-atts[j], apfx && -apfx, ns, atts[j + 2], false)
              j += 3
            end
          else
            list = EMPTY_ARRAY
          end
          cb.call(@user_data, name, prefix, uri, 0, EMPTY_ARRAY, list.length, 0, list)
        end

        # the attributes after the element name at +e+ (a space): [[name, prefix, value, ...], end,
        # dcol], or nil if the general path is needed. Taken: single-space separated, no xmlns
        # declarations, prefixes bound in scope (or "xml" without an xml:lang check or an invalid
        # xml:space), plain values, distinct local names.
        def lean_attributes(e, dcol, eprefix, elocal)
          ss = @ss
          b = @buf
          atts = []
          while true
            c1 = b.getbyte(e + 1)
            return nil if c1 == 0x20 || c1 == 0x0A || c1 == 0x09 || c1 == 0x0D

            ss.pos = e + 1
            n = ss.skip(ATTR_FAST_RE)
            return nil if n.nil?

            name = ss[1]
            if (prefix = ss[2])
              name, prefix = prefix, name
              return nil unless lean_attribute_prefix_ok?(prefix, name, ss)
            end
            return nil if name == "xmlns" || n > XML_MAX_NAME_LENGTH

            value = ss[3] || ss[4]
            # a value the DTD normalizes is taken as is only without spaces
            return nil if @atts_special && value.include?(" ") && special_attr?(eprefix, elocal, prefix, name)

            atts << name << prefix << value
            dcol += 1 + (value.ascii_only? ? n : n - value.bytesize + value.length)
            e += 1 + n
            c = b.getbyte(e)
            break if c == 0x3E || (c == 0x2F && b.getbyte(e + 1) == 0x3E)
            return nil if c != 0x20
          end
          # (duplicates are reported by the general path)
          if atts.length > 3
            names = []
            k = 0
            while k < atts.length
              names << atts[k]
              k += 3
            end
            return nil if names.uniq!
          end
          [atts, e, dcol]
        end

        def lean_attribute_prefix_ok?(prefix, name, ss)
          return false if prefix == "xmlns"

          if prefix == "xml"
            return false if name == "lang" && @pedantic != 0
            return true unless name == "space"

            v = ss[3] || ss[4]
            return v == "default" || v == "preserve"
          end
          idx = @ns_hash.fetch(prefix, INT_MAX)
          idx != INT_MAX && idx >= @min_ns_index
        end

        # xml:space among the attributes (valid values only): as xmlParseAttribute2 sets it
        def lean_xml_space(atts)
          j = 0
          while j < atts.length
            if atts[j] == "space" && atts[j + 1] == "xml"
              self.space = atts[j + 2] == "default" ? 0 : 1
            end
            j += 3
          end
        end

        # "</qname>" closing the current element
        def lean_end_tag
          return false if @input.pending_error

          tab = @name_tab
          tag = @push_tab[tab.length - 1]
          b = @buf
          ss = @ss
          ss.pos = @cur + 2
          pfx = tag.prefix
          return false unless (pfx.nil? || (ss.skip(pfx) && ss.skip(":"))) && ss.skip(@name) &&
            b.getbyte(p = ss.pos) == 0x3E

          @col += p + 1 - @cur
          @cur = p + 1
          if @disable_sax == 0 && (cb = @sax.end_element_ns)
            if cb.equal?(SAX2::END_ELEMENT_NS) && @user_data.equal?(self)
              sax2_end_element_ns
            else
              cb.call(@user_data, @name, pfx, tag.uri)
            end
          end
          # spacePop
          if (snr = @space_nr) > 0
            @space_nr = snr - 1
            @space_tab[snr - 1] = -1
          end
          ns_pop(tag.ns_nr) if tag.ns_nr != 0
          # namePop
          tab.pop
          @name = tab[-1]
          true
        end
      end
    end
  end
end
