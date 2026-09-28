# frozen_string_literal: true

# relaxng.c: compiling element content into xmlRegexp automata.
module Nokogiri
  module Pure
    module RelaxNG
      module_function

      # xmlRelaxNGIsCompilable
      def is_compilable(defn)
        ret = -1
        return -1 if defn.nil?
        return 1 if defn.type != ELEMENT && defn.dflags & IS_COMPILABLE != 0
        return 0 if defn.type != ELEMENT && defn.dflags & IS_NOT_COMPILABLE != 0

        case defn.type
        when NOOP
          ret = is_compilable(defn.content)
        when TEXT, EMPTY
          ret = 1
        when ELEMENT
          if defn.dflags & IS_NOT_COMPILABLE == 0 && defn.dflags & IS_COMPILABLE == 0
            list = defn.content
            while list
              ret = is_compilable(list)
              break if ret != 1

              list = list.next
            end
            if ret == 0
              defn.dflags &= ~IS_COMPILABLE
              defn.dflags |= IS_NOT_COMPILABLE
            end
            # C: `if ((ret == 1) && !(def->dflags &= IS_NOT_COMPILABLE))` (an assignment)
            if ret == 1
              defn.dflags &= IS_NOT_COMPILABLE
              defn.dflags |= IS_COMPILABLE if defn.dflags == 0
            end
          end
          return (!defn.name_class.nil? || defn.name.nil?) ? 0 : 1
        when REF, EXTERNALREF, PARENTREF
          if defn.depth == -20
            return 1
          else
            defn.depth = -20
            list = defn.content
            while list
              ret = is_compilable(list)
              break if ret != 1

              list = list.next
            end
          end
        when START, OPTIONAL, ZEROORMORE, ONEORMORE, CHOICE, GROUP, DEF
          list = defn.content
          while list
            ret = is_compilable(list)
            break if ret != 1

            list = list.next
          end
        when EXCEPT, ATTRIBUTE, INTERLEAVE, DATATYPE, LIST, PARAM, VALUE, NOT_ALLOWED
          ret = 0
        end
        defn.dflags |= IS_NOT_COMPILABLE if ret == 0
        defn.dflags |= IS_COMPILABLE if ret == 1
        ret
      end

      # xmlRelaxNGCompile
      def compile(ctxt, defn)
        ret = 0
        return -1 if ctxt.nil? || defn.nil?

        x = XmlRegexp
        case defn.type
        when START
          if is_compilable(defn) == 1 && defn.depth != -25
            oldam = ctxt.am
            oldstate = ctxt.state
            defn.depth = -25
            list = defn.content
            ctxt.am = x.new_automata
            return -1 if ctxt.am.nil?

            x.automata_set_flags(ctxt.am, 1)
            ctxt.state = x.automata_get_init_state(ctxt.am)
            while list
              compile(ctxt, list)
              list = list.next
            end
            x.automata_set_final_state(ctxt.am, ctxt.state)
            if x.automata_is_determinist(ctxt.am) != 0
              defn.cont_model = x.automata_compile(ctxt.am)
            end
            ctxt.state = oldstate
            ctxt.am = oldam
          end
        when ELEMENT
          if ctxt.am && defn.name
            ctxt.state = x.automata_new_transition2(ctxt.am, ctxt.state, nil, defn.name, defn.ns, defn)
          end
          if defn.dflags & IS_COMPILABLE != 0 && defn.depth != -25
            oldam = ctxt.am
            oldstate = ctxt.state
            defn.depth = -25
            list = defn.content
            ctxt.am = x.new_automata
            return -1 if ctxt.am.nil?

            x.automata_set_flags(ctxt.am, 1)
            ctxt.state = x.automata_get_init_state(ctxt.am)
            while list
              compile(ctxt, list)
              list = list.next
            end
            x.automata_set_final_state(ctxt.am, ctxt.state)
            defn.cont_model = x.automata_compile(ctxt.am)
            if x.regexp_is_determinist(defn.cont_model) == 0 || defn.cont_model.nil?
              # we can only use the automata if it is determinist
              defn.cont_model = nil
            end
            ctxt.state = oldstate
            ctxt.am = oldam
          else
            oldam = ctxt.am
            ret = try_compile(ctxt, defn)
            ctxt.am = oldam
          end
        when NOOP
          ret = compile(ctxt, defn.content)
        when OPTIONAL
          oldstate = ctxt.state
          list = defn.content
          while list
            compile(ctxt, list)
            list = list.next
          end
          x.automata_new_epsilon(ctxt.am, oldstate, ctxt.state)
        when ZEROORMORE
          ctxt.state = x.automata_new_epsilon(ctxt.am, ctxt.state, nil)
          oldstate = ctxt.state
          list = defn.content
          while list
            compile(ctxt, list)
            list = list.next
          end
          x.automata_new_epsilon(ctxt.am, ctxt.state, oldstate)
          ctxt.state = x.automata_new_epsilon(ctxt.am, oldstate, nil)
        when ONEORMORE
          list = defn.content
          while list
            compile(ctxt, list)
            list = list.next
          end
          oldstate = ctxt.state
          list = defn.content
          while list
            compile(ctxt, list)
            list = list.next
          end
          x.automata_new_epsilon(ctxt.am, ctxt.state, oldstate)
          ctxt.state = x.automata_new_epsilon(ctxt.am, oldstate, nil)
        when CHOICE
          target = nil
          oldstate = ctxt.state
          list = defn.content
          while list
            ctxt.state = oldstate
            ret = compile(ctxt, list)
            break if ret != 0

            if target.nil?
              target = ctxt.state
            else
              x.automata_new_epsilon(ctxt.am, ctxt.state, target)
            end
            list = list.next
          end
          ctxt.state = target
        when REF, EXTERNALREF, PARENTREF, GROUP, DEF
          list = defn.content
          while list
            ret = compile(ctxt, list)
            break if ret != 0

            list = list.next
          end
        when TEXT
          ctxt.state = x.automata_new_epsilon(ctxt.am, ctxt.state, nil)
          oldstate = ctxt.state
          compile(ctxt, defn.content)
          x.automata_new_transition(ctxt.am, ctxt.state, ctxt.state, "#text", nil)
          ctxt.state = x.automata_new_epsilon(ctxt.am, oldstate, nil)
        when EMPTY
          ctxt.state = x.automata_new_epsilon(ctxt.am, ctxt.state, nil)
        when EXCEPT, ATTRIBUTE, INTERLEAVE, NOT_ALLOWED, DATATYPE, LIST, PARAM, VALUE
          # This should not happen and generate an internal error
          $stderr.print("RNG internal error trying to compile #{def_name(defn)}\n")
        end
        ret
      end

      # xmlRelaxNGTryCompile
      def try_compile(ctxt, defn)
        ret = 0
        return -1 if ctxt.nil? || defn.nil?

        if defn.type == START || defn.type == ELEMENT
          ret = is_compilable(defn)
          if defn.dflags & IS_COMPILABLE != 0 && defn.depth != -25
            ctxt.am = nil
            return compile(ctxt, defn)
          end
        end
        case defn.type
        when NOOP
          ret = try_compile(ctxt, defn.content)
        when TEXT, DATATYPE, LIST, PARAM, VALUE, EMPTY, ELEMENT
          ret = 0
        when OPTIONAL, ZEROORMORE, ONEORMORE, CHOICE, GROUP, DEF, START, REF, EXTERNALREF, PARENTREF
          list = defn.content
          while list
            ret = try_compile(ctxt, list)
            break if ret != 0

            list = list.next
          end
        when EXCEPT, ATTRIBUTE, INTERLEAVE, NOT_ALLOWED
          ret = 0
        end
        ret
      end
    end
  end
end
