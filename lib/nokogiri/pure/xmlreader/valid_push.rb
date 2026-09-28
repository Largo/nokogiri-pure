# frozen_string_literal: true

# Streaming DTD validation used by the reader (valid.c xmlValidatePushElement / xmlValidatePushCData /
# xmlValidatePopElement with the LIBXML_REGEXP_ENABLED vstate stack). Only reachable through
# xmlTextReaderRead with XML_PARSE_DTDVALID.

module Nokogiri
  module Pure
    module XmlReader
      module ValidPush
        # xmlValidState
        State = Struct.new(:elem_decl, :node, :exec)

        module_function

        def stack(vctxt)
          vctxt.vstate_tab ||= []
        end

        # vstateVPush
        def vstate_push(vctxt, elem_decl, node)
          st = State.new(elem_decl, node, nil)
          if elem_decl && elem_decl.etype == ELEMENT_TYPE_ELEMENT
            Valid.build_content_model(vctxt, elem_decl) if elem_decl.cont_model.nil?
            if elem_decl.cont_model
              st.exec = XmlRegexp.reg_new_exec_ctxt(elem_decl.cont_model, nil, nil)
            else
              Valid.err_valid_node(vctxt, elem_decl, ErrCode::ERR_INTERNAL_ERROR,
                "Failed to build content model regexp for #{node.name}\n", node.name)
            end
          end
          stack(vctxt) << st
          vctxt.vstate = st
          stack(vctxt).length - 1
        end

        # vstateVPop
        def vstate_pop(vctxt)
          tab = stack(vctxt)
          return -1 if tab.empty?

          tab.pop
          vctxt.vstate = tab.last
          tab.length
        end

        # xmlSplitQName3: [localname, prefix_len] or nil
        def split_qname3(name)
          return nil if name.start_with?(":")

          i = name.index(":")
          return nil if i.nil? || i == name.length - 1

          [name[(i + 1)..], name.byteslice(0, name.index(":")).bytesize]
        end

        # xmlStrncmp(prefix, qname, plen) == 0
        def prefix_match?(prefix, qname, plen)
          a = prefix.b
          b = qname.b
          plen.times do |k|
            ca = a.getbyte(k) || 0
            cb = b.getbyte(k) || 0
            return false if ca != cb
            return true if ca == 0
          end
          true
        end

        # xmlValidateCheckMixed
        def check_mixed(vctxt, cont, qname)
          sp = split_qname3(qname)
          if sp.nil?
            while cont
              if cont.type == ELEMENT_CONTENT_ELEMENT
                return 1 if cont.prefix.nil? && cont.name == qname
              elsif cont.type == ELEMENT_CONTENT_OR && cont.c1 && cont.c1.type == ELEMENT_CONTENT_ELEMENT
                return 1 if cont.c1.prefix.nil? && cont.c1.name == qname
              elsif cont.type != ELEMENT_CONTENT_OR || cont.c1.nil? || cont.c1.type != ELEMENT_CONTENT_PCDATA
                Valid.err_valid(nil, ErrCode::DTD_MIXED_CORRUPT, "Internal: MIXED struct corrupted\n")
                break
              end
              cont = cont.c2
            end
          else
            name, plen = sp
            while cont
              if cont.type == ELEMENT_CONTENT_ELEMENT
                return 1 if cont.prefix && prefix_match?(cont.prefix, qname, plen) && cont.name == name
              elsif cont.type == ELEMENT_CONTENT_OR && cont.c1 && cont.c1.type == ELEMENT_CONTENT_ELEMENT
                return 1 if cont.c1.prefix && prefix_match?(cont.c1.prefix, qname, plen) && cont.c1.name == name
              elsif cont.type != ELEMENT_CONTENT_OR || cont.c1.nil? || cont.c1.type != ELEMENT_CONTENT_PCDATA
                Valid.err_valid(vctxt, ErrCode::DTD_MIXED_CORRUPT, "Internal: MIXED struct corrupted\n")
                break
              end
              cont = cont.c2
            end
          end
          0
        end

        # xmlValidatePushElement
        def push_element(vctxt, doc, elem, qname)
          return 0 if vctxt.nil?

          ret = 1
          state = vctxt.vstate
          if !stack(vctxt).empty? && state && (elem_decl = state.elem_decl)
            case elem_decl.etype
            when ELEMENT_TYPE_UNDEFINED
              ret = 0
            when ELEMENT_TYPE_EMPTY
              Valid.err_valid_node(vctxt, state.node, ErrCode::DTD_NOT_EMPTY,
                "Element #{state.node.name} was declared EMPTY this one has content\n", state.node.name)
              ret = 0
            when ELEMENT_TYPE_ANY
              nil
            when ELEMENT_TYPE_MIXED
              if elem_decl.econtent && elem_decl.econtent.type == ELEMENT_CONTENT_PCDATA
                Valid.err_valid_node(vctxt, state.node, ErrCode::DTD_NOT_PCDATA,
                  "Element #{state.node.name} was declared #PCDATA but contains non text nodes\n", state.node.name)
                ret = 0
              else
                ret = check_mixed(vctxt, elem_decl.econtent, qname)
                if ret != 1
                  Valid.err_valid_node(vctxt, state.node, ErrCode::DTD_INVALID_CHILD,
                    "Element #{qname} is not declared in #{state.node.name} list of possible children\n",
                    qname, state.node.name)
                end
              end
            when ELEMENT_TYPE_ELEMENT
              if state.exec
                r = XmlRegexp.reg_exec_push_string(state.exec, qname, nil)
                if r < 0
                  Valid.err_valid_node(vctxt, state.node, ErrCode::DTD_CONTENT_MODEL,
                    "Element #{state.node.name} content does not follow the DTD, Misplaced #{qname}\n",
                    state.node.name, qname)
                  ret = 0
                else
                  ret = 1
                end
              end
            end
          end
          e_decl, = Valid.valid_get_elem_decl(vctxt, doc, elem)
          vstate_push(vctxt, e_decl, elem)
          ret
        end

        # xmlValidatePushCData
        def push_cdata(vctxt, data, len)
          return 0 if vctxt.nil?
          return 1 if len <= 0

          state = vctxt.vstate
          if !stack(vctxt).empty? && state && (elem_decl = state.elem_decl)
            case elem_decl.etype
            when ELEMENT_TYPE_UNDEFINED
              return 0
            when ELEMENT_TYPE_EMPTY
              Valid.err_valid_node(vctxt, state.node, ErrCode::DTD_NOT_EMPTY,
                "Element #{state.node.name} was declared EMPTY this one has content\n", state.node.name)
              return 0
            when ELEMENT_TYPE_ELEMENT
              if data.b.byteslice(0, len).match?(/[^ \t\n\r]/n)
                Valid.err_valid_node(vctxt, state.node, ErrCode::DTD_CONTENT_MODEL,
                  "Element #{state.node.name} content does not follow the DTD, Text not allowed\n", state.node.name)
                return 0
              end
            end
          end
          1
        end

        # xmlValidatePopElement
        def pop_element(vctxt, _doc, _elem, _qname)
          return 0 if vctxt.nil?

          ret = 1
          state = vctxt.vstate
          if !stack(vctxt).empty? && state
            elem_decl = state.elem_decl
            if elem_decl && elem_decl.etype == ELEMENT_TYPE_ELEMENT && state.exec
              r = XmlRegexp.reg_exec_push_string(state.exec, nil, nil)
              if r <= 0
                Valid.err_valid_node(vctxt, state.node, ErrCode::DTD_CONTENT_MODEL,
                  "Element #{state.node.name} content does not follow the DTD, Expecting more children\n",
                  state.node.name)
                ret = 0
              else
                ret = 1
              end
            end
            vstate_pop(vctxt)
          end
          ret
        end
      end
    end
  end
end
