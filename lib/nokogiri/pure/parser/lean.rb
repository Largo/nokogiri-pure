# frozen_string_literal: true

module Nokogiri
  module Pure
    module Parser
      # Fused fast paths of the content loop for the tree-building (default SAX2) handler: a start
      # tag without attributes and an end tag matching the open element run xmlParseElementStart /
      # xmlParseStartTag2 / xmlSAX2StartElementNs (resp. xmlParseElementEnd / xmlParseEndTag2 /
      # xmlSAX2EndElementNs) in one method, with the same effects in the same order. They return
      # false, having changed nothing, whenever the general path is needed.
      class Ctxt
        # an unprefixed ASCII name directly followed by ">" or "/>"
        SIMPLE_TAG_NAME_RE = /[A-Za-z_][-A-Za-z0-9_.]*(?=\/?>)/

        # the content loop may use the fused paths (default tree-building handler)
        def lean_handler?
          sax = @sax
          @sax2 != 0 && @user_data.equal?(self) && sax.start_element_ns.equal?(SAX2::START_ELEMENT_NS) &&
            sax.end_element_ns.equal?(SAX2::END_ELEMENT_NS)
        end

        # "<name>" or "<name/>" at @cur
        def lean_start_tag
          return false if @disable_sax != 0 || @validate != 0 || @in_subset != 0 || @atts_default ||
            @input.pending_error

          limit = (@options & PARSE_HUGE) != 0 ? 2048 : 256
          return false if @name_tab.length > limit || @node_tab.length > limit

          ss = @ss
          cur = @cur
          ss.pos = cur + 1
          n = ss.skip(SIMPLE_TAG_NAME_RE)
          return false if n.nil? || n > XML_MAX_NAME_LENGTH

          b = @buf
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
          name = -b.byteslice(cur + 1, n)
          idx = @ns_default_index
          if idx == INT_MAX || idx < @min_ns_index
            uri = nil
          else
            uri = @ns_tab[idx][1]
            uri = nil if uri.empty?
          end
          e = cur + 1 + n
          @cur = e
          @col += n + 1
          # xmlSAX2StartElementNs (no namespaces, no attributes, not validating)
          ret = XmlNode.new(ELEMENT_NODE, name, @my_doc)
          @nodemem = -1
          sax2_append_child(ret)
          @node_tab << ret
          @node = ret
          if uri
            ns = idx == INT_MAX || idx < @min_ns_index ? nil : @ns_extra[idx][0]
            if ns
              ret.ns = ns
            else
              Tree.new_ns(ret, nil, nil)
              ctxt_err(nil, Domain::NAMESPACE, ErrCode::NS_ERR_UNDEFINED_NAMESPACE, Level::WARNING, nil, nil,
                nil, 0, "Namespace default prefix was not found\n")
            end
          end
          # nameNsPush
          (tab = @name_tab) << name
          @name = name
          if (st = @push_tab[tab.length - 1])
            st.prefix = nil
            st.uri = uri
            st.line = line
            st.ns_nr = 0
          else
            @push_tab[tab.length - 1] = StartTag.new(nil, uri, line, 0)
          end
          if b.getbyte(e) == 0x3E
            @cur = e + 1
            @col += 1
            return true
          end
          # "/>"
          @cur = e + 2
          @col += 2
          sax2_end_element_ns if @disable_sax == 0
          # namePop, spacePop
          tab.pop
          @name = tab[-1]
          if (snr = @space_nr) > 0
            @space_nr = snr - 1
            @space_tab[snr - 1] = -1
          end
          true
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
          sax2_end_element_ns if @disable_sax == 0
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
