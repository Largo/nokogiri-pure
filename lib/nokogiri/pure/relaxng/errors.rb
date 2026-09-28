# frozen_string_literal: true

# relaxng.c: error reporting (xmlRngPErr / xmlRngVErr, the validation error stack).
module Nokogiri
  module Pure
    module RelaxNG
      module_function

      # printf with the only conversions relaxng.c messages use (%s, nil -> "(null)") and %%
      def c_format(fmt, str1 = nil, str2 = nil)
        return fmt unless fmt.include?("%")

        args = [str1, str2]
        i = 0
        fmt.gsub(/%[s%]/) do |m|
          if m == "%%"
            "%"
          else
            a = args[i]
            i += 1
            a.nil? ? "(null)" : a.to_s
          end
        end
      end

      # xmlVRaiseError / xmlVUpdateError: node -> file / line
      def raise_error(schannel, node, domain, code, level, str1, str2, msg)
        file = nil
        line = 0
        if node
          10.times do
            break if node.type == ELEMENT_NODE || node.parent.nil?

            node = node.parent
          end
          file = node.doc&.url
          line = node.line if node.type == ELEMENT_NODE
          line = Tree.get_line_no(node) if line.nil? || line == 0 || line == 65535
        end
        err = XmlError.new(domain: domain, code: code, message: msg, level: level, file: file,
          line: line || 0, str1: str1&.dup, str2: str2&.dup, node: node)
        if schannel
          schannel.call(err)
        else
          Errors.report(err)
        end
        0
      end

      # xmlRngPErr
      def p_err(ctxt, node, error, msg, str1 = nil, str2 = nil)
        schannel = nil
        if ctxt
          schannel = ctxt.serror
          ctxt.nb_errors += 1
        end
        raise_error(schannel, node, Domain::RELAXNGP, error, Level::ERROR, str1, str2,
          c_format(msg, str1, str2))
      end

      # xmlRngVErr (+msg+ is the already escaped message used as a format)
      def v_err(ctxt, node, error, msg, str1 = nil, str2 = nil)
        schannel = nil
        if ctxt
          schannel = ctxt.serror
          ctxt.nb_errors += 1
        end
        raise_error(schannel, node, Domain::RELAXNGV, error, Level::ERROR, str1, str2,
          c_format(msg, str1, str2))
      end

      DEF_NAMES = {
        EMPTY => "empty", NOT_ALLOWED => "notAllowed", EXCEPT => "except", TEXT => "text",
        ELEMENT => "element", DATATYPE => "datatype", VALUE => "value", LIST => "list",
        ATTRIBUTE => "attribute", DEF => "def", REF => "ref", EXTERNALREF => "externalRef",
        PARENTREF => "parentRef", OPTIONAL => "optional", ZEROORMORE => "zeroOrMore",
        ONEORMORE => "oneOrMore", CHOICE => "choice", GROUP => "group", INTERLEAVE => "interleave",
        START => "start", NOOP => "noop", PARAM => "param",
      }.freeze

      # xmlRelaxNGDefName
      def def_name(defn)
        return "none" if defn.nil?

        DEF_NAMES[defn.type] || "unknown"
      end

      # xmlRelaxNGGetErrorString
      def get_error_string(err, arg1, arg2)
        arg1 = "" if arg1.nil?
        arg2 = "" if arg2.nil?
        msg = case err
        when OK then return nil
        when ERR_MEMORY then return "out of memory\n"
        when ERR_TYPE then "failed to validate type #{arg1}\n"
        when ERR_TYPEVAL then "Type #{arg1} doesn't allow value '#{arg2}'\n"
        when ERR_DUPID then "ID #{arg1} redefined\n"
        when ERR_TYPECMP then "failed to compare type #{arg1}\n"
        when ERR_NOSTATE then return "Internal error: no state\n"
        when ERR_NODEFINE then return "Internal error: no define\n"
        when ERR_INTERNAL then "Internal error: #{arg1}\n"
        when ERR_LISTEXTRA then "Extra data in list: #{arg1}\n"
        when ERR_INTERNODATA then return "Internal: interleave block has no data\n"
        when ERR_INTERSEQ then return "Invalid sequence in interleave\n"
        when ERR_INTEREXTRA then "Extra element #{arg1} in interleave\n"
        when ERR_ELEMNAME then "Expecting element #{arg1}, got #{arg2}\n"
        when ERR_ELEMNONS then "Expecting a namespace for element #{arg1}\n"
        when ERR_ELEMWRONGNS then "Element #{arg1} has wrong namespace: expecting #{arg2}\n"
        when ERR_ELEMWRONG then "Did not expect element #{arg1} there\n"
        when ERR_TEXTWRONG then "Did not expect text in element #{arg1} content\n"
        when ERR_ELEMEXTRANS then "Expecting no namespace for element #{arg1}\n"
        when ERR_ELEMNOTEMPTY then "Expecting element #{arg1} to be empty\n"
        when ERR_NOELEM then "Expecting an element #{arg1}, got nothing\n"
        when ERR_NOTELEM then return "Expecting an element got text\n"
        when ERR_ATTRVALID then "Element #{arg1} failed to validate attributes\n"
        when ERR_CONTENTVALID then "Element #{arg1} failed to validate content\n"
        when ERR_EXTRACONTENT then "Element #{arg1} has extra content: #{arg2}\n"
        when ERR_INVALIDATTR then "Invalid attribute #{arg1} for element #{arg2}\n"
        when ERR_LACKDATA then "Datatype element #{arg1} contains no data\n"
        when ERR_DATAELEM then "Datatype element #{arg1} has child elements\n"
        when ERR_VALELEM then "Value element #{arg1} has child elements\n"
        when ERR_LISTELEM then "List element #{arg1} has child elements\n"
        when ERR_DATATYPE then "Error validating datatype #{arg1}\n"
        when ERR_VALUE then "Error validating value #{arg1}\n"
        when ERR_LIST then return "Error validating list\n"
        when ERR_NOGRAMMAR then return "No top grammar defined\n"
        when ERR_EXTRADATA then return "Extra data in the document\n"
        else return "Unknown error !\n"
        end
        msg = msg.b
        # snprintf(msg, 1000, ...)
        msg = msg.byteslice(0, 999) if msg.bytesize > 999
        msg.force_encoding(Encoding::UTF_8)
        # xmlEscapeFormatString
        msg.include?("%") ? msg.gsub("%", "%%") : msg
      end

      # xmlRelaxNGShowValidError
      def show_valid_error(ctxt, err, node, child, arg1, arg2)
        return if ctxt.flags & FLAGS_NOERROR != 0

        msg = get_error_string(err, arg1, arg2)
        return if msg.nil?

        ctxt.err_no = err if ctxt.err_no == OK
        v_err(ctxt, child.nil? ? node : child, err, msg, arg1, arg2)
      end

      # xmlRelaxNGValidErrorPush
      def valid_error_push(ctxt, err, arg1, arg2, dup)
        if ctxt.err_tab.nil?
          ctxt.err_tab = []
          ctxt.err_max = 8
          ctxt.err_nr = 0
          ctxt.err = nil
        end
        if ctxt.err_nr >= ctxt.err_max
          ctxt.err_max *= 2
          ctxt.err = ctxt.err_nr - 1
        end
        if ctxt.err && ctxt.state &&
            (e = ctxt.err_tab[ctxt.err]) && e.node.equal?(ctxt.state.node) && e.err == err
          return ctxt.err_nr
        end
        cur = (ctxt.err_tab[ctxt.err_nr] ||= ValidError.new)
        cur.err = err
        if dup
          cur.arg1 = arg1&.dup
          cur.arg2 = arg2&.dup
          cur.flags = ERROR_IS_DUP
        else
          cur.arg1 = arg1
          cur.arg2 = arg2
          cur.flags = 0
        end
        if ctxt.state
          cur.node = ctxt.state.node
          cur.seq = ctxt.state.seq
        else
          cur.node = nil
          cur.seq = nil
        end
        ctxt.err = ctxt.err_nr
        n = ctxt.err_nr
        ctxt.err_nr += 1
        n
      end

      # xmlRelaxNGValidErrorPop
      def valid_error_pop(ctxt)
        if ctxt.err_nr <= 0
          ctxt.err = nil
          return
        end
        ctxt.err_nr -= 1
        ctxt.err = ctxt.err_nr > 0 ? ctxt.err_nr - 1 : nil
        cur = ctxt.err_tab[ctxt.err_nr]
        if cur.flags & ERROR_IS_DUP != 0
          cur.arg1 = nil
          cur.arg2 = nil
          cur.flags = 0
        end
      end

      # xmlRelaxNGPopErrors
      def pop_errors(ctxt, level)
        i = level
        while i < ctxt.err_nr
          err = ctxt.err_tab[i]
          if err.flags & ERROR_IS_DUP != 0
            err.arg1 = nil
            err.arg2 = nil
            err.flags = 0
          end
          i += 1
        end
        ctxt.err_nr = level
        ctxt.err = nil if ctxt.err_nr <= 0
      end

      # xmlRelaxNGDumpValidError
      def dump_valid_error(ctxt)
        k = 0
        i = 0
        while i < ctxt.err_nr
          err = ctxt.err_tab[i]
          if k < MAX_ERROR
            skip = false
            j = 0
            while j < i
              dup = ctxt.err_tab[j]
              if err.err == dup.err && err.node.equal?(dup.node) && err.arg1 == dup.arg1 &&
                  err.arg2 == dup.arg2
                skip = true
                break
              end
              j += 1
            end
            unless skip
              show_valid_error(ctxt, err.err, err.node, err.seq, err.arg1, err.arg2)
              k += 1
            end
          end
          if err.flags & ERROR_IS_DUP != 0
            err.arg1 = nil
            err.arg2 = nil
            err.flags = 0
          end
          i += 1
        end
        ctxt.err_nr = 0
      end

      # xmlRelaxNGAddValidError
      def add_valid_error(ctxt, err, arg1 = nil, arg2 = nil, dup = false)
        return if ctxt.nil?
        return if ctxt.flags & FLAGS_NOERROR != 0

        if ctxt.flags & FLAGS_IGNORABLE == 0 || ctxt.flags & FLAGS_NEGATIVE != 0
          dump_valid_error(ctxt) if ctxt.err_nr != 0
          if ctxt.state
            node = ctxt.state.node
            seq = ctxt.state.seq
          else
            node = seq = nil
          end
          node = ctxt.pnode if node.nil? && seq.nil?
          show_valid_error(ctxt, err, node, seq, arg1, arg2)
        else
          valid_error_push(ctxt, err, arg1, arg2, dup)
        end
      end
    end
  end
end
