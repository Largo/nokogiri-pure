# frozen_string_literal: true

# relaxng.c: validation of instance documents.
module Nokogiri
  module Pure
    module RelaxNG
      module_function

      # ---- validation states --------------------------------------------------------------

      # xmlRelaxNGNewStates
      def new_states(_ctxt, size)
        States.new(size < 16 ? 16 : size)
      end

      # xmlRelaxNGAddStatesUniq
      def add_states_uniq(_ctxt, states, state)
        return -1 if state.nil?

        states.tab_state[states.nb_state] = state
        states.nb_state += 1
        1
      end

      # xmlRelaxNGAddStates
      def add_states(ctxt, states, state)
        return -1 if state.nil? || states.nil?

        i = 0
        while i < states.nb_state
          if equal_valid_state(ctxt, state, states.tab_state[i])
            free_valid_state(ctxt, state)
            return 0
          end
          i += 1
        end
        states.tab_state[states.nb_state] = state
        states.nb_state += 1
        1
      end

      # xmlRelaxNGFreeStates
      def free_states(_ctxt, _states) = nil

      # xmlRelaxNGNewValidState
      def new_valid_state(ctxt, node)
        root = nil
        attrs = []
        if node.nil?
          root = Tree.doc_get_root_element(ctxt.doc)
          return nil if root.nil?
        else
          attr = node.properties
          while attr
            attrs << attr
            attr = attr.next
          end
        end
        ret = ValidState.new
        ret.value = nil
        ret.endvalue = nil
        if node.nil?
          ret.node = ctxt.doc
          ret.seq = root
        else
          ret.node = node
          ret.seq = node.children
        end
        ret.nb_attrs = 0
        unless attrs.empty?
          ret.max_attrs = attrs.size < 4 ? 4 : attrs.size
          ret.attrs = attrs
          ret.nb_attrs = attrs.size
        end
        ret.nb_attr_left = ret.nb_attrs
        ret
      end

      # xmlRelaxNGCopyValidState
      def copy_valid_state(_ctxt, state)
        return nil if state.nil?

        ret = ValidState.new
        ret.node = state.node
        ret.seq = state.seq
        ret.nb_attrs = state.nb_attrs
        ret.max_attrs = state.max_attrs
        ret.nb_attr_left = state.nb_attr_left
        ret.value = state.value
        ret.endvalue = state.endvalue
        ret.attrs = state.nb_attrs > 0 ? state.attrs[0, state.nb_attrs] : nil
        ret
      end

      # xmlRelaxNGEqualValidState
      def equal_valid_state(_ctxt, state1, state2)
        return false if state1.nil? || state2.nil?
        return true if state1.equal?(state2)
        return false unless state1.node.equal?(state2.node)
        return false unless state1.seq.equal?(state2.seq)
        return false if state1.nb_attr_left != state2.nb_attr_left
        return false if state1.nb_attrs != state2.nb_attrs
        return false unless state1.endvalue == state2.endvalue
        if !(state1.value == state2.value) && !str_equal(cstr(state1.value), cstr(state2.value))
          return false
        end

        i = 0
        while i < state1.nb_attrs
          return false unless state1.attrs[i].equal?(state2.attrs[i])

          i += 1
        end
        true
      end

      # xmlRelaxNGFreeValidState
      def free_valid_state(_ctxt, _state) = nil

      # ---- compiled content ---------------------------------------------------------------

      # xmlRelaxNGValidateCompiledCallback
      def validate_compiled_callback(_data, token, transdata, inputdata)
        ctxt = inputdata
        define = transdata
        if ctxt.nil?
          $stderr.print("callback on #{token} missing context\n")
          return
        end
        if define.nil?
          return if token.start_with?("#")

          $stderr.print("callback on #{token} missing define\n")
          ctxt.err_no = ERR_INTERNAL if ctxt.err_no == OK
          return
        end
        if define.type != ELEMENT
          $stderr.print("callback on #{token} define is not element\n")
          ctxt.err_no = ERR_INTERNAL if ctxt.err_no == OK
          return
        end
        ret = validate_definition(ctxt, define)
        ctxt.perr = ret if ret != 0
      end

      COMPILED_CALLBACK = ->(data, token, transdata, inputdata) do
        RelaxNG.validate_compiled_callback(data, token, transdata, inputdata)
      end

      # xmlRelaxNGValidateCompiledContent
      def validate_compiled_content(ctxt, regexp, content)
        ret = 0
        return -1 if ctxt.nil? || regexp.nil?

        x = XmlRegexp
        oldperr = ctxt.perr
        exec = x.reg_new_exec_ctxt(regexp, COMPILED_CALLBACK, ctxt)
        ctxt.perr = 0
        cur = content
        while cur
          ctxt.state.seq = cur
          case cur.type
          when TEXT_NODE, CDATA_SECTION_NODE
            unless Tree.is_blank_node(cur)
              ret = x.reg_exec_push_string(exec, "#text", ctxt)
              add_valid_error(ctxt, ERR_TEXTWRONG, cur.parent.name) if ret < 0
            end
          when ELEMENT_NODE
            ret = if cur.ns
              x.reg_exec_push_string2(exec, cur.name, cur.ns.href, ctxt)
            else
              x.reg_exec_push_string(exec, cur.name, ctxt)
            end
            add_valid_error(ctxt, ERR_ELEMWRONG, cur.name) if ret < 0
          end
          break if ret < 0

          # Switch to next element
          cur = cur.next
        end
        ret = x.reg_exec_push_string(exec, nil, nil)
        if ret == 1
          ret = 0
          ctxt.state.seq = nil
        elsif ret == 0
          add_valid_error(ctxt, ERR_NOELEM, "")
          ret = -1
          dump_valid_error(ctxt) if ctxt.flags & FLAGS_IGNORABLE == 0
        else
          ret = -1
        end
        # There might be content model errors outside of the pure regexp validation, e.g.
        # for attribute values.
        ret = ctxt.perr if ret == 0 && ctxt.perr != 0
        ctxt.perr = oldperr
        ret
      end

      # ---- interpreted validation ---------------------------------------------------------

      # xmlRelaxNGSkipIgnored
      def skip_ignored(ctxt, node)
        while node
          t = node.type
          if t == COMMENT_NODE || t == PI_NODE || t == XINCLUDE_START || t == XINCLUDE_END ||
              ((t == TEXT_NODE || t == CDATA_SECTION_NODE) &&
               (ctxt.flags & FLAGS_MIXED_CONTENT != 0 || is_blank(node.content)))
            node = node.next
          else
            break
          end
        end
        node
      end

      # xmlRelaxNGNormalize (on a C string, returns a String or nil)
      def normalize(_ctxt, str)
        return nil if str.nil?

        b = str.b
        n = b.bytesize
        i = 0
        out = +"".b
        i += 1 while i < n && blank_ch?(b.getbyte(i))
        while i < n
          c = b.getbyte(i)
          if blank_ch?(c)
            i += 1 while i < n && blank_ch?(b.getbyte(i))
            break if i >= n

            out << 0x20
          else
            out << c
            i += 1
          end
        end
        out.force_encoding(Encoding::UTF_8)
      end

      # xmlRelaxNGValidateDatatype (+value+ is a CPtr or nil)
      def validate_datatype(ctxt, value, define, node)
        result = nil
        return -1 if define.nil? || define.data.nil?

        lib = define.data
        vstr = cstr(value)
        if lib.check
          want = !define.attrs.nil? && define.attrs.type == PARAM
          ret, result = lib.check.call(lib.data, define.name, vstr, want, node)
          result = nil unless want
        else
          ret = -1
        end
        if ret < 0
          add_valid_error(ctxt, ERR_TYPE, define.name)
          return -1
        elsif ret == 1
          ret = 0
        elsif ret == 2
          add_valid_error(ctxt, ERR_DUPID, vstr, nil, true)
        else
          add_valid_error(ctxt, ERR_TYPEVAL, define.name, vstr, true)
          ret = -1
        end
        cur = define.attrs
        while ret == 0 && cur && cur.type == PARAM
          if lib.facet
            tmp = lib.facet.call(lib.data, define.name, cur.name, cur.value, vstr, result)
            ret = -1 if tmp != 0
          end
          cur = cur.next
        end
        if ret == 0 && define.content
          oldvalue = ctxt.state.value
          oldendvalue = ctxt.state.endvalue
          ctxt.state.value = value
          ctxt.state.endvalue = nil
          ret = validate_value(ctxt, define.content)
          ctxt.state.value = oldvalue
          ctxt.state.endvalue = oldendvalue
        end
        ret
      end

      # xmlRelaxNGNextValue
      def next_value(ctxt)
        cur = ctxt.state.value
        if cur.nil? || ctxt.state.endvalue.nil?
          ctxt.state.value = nil
          ctxt.state.endvalue = nil
          return 0
        end
        cur += 1 while cur.byte != 0
        cur += 1 while cur != ctxt.state.endvalue && cur.byte == 0
        ctxt.state.value = cur == ctxt.state.endvalue ? nil : cur
        0
      end

      # xmlRelaxNGValidateValueList
      def validate_value_list(ctxt, defines)
        ret = 0
        while defines
          ret = validate_value(ctxt, defines)
          break if ret != 0

          defines = defines.next
        end
        ret
      end

      # xmlRelaxNGValidateValue
      def validate_value(ctxt, define)
        ret = 0
        value = ctxt.state.value
        case define.type
        when EMPTY
          if value && value.byte != 0
            idx = 0
            idx += 1 while blank_ch?(value.byte(idx))
            ret = -1 if value.byte(idx) != 0
          end
        when TEXT
          # nothing
        when VALUE
          vstr = cstr(value)
          unless str_equal(vstr, define.value)
            if define.name
              lib = define.data
              ret = if lib && lib.comp
                lib.comp.call(lib.data, define.name, define.value, define.node, define.attrs, vstr,
                  ctxt.state.node)
              else
                -1
              end
              if ret < 0
                add_valid_error(ctxt, ERR_TYPECMP, define.name)
                return -1
              elsif ret == 1
                ret = 0
              else
                ret = -1
              end
            else
              nval = normalize(ctxt, define.value)
              nvalue = normalize(ctxt, vstr)
              ret = -1 if nval.nil? || nvalue.nil? || nval != nvalue
            end
          end
          next_value(ctxt) if ret == 0
        when DATATYPE
          ret = validate_datatype(ctxt, value, define, ctxt.state.seq)
          next_value(ctxt) if ret == 0
        when CHOICE
          list = define.content
          oldflags = ctxt.flags
          ctxt.flags |= FLAGS_IGNORABLE
          oldvalue = ctxt.state.value
          while list
            ret = validate_value(ctxt, list)
            break if ret == 0

            ctxt.state.value = oldvalue
            list = list.next
          end
          ctxt.flags = oldflags
          if ret != 0
            dump_valid_error(ctxt) if ctxt.flags & FLAGS_IGNORABLE == 0
          elsif ctxt.err_nr > 0
            pop_errors(ctxt, 0)
          end
        when LIST
          list = define.content
          oldvalue = ctxt.state.value
          oldend = ctxt.state.endvalue

          val = CPtr.dup(oldvalue.nil? ? "" : oldvalue.str)
          cur = val
          while cur.byte != 0
            if blank_ch?(cur.byte)
              cur.set_byte(0, 0)
              cur += 1
              while blank_ch?(cur.byte)
                cur.set_byte(0, 0)
                cur += 1
              end
            else
              cur += 1
            end
          end
          ctxt.state.endvalue = cur
          cur = val
          cur += 1 while cur.byte == 0 && cur != ctxt.state.endvalue
          ctxt.state.value = cur

          while list
            ctxt.state.value = nil if ctxt.state.value == ctxt.state.endvalue
            ret = validate_value(ctxt, list)
            break if ret != 0

            list = list.next
          end

          if ret == 0 && ctxt.state.value && ctxt.state.value != ctxt.state.endvalue
            add_valid_error(ctxt, ERR_LISTEXTRA, ctxt.state.value.str)
            ret = -1
          end
          ctxt.state.value = oldvalue
          ctxt.state.endvalue = oldend
        when ONEORMORE, ZEROORMORE
          if define.type == ONEORMORE
            ret = validate_value_list(ctxt, define.content)
            return ret if ret != 0
          end
          if ctxt.state.value.nil? || ctxt.state.value.byte == 0
            ret = 0
          else
            oldflags = ctxt.flags
            ctxt.flags |= FLAGS_IGNORABLE
            cur = ctxt.state.value
            temp = nil
            while cur && cur != ctxt.state.endvalue && temp != cur
              temp = cur
              ret = validate_value_list(ctxt, define.content)
              if ret != 0
                ctxt.state.value = temp
                ret = 0
                break
              end
              cur = ctxt.state.value
            end
            ctxt.flags = oldflags
            pop_errors(ctxt, 0) if ctxt.err_nr > 0
          end
        when OPTIONAL
          if ctxt.state.value.nil? || ctxt.state.value.byte == 0
            ret = 0
          else
            oldflags = ctxt.flags
            ctxt.flags |= FLAGS_IGNORABLE
            temp = ctxt.state.value
            ret = validate_value(ctxt, define.content)
            ctxt.flags = oldflags
            if ret != 0
              ctxt.state.value = temp
              pop_errors(ctxt, 0) if ctxt.err_nr > 0
              ret = 0
            elsif ctxt.err_nr > 0
              pop_errors(ctxt, 0)
            end
          end
        when EXCEPT
          list = define.content
          while list
            ret = validate_value(ctxt, list)
            if ret == 0
              ret = -1
              break
            else
              ret = 0
            end
            list = list.next
          end
        when DEF, GROUP
          list = define.content
          while list
            ret = validate_value(ctxt, list)
            if ret != 0
              ret = -1
              break
            else
              ret = 0
            end
            list = list.next
          end
        when REF, PARENTREF
          if define.content.nil?
            add_valid_error(ctxt, ERR_NODEFINE)
            ret = -1
          else
            ret = validate_value(ctxt, define.content)
          end
        else
          ret = -1
        end
        ret
      end

      # xmlRelaxNGValidateValueContent
      def validate_value_content(ctxt, defines)
        ret = 0
        while defines
          ret = validate_value(ctxt, defines)
          break if ret != 0

          defines = defines.next
        end
        ret
      end

      # xmlRelaxNGAttributeMatch
      def attribute_match(ctxt, define, prop)
        if define.name
          return 0 if define.name != prop.name
        end
        if define.ns
          if define.ns.empty?
            return 0 if prop.ns
          elsif prop.ns.nil? || define.ns != prop.ns.href
            return 0
          end
        end
        return 1 if define.name_class.nil?

        define = define.name_class
        if define.type == EXCEPT
          list = define.content
          while list
            ret = attribute_match(ctxt, list, prop)
            return 0 if ret == 1
            return ret if ret < 0

            list = list.next
          end
        elsif define.type == CHOICE
          list = define.name_class
          while list
            ret = attribute_match(ctxt, list, prop)
            return 1 if ret == 1
            return ret if ret < 0

            list = list.next
          end
          return 0
        else
          return 0
        end
        1
      end

      # xmlRelaxNGValidateAttribute
      def validate_attribute(ctxt, define)
        ret = 0
        prop = nil
        state = ctxt.state
        return -1 if state.nb_attr_left <= 0

        i = 0
        if define.name
          while i < state.nb_attrs
            tmp = state.attrs[i]
            if tmp && define.name == tmp.name
              if ((define.ns.nil? || define.ns.empty?) && tmp.ns.nil?) ||
                  (tmp.ns && define.ns == tmp.ns.href)
                prop = tmp
                break
              end
            end
            i += 1
          end
          if prop
            value = Tree.node_list_get_string(prop.doc, prop.children, true)
            oldvalue = state.value
            oldseq = state.seq
            state.seq = prop
            state.value = value.nil? ? nil : CPtr.dup(value)
            state.endvalue = nil
            ret = validate_value_content(ctxt, define.content)
            ctxt.state.value = oldvalue
            ctxt.state.seq = oldseq
            if ret == 0
              # flag the attribute as processed
              ctxt.state.attrs[i] = nil
              ctxt.state.nb_attr_left -= 1
            end
          else
            ret = -1
          end
        else
          while i < state.nb_attrs
            tmp = state.attrs[i]
            if tmp && attribute_match(ctxt, define, tmp) == 1
              prop = tmp
              break
            end
            i += 1
          end
          if prop
            value = Tree.node_list_get_string(prop.doc, prop.children, true)
            oldvalue = state.value
            oldseq = state.seq
            state.seq = prop
            state.value = value.nil? ? nil : CPtr.dup(value)
            ret = validate_value_content(ctxt, define.content)
            ctxt.state.value = oldvalue
            ctxt.state.seq = oldseq
            if ret == 0
              # flag the attribute as processed
              ctxt.state.attrs[i] = nil
              ctxt.state.nb_attr_left -= 1
            end
          else
            ret = -1
          end
        end
        ret
      end

      # xmlRelaxNGValidateAttributeList
      def validate_attribute_list(ctxt, defines)
        ret = 0
        res = 0
        needmore = false
        cur = defines
        while cur
          if cur.type == ATTRIBUTE
            ret = -1 if validate_attribute(ctxt, cur) != 0
          else
            needmore = true
          end
          cur = cur.next
        end
        return ret unless needmore

        cur = defines
        while cur
          if cur.type != ATTRIBUTE
            if ctxt.state || ctxt.states
              res = validate_definition(ctxt, cur)
              ret = -1 if res < 0
            else
              add_valid_error(ctxt, ERR_NOSTATE)
              return -1
            end
            break if res == -1 # continues on -2
          end
          cur = cur.next
        end
        ret
      end

      # xmlRelaxNGNodeMatchesList
      def node_matches_list(node, list)
        return 0 if node.nil? || list.nil?

        list.each do |cur|
          if node.type == ELEMENT_NODE && cur.type == ELEMENT
            return 1 if element_match(nil, cur, node) == 1
          elsif (node.type == TEXT_NODE || node.type == CDATA_SECTION_NODE) &&
              (cur.type == DATATYPE || cur.type == LIST || cur.type == TEXT || cur.type == VALUE)
            return 1
          end
        end
        0
      end

      # xmlRelaxNGValidateInterleave
      def validate_interleave(ctxt, define)
        ret = 0
        err_nr = ctxt.err_nr
        group = nil
        last = nil
        lastchg = nil

        if define.data
          partitions = define.data
          nbgroups = partitions.nbgroups
        else
          add_valid_error(ctxt, ERR_INTERNODATA)
          return -1
        end
        # Optimizations for MIXED
        oldflags = ctxt.flags
        if define.dflags & IS_MIXED != 0
          ctxt.flags |= FLAGS_MIXED_CONTENT
          if nbgroups == 2
            # this is a pure <mixed> case
            ctxt.state.seq = skip_ignored(ctxt, ctxt.state.seq) if ctxt.state
            ret = if partitions.groups[0].rule.type == TEXT
              validate_definition(ctxt, partitions.groups[1].rule)
            else
              validate_definition(ctxt, partitions.groups[0].rule)
            end
            if ret == 0
              ctxt.state.seq = skip_ignored(ctxt, ctxt.state.seq) if ctxt.state
            end
            ctxt.flags = oldflags
            return ret
          end
        end

        # Build arrays to store the first and last node of the chain pertaining to each group
        list = Array.new(nbgroups)
        lasts = Array.new(nbgroups)

        # Walk the sequence of children finding the right group and sorting them in sequences.
        cur = ctxt.state.seq
        cur = skip_ignored(ctxt, cur)
        start = cur
        while cur
          ctxt.state.seq = cur
          if partitions.triage && partitions.flags & IS_DETERMINIST != 0
            tmp = nil
            if cur.type == TEXT_NODE || cur.type == CDATA_SECTION_NODE
              tmp = partitions.triage.lookup("#text", nil)
            elsif cur.type == ELEMENT_NODE
              if cur.ns
                tmp = partitions.triage.lookup(cur.name, cur.ns.href)
                tmp = partitions.triage.lookup("#any", cur.ns.href) if tmp.nil?
              else
                tmp = partitions.triage.lookup(cur.name, nil)
              end
              tmp = partitions.triage.lookup("#any", nil) if tmp.nil?
            end

            if tmp.nil?
              i = nbgroups
            else
              i = tmp - 1
              if partitions.flags & IS_NEEDCHECK != 0
                group = partitions.groups[i]
                i = nbgroups if node_matches_list(cur, group.defs) == 0
              end
            end
          else
            i = 0
            while i < nbgroups
              group = partitions.groups[i]
              if group
                break if node_matches_list(cur, group.defs) != 0
              end
              i += 1
            end
          end
          # We break as soon as an element not matched is found
          break if i >= nbgroups

          if lasts[i]
            lasts[i].next = cur
            lasts[i] = cur
          else
            list[i] = cur
            lasts[i] = cur
          end
          lastchg = cur.next || cur
          cur = skip_ignored(ctxt, cur.next)
        end
        catch(:done) do
          if ret != 0
            add_valid_error(ctxt, ERR_INTERSEQ)
            ret = -1
            throw :done
          end
          lastelem = cur
          oldstate = ctxt.state
          i = 0
          while i < nbgroups
            ctxt.state = copy_valid_state(ctxt, oldstate)
            if ctxt.state.nil?
              ret = -1
              break
            end
            group = partitions.groups[i]
            if lasts[i]
              last = lasts[i].next
              lasts[i].next = nil
            end
            ctxt.state.seq = list[i]
            ret = validate_definition(ctxt, group.rule)
            break if ret != 0

            if ctxt.state
              cur = ctxt.state.seq
              cur = skip_ignored(ctxt, cur)
              free_valid_state(ctxt, oldstate)
              oldstate = ctxt.state
              ctxt.state = nil
              if cur && (define.parent.type != DEF || define.parent.name != "open-name-class")
                add_valid_error(ctxt, ERR_INTEREXTRA, cur.name)
                ret = -1
                ctxt.state = oldstate
                throw :done
              end
            elsif ctxt.states
              found = 0
              best = -1
              lowattr = -1
              # PBM: what happen if there is attributes checks in the interleaves
              j = 0
              while j < ctxt.states.nb_state
                cur = ctxt.states.tab_state[j].seq
                cur = skip_ignored(ctxt, cur)
                if cur.nil?
                  if found == 0
                    lowattr = ctxt.states.tab_state[j].nb_attr_left
                    best = j
                  end
                  found = 1
                  if ctxt.states.tab_state[j].nb_attr_left <= lowattr
                    # try  to keep the latest one to mach old heuristic
                    lowattr = ctxt.states.tab_state[j].nb_attr_left
                    best = j
                  end
                  break if lowattr == 0
                elsif found == 0
                  if lowattr == -1
                    lowattr = ctxt.states.tab_state[j].nb_attr_left
                    best = j
                  elsif ctxt.states.tab_state[j].nb_attr_left <= lowattr
                    # try  to keep the latest one to mach old heuristic
                    lowattr = ctxt.states.tab_state[j].nb_attr_left
                    best = j
                  end
                end
                j += 1
              end
              # BIG PBM: here we pick only one restarting point :-(
              if ctxt.states.nb_state > 0
                free_valid_state(ctxt, oldstate)
                if best != -1
                  oldstate = ctxt.states.tab_state[best]
                  ctxt.states.tab_state[best] = nil
                else
                  oldstate = ctxt.states.tab_state[ctxt.states.nb_state - 1]
                  ctxt.states.tab_state[ctxt.states.nb_state - 1] = nil
                  ctxt.states.nb_state -= 1
                end
              end
              free_states(ctxt, ctxt.states)
              ctxt.states = nil
              if found == 0
                if cur.nil?
                  add_valid_error(ctxt, ERR_INTEREXTRA, "noname")
                else
                  add_valid_error(ctxt, ERR_INTEREXTRA, cur.name)
                end
                ret = -1
                ctxt.state = oldstate
                throw :done
              end
            else
              ret = -1
              break
            end
            lasts[i].next = last if lasts[i]
            i += 1
          end
          free_valid_state(ctxt, ctxt.state) if ctxt.state
          ctxt.state = oldstate
          ctxt.state.seq = lastelem
          if ret != 0
            add_valid_error(ctxt, ERR_INTERSEQ)
            ret = -1
            throw :done
          end
        end

        # done:
        ctxt.flags = oldflags
        # builds the next links chain from the prev one
        cur = lastchg
        while cur
          break if cur.equal?(start) || cur.prev.nil?

          cur.prev.next = cur
          cur = cur.prev
        end
        pop_errors(ctxt, err_nr) if ret == 0 && ctxt.err_nr > err_nr
        ret
      end

      # xmlRelaxNGValidateDefinitionList
      def validate_definition_list(ctxt, defines)
        ret = 0
        res = 0
        if defines.nil?
          add_valid_error(ctxt, ERR_INTERNAL, "NULL definition list")
          return -1
        end
        while defines
          if ctxt.state || ctxt.states
            res = validate_definition(ctxt, defines)
            ret = -1 if res < 0
          else
            add_valid_error(ctxt, ERR_NOSTATE)
            return -1
          end
          break if res == -1 # continues on -2

          defines = defines.next
        end
        ret
      end

      # xmlRelaxNGElementMatch
      def element_match(ctxt, define, elem)
        ret = 0
        oldflags = 0
        if define.name
          if elem.name != define.name
            add_valid_error(ctxt, ERR_ELEMNAME, define.name, elem.name)
            return 0
          end
        end
        if define.ns && !define.ns.empty?
          if elem.ns.nil?
            add_valid_error(ctxt, ERR_ELEMNONS, elem.name)
            return 0
          elsif elem.ns.href != define.ns
            add_valid_error(ctxt, ERR_ELEMWRONGNS, elem.name, define.ns)
            return 0
          end
        elsif elem.ns && define.ns && define.name.nil?
          add_valid_error(ctxt, ERR_ELEMEXTRANS, elem.name)
          return 0
        elsif elem.ns && define.name
          add_valid_error(ctxt, ERR_ELEMEXTRANS, define.name)
          return 0
        end

        return 1 if define.name_class.nil?

        define = define.name_class
        if define.type == EXCEPT
          if ctxt
            oldflags = ctxt.flags
            ctxt.flags |= FLAGS_IGNORABLE
          end
          list = define.content
          while list
            ret = element_match(ctxt, list, elem)
            if ret == 1
              ctxt.flags = oldflags if ctxt
              return 0
            end
            if ret < 0
              ctxt.flags = oldflags if ctxt
              return ret
            end
            list = list.next
          end
          ret = 1
          ctxt.flags = oldflags if ctxt
        elsif define.type == CHOICE
          if ctxt
            oldflags = ctxt.flags
            ctxt.flags |= FLAGS_IGNORABLE
          end
          list = define.name_class
          while list
            ret = element_match(ctxt, list, elem)
            if ret == 1
              ctxt.flags = oldflags if ctxt
              return 1
            end
            if ret < 0
              ctxt.flags = oldflags if ctxt
              return ret
            end
            list = list.next
          end
          if ctxt
            if ret != 0
              dump_valid_error(ctxt) if ctxt.flags & FLAGS_IGNORABLE == 0
            elsif ctxt.err_nr > 0
              pop_errors(ctxt, 0)
            end
          end
          ret = 0
          ctxt.flags = oldflags if ctxt
        else
          ret = -1
        end
        ret
      end

      # xmlRelaxNGBestState
      def best_state(ctxt)
        best = -1
        value = 1_000_000
        return -1 if ctxt.nil? || ctxt.states.nil? || ctxt.states.nb_state <= 0

        i = 0
        while i < ctxt.states.nb_state
          state = ctxt.states.tab_state[i]
          if state
            if state.seq
              if best == -1 || value > 100_000
                value = 100_000
                best = i
              end
            else
              tmp = state.nb_attr_left
              if best == -1 || value > tmp
                value = tmp
                best = i
              end
            end
          end
          i += 1
        end
        best
      end

      # xmlRelaxNGLogBestError
      def log_best_error(ctxt)
        return if ctxt.nil? || ctxt.states.nil? || ctxt.states.nb_state <= 0

        best = best_state(ctxt)
        if best >= 0 && best < ctxt.states.nb_state
          ctxt.state = ctxt.states.tab_state[best]
          validate_element_end(ctxt, 1)
        end
      end

      # xmlRelaxNGValidateElementEnd
      def validate_element_end(ctxt, dolog)
        state = ctxt.state
        if state.seq
          state.seq = skip_ignored(ctxt, state.seq)
          if state.seq
            add_valid_error(ctxt, ERR_EXTRACONTENT, state.node.name, state.seq.name) if dolog != 0
            return -1
          end
        end
        i = 0
        while i < state.nb_attrs
          if state.attrs[i]
            add_valid_error(ctxt, ERR_INVALIDATTR, state.attrs[i].name, state.node.name) if dolog != 0
            return -1 - i
          end
          i += 1
        end
        0
      end

      # the error popping loop of xmlRelaxNGValidateState's element case
      def pop_element_errors(ctxt, node)
        while ctxt.err && (e = ctxt.err_tab[ctxt.err]) &&
            ((e.err == ERR_ELEMNAME && e.arg2 == node.name) ||
             (e.err == ERR_ELEMEXTRANS && e.arg1 == node.name) ||
             e.err == ERR_NOELEM || e.err == ERR_NOTELEM)
          valid_error_pop(ctxt)
        end
      end

      # concatenation of the text / CDATA content of +node+ and its following siblings, or
      # :elem if an element is found
      def collect_text(node)
        content = nil
        child = node
        while child
          if child.type == ELEMENT_NODE
            return :elem
          elsif child.type == TEXT_NODE || child.type == CDATA_SECTION_NODE
            content = content.nil? ? (child.content || "").dup : content << (child.content || "")
          end
          child = child.next
        end
        content
      end

      # xmlRelaxNGValidateState
      def validate_state(ctxt, define)
        ret = 0
        if define.nil?
          add_valid_error(ctxt, ERR_NODEFINE)
          return -1
        end

        node = ctxt.state ? ctxt.state.seq : nil
        ctxt.depth += 1
        case define.type
        when EMPTY
          ret = 0
        when NOT_ALLOWED
          ret = -1
        when TEXT
          while node && (node.type == TEXT_NODE || node.type == COMMENT_NODE || node.type == PI_NODE ||
                         node.type == CDATA_SECTION_NODE)
            node = node.next
          end
          ctxt.state.seq = node
        when ELEMENT
          ret = validate_element(ctxt, define, node)
        when OPTIONAL
          err_nr = ctxt.err_nr
          oldflags = ctxt.flags
          ctxt.flags |= FLAGS_IGNORABLE
          oldstate = copy_valid_state(ctxt, ctxt.state)
          ret = validate_definition_list(ctxt, define.content)
          if ret != 0
            free_valid_state(ctxt, ctxt.state) if ctxt.state
            ctxt.state = oldstate
            ctxt.flags = oldflags
            ret = 0
            pop_errors(ctxt, err_nr) if ctxt.err_nr > err_nr
          else
            if ctxt.states
              add_states(ctxt, ctxt.states, oldstate)
            else
              ctxt.states = new_states(ctxt, 1)
              add_states(ctxt, ctxt.states, oldstate)
              add_states(ctxt, ctxt.states, ctxt.state)
              ctxt.state = nil
            end
            ctxt.flags = oldflags
            ret = 0
            pop_errors(ctxt, err_nr) if ctxt.err_nr > err_nr
          end
        when ONEORMORE, ZEROORMORE
          catch(:brk) do
            if define.type == ONEORMORE
              err_nr = ctxt.err_nr
              ret = validate_definition_list(ctxt, define.content)
              throw :brk if ret != 0

              pop_errors(ctxt, err_nr) if ctxt.err_nr > err_nr
            end
            ret = validate_zero_or_more(ctxt, define)
          end
        when CHOICE
          ret = validate_choice(ctxt, define, node)
        when DEF, GROUP
          ret = validate_definition_list(ctxt, define.content)
        when INTERLEAVE
          ret = validate_interleave(ctxt, define)
        when ATTRIBUTE
          ret = validate_attribute(ctxt, define)
        when START, NOOP, REF, EXTERNALREF, PARENTREF
          ret = validate_definition(ctxt, define.content)
        when DATATYPE
          content = collect_text(node)
          if content == :elem
            add_valid_error(ctxt, ERR_DATAELEM, node.parent.name)
            ret = -1
          else
            content = CPtr.dup(content || "")
            ret = validate_datatype(ctxt, content, define, ctxt.state.seq)
            if ret == -1
              add_valid_error(ctxt, ERR_DATATYPE, define.name)
            elsif ret == 0
              ctxt.state.seq = nil
            end
          end
        when VALUE
          content = collect_text(node)
          if content == :elem
            add_valid_error(ctxt, ERR_VALELEM, node.parent.name)
            ret = -1
          else
            content = CPtr.dup(content || "")
            oldvalue = ctxt.state.value
            ctxt.state.value = content
            ret = validate_value(ctxt, define)
            ctxt.state.value = oldvalue
            if ret == -1
              add_valid_error(ctxt, ERR_VALUE, define.name)
            elsif ret == 0
              ctxt.state.seq = nil
            end
          end
        when LIST
          content = collect_text(node)
          if content == :elem
            add_valid_error(ctxt, ERR_LISTELEM, node.parent.name)
            ret = -1
          else
            content = CPtr.dup(content || "")
            len = content.buf.bytesize - 1
            oldvalue = ctxt.state.value
            oldendvalue = ctxt.state.endvalue
            ctxt.state.value = content
            ctxt.state.endvalue = content + len
            ret = validate_value(ctxt, define)
            ctxt.state.value = oldvalue
            ctxt.state.endvalue = oldendvalue
            if ret == -1
              add_valid_error(ctxt, ERR_LIST)
            elsif ret == 0 && node
              ctxt.state.seq = node.next
            end
          end
        when EXCEPT, PARAM
          ret = -1
        end
        ctxt.depth -= 1
        ret
      end

      # the XML_RELAXNG_ELEMENT case of xmlRelaxNGValidateState
      def validate_element(ctxt, define, node)
        ret = 0
        err_nr = ctxt.err_nr
        node = skip_ignored(ctxt, node)
        if node.nil?
          add_valid_error(ctxt, ERR_NOELEM, define.name)
          dump_valid_error(ctxt) if ctxt.flags & FLAGS_IGNORABLE == 0
          return -1
        end
        if node.type != ELEMENT_NODE
          add_valid_error(ctxt, ERR_NOTELEM)
          dump_valid_error(ctxt) if ctxt.flags & FLAGS_IGNORABLE == 0
          return -1
        end
        # This node was already validated successfully against this definition.
        if node.psvi.equal?(define)
          ctxt.state.seq = skip_ignored(ctxt, node.next)
          pop_errors(ctxt, err_nr) if ctxt.err_nr > err_nr
          pop_element_errors(ctxt, node) if ctxt.err_nr != 0
          return 0
        end

        ret = element_match(ctxt, define, node)
        if ret <= 0
          dump_valid_error(ctxt) if ctxt.flags & FLAGS_IGNORABLE == 0
          return -1
        end
        ret = 0
        if ctxt.err_nr != 0
          pop_errors(ctxt, err_nr) if ctxt.err_nr > err_nr
          pop_element_errors(ctxt, node)
        end
        err_nr = ctxt.err_nr

        oldflags = ctxt.flags
        ctxt.flags -= FLAGS_MIXED_CONTENT if ctxt.flags & FLAGS_MIXED_CONTENT != 0
        state = new_valid_state(ctxt, node)
        if state.nil?
          dump_valid_error(ctxt) if ctxt.flags & FLAGS_IGNORABLE == 0
          return -1
        end

        oldstate = ctxt.state
        ctxt.state = state
        if define.attrs
          tmp = validate_attribute_list(ctxt, define.attrs)
          if tmp != 0
            ret = -1
            add_valid_error(ctxt, ERR_ATTRVALID, node.name)
          end
        end
        if define.cont_model
          tmpstate = ctxt.state
          tmpstates = ctxt.states
          nstate = new_valid_state(ctxt, node)
          ctxt.state = nstate
          ctxt.states = nil

          tmp = validate_compiled_content(ctxt, define.cont_model, ctxt.state.seq)
          nseq = ctxt.state.seq
          ctxt.state = tmpstate
          ctxt.states = tmpstates
          free_valid_state(ctxt, nstate)

          ret = -1 if tmp != 0

          if ctxt.states
            tmp = -1
            i = 0
            while i < ctxt.states.nb_state
              state = ctxt.states.tab_state[i]
              ctxt.state = state
              ctxt.state.seq = nseq
              if validate_element_end(ctxt, 0) == 0
                tmp = 0
                break
              end
              i += 1
            end
            if tmp != 0
              # validation error, log the message for the "best" one
              ctxt.flags |= FLAGS_IGNORABLE
              log_best_error(ctxt)
            end
            free_states(ctxt, ctxt.states)
            ctxt.flags = oldflags
            ctxt.states = nil
            ret = -1 if ret == 0 && tmp == -1
          else
            state = ctxt.state
            ctxt.state.seq = nseq if ctxt.state
            ret = validate_element_end(ctxt, 1) if ret == 0
            free_valid_state(ctxt, state)
          end
        else
          if define.content
            tmp = validate_definition_list(ctxt, define.content)
            if tmp != 0
              ret = -1
              if ctxt.state.nil?
                ctxt.state = oldstate
                add_valid_error(ctxt, ERR_CONTENTVALID, node.name)
                ctxt.state = nil
              else
                add_valid_error(ctxt, ERR_CONTENTVALID, node.name)
              end
            end
          end
          if ctxt.states
            tmp = -1
            i = 0
            while i < ctxt.states.nb_state
              state = ctxt.states.tab_state[i]
              ctxt.state = state
              if validate_element_end(ctxt, 0) == 0
                tmp = 0
                break
              end
              i += 1
            end
            if tmp != 0
              # validation error, log the message for the "best" one
              ctxt.flags |= FLAGS_IGNORABLE
              log_best_error(ctxt)
            end
            i = 0
            while i < ctxt.states.nb_state
              ctxt.states.tab_state[i] = nil
              i += 1
            end
            free_states(ctxt, ctxt.states)
            ctxt.flags = oldflags
            ctxt.states = nil
            ret = -1 if ret == 0 && tmp == -1
          else
            state = ctxt.state
            ret = validate_element_end(ctxt, 1) if ret == 0
            free_valid_state(ctxt, state)
          end
        end
        node.psvi = define if ret == 0
        ctxt.flags = oldflags
        ctxt.state = oldstate
        oldstate.seq = skip_ignored(ctxt, node.next) if oldstate
        if ret != 0
          if ctxt.flags & FLAGS_IGNORABLE == 0
            dump_valid_error(ctxt)
            ret = 0
          end
        elsif ctxt.err_nr > err_nr
          pop_errors(ctxt, err_nr)
        end
        ret
      end

      # the XML_RELAXNG_ZEROORMORE case of xmlRelaxNGValidateState
      def validate_zero_or_more(ctxt, define)
        states = nil
        res = new_states(ctxt, 1)
        # All the input states are also exit states
        if ctxt.state
          add_states(ctxt, res, copy_valid_state(ctxt, ctxt.state))
        else
          j = 0
          while j < ctxt.states.nb_state
            add_states(ctxt, res, copy_valid_state(ctxt, ctxt.states.tab_state[j]))
            j += 1
          end
        end
        oldflags = ctxt.flags
        ctxt.flags |= FLAGS_IGNORABLE
        loop do
          progress = 0
          base = res.nb_state

          if ctxt.states
            states = ctxt.states
            i = 0
            while i < states.nb_state
              ctxt.state = states.tab_state[i]
              ctxt.states = nil
              ret = validate_definition_list(ctxt, define.content)
              if ret == 0
                if ctxt.state
                  tmp = add_states(ctxt, res, ctxt.state)
                  ctxt.state = nil
                  progress = 1 if tmp == 1
                elsif ctxt.states
                  j = 0
                  while j < ctxt.states.nb_state
                    tmp = add_states(ctxt, res, ctxt.states.tab_state[j])
                    progress = 1 if tmp == 1
                    j += 1
                  end
                  free_states(ctxt, ctxt.states)
                  ctxt.states = nil
                end
              elsif ctxt.state
                free_valid_state(ctxt, ctxt.state)
                ctxt.state = nil
              end
              i += 1
            end
          else
            ret = validate_definition_list(ctxt, define.content)
            if ret != 0
              free_valid_state(ctxt, ctxt.state)
              ctxt.state = nil
            else
              base = res.nb_state
              if ctxt.state
                tmp = add_states(ctxt, res, ctxt.state)
                ctxt.state = nil
                progress = 1 if tmp == 1
              elsif ctxt.states
                j = 0
                while j < ctxt.states.nb_state
                  tmp = add_states(ctxt, res, ctxt.states.tab_state[j])
                  progress = 1 if tmp == 1
                  j += 1
                end
                if states.nil?
                  states = ctxt.states
                else
                  free_states(ctxt, ctxt.states)
                end
                ctxt.states = nil
              end
            end
          end
          if progress != 0
            # Collect all the new nodes added at that step and make them the new node set
            if res.nb_state - base == 1
              ctxt.state = copy_valid_state(ctxt, res.tab_state[base])
            else
              if states.nil?
                # C: xmlRelaxNGNewStates(ctxt, ...) result is dropped; states = ctxt->states (NULL)
                states = ctxt.states
                if states.nil?
                  progress = 0
                  break
                end
              end
              states.nb_state = 0
              i = base
              while i < res.nb_state
                add_states(ctxt, states, copy_valid_state(ctxt, res.tab_state[i]))
                i += 1
              end
              ctxt.states = states
            end
          end
          break if progress != 1
        end
        free_states(ctxt, states) if states
        ctxt.states = res
        ctxt.flags = oldflags
        0
      end

      # the XML_RELAXNG_CHOICE case of xmlRelaxNGValidateState
      def validate_choice(ctxt, define, node)
        ret = 0
        states = nil
        node = skip_ignored(ctxt, node)
        err_nr = ctxt.err_nr
        if define.dflags & IS_TRIABLE != 0 && define.data && node
          # node == NULL can't be optimized since IS_TRIABLE doesn't account for choice which
          # may lead to only attributes.
          triage = define.data
          list = nil
          # Something we can optimize cleanly there is only one possible branch out !
          if node.type == TEXT_NODE || node.type == CDATA_SECTION_NODE
            list = triage.lookup("#text", nil)
          elsif node.type == ELEMENT_NODE
            if node.ns
              list = triage.lookup(node.name, node.ns.href)
              list = triage.lookup("#any", node.ns.href) if list.nil?
            else
              list = triage.lookup(node.name, nil)
            end
            list = triage.lookup("#any", nil) if list.nil?
          end
          if list.nil?
            add_valid_error(ctxt, ERR_ELEMWRONG, node.name)
            return -1
          end
          return validate_definition(ctxt, list)
        end

        list = define.content
        oldflags = ctxt.flags
        ctxt.flags |= FLAGS_IGNORABLE

        oldstate = nil
        while list
          oldstate = copy_valid_state(ctxt, ctxt.state)
          ret = validate_definition(ctxt, list)
          if ret == 0
            states = new_states(ctxt, 1) if states.nil?
            if ctxt.state
              add_states(ctxt, states, ctxt.state)
            elsif ctxt.states
              i = 0
              while i < ctxt.states.nb_state
                add_states(ctxt, states, ctxt.states.tab_state[i])
                i += 1
              end
              free_states(ctxt, ctxt.states)
              ctxt.states = nil
            end
          else
            free_valid_state(ctxt, ctxt.state)
          end
          ctxt.state = oldstate
          list = list.next
        end
        if states
          free_valid_state(ctxt, oldstate)
          ctxt.states = states
          ctxt.state = nil
          ret = 0
        else
          ctxt.states = nil
        end
        ctxt.flags = oldflags
        if ret != 0
          dump_valid_error(ctxt) if ctxt.flags & FLAGS_IGNORABLE == 0
        elsif ctxt.err_nr > err_nr
          pop_errors(ctxt, err_nr)
        end
        ret
      end

      # xmlRelaxNGValidateDefinition
      def validate_definition(ctxt, define)
        # We should NOT have both ctxt->state and ctxt->states
        if ctxt.state && ctxt.states
          free_valid_state(ctxt, ctxt.state)
          ctxt.state = nil
        end

        if ctxt.states.nil? || ctxt.states.nb_state == 1
          if ctxt.states
            ctxt.state = ctxt.states.tab_state[0]
            free_states(ctxt, ctxt.states)
            ctxt.states = nil
          end
          ret = validate_state(ctxt, define)
          if ctxt.state && ctxt.states
            free_valid_state(ctxt, ctxt.state)
            ctxt.state = nil
          end
          if ctxt.states && ctxt.states.nb_state == 1
            ctxt.state = ctxt.states.tab_state[0]
            free_states(ctxt, ctxt.states)
            ctxt.states = nil
          end
          return ret
        end

        states = ctxt.states
        ctxt.states = nil
        res = nil
        j = 0
        oldflags = ctxt.flags
        ctxt.flags |= FLAGS_IGNORABLE
        i = 0
        while i < states.nb_state
          ctxt.state = states.tab_state[i]
          ctxt.states = nil
          ret = validate_state(ctxt, define)
          # We should NOT have both ctxt->state and ctxt->states
          if ctxt.state && ctxt.states
            free_valid_state(ctxt, ctxt.state)
            ctxt.state = nil
          end
          if ret == 0
            if ctxt.states.nil?
              if res
                # add the state to the container
                add_states(ctxt, res, ctxt.state)
                ctxt.state = nil
              else
                # add the state directly in states
                states.tab_state[j] = ctxt.state
                j += 1
                ctxt.state = nil
              end
            elsif res.nil?
              # make it the new container and copy other results
              res = ctxt.states
              ctxt.states = nil
              k = 0
              while k < j
                add_states(ctxt, res, states.tab_state[k])
                k += 1
              end
            else
              # add all the new results to res and reff the container
              k = 0
              while k < ctxt.states.nb_state
                add_states(ctxt, res, ctxt.states.tab_state[k])
                k += 1
              end
              free_states(ctxt, ctxt.states)
              ctxt.states = nil
            end
          elsif ctxt.state
            free_valid_state(ctxt, ctxt.state)
            ctxt.state = nil
          elsif ctxt.states
            free_states(ctxt, ctxt.states)
            ctxt.states = nil
          end
          i += 1
        end
        ctxt.flags = oldflags
        if res
          free_states(ctxt, states)
          ctxt.states = res
          ret = 0
        elsif j > 1
          states.nb_state = j
          ctxt.states = states
          ret = 0
        elsif j == 1
          ctxt.state = states.tab_state[0]
          free_states(ctxt, states)
          ret = 0
        else
          ret = -1
          free_states(ctxt, states)
          if ctxt.states
            free_states(ctxt, ctxt.states)
            ctxt.states = nil
          end
        end
        if ctxt.state && ctxt.states
          free_valid_state(ctxt, ctxt.state)
          ctxt.state = nil
        end
        ret
      end

      # xmlRelaxNGValidateDocument
      def validate_document(ctxt, doc)
        return -1 if ctxt.nil? || ctxt.schema.nil? || doc.nil?

        ctxt.err_no = OK
        schema = ctxt.schema
        grammar = schema.topgrammar
        if grammar.nil?
          add_valid_error(ctxt, ERR_NOGRAMMAR)
          return -1
        end
        state = new_valid_state(ctxt, nil)
        ctxt.state = state
        ret = validate_definition(ctxt, grammar.start)
        if ctxt.state && state.seq
          state = ctxt.state
          node = state.seq
          node = skip_ignored(ctxt, node)
          if node && ret != -1
            add_valid_error(ctxt, ERR_EXTRADATA)
            ret = -1
          end
        elsif ctxt.states
          tmp = -1
          i = 0
          while i < ctxt.states.nb_state
            state = ctxt.states.tab_state[i]
            node = state.seq
            node = skip_ignored(ctxt, node)
            tmp = 0 if node.nil?
            free_valid_state(ctxt, state)
            i += 1
          end
          if tmp == -1 && ret != -1
            add_valid_error(ctxt, ERR_EXTRADATA)
            ret = -1
          end
        end
        if ctxt.state
          free_valid_state(ctxt, ctxt.state)
          ctxt.state = nil
        end
        dump_valid_error(ctxt) if ret != 0
        if ctxt.idref == 1
          ret = -1 if validate_document_final(doc) != 1
        end
        ret = -1 if ret == 0 && ctxt.err_no != OK
        ret
      end

      # xmlValidateDocumentFinal (valid.c) as called by xmlRelaxNGValidateDocument: the IDREF /
      # IDREFS values recorded while validating must match an ID. The C validation context has
      # no structured handler, so the errors go to the global structured error handler.
      def validate_document_final(doc)
        return 0 if doc.nil?

        if Pure.const_defined?(:Valid) && Pure::Valid.respond_to?(:validate_document_final)
          return Pure::Valid.validate_document_final(nil, doc)
        end

        refs = doc.refs
        return 1 if refs.nil? || refs.empty?

        valid = 1
        refs.each_value do |list|
          Array(list).each do |ref|
            attr = ref.respond_to?(:attr) ? ref.attr : nil
            name = ref.respond_to?(:name) && ref.name ? ref.name : attr&.name
            value = ref.value
            next if attr.nil? && name.nil?

            atype = attr&.atype
            if atype == ATTRIBUTE_IDREFS || atype == ATTRIBUTE_ENTITIES
              value.split(/[ \t\n\r]+/).reject(&:empty?).each do |tok|
                next if Tree.get_id(doc, tok)

                valid = 0
                report_unknown_id(attr, name, tok)
              end
            elsif Tree.get_id(doc, value).nil?
              valid = 0
              report_unknown_id(attr, name, value)
            end
          end
        end
        valid
      end

      def report_unknown_id(attr, name, value)
        node = attr&.parent
        err = XmlError.new(domain: Domain::VALID, code: ErrCode::DTD_UNKNOWN_ID, level: Level::ERROR,
          message: "IDREF attribute #{name} references an unknown ID \"#{value}\"\n",
          file: node&.doc&.url, line: node ? node.line : 0, str1: name, str2: value, node: node)
        Errors.report(err)
      end

      # xmlRelaxNGCleanPSVI
      def clean_psvi(node)
        return if node.nil? ||
          (node.type != ELEMENT_NODE && node.type != DOCUMENT_NODE && node.type != HTML_DOCUMENT_NODE)

        node.psvi = nil if node.type == ELEMENT_NODE
        cur = node.children
        while cur
          if cur.type == ELEMENT_NODE
            cur.psvi = nil
            if cur.children
              cur = cur.children
              next
            end
          end
          if cur.next
            cur = cur.next
            next
          end
          loop do
            cur = cur.parent
            break if cur.nil?

            if cur.equal?(node)
              cur = nil
              break
            end
            if cur.next
              cur = cur.next
              break
            end
          end
        end
      end

      # ---- validation interfaces ------------------------------------------------------------

      # xmlRelaxNGNewValidCtxt
      def new_valid_ctxt(schema)
        ret = ValidCtxt.new
        ret.schema = schema
        ret.idref = schema.idref if schema
        ret.err_no = OK
        ret
      end

      # xmlRelaxNGValidateDoc
      def validate_doc(ctxt, doc)
        return -1 if ctxt.nil? || doc.nil?

        ctxt.doc = doc
        ret = validate_document(ctxt, doc)
        # Remove all left PSVI
        clean_psvi(doc)
        return 1 if ret == -1

        ret
      end
    end
  end
end
