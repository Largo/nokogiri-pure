# frozen_string_literal: true

# Port of libxslt pattern.c: compilation of XSLT match patterns into step lists (evaluated
# right-to-left), template registration by name/mode/type, and template lookup.

module Nokogiri
  module Pure
    module XSLT
      # xsltOp
      OP_END = 0
      OP_ROOT = 1
      OP_ELEM = 2
      OP_ATTR = 3
      OP_PARENT = 4
      OP_ANCESTOR = 5
      OP_ID = 6
      OP_KEY = 7
      OP_NS = 8
      OP_ALL = 9
      OP_PI = 10
      OP_COMMENT = 11
      OP_TEXT = 12
      OP_NODE = 13
      OP_PREDICATE = 14

      PAT_AXIS_CHILD = 1
      PAT_AXIS_ATTRIBUTE = 2

      # xsltStepOp
      class StepOp
        attr_accessor :op, :value, :value2, :value3, :comp

        def initialize(op, value, value2)
          @op = op
          @value = value
          @value2 = value2
          @value3 = nil
          @comp = nil
        end
      end

      # xsltCompMatch
      class CompMatch
        attr_accessor :next, :priority, :pattern, :mode, :mode_uri, :template, :node, :direct,
          :steps, :ns_list

        def initialize
          @steps = []
          @direct = false
          @priority = 0.0
        end

        def nb_step = @steps.length
      end

      # per transformation-context runtime cache of a step (the XSLT_RUNTIME_EXTRA slots)
      class StepCache
        attr_accessor :previous, :index, :len, :list

        def initialize
          @index = 0
          @len = 0
        end
      end

      # xsltParserContext (pattern compiler)
      class PatternParser
        attr_accessor :style, :ctxt, :s, :pos, :doc, :elem, :error, :comp, :novar

        def initialize(style, ctxt)
          @style = style
          @ctxt = ctxt
          @error = 0
        end

        def cur = @s.getbyte(@pos) || 0
        def nxt(n) = @s.getbyte(@pos + n) || 0

        def next!
          @pos += 1 if @pos < @s.bytesize
        end

        def skip_blanks
          while (c = @s.getbyte(@pos)) && (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D)
            @pos += 1
          end
        end

        # xsltGetUTF8CharZ at pos: [codepoint, len]; [-1, 0] on error / end ([0, 1] at end)
        def utf8_char_at(pos)
          c = @s.getbyte(pos)
          return [0, 1] if c.nil?

          XSLT.get_utf8_char(@s, pos)
        end

        def push(op, value, value2)
          comp = @comp
          step = StepOp.new(op, value, value2)
          if op == OP_PREDICATE
            flags = @novar ? XPath::XML_XPATH_NOVAR : 0
            step.comp = XSLT.xpath_compile_flags(@style, value, flags)
            if step.comp.nil?
              XSLT.transform_error(nil, @style, @elem, "Failed to compile predicate\n")
              @style.errors += 1 if @style
            end
          end
          comp.steps << step
        end

        # xsltSwapTopCompMatch
        def swap_top
          st = @comp.steps
          j = st.length - 1
          st[j - 1], st[j] = st[j], st[j - 1] if j > 0
        end

        def u8(b) = b.nil? ? nil : b.dup.force_encoding(Encoding::UTF_8)

        # xsltScanLiteral
        def scan_literal
          skip_blanks
          q = cur
          if q == 0x22 || q == 0x27
            next!
            start = @pos
            p = @pos
            val, len = utf8_char_at(p)
            while val > 0 && XPath::Chars.char?(val) && val != q
              p += len
              val, len = utf8_char_at(p)
            end
            if val <= 0 || !XPath::Chars.char?(val)
              @error = 1
              return nil
            end
            ret = u8(@s.byteslice(start, p - start))
            @pos = p + len
            ret
          else
            @error = 1
            nil
          end
        end

        # xsltScanNCName
        def scan_ncname
          skip_blanks
          p = @pos
          val, len = utf8_char_at(p)
          return nil unless val > 0 && (XPath::Chars.letter?(val) || val == 0x5F)

          while val > 0 && (XPath::Chars.letter?(val) || XPath::Chars.digit?(val) || val == 0x2E ||
                val == 0x2D || val == 0x5F || XPath::Chars.combining?(val) || XPath::Chars.extender?(val))
            p += len
            val, len = utf8_char_at(p)
          end
          ret = u8(@s.byteslice(@pos, p - @pos))
          @pos = p
          ret
        end

        def err(msg)
          XSLT.transform_error(nil, nil, nil, msg)
          @error = 1
        end

        # xsltCompileIdKeyPattern
        def compile_id_key_pattern(name, aid, axis)
          if cur != 0x28
            err("xsltCompileIdKeyPattern : ( expected\n")
            return
          end
          if aid && name == "id"
            if axis != 0
              err("xsltCompileIdKeyPattern : NodeTest expected\n")
              return
            end
            next!
            skip_blanks
            lit = scan_literal
            if @error != 0
              XSLT.transform_error(nil, nil, nil, "xsltCompileIdKeyPattern : Literal expected\n")
              return
            end
            skip_blanks
            if cur != 0x29
              err("xsltCompileIdKeyPattern : ) expected\n")
              return
            end
            next!
            push(OP_ID, lit, nil)
          elsif aid && name == "key"
            if axis != 0
              err("xsltCompileIdKeyPattern : NodeTest expected\n")
              return
            end
            next!
            skip_blanks
            lit = scan_literal
            if @error != 0
              XSLT.transform_error(nil, nil, nil, "xsltCompileIdKeyPattern : Literal expected\n")
              return
            end
            skip_blanks
            if cur != 0x2C
              err("xsltCompileIdKeyPattern : , expected\n")
              return
            end
            next!
            skip_blanks
            lit2 = scan_literal
            if @error != 0
              XSLT.transform_error(nil, nil, nil, "xsltCompileIdKeyPattern : Literal expected\n")
              return
            end
            skip_blanks
            if cur != 0x29
              err("xsltCompileIdKeyPattern : ) expected\n")
              return
            end
            next!
            push(OP_KEY, lit, lit2)
          elsif name == "processing-instruction"
            next!
            skip_blanks
            lit = nil
            if cur != 0x29
              lit = scan_literal
              if @error != 0
                XSLT.transform_error(nil, nil, nil, "xsltCompileIdKeyPattern : Literal expected\n")
                return
              end
              skip_blanks
              if cur != 0x29
                err("xsltCompileIdKeyPattern : ) expected\n")
                return
              end
            end
            next!
            push(OP_PI, lit, nil)
          elsif name == "text"
            next!
            skip_blanks
            if cur != 0x29
              err("xsltCompileIdKeyPattern : ) expected\n")
              return
            end
            next!
            push(OP_TEXT, nil, nil)
          elsif name == "comment"
            next!
            skip_blanks
            if cur != 0x29
              err("xsltCompileIdKeyPattern : ) expected\n")
              return
            end
            next!
            push(OP_COMMENT, nil, nil)
          elsif name == "node"
            next!
            skip_blanks
            if cur != 0x29
              err("xsltCompileIdKeyPattern : ) expected\n")
              return
            end
            next!
            if axis == PAT_AXIS_ATTRIBUTE
              push(OP_ATTR, nil, nil)
            else
              push(OP_NODE, nil, nil)
            end
          elsif aid
            err("xsltCompileIdKeyPattern : expecting 'key' or 'id' or node type\n")
          else
            err("xsltCompileIdKeyPattern : node type\n")
          end
        end

        # xsltCompileStepPattern
        def compile_step_pattern(token)
          axis = 0
          skip_blanks
          if token.nil? && cur == 0x40
            next!
            axis = PAT_AXIS_ATTRIBUTE
          end
          loop do # parse_node_test
            token = scan_ncname if token.nil?
            if token.nil?
              if cur == 0x2A
                next!
                if axis == PAT_AXIS_ATTRIBUTE
                  push(OP_ATTR, nil, nil)
                else
                  push(OP_ALL, nil, nil)
                end
                break
              else
                err("xsltCompileStepPattern : Name expected\n")
                return
              end
            end
            skip_blanks
            if cur == 0x28
              compile_id_key_pattern(token, false, axis)
              return if @error != 0
            elsif cur == 0x3A
              next!
              if cur != 0x3A
                prefix = token
                token = scan_ncname
                ns = Tree.search_ns(@doc, @elem, prefix)
                if ns.nil?
                  err("xsltCompileStepPattern : no namespace bound to prefix #{prefix}\n")
                  return
                end
                url = ns.href
                if token.nil?
                  if cur == 0x2A
                    next!
                    if axis == PAT_AXIS_ATTRIBUTE
                      push(OP_ATTR, nil, url)
                    else
                      push(OP_NS, url, nil)
                    end
                  else
                    err("xsltCompileStepPattern : Name expected\n")
                    return
                  end
                elsif axis == PAT_AXIS_ATTRIBUTE
                  push(OP_ATTR, token, url)
                else
                  push(OP_ELEM, token, url)
                end
              else
                if axis != 0
                  err("xsltCompileStepPattern : NodeTest expected\n")
                  return
                end
                next!
                if token == "child"
                  axis = PAT_AXIS_CHILD
                elsif token == "attribute"
                  axis = PAT_AXIS_ATTRIBUTE
                else
                  err("xsltCompileStepPattern : 'child' or 'attribute' expected\n")
                  return
                end
                skip_blanks
                token = scan_ncname
                next # goto parse_node_test
              end
            else
              uri, token = XSLT.get_qname_uri(@elem, token)
              if token.nil?
                @error = 1
                return
              end
              if axis == PAT_AXIS_ATTRIBUTE
                push(OP_ATTR, token, uri)
              else
                push(OP_ELEM, token, uri)
              end
            end
            break
          end
          # parse_predicate:
          skip_blanks
          while cur == 0x5B
            level = 1
            next!
            q = @pos
            while cur != 0
              c = cur
              if c == 0x5B
                level += 1
              elsif c == 0x5D
                level -= 1
                break if level == 0
              elsif c == 0x22
                next!
                next! while cur != 0 && cur != 0x22
              elsif c == 0x27
                next!
                next! while cur != 0 && cur != 0x27
              end
              next!
            end
            if cur == 0
              err("xsltCompileStepPattern : ']' expected\n")
              return
            end
            ret = u8(@s.byteslice(q, @pos - q))
            push(OP_PREDICATE, ret, nil)
            swap_top
            next!
            skip_blanks
          end
        end

        # xsltCompileRelativePathPattern
        def compile_relative_path_pattern(token)
          compile_step_pattern(token)
          return if @error != 0

          skip_blanks
          while cur != 0 && cur != 0x7C
            if cur == 0x2F && nxt(1) == 0x2F
              push(OP_ANCESTOR, nil, nil)
              next!
              next!
              skip_blanks
              compile_step_pattern(nil)
            elsif cur == 0x2F
              push(OP_PARENT, nil, nil)
              next!
              skip_blanks
              compile_step_pattern(nil)
            else
              @error = 1
            end
            return if @error != 0

            skip_blanks
          end
        end

        NODE_TYPES = %w[comment text processing-instruction node].freeze

        # xsltCompileLocationPathPattern
        def compile_location_path_pattern
          skip_blanks
          if cur == 0x2F && nxt(1) == 0x2F
            next!
            next!
            @comp.priority = 0.5
            compile_relative_path_pattern(nil)
          elsif cur == 0x2F
            next!
            skip_blanks
            push(OP_ROOT, nil, nil)
            if cur != 0 && cur != 0x7C
              push(OP_PARENT, nil, nil)
              compile_relative_path_pattern(nil)
            end
          elsif cur == 0x2A || cur == 0x40
            compile_relative_path_pattern(nil)
          else
            name = scan_ncname
            if name.nil?
              err("xsltCompileLocationPathPattern : Name expected\n")
              return
            end
            skip_blanks
            if cur == 0x28 && !NODE_TYPES.include?(name)
              compile_id_key_pattern(name, true, 0)
              return if @error != 0

              if cur == 0x2F && nxt(1) == 0x2F
                push(OP_ANCESTOR, nil, nil)
                next!
                next!
                skip_blanks
                compile_relative_path_pattern(nil)
              elsif cur == 0x2F
                push(OP_PARENT, nil, nil)
                next!
                skip_blanks
                compile_relative_path_pattern(nil)
              end
              return
            end
            compile_relative_path_pattern(name)
          end
        end
      end

      module_function

      # xsltReverseCompMatch
      def reverse_comp_match(comp)
        comp.steps.reverse!
        comp.steps << StepOp.new(OP_END, nil, nil)
        (0...(comp.nb_step - 1)).each do |i|
          if comp.steps[i].op == OP_PREDICATE && comp.steps[i + 1].op == OP_PREDICATE
            comp.direct = true
            comp.pattern = "//#{comp.pattern}" unless comp.pattern.start_with?("/")
            break
          end
        end
      end

      BLANK_BYTES = [0x20, 0x09, 0x0A, 0x0D].freeze

      # xsltCompilePatternInternal
      def compile_pattern_internal(pattern, doc, node, style, runtime, novar)
        if pattern.nil?
          transform_error(nil, nil, node, "xsltCompilePattern : NULL pattern\n")
          return nil
        end
        parser = PatternParser.new(style, runtime)
        parser.doc = doc
        parser.elem = node
        parser.novar = novar
        pat = pattern.b
        plen = pat.bytesize
        first = nil
        previous = nil
        current = 0
        endp = 0
        while current < plen
          start = current
          current += 1 while current < plen && BLANK_BYTES.include?(pat.getbyte(current))
          endp = current
          level = 0
          while endp < plen && (pat.getbyte(endp) != 0x7C || level != 0)
            c = pat.getbyte(endp)
            if c == 0x5B
              level += 1
            elsif c == 0x5D
              level -= 1
            elsif c == 0x27
              endp += 1
              endp += 1 while endp < plen && pat.getbyte(endp) != 0x27
            elsif c == 0x22
              endp += 1
              endp += 1 while endp < plen && pat.getbyte(endp) != 0x22
            end
            break if endp >= plen

            endp += 1
          end
          if current == endp
            transform_error(nil, nil, node, "xsltCompilePattern : NULL pattern\n")
            return nil
          end
          element = CompMatch.new
          if first.nil?
            first = element
          elsif previous
            previous.next = element
          end
          previous = element
          parser.comp = element
          base = pat.byteslice(start, endp - start)
          parser.s = base
          parser.pos = current - start
          element.pattern = base.dup.force_encoding(Encoding::UTF_8)
          element.node = node
          element.ns_list = Tree.get_ns_list(doc, node)
          element.priority = 0.0
          parser.compile_location_path_pattern
          if parser.error != 0
            transform_error(nil, style, node, "xsltCompilePattern : failed to compile '#{element.pattern}'\n")
            style.errors += 1 if style
            return nil
          end
          reverse_comp_match(element)
          if element.priority == 0
            s0 = element.steps[0]
            s1 = element.steps[1]
            if [OP_ELEM, OP_ATTR, OP_PI].include?(s0.op) && s0.value && s1.op == OP_END
              # previously preset
            elsif s0.op == OP_ATTR && s0.value2 && s1.op == OP_END
              element.priority = -0.25
            elsif s0.op == OP_NS && s0.value && s1.op == OP_END
              element.priority = -0.25
            elsif s0.op == OP_ATTR && s0.value.nil? && s0.value2.nil? && s1.op == OP_END
              element.priority = -0.5
            elsif [OP_PI, OP_TEXT, OP_ALL, OP_NODE, OP_COMMENT].include?(s0.op) && s1.op == OP_END
              element.priority = -0.5
            else
              element.priority = 0.5
            end
          end
          endp += 1 if pat.getbyte(endp) == 0x7C
          current = endp
        end
        if endp == 0
          transform_error(nil, style, node, "xsltCompilePattern : NULL pattern\n")
          style.errors += 1 if style
          return nil
        end
        first
      end

      # xsltCompilePattern
      def compile_pattern(pattern, doc, node, style, runtime)
        compile_pattern_internal(pattern, doc, node, style, runtime, false)
      end

      def step_cache(ctxt, sel)
        (ctxt.pattern_cache ||= {}.compare_by_identity)[sel] ||= StepCache.new
      end

      # xsltTestCompMatchDirect
      def test_comp_match_direct(ctxt, comp, node, ns_list)
        doc = node.doc
        is_rvt = res_tree_frag?(doc)
        sel = comp.steps[0]
        cache = step_cache(ctxt, sel)
        prevdoc = cache.previous
        ix = cache.index
        list = cache.list
        nocache = false
        if list.nil? || !prevdoc.equal?(doc)
          parent = node.parent
          xp = ctxt.xpath_ctxt
          oldnode = xp.node
          olddoc = xp.doc
          old_ns = xp.namespaces
          old_cs = xp.context_size
          old_cp = xp.proximity_position
          xp.node = node
          xp.doc = doc
          xp.namespaces = ns_list
          newlist = XPath.eval(comp.pattern, xp)
          xp.node = oldnode
          xp.doc = olddoc
          xp.namespaces = old_ns
          xp.context_size = old_cs
          xp.proximity_position = old_cp
          return -1 if newlist.nil?
          return -1 unless newlist.is_a?(Array) && !newlist.is_a?(XPath::ValueTree)

          ix = 0
          nocache = true if parent.nil? || node.doc.nil? || is_rvt
          if !nocache
            list = newlist
            cache.list = list
            cache.previous = doc
            cache.index = 0
          else
            list = newlist
          end
        end
        return 0 if list.empty?

        if ix == 0
          list.each { |n| return 1 if n.equal?(node) }
        end
        0
      end

      # xsltTestStepMatch
      def test_step_match(ctxt, node, step)
        case step.op
        when OP_ROOT
          t = node.type
          return 1 if t == DOCUMENT_NODE || t == HTML_DOCUMENT_NODE
          return 1 if t == ELEMENT_NODE && node.name.start_with?(" ")

          0
        when OP_ELEM
          return 0 if node.type != ELEMENT_NODE
          return 1 if step.value.nil?
          return 0 if step.value != node.name

          if node.ns.nil?
            return 0 if step.value2
          elsif node.ns.href
            return 0 if step.value2.nil? || step.value2 != node.ns.href
          end
          1
        when OP_ATTR
          return 0 if node.type != ATTRIBUTE_NODE
          return 0 if step.value && step.value != node.name

          if node.ns.nil?
            return 0 if step.value2
          elsif step.value2
            return 0 if step.value2 != node.ns.href
          end
          1
        when OP_ID
          return 0 if node.type != ELEMENT_NODE

          id = Tree.get_id(node.doc, step.value)
          return 0 if id.nil? || !id.parent.equal?(node)

          1
        when OP_KEY
          list = get_key(ctxt, step.value, step.value3, step.value2)
          return 0 if list.nil?
          return 0 unless list.any? { |n| n.equal?(node) }

          1
        when OP_NS
          return 0 if node.type != ELEMENT_NODE

          if node.ns.nil?
            return 0 if step.value
          elsif node.ns.href
            return 0 if step.value.nil? || step.value != node.ns.href
          end
          1
        when OP_ALL
          node.type == ELEMENT_NODE ? 1 : 0
        when OP_PI
          return 0 if node.type != PI_NODE
          return 0 if step.value && step.value != node.name

          1
        when OP_COMMENT
          node.type == COMMENT_NODE ? 1 : 0
        when OP_TEXT
          node.type == TEXT_NODE || node.type == CDATA_SECTION_NODE ? 1 : 0
        when OP_NODE
          case node.type
          when ELEMENT_NODE, CDATA_SECTION_NODE, PI_NODE, COMMENT_NODE, TEXT_NODE then 1
          else 0
          end
        else
          transform_error(ctxt, nil, node, "xsltTestStepMatch: unexpected step op #{step.op}\n")
          -1
        end
      end

      # xsltTestPredicateMatch
      def test_predicate_match(ctxt, comp, node, step, sel)
        return false if step.value.nil? || step.comp.nil? || sel.nil?

        doc = node.doc
        is_rvt = res_tree_frag?(doc)
        xp = ctxt.xpath_ctxt
        old_cs = xp.context_size
        old_cp = xp.proximity_position
        pos = 0
        len = 0
        cache = step_cache(ctxt, sel)
        nocache = false
        previous = cache.previous
        if previous && !previous.is_a?(XmlDoc) && previous.parent.equal?(node.parent)
          indx = 0
          sibling = node
          while sibling
            break if sibling.equal?(previous)

            indx += 1 if test_step_match(ctxt, sibling, sel) == 1
            sibling = sibling.prev
          end
          if sibling.nil?
            indx = 0
            sibling = node
            while sibling
              break if sibling.equal?(previous)

              indx -= 1 if test_step_match(ctxt, sibling, sel) == 1
              sibling = sibling.next
            end
          end
          if sibling
            pos = cache.index + indx
            if node.doc
              len = cache.len
              unless is_rvt
                cache.previous = node
                cache.index = pos
              end
            end
          else
            pos = 0
          end
        else
          parent = node.parent
          siblings = parent&.children
          while siblings
            if siblings.equal?(node)
              len += 1
              pos = len
            elsif test_step_match(ctxt, siblings, sel) == 1
              len += 1
            end
            siblings = siblings.next
          end
          if parent.nil? || node.doc.nil?
            nocache = true
          else
            parent = parent.parent while parent.parent
            if (parent.type != DOCUMENT_NODE && parent.type != HTML_DOCUMENT_NODE) || !parent.equal?(node.doc)
              nocache = true
            end
          end
        end
        if pos != 0
          xp.context_size = len
          xp.proximity_position = pos
          if !is_rvt && node.doc && !nocache
            cache.previous = node
            cache.index = pos
            cache.len = len
          end
        end
        old_node = ctxt.node
        ctxt.node = node
        match = eval_xpath_predicate(ctxt, step.comp, comp.ns_list)
        if pos != 0
          xp.context_size = old_cs
          xp.proximity_position = old_cp
        end
        ctxt.node = old_node
        match
      end

      # xsltTestCompMatch
      def test_comp_match(ctxt, comp, match_node, mode, mode_uri)
        node = match_node
        if comp.nil? || node.nil? || ctxt.nil?
          transform_error(ctxt, nil, node, "xsltTestCompMatch: null arg\n")
          return -1
        end
        if mode
          return 0 if comp.mode.nil? || comp.mode != mode
        elsif comp.mode
          return 0
        end
        if mode_uri
          return 0 if comp.mode_uri.nil? || comp.mode_uri != mode_uri
        elsif comp.mode_uri
          return 0
        end

        old_inst = ctxt.inst
        ctxt.inst = comp.node
        states = nil
        found = 0
        steps = comp.steps
        nb = steps.length
        sel = nil
        i = 0
        begin
          result = catch(:pattern_done) do
            loop do # restart
              rollback = false
              while i < nb
                step = steps[i]
                sel = step if step.op != OP_PREDICATE
                case step.op
                when OP_END
                  throw :pattern_done, 1
                when OP_PARENT
                  t = node.type
                  if t == DOCUMENT_NODE || t == HTML_DOCUMENT_NODE || node.is_a?(XmlNs)
                    rollback = true
                    break
                  end
                  node = node.parent
                  if node.nil?
                    rollback = true
                    break
                  end
                  if step.value.nil?
                    i += 1
                    next
                  end
                  if step.value != node.name ||
                      (node.ns.nil? ? !step.value2.nil? : (node.ns.href && (step.value2.nil? || step.value2 != node.ns.href)))
                    rollback = true
                    break
                  end
                  i += 1
                  next
                when OP_ANCESTOR
                  if step.value.nil?
                    step = steps[i + 1]
                    throw :pattern_done, 1 if step.op == OP_ROOT
                    unless [OP_ELEM, OP_ALL, OP_NS, OP_ID, OP_KEY].include?(step.op)
                      rollback = true
                      break
                    end
                  end
                  if node.nil?
                    rollback = true
                    break
                  end
                  t = node.type
                  if t == DOCUMENT_NODE || t == HTML_DOCUMENT_NODE || node.is_a?(XmlNs)
                    rollback = true
                    break
                  end
                  node = node.parent
                  if step.op != OP_ELEM && step.op != OP_ALL
                    (states ||= []) << [i, node]
                    i += 1
                    next
                  end
                  i += 1
                  sel = step
                  if step.value.nil?
                    (states ||= []) << [i - 1, node]
                    i += 1
                    next
                  end
                  while node
                    if node.type == ELEMENT_NODE && step.value == node.name
                      if node.ns.nil?
                        break if step.value2.nil?
                      elsif node.ns.href
                        break if step.value2 && step.value2 == node.ns.href
                      end
                    end
                    node = node.parent
                  end
                  if node.nil?
                    rollback = true
                    break
                  end
                  (states ||= []) << [i - 1, node]
                  i += 1
                  next
                when OP_PREDICATE
                  throw :pattern_done, test_comp_match_direct(ctxt, comp, match_node, comp.ns_list) if comp.direct

                  unless test_predicate_match(ctxt, comp, node, step, sel)
                    rollback = true
                    break
                  end
                else
                  if test_step_match(ctxt, node, step) != 1
                    rollback = true
                    break
                  end
                end
                i += 1
              end
              throw :pattern_done, 1 unless rollback

              # rollback:
              throw :pattern_done, 0 if states.nil? || states.empty?

              i, node = states.pop
            end
          end
          found = result
        ensure
          ctxt.inst = old_inst
        end
        found
      end

      # xsltTestCompMatchList
      def test_comp_match_list(ctxt, node, comp)
        return -1 if ctxt.nil? || node.nil?

        while comp
          return 1 if test_comp_match(ctxt, comp, node, nil, nil) == 1

          comp = comp.next
        end
        0
      end

      # xsltCompMatchClearCache
      def comp_match_clear_cache(ctxt, comp)
        return if ctxt.nil? || comp.nil?

        ctxt.pattern_cache&.delete(comp.steps[0])
      end

      def insert_by_priority(list, pat)
        if list.nil?
          pat.next = nil
          return pat
        end
        if list.priority <= pat.priority
          pat.next = list
          return pat
        end
        head = list
        list = list.next while list.next && list.next.priority > pat.priority
        pat.next = list.next
        list.next = pat
        head
      end

      # xsltAddTemplate
      def add_template(style, cur, mode, mode_uri)
        return -1 if style.nil? || cur.nil?

        cur.position = cur.next.position + 1 if cur.next

        if cur.name
          style.named_templates ||= {}
          if style.named_templates.key?([cur.name, cur.name_uri])
            transform_error(nil, style, cur.elem, "xsl:template: error duplicate name '#{cur.name}'\n")
            style.errors += 1
            return -1
          end
          style.named_templates[[cur.name, cur.name_uri]] = cur
        end

        if cur.match.nil?
          if cur.name.nil?
            transform_error(nil, style, cur.elem, "xsl:template: need to specify match or name attribute\n")
            style.errors += 1
            return -1
          end
          return 0
        end

        priority = cur.priority
        pat = compile_pattern_internal(cur.match, style.doc, cur.elem, style, nil, true)
        return -1 if pat.nil?

        while pat
          nxt = pat.next
          pat.next = nil
          name = nil
          top = nil
          pat.template = cur
          pat.mode = mode if mode
          pat.mode_uri = mode_uri if mode_uri
          pat.priority = priority if priority != PAT_NO_PRIORITY
          s0 = pat.steps[0]
          case s0.op
          when OP_ATTR
            if s0.value
              name = s0.value
            else
              top = :attr_match
            end
          when OP_PARENT, OP_ANCESTOR, OP_ID, OP_NS, OP_ALL
            top = :elem_match
          when OP_ROOT
            top = :root_match
          when OP_KEY
            top = :key_match
          when OP_END, OP_PREDICATE
            transform_error(nil, style, nil, "xsltAddTemplate: invalid compiled pattern\n")
            return -1
          when OP_PI
            if s0.value
              name = s0.value
            else
              top = :pi_match
            end
          when OP_COMMENT
            top = :comment_match
          when OP_TEXT
            top = :text_match
          when OP_ELEM, OP_NODE
            if s0.value
              name = s0.value
            else
              top = :elem_match
            end
          end
          if name
            style.templates_hash ||= {}
            key = [name, mode, mode_uri]
            style.templates_hash[key] = insert_by_priority(style.templates_hash[key], pat)
          elsif top
            style.__send__(:"#{top}=", insert_by_priority(style.__send__(top), pat))
          end
          pat = nxt
        end
        0
      end

      # xsltComputeAllKeys
      def compute_all_keys(ctxt, context_node)
        if ctxt.nil? || context_node.nil?
          transform_error(ctxt, nil, ctxt&.inst, "Internal error in xsltComputeAllKeys(): Bad arguments.\n")
          return -1
        end
        if ctxt.document.nil?
          if context_node.doc._private.is_a?(Document)
            transform_error(ctxt, nil, ctxt.inst,
              "Internal error in xsltComputeAllKeys(): The context's document info doesn't match the " \
              "document info of the current result tree.\n")
            ctxt.state = STATE_STOPPED
            return -1
          end
          ctxt.document = new_document(ctxt, context_node.doc)
        end
        init_all_doc_keys(ctxt)
      end

      def match_list_scan(ctxt, list, node, ret, priority)
        while list && (ret.nil? || list.priority > priority ||
                       (list.priority == priority && list.template.position > ret.position))
          if test_comp_match(ctxt, list, node, ctxt.mode, ctxt.mode_uri) == 1
            return [list.template, list.priority]
          end

          list = list.next
        end
        [ret, priority]
      end

      # xsltGetTemplate
      def get_template(ctxt, node, style)
        return nil if ctxt.nil? || node.nil?

        curstyle = style.nil? ? ctxt.style : next_import(style)
        name = nil
        while curstyle && !curstyle.equal?(style)
          priority = PAT_NO_PRIORITY
          ret = nil
          if curstyle.templates_hash
            case node.type
            when ELEMENT_NODE
              name = node.name unless node.name.start_with?(" ")
            when ATTRIBUTE_NODE, PI_NODE
              name = node.name
            end
          end
          list = name ? curstyle.templates_hash&.[]([name, ctxt.mode, ctxt.mode_uri]) : nil
          while list
            if test_comp_match(ctxt, list, node, ctxt.mode, ctxt.mode_uri) == 1
              ret = list.template
              priority = list.priority
              break
            end
            list = list.next
          end

          list = case node.type
          when ELEMENT_NODE
            node.name.start_with?(" ") ? curstyle.root_match : curstyle.elem_match
          when ATTRIBUTE_NODE then curstyle.attr_match
          when PI_NODE then curstyle.pi_match
          when DOCUMENT_NODE, HTML_DOCUMENT_NODE then curstyle.root_match
          when TEXT_NODE, CDATA_SECTION_NODE then curstyle.text_match
          when COMMENT_NODE then curstyle.comment_match
          end
          ret, priority = match_list_scan(ctxt, list, node, ret, priority)

          case node.type
          when DOCUMENT_NODE, HTML_DOCUMENT_NODE, TEXT_NODE, PI_NODE, COMMENT_NODE
            ret, priority = match_list_scan(ctxt, curstyle.elem_match, node, ret, priority)
          end

          loop do # keyed_match
            if (get_source_node_flags(ctxt, node) & SOURCE_NODE_HAS_KEY) != 0
              ret, priority = match_list_scan(ctxt, curstyle.key_match, node, ret, priority)
            elsif ctxt.has_templ_key_patterns &&
                (ctxt.document.nil? || ctxt.document.nb_keys_computed < ctxt.nb_keys)
              return nil if compute_all_keys(ctxt, node) == -1
              next if (get_source_node_flags(ctxt, node) & SOURCE_NODE_HAS_KEY) != 0
            end
            break
          end
          return ret if ret

          curstyle = next_import(curstyle)
        end
        nil
      end

      # xsltGetSourceNodeFlags
      def get_source_node_flags(ctxt, node)
        ctxt.source_flags[node] || 0
      end

      # xsltSetSourceNodeFlags
      def set_source_node_flags(ctxt, node, flags)
        ctxt.source_doc_dirty = true if node.doc.equal?(ctxt.initial_context_doc)
        case node.type
        when DOCUMENT_NODE, HTML_DOCUMENT_NODE, ATTRIBUTE_NODE, ELEMENT_NODE, TEXT_NODE,
             CDATA_SECTION_NODE, PI_NODE, COMMENT_NODE
          ctxt.source_flags[node] = (ctxt.source_flags[node] || 0) | flags
          0
        else
          -1
        end
      end
    end
  end
end
