# frozen_string_literal: true

# relaxng.c: the checks and simplifications run on the parsed definitions (nullability,
# choice determinism, interleave partitions, cycles, section 4.19-4.20 simplification and
# the restrictions of section 7).
module Nokogiri
  module Pure
    module RelaxNG
      # the fake node / namespace built on the stack by xmlRelaxNGCompareNameClasses
      FakeNs = Struct.new(:href)
      FakeNode = Struct.new(:name, :ns)

      module_function

      # xmlRelaxNGIsNullable
      def is_nullable(define)
        return -1 if define.nil?
        return 1 if define.dflags & IS_NULLABLE != 0
        return 0 if define.dflags & IS_NOT_NULLABLE != 0

        case define.type
        when EMPTY, TEXT
          ret = 1
        when NOOP, DEF, REF, EXTERNALREF, PARENTREF, ONEORMORE
          ret = is_nullable(define.content)
        when EXCEPT, NOT_ALLOWED, ELEMENT, DATATYPE, PARAM, VALUE, LIST, ATTRIBUTE
          ret = 0
        when CHOICE
          list = define.content
          ret = 0
          found = false
          while list
            ret = is_nullable(list)
            if ret != 0
              found = true
              break
            end
            list = list.next
          end
          ret = 0 unless found
        when START, INTERLEAVE, GROUP
          list = define.content
          while list
            ret = is_nullable(list)
            if ret != 1
              define.dflags |= IS_NOT_NULLABLE if ret == 0
              return ret
            end
            list = list.next
          end
          return 1
        else
          return -1
        end
        define.dflags |= IS_NOT_NULLABLE if ret == 0
        define.dflags |= IS_NULLABLE if ret == 1
        ret
      end

      # xmlRelaxNGCompareNameClasses
      def compare_name_classes(def1, def2)
        ret = 1
        ns = FakeNs.new(nil)
        node = FakeNode.new(nil, nil)
        ctxt = ValidCtxt.new
        ctxt.flags = FLAGS_IGNORABLE | FLAGS_NOERROR

        if def1.type == ELEMENT || def1.type == ATTRIBUTE
          return 1 if def2.type == TEXT

          node.name = def1.name.nil? ? INVALID_NAME : def1.name
          if def1.ns
            if def1.ns.empty?
              node.ns = nil
            else
              node.ns = ns
              ns.href = def1.ns
            end
          else
            node.ns = nil
          end
          ret = if element_match(ctxt, def2, node) != 0
            def1.name_class ? compare_name_classes(def1.name_class, def2) : 0
          else
            1
          end
        elsif def1.type == TEXT
          return 0 if def2.type == TEXT

          return 1
        elsif def1.type == EXCEPT
          ret = compare_name_classes(def1.content, def2)
          if ret == 0
            ret = 1
          elsif ret == 1
            ret = 0
          end
        else
          ret = 0
        end
        return ret if ret == 0

        if def2.type == ELEMENT || def2.type == ATTRIBUTE
          node.name = def2.name.nil? ? INVALID_NAME : def2.name
          node.ns = ns
          if def2.ns
            if def2.ns.empty?
              node.ns = nil
            else
              ns.href = def2.ns
            end
          else
            ns.href = INVALID_NAME
          end
          ret = if element_match(ctxt, def1, node) != 0
            def2.name_class ? compare_name_classes(def2.name_class, def1) : 0
          else
            1
          end
        else
          ret = 0
        end
        ret
      end

      # xmlRelaxNGCompareElemDefLists
      def compare_elem_def_lists(_ctxt, def1, def2)
        return 1 if def1.nil? || def2.nil?
        return 1 if def1.empty? || def2.empty?

        def1.each do |d1|
          def2.each do |d2|
            return 0 if compare_name_classes(d1, d2) == 0
          end
        end
        1
      end

      GENERATES_NON_ATTR = [ELEMENT, TEXT, DATATYPE, PARAM, LIST, VALUE, EMPTY].freeze
      CONTAINERS_GA = [CHOICE, INTERLEAVE, GROUP, ONEORMORE, ZEROORMORE, OPTIONAL, PARENTREF,
        EXTERNALREF, REF, DEF].freeze

      # xmlRelaxNGGenerateAttributes
      def generate_attributes(ctxt, defn)
        # Don't run that check in case of error. Infinite recursion becomes possible.
        return -1 if ctxt.nb_errors != 0

        cur = defn
        while cur
          return 0 if GENERATES_NON_ATTR.include?(cur.type)

          if CONTAINERS_GA.include?(cur.type) && cur.content
            parent = cur
            cur = cur.content
            tmp = cur
            while tmp
              tmp.parent = parent
              tmp = tmp.next
            end
            next
          end
          break if cur.equal?(defn)

          if cur.next
            cur = cur.next
            next
          end
          loop do
            cur = cur.parent
            break if cur.nil?
            return 1 if cur.equal?(defn)

            if cur.next
              cur = cur.next
              break
            end
          end
        end
        1
      end

      CONTAINERS_GE = [CHOICE, INTERLEAVE, GROUP, ONEORMORE, ZEROORMORE, OPTIONAL, PARENTREF, REF,
        DEF, EXTERNALREF].freeze

      # xmlRelaxNGGetElements: gather elements (0), attributes (1) or elements and text (2)
      def get_elements(ctxt, defn, eora)
        ret = nil
        # Don't run that check in case of error. Infinite recursion becomes possible.
        return nil if ctxt.nb_errors != 0

        cur = defn
        while cur
          t = cur.type
          if (eora == 0 && (t == ELEMENT || t == TEXT)) ||
              (eora == 1 && t == ATTRIBUTE) ||
              (eora == 2 && (t == DATATYPE || t == ELEMENT || t == LIST || t == TEXT || t == VALUE))
            (ret ||= []) << cur
          elsif CONTAINERS_GE.include?(t)
            # Don't go within elements or attributes or string values.
            if cur.content
              parent = cur
              cur = cur.content
              tmp = cur
              while tmp
                tmp.parent = parent
                tmp = tmp.next
              end
              next
            end
          end
          break if cur.equal?(defn)

          if cur.next
            cur = cur.next
            next
          end
          loop do
            cur = cur.parent
            break if cur.nil?
            return ret if cur.equal?(defn)

            if cur.next
              cur = cur.next
              break
            end
          end
        end
        ret
      end

      # xmlRelaxNGCheckChoiceDeterminism
      def check_choice_determinism(ctxt, defn)
        return if defn.nil? || defn.type != CHOICE
        return if defn.dflags & IS_PROCESSED != 0
        # Don't run that check in case of error. Infinite recursion becomes possible.
        return if ctxt.nb_errors != 0

        is_indeterminist = 0
        is_triable = 1
        is_nullable = is_nullable(defn)

        list = []
        triage = nil
        if is_nullable == 0
          triage = Hash2.new
        else
          is_triable = 0
        end
        cur = defn.content
        while cur
          elems = get_elements(ctxt, cur, 0)
          list << elems
          if elems.nil? || elems.empty?
            is_triable = 0
          elsif is_triable == 1
            elems.each do |tmp|
              break if is_triable != 1

              if tmp.type == TEXT
                res = triage.add("#text", cur, nil)
                is_triable = -1 if res != 0
              elsif tmp.type == ELEMENT && tmp.name
                res = if tmp.ns.nil? || tmp.ns.empty?
                  triage.add(tmp.name, cur, nil)
                else
                  triage.add(tmp.name, cur, tmp.ns)
                end
                is_triable = -1 if res != 0
              elsif tmp.type == ELEMENT
                res = if tmp.ns.nil? || tmp.ns.empty?
                  triage.add("#any", cur, nil)
                else
                  triage.add("#any", cur, tmp.ns)
                end
                is_triable = -1 if res != 0
              else
                is_triable = -1
              end
            end
          end
          cur = cur.next
        end

        list.each_with_index do |li, i|
          next if li.nil?

          j = 0
          while j < i
            lj = list[j]
            if lj && compare_elem_def_lists(ctxt, li, lj) == 0
              is_indeterminist = 1
            end
            j += 1
          end
        end

        defn.dflags |= IS_INDETERMINIST if is_indeterminist != 0
        if is_triable == 1
          defn.dflags |= IS_TRIABLE
          defn.data = triage
        end
        defn.dflags |= IS_PROCESSED
      end

      # xmlRelaxNGCheckGroupAttrs
      def check_group_attrs(ctxt, defn)
        return if defn.nil? || (defn.type != GROUP && defn.type != ELEMENT)
        return if defn.dflags & IS_PROCESSED != 0
        # Don't run that check in case of error. Infinite recursion becomes possible.
        return if ctxt.nb_errors != 0

        list = []
        cur = defn.attrs
        while cur
          list << get_elements(ctxt, cur, 1)
          cur = cur.next
        end
        cur = defn.content
        while cur
          list << get_elements(ctxt, cur, 1)
          cur = cur.next
        end

        list.each_with_index do |li, i|
          next if li.nil?

          j = 0
          while j < i
            lj = list[j]
            if lj && compare_elem_def_lists(ctxt, li, lj) == 0
              p_err(ctxt, defn.node, ErrCode::RNGP_GROUP_ATTR_CONFLICT, "Attributes conflicts in group\n")
            end
            j += 1
          end
        end
        defn.dflags |= IS_PROCESSED
      end

      # xmlRelaxNGComputeInterleaves
      def compute_interleaves(ctxt, defn)
        # Don't run that check in case of error. Infinite recursion becomes possible.
        return if ctxt.nb_errors != 0

        is_mixed = 0
        is_determinist = 1
        groups = []
        cur = defn.content
        while cur
          is_mixed += 1 if cur.type == TEXT
          groups << InterleaveGroup.new(cur, get_elements(ctxt, cur, 2), get_elements(ctxt, cur, 1))
          cur = cur.next
        end
        nbgroups = groups.size

        # Let's check that all rules makes a partitions according to 7.4
        partitions = Partition.new
        partitions.nbgroups = nbgroups
        partitions.triage = Hash2.new
        i = 0
        while i < nbgroups
          group = groups[i]
          j = i + 1
          while j < nbgroups
            if groups[j]
              ret = compare_elem_def_lists(ctxt, group.defs, groups[j].defs)
              if ret == 0
                p_err(ctxt, defn.node, ErrCode::RNGP_ELEM_TEXT_CONFLICT, "Element or text conflicts in interleave\n")
              end
              ret = compare_elem_def_lists(ctxt, group.attrs, groups[j].attrs)
              if ret == 0
                p_err(ctxt, defn.node, ErrCode::RNGP_ATTR_CONFLICT, "Attributes conflicts in interleave\n")
              end
            end
            j += 1
          end
          tmp = group.defs
          if tmp && !tmp.empty?
            tmp.each do |t|
              if t.type == TEXT
                res = partitions.triage.add("#text", i + 1, nil)
                is_determinist = -1 if res != 0
              elsif t.type == ELEMENT && t.name
                res = if t.ns.nil? || t.ns.empty?
                  partitions.triage.add(t.name, i + 1, nil)
                else
                  partitions.triage.add(t.name, i + 1, t.ns)
                end
                is_determinist = -1 if res != 0
              elsif t.type == ELEMENT
                res = if t.ns.nil? || t.ns.empty?
                  partitions.triage.add("#any", i + 1, nil)
                else
                  partitions.triage.add("#any", i + 1, t.ns)
                end
                is_determinist = 2 if t.name_class
                is_determinist = -1 if res != 0
              else
                is_determinist = -1
              end
            end
          else
            is_determinist = 0
          end
          i += 1
        end
        partitions.groups = groups

        # and save the partition list back in the def
        defn.data = partitions
        defn.dflags |= IS_MIXED if is_mixed != 0
        partitions.flags = IS_DETERMINIST if is_determinist == 1
        partitions.flags = IS_DETERMINIST | IS_NEEDCHECK if is_determinist == 2
      end

      # xmlRelaxNGCheckCycles
      def check_cycles(ctxt, cur, depth)
        ret = 0
        while ret == 0 && cur
          if cur.type == REF || cur.type == PARENTREF
            if cur.depth == -1
              cur.depth = depth
              ret = check_cycles(ctxt, cur.content, depth)
              cur.depth = -2
            elsif depth == cur.depth
              p_err(ctxt, cur.node, ErrCode::RNGP_REF_CYCLE, "Detected a cycle in %s references\n", cur.name)
              return -1
            end
          elsif cur.type == ELEMENT
            ret = check_cycles(ctxt, cur.content, depth + 1)
          else
            ret = check_cycles(ctxt, cur.content, depth)
          end
          cur = cur.next
        end
        ret
      end

      # xmlRelaxNGTryUnlink
      def try_unlink(_ctxt, cur, parent, prev)
        if prev
          prev.next = cur.next
        elsif parent
          if parent.content.equal?(cur)
            parent.content = cur.next
          elsif parent.attrs.equal?(cur)
            parent.attrs = cur.next
          elsif parent.name_class.equal?(cur)
            parent.name_class = cur.next
          end
        else
          cur.type = NOOP
          prev = cur
        end
        prev
      end

      NOT_ALLOWED_PROPAGATES = [ATTRIBUTE, LIST, GROUP, INTERLEAVE, ONEORMORE, ZEROORMORE].freeze

      # xmlRelaxNGSimplify
      def simplify(ctxt, cur, parent)
        prev = nil
        while cur
          if cur.type == REF || cur.type == PARENTREF
            if cur.depth != -3
              cur.depth = -3
              simplify(ctxt, cur.content, cur)
            end
          elsif cur.type == NOT_ALLOWED
            cur.parent = parent
            if parent && NOT_ALLOWED_PROPAGATES.include?(parent.type)
              parent.type = NOT_ALLOWED
              break
            end
            prev = if parent && parent.type == CHOICE
              try_unlink(ctxt, cur, parent, prev)
            else
              cur
            end
          elsif cur.type == EMPTY
            cur.parent = parent
            if parent && (parent.type == ONEORMORE || parent.type == ZEROORMORE)
              parent.type = EMPTY
              break
            end
            prev = if parent && (parent.type == GROUP || parent.type == INTERLEAVE)
              try_unlink(ctxt, cur, parent, prev)
            else
              cur
            end
          else
            cur.parent = parent
            simplify(ctxt, cur.content, cur) if cur.content
            simplify(ctxt, cur.attrs, cur) if cur.type != VALUE && cur.attrs
            simplify(ctxt, cur.name_class, cur) if cur.name_class
            # On Elements, try to move attribute only generating rules on the attrs rules.
            if cur.type == ELEMENT
              while cur.content
                attronly = generate_attributes(ctxt, cur.content)
                if attronly == 1
                  # migrate cur->content to attrs
                  tmp = cur.content
                  cur.content = tmp.next
                  tmp.next = cur.attrs
                  cur.attrs = tmp
                else
                  # cur->content can generate elements or text
                  break
                end
              end
              pre = cur.content
              while pre && pre.next
                tmp = pre.next
                attronly = generate_attributes(ctxt, tmp)
                if attronly == 1
                  # migrate tmp to attrs
                  pre.next = tmp.next
                  tmp.next = cur.attrs
                  cur.attrs = tmp
                else
                  pre = tmp
                end
              end
            end
            # This may result in a simplification
            if cur.type == GROUP || cur.type == INTERLEAVE
              if cur.content.nil?
                cur.type = EMPTY
              elsif cur.content.next.nil?
                if parent.nil? && prev.nil?
                  cur.type = NOOP
                elsif prev.nil?
                  parent.content = cur.content
                  cur.content.next = cur.next
                  cur = cur.content
                else
                  cur.content.next = cur.next
                  prev.next = cur.content
                  cur = cur.content
                end
              end
            end
            # the current node may have been transformed back
            if cur.type == EXCEPT && cur.content && cur.content.type == NOT_ALLOWED
              prev = try_unlink(ctxt, cur, parent, prev)
            elsif cur.type == NOT_ALLOWED
              if parent && NOT_ALLOWED_PROPAGATES.include?(parent.type)
                parent.type = NOT_ALLOWED
                break
              end
              prev = if parent && parent.type == CHOICE
                try_unlink(ctxt, cur, parent, prev)
              else
                cur
              end
            elsif cur.type == EMPTY
              if parent && (parent.type == ONEORMORE || parent.type == ZEROORMORE)
                parent.type = EMPTY
                break
              end
              prev = if parent && (parent.type == GROUP || parent.type == INTERLEAVE || parent.type == CHOICE)
                try_unlink(ctxt, cur, parent, prev)
              else
                cur
              end
            else
              prev = cur
            end
          end
          cur = cur.next
        end
      end

      # xmlRelaxNGGroupContentType
      def group_content_type(ct1, ct2)
        return CONTENT_ERROR if ct1 == CONTENT_ERROR || ct2 == CONTENT_ERROR
        return ct2 if ct1 == CONTENT_EMPTY
        return ct1 if ct2 == CONTENT_EMPTY
        return CONTENT_COMPLEX if ct1 == CONTENT_COMPLEX && ct2 == CONTENT_COMPLEX

        CONTENT_ERROR
      end

      # xmlRelaxNGMaxContentType
      def max_content_type(ct1, ct2)
        return CONTENT_ERROR if ct1 == CONTENT_ERROR || ct2 == CONTENT_ERROR
        return CONTENT_SIMPLE if ct1 == CONTENT_SIMPLE || ct2 == CONTENT_SIMPLE
        return CONTENT_COMPLEX if ct1 == CONTENT_COMPLEX || ct2 == CONTENT_COMPLEX

        CONTENT_EMPTY
      end

      # xmlRelaxNGCheckRules
      def check_rules(ctxt, cur, flags, ptype)
        val = CONTENT_EMPTY
        while cur
          ret = CONTENT_EMPTY
          case cur.type
          when REF, PARENTREF
            if flags & IN_DATAEXCEPT != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_DATA_EXCEPT_REF, "Found forbidden pattern data/except//ref\n")
            end
            if cur.content.nil?
              if cur.type == PARENTREF
                p_err(ctxt, cur.node, ErrCode::RNGP_REF_NO_DEF, "Internal found no define for parent refs\n")
              else
                p_err(ctxt, cur.node, ErrCode::RNGP_REF_NO_DEF, "Internal found no define for ref %s\n",
                  cur.name || "null")
              end
            end
            if cur.depth > -4
              cur.depth = -4
              ret = check_rules(ctxt, cur.content, flags, cur.type)
              cur.depth = ret - 15
            elsif cur.depth == -4
              ret = CONTENT_COMPLEX
            else
              ret = cur.depth + 15
            end
          when ELEMENT
            # The 7.3 Attribute derivation rule for groups is plugged there
            check_group_attrs(ctxt, cur)
            if flags & IN_DATAEXCEPT != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_DATA_EXCEPT_ELEM,
                "Found forbidden pattern data/except//element(ref)\n")
            end
            if flags & IN_LIST != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_LIST_ELEM, "Found forbidden pattern list//element(ref)\n")
            end
            if flags & IN_ATTRIBUTE != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_ATTR_ELEM,
                "Found forbidden pattern attribute//element(ref)\n")
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_ATTR_ELEM,
                "Found forbidden pattern attribute//element(ref)\n")
            end
            # reset since in the simple form elements are only child of grammar/define
            nflags = 0
            ret = check_rules(ctxt, cur.attrs, nflags, cur.type)
            if ret != CONTENT_EMPTY
              p_err(ctxt, cur.node, ErrCode::RNGP_ELEM_CONTENT_EMPTY,
                "Element %s attributes have a content type error\n", cur.name)
            end
            ret = check_rules(ctxt, cur.content, nflags, cur.type)
            if ret == CONTENT_ERROR
              p_err(ctxt, cur.node, ErrCode::RNGP_ELEM_CONTENT_ERROR, "Element %s has a content type error\n",
                cur.name)
            else
              ret = CONTENT_COMPLEX
            end
          when ATTRIBUTE
            if flags & IN_ATTRIBUTE != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_ATTR_ATTR, "Found forbidden pattern attribute//attribute\n")
            end
            if flags & IN_LIST != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_LIST_ATTR, "Found forbidden pattern list//attribute\n")
            end
            if flags & IN_OOMGROUP != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_ONEMORE_GROUP_ATTR,
                "Found forbidden pattern oneOrMore//group//attribute\n")
            end
            if flags & IN_OOMINTERLEAVE != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_ONEMORE_INTERLEAVE_ATTR,
                "Found forbidden pattern oneOrMore//interleave//attribute\n")
            end
            if flags & IN_DATAEXCEPT != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_DATA_EXCEPT_ATTR,
                "Found forbidden pattern data/except//attribute\n")
            end
            if flags & IN_START != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_START_ATTR, "Found forbidden pattern start//attribute\n")
            end
            if flags & IN_ONEORMORE == 0 && cur.name.nil? && cur.name_class.nil?
              if cur.ns.nil?
                p_err(ctxt, cur.node, ErrCode::RNGP_ANYNAME_ATTR_ANCESTOR,
                  "Found anyName attribute without oneOrMore ancestor\n")
              else
                p_err(ctxt, cur.node, ErrCode::RNGP_NSNAME_ATTR_ANCESTOR,
                  "Found nsName attribute without oneOrMore ancestor\n")
              end
            end
            nflags = flags | IN_ATTRIBUTE
            check_rules(ctxt, cur.content, nflags, cur.type)
            ret = CONTENT_EMPTY
          when ONEORMORE, ZEROORMORE
            if flags & IN_DATAEXCEPT != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_DATA_EXCEPT_ONEMORE,
                "Found forbidden pattern data/except//oneOrMore\n")
            end
            if flags & IN_START != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_START_ONEMORE, "Found forbidden pattern start//oneOrMore\n")
            end
            nflags = flags | IN_ONEORMORE
            ret = check_rules(ctxt, cur.content, nflags, cur.type)
            ret = group_content_type(ret, ret)
          when LIST
            if flags & IN_LIST != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_LIST_LIST, "Found forbidden pattern list//list\n")
            end
            if flags & IN_DATAEXCEPT != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_DATA_EXCEPT_LIST, "Found forbidden pattern data/except//list\n")
            end
            if flags & IN_START != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_START_LIST, "Found forbidden pattern start//list\n")
            end
            nflags = flags | IN_LIST
            ret = check_rules(ctxt, cur.content, nflags, cur.type)
          when GROUP
            if flags & IN_DATAEXCEPT != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_DATA_EXCEPT_GROUP, "Found forbidden pattern data/except//group\n")
            end
            if flags & IN_START != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_START_GROUP, "Found forbidden pattern start//group\n")
            end
            nflags = flags & IN_ONEORMORE != 0 ? flags | IN_OOMGROUP : flags
            ret = check_rules(ctxt, cur.content, nflags, cur.type)
            # The 7.3 Attribute derivation rule for groups is plugged there
            check_group_attrs(ctxt, cur)
          when INTERLEAVE
            if flags & IN_LIST != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_LIST_INTERLEAVE, "Found forbidden pattern list//interleave\n")
            end
            if flags & IN_DATAEXCEPT != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_DATA_EXCEPT_INTERLEAVE,
                "Found forbidden pattern data/except//interleave\n")
            end
            if flags & IN_START != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_DATA_EXCEPT_INTERLEAVE,
                "Found forbidden pattern start//interleave\n")
            end
            nflags = flags & IN_ONEORMORE != 0 ? flags | IN_OOMINTERLEAVE : flags
            ret = check_rules(ctxt, cur.content, nflags, cur.type)
          when EXCEPT
            nflags = cur.parent && cur.parent.type == DATATYPE ? flags | IN_DATAEXCEPT : flags
            ret = check_rules(ctxt, cur.content, nflags, cur.type)
          when DATATYPE
            if flags & IN_START != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_START_DATA, "Found forbidden pattern start//data\n")
            end
            check_rules(ctxt, cur.content, flags, cur.type)
            ret = CONTENT_SIMPLE
          when VALUE
            if flags & IN_START != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_START_VALUE, "Found forbidden pattern start//value\n")
            end
            check_rules(ctxt, cur.content, flags, cur.type)
            ret = CONTENT_SIMPLE
          when TEXT
            if flags & IN_LIST != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_LIST_TEXT, "Found forbidden pattern list//text\n")
            end
            if flags & IN_DATAEXCEPT != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_DATA_EXCEPT_TEXT, "Found forbidden pattern data/except//text\n")
            end
            if flags & IN_START != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_START_TEXT, "Found forbidden pattern start//text\n")
            end
            ret = CONTENT_COMPLEX
          when EMPTY
            if flags & IN_DATAEXCEPT != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_DATA_EXCEPT_EMPTY, "Found forbidden pattern data/except//empty\n")
            end
            if flags & IN_START != 0
              p_err(ctxt, cur.node, ErrCode::RNGP_PAT_START_EMPTY, "Found forbidden pattern start//empty\n")
            end
            ret = CONTENT_EMPTY
          when CHOICE
            check_choice_determinism(ctxt, cur)
            ret = check_rules(ctxt, cur.content, flags, cur.type)
          else
            ret = check_rules(ctxt, cur.content, flags, cur.type)
          end
          cur = cur.next
          if ptype == GROUP
            val = group_content_type(val, ret)
          elsif ptype == INTERLEAVE
            # the C code computes a value it never uses here
          elsif ptype == CHOICE
            val = max_content_type(val, ret)
          elsif ptype == LIST
            val = CONTENT_SIMPLE
          elsif ptype == EXCEPT
            val = ret == CONTENT_ERROR ? CONTENT_ERROR : CONTENT_SIMPLE
          else
            val = group_content_type(val, ret)
          end
        end
        val
      end
    end
  end
end
