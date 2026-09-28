# frozen_string_literal: true

# relaxng.c: "progressive" (streaming) validation, used by xmlTextReader's RelaxNG support
# (xmlRelaxNGValidatePushElement / PushCData / PopElement / FullElement).
module Nokogiri
  module Pure
    module RelaxNG
      module_function

      # xmlRelaxNGElemPush
      def elem_push(ctxt, exec)
        (ctxt.elem_tab ||= []) << exec
        ctxt.elem = exec
        0
      end

      # xmlRelaxNGElemPop
      def elem_pop(ctxt)
        return nil if ctxt.elem_tab.nil? || ctxt.elem_tab.empty?

        ret = ctxt.elem_tab.pop
        ctxt.elem = ctxt.elem_tab.last
        ret
      end

      # xmlRelaxNGValidateProgressiveCallback
      def validate_progressive_callback(_data, token, transdata, inputdata)
        ctxt = inputdata
        define = transdata
        if ctxt.nil?
          $stderr.print("callback on #{token} missing context\n")
          return
        end
        node = ctxt.pnode
        ctxt.pstate = 1
        if define.nil?
          return if token.start_with?("#")

          $stderr.print("callback on #{token} missing define\n")
          ctxt.err_no = ERR_INTERNAL if ctxt.err_no == OK
          ctxt.pstate = -1
          return
        end
        if define.type != ELEMENT
          $stderr.print("callback on #{token} define is not element\n")
          ctxt.err_no = ERR_INTERNAL if ctxt.err_no == OK
          ctxt.pstate = -1
          return
        end
        if node.type != ELEMENT_NODE
          add_valid_error(ctxt, ERR_NOTELEM)
          dump_valid_error(ctxt) if ctxt.flags & FLAGS_IGNORABLE == 0
          ctxt.pstate = -1
          return
        end
        if define.cont_model.nil?
          # this node cannot be validated in a streamable fashion
          ctxt.pstate = 0
          ctxt.pdef = define
          return
        end
        exec = XmlRegexp.reg_new_exec_ctxt(define.cont_model, PROGRESSIVE_CALLBACK, ctxt)
        if exec.nil?
          ctxt.pstate = -1
          return
        end
        elem_push(ctxt, exec)

        # Validate the attributes part of the content.
        state = new_valid_state(ctxt, node)
        if state.nil?
          ctxt.pstate = -1
          return
        end
        oldstate = ctxt.state
        ctxt.state = state
        ret = 0
        if define.attrs
          ret = validate_attribute_list(ctxt, define.attrs)
          if ret != 0
            ctxt.pstate = -1
            add_valid_error(ctxt, ERR_ATTRVALID, node.name)
          end
        end
        if ctxt.state
          ctxt.state.seq = nil
          ret = validate_element_end(ctxt, 1)
          ctxt.pstate = -1 if ret != 0
          free_valid_state(ctxt, ctxt.state)
        elsif ctxt.states
          tmp = -1
          oldflags = ctxt.flags
          i = 0
          while i < ctxt.states.nb_state
            state = ctxt.states.tab_state[i]
            ctxt.state = state
            ctxt.state.seq = nil
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
          ctxt.states = nil
          ctxt.pstate = -1 if ret == 0 && tmp == -1
          ctxt.flags = oldflags
        end
        dump_valid_error(ctxt) if ctxt.pstate == -1 && ctxt.flags & FLAGS_IGNORABLE == 0
        ctxt.state = oldstate
      end

      PROGRESSIVE_CALLBACK = ->(data, token, transdata, inputdata) do
        RelaxNG.validate_progressive_callback(data, token, transdata, inputdata)
      end

      # xmlRelaxNGValidatePushElement: 1 if no problem, 0 if the element needs a full
      # validation (xmlRelaxNGValidateFullElement), -1 on error
      def validate_push_element(ctxt, _doc, elem)
        return -1 if ctxt.nil? || elem.nil?

        if ctxt.elem.nil?
          schema = ctxt.schema
          if schema.nil?
            add_valid_error(ctxt, ERR_NOGRAMMAR)
            return -1
          end
          grammar = schema.topgrammar
          if grammar.nil? || grammar.start.nil?
            add_valid_error(ctxt, ERR_NOGRAMMAR)
            return -1
          end
          define = grammar.start
          if define.cont_model.nil?
            ctxt.pdef = define
            return 0
          end
          exec = XmlRegexp.reg_new_exec_ctxt(define.cont_model, PROGRESSIVE_CALLBACK, ctxt)
          return -1 if exec.nil?

          elem_push(ctxt, exec)
        end
        ctxt.pnode = elem
        ctxt.pstate = 0
        ret = if elem.ns
          XmlRegexp.reg_exec_push_string2(ctxt.elem, elem.name, elem.ns.href, ctxt)
        else
          XmlRegexp.reg_exec_push_string(ctxt.elem, elem.name, ctxt)
        end
        if ret < 0
          add_valid_error(ctxt, ERR_ELEMWRONG, elem.name)
        else
          ret = if ctxt.pstate == 0
            0
          elsif ctxt.pstate < 0
            -1
          else
            1
          end
        end
        ret
      end

      # xmlRelaxNGValidatePushCData: 1 if no problem, -1 otherwise
      def validate_push_cdata(ctxt, data, _len = nil)
        return -1 if ctxt.nil? || ctxt.elem.nil? || data.nil?
        return 1 unless data.match?(/[^ \t\n\r]/)

        ret = XmlRegexp.reg_exec_push_string(ctxt.elem, "#text", ctxt)
        if ret < 0
          add_valid_error(ctxt, ERR_TEXTWRONG, " TODO ")
          return -1
        end
        1
      end

      # xmlRelaxNGValidatePopElement: 1 if no problem, 0 otherwise
      def validate_pop_element(ctxt, _doc, elem)
        return -1 if ctxt.nil? || ctxt.elem.nil? || elem.nil?

        # verify that we reached a terminal state of the content model.
        exec = elem_pop(ctxt)
        ret = XmlRegexp.reg_exec_push_string(exec, nil, nil)
        if ret == 0
          add_valid_error(ctxt, ERR_NOELEM, "")
          -1
        elsif ret < 0
          -1
        else
          1
        end
      end

      # xmlRelaxNGValidateFullElement: 1 if no problem, -1 on error
      def validate_full_element(ctxt, _doc, elem)
        return -1 if ctxt.nil? || ctxt.pdef.nil? || elem.nil?

        state = new_valid_state(ctxt, elem.parent)
        return -1 if state.nil?

        state.seq = elem
        ctxt.state = state
        ctxt.err_no = OK
        ret = validate_definition(ctxt, ctxt.pdef)
        ret = ret != 0 || ctxt.err_no != OK ? -1 : 1
        free_valid_state(ctxt, ctxt.state)
        ctxt.state = nil
        ret
      end
    end
  end
end
