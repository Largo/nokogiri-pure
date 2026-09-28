# frozen_string_literal: true

require_relative "structs"
require_relative "../html_parser/chvalid"

# Port of the parts of libxml2 2.13.9 pattern.c used by xmlschemas.c for identity-constraint
# selectors/fields: xmlPatterncompile (XML_PATTERN_XSSEL / XML_PATTERN_XSFIELD flavours and the
# generic path pattern), xmlPatternGetStreamCtxt, xmlStreamPush, xmlStreamPushAttr, xmlStreamPop.
module Nokogiri
  module Pure
    module Schemas
      XML_PATTERN_DEFAULT = 0
      XML_PATTERN_XPATH = 1 << 0
      XML_PATTERN_XSSEL = 1 << 1
      XML_PATTERN_XSFIELD = 1 << 2

      module Pattern
        extend self

        XML_STREAM_STEP_DESC = 1
        XML_STREAM_STEP_FINAL = 2
        XML_STREAM_STEP_ROOT = 4
        XML_STREAM_STEP_ATTR = 8
        XML_STREAM_STEP_NODE = 16
        XML_STREAM_STEP_IN_SET = 32

        XML_STREAM_FINAL_IS_ANY_NODE = 1 << 14
        XML_STREAM_FROM_ROOT = 1 << 15
        XML_STREAM_DESC = 1 << 16

        XML_STREAM_ANY_NODE = 100

        XML_PATTERN_NOTPATTERN = XML_PATTERN_XPATH | XML_PATTERN_XSSEL | XML_PATTERN_XSFIELD

        XML_OP_END = 0
        XML_OP_ROOT = 1
        XML_OP_ELEM = 2
        XML_OP_CHILD = 3
        XML_OP_ATTR = 4
        XML_OP_PARENT = 5
        XML_OP_ANCESTOR = 6
        XML_OP_NS = 7
        XML_OP_ALL = 8

        PAT_FROM_ROOT = 1 << 8
        PAT_FROM_CUR = 1 << 9

        XML_XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace"

        StreamStep = Struct.new(:flags, :name, :ns, :node_type)
        StreamComp = Struct.new(:steps, :flags)
        StreamCtxt = Struct.new(:next, :comp, :states, :nb_state, :level, :flags, :block_level)
        StepOp = Struct.new(:op, :value, :value2)
        PatternC = Struct.new(:next, :pattern, :flags, :steps, :stream)

        class PatError < StandardError; end

        class ParserCtxt
          attr_accessor :cps, :pos, :base, :error, :comp, :namespaces, :nb_namespaces

          def cur = @cps[@pos] || 0
          def nxt(n) = @cps[@pos + n] || 0
          def peekprev(n) = @cps[@pos - n] || 0

          def next!
            @pos += 1 if @pos < @cps.size
          end

          def skip_blanks
            while (c = cur) == 0x20 || c == 0x9 || c == 0xA || c == 0xD
              @pos += 1
            end
          end
        end

        def blank_ch?(c) = c == 0x20 || c == 0x9 || c == 0xA || c == 0xD

        # PUSH(op, val, val2)
        def push(ctxt, op, val, val2)
          ctxt.comp.steps << StepOp.new(op, val, val2)
        end

        def name_char?(val)
          ChValid.letter?(val) || ChValid.digit?(val) || val == 0x2E || val == 0x2D || val == 0x5F ||
            ChValid.combining?(val) || ChValid.extender?(val)
        end

        ChValid = HTMLParser::ChValid

        # xmlPatScanName
        def scan_name(ctxt)
          ctxt.skip_blanks
          q = ctxt.pos
          val = ctxt.cur
          return nil if !ChValid.letter?(val) && val != 0x5F && val != 0x3A

          ctxt.pos += 1 while name_char?(ctxt.cur) && ctxt.cur != 0
          ctxt.cps[q...ctxt.pos].pack("U*")
        end

        # xmlPatScanNCName
        def scan_ncname(ctxt)
          ctxt.skip_blanks
          q = ctxt.pos
          val = ctxt.cur
          return nil if !ChValid.letter?(val) && val != 0x5F

          ctxt.pos += 1 while name_char?(ctxt.cur) && ctxt.cur != 0
          ctxt.cps[q...ctxt.pos].pack("U*")
        end

        def lookup_prefix(ctxt, prefix)
          return XML_XML_NAMESPACE if prefix == "xml"

          ctxt.nb_namespaces.times do |i|
            return ctxt.namespaces[2 * i] if ctxt.namespaces[2 * i + 1] == prefix
          end
          nil
        end

        # xmlCompileAttributeTest
        def compile_attribute_test(ctxt)
          ctxt.skip_blanks
          name = scan_ncname(ctxt)
          if name.nil?
            if ctxt.cur == 0x2A # '*'
              push(ctxt, XML_OP_ATTR, nil, nil)
              ctxt.next!
            else
              ctxt.error = 1
            end
            return
          end
          if ctxt.cur == 0x3A # ':'
            prefix = name
            ctxt.next!
            if blank_ch?(ctxt.cur)
              ctxt.error = 1
              return
            end
            token = scan_name(ctxt)
            url = lookup_prefix(ctxt, prefix)
            if url.nil?
              ctxt.error = 1
              return
            end
            if token.nil?
              if ctxt.cur == 0x2A
                ctxt.next!
                push(ctxt, XML_OP_ATTR, nil, url)
              else
                ctxt.error = 1
                return
              end
            else
              push(ctxt, XML_OP_ATTR, token, url)
            end
          else
            push(ctxt, XML_OP_ATTR, name, nil)
          end
        end

        # xmlCompileStepPattern
        def compile_step_pattern(ctxt)
          has_blanks = false
          ctxt.skip_blanks
          if ctxt.cur == 0x2E # '.'
            ctxt.next!
            push(ctxt, XML_OP_ELEM, nil, nil)
            return
          end
          if ctxt.cur == 0x40 # '@'
            if (ctxt.comp.flags & XML_PATTERN_XSSEL) != 0
              ctxt.error = 1
              return
            end
            ctxt.next!
            compile_attribute_test(ctxt)
            return
          end
          name = scan_ncname(ctxt)
          if name.nil?
            if ctxt.cur == 0x2A
              ctxt.next!
              push(ctxt, XML_OP_ALL, nil, nil)
            else
              ctxt.error = 1
            end
            return
          end
          if blank_ch?(ctxt.cur)
            has_blanks = true
            ctxt.skip_blanks
          end
          if ctxt.cur == 0x3A # ':'
            ctxt.next!
            if ctxt.cur != 0x3A
              prefix = name
              if has_blanks || blank_ch?(ctxt.cur)
                ctxt.error = 1
                return
              end
              token = scan_name(ctxt)
              url = lookup_prefix(ctxt, prefix)
              if url.nil?
                ctxt.error = 1
                return
              end
              if token.nil?
                if ctxt.cur == 0x2A
                  ctxt.next!
                  push(ctxt, XML_OP_NS, url, nil)
                else
                  ctxt.error = 1
                  return
                end
              else
                push(ctxt, XML_OP_ELEM, token, url)
              end
            else
              ctxt.next!
              if name == "child"
                name = scan_name(ctxt)
                if name.nil?
                  if ctxt.cur == 0x2A
                    ctxt.next!
                    push(ctxt, XML_OP_ALL, nil, nil)
                  else
                    ctxt.error = 1
                  end
                  return
                end
                if ctxt.cur == 0x3A
                  prefix = name
                  ctxt.next!
                  if blank_ch?(ctxt.cur)
                    ctxt.error = 1
                    return
                  end
                  token = scan_name(ctxt)
                  url = lookup_prefix(ctxt, prefix)
                  if url.nil?
                    ctxt.error = 1
                    return
                  end
                  if token.nil?
                    if ctxt.cur == 0x2A
                      ctxt.next!
                      push(ctxt, XML_OP_NS, url, nil)
                    else
                      ctxt.error = 1
                      return
                    end
                  else
                    push(ctxt, XML_OP_ELEM, token, url)
                  end
                else
                  push(ctxt, XML_OP_ELEM, name, nil)
                end
                return
              elsif name == "attribute"
                if (ctxt.comp.flags & XML_PATTERN_XSSEL) != 0
                  ctxt.error = 1
                  return
                end
                compile_attribute_test(ctxt)
                return
              else
                ctxt.error = 1
                return
              end
            end
          elsif ctxt.cur == 0x2A
            # name != NULL here
            ctxt.error = 1
            return
          else
            push(ctxt, XML_OP_ELEM, name, nil)
          end
        end

        # xmlCompilePathPattern
        def compile_path_pattern(ctxt)
          ctxt.skip_blanks
          if ctxt.cur == 0x2F
            ctxt.comp.flags |= PAT_FROM_ROOT
          elsif ctxt.cur == 0x2E || (ctxt.comp.flags & XML_PATTERN_NOTPATTERN) != 0
            ctxt.comp.flags |= PAT_FROM_CUR
          end

          if ctxt.cur == 0x2F && ctxt.nxt(1) == 0x2F
            push(ctxt, XML_OP_ANCESTOR, nil, nil)
            ctxt.next!
            ctxt.next!
          elsif ctxt.cur == 0x2E && ctxt.nxt(1) == 0x2F && ctxt.nxt(2) == 0x2F
            push(ctxt, XML_OP_ANCESTOR, nil, nil)
            3.times { ctxt.next! }
            ctxt.skip_blanks
            if ctxt.cur == 0
              ctxt.error = 1
              return
            end
          end
          if ctxt.cur == 0x40
            ctxt.next!
            compile_attribute_test(ctxt)
            return if ctxt.error != 0

            ctxt.skip_blanks
            if ctxt.cur != 0
              compile_step_pattern(ctxt)
              return if ctxt.error != 0
            end
          else
            if ctxt.cur == 0x2F
              push(ctxt, XML_OP_ROOT, nil, nil)
              ctxt.next!
              ctxt.skip_blanks
              if ctxt.cur == 0
                ctxt.error = 1
                return
              end
            end
            compile_step_pattern(ctxt)
            return if ctxt.error != 0

            ctxt.skip_blanks
            while ctxt.cur == 0x2F
              if ctxt.nxt(1) == 0x2F
                push(ctxt, XML_OP_ANCESTOR, nil, nil)
                ctxt.next!
                ctxt.next!
                ctxt.skip_blanks
                compile_step_pattern(ctxt)
                return if ctxt.error != 0
              else
                push(ctxt, XML_OP_PARENT, nil, nil)
                ctxt.next!
                ctxt.skip_blanks
                if ctxt.cur == 0
                  ctxt.error = 1
                  return
                end
                compile_step_pattern(ctxt)
                return if ctxt.error != 0
              end
            end
          end
          ctxt.error = 1 if ctxt.cur != 0
        end

        # xmlCompileIDCXPathPath
        def compile_idc_xpath_path(ctxt)
          ctxt.skip_blanks
          if ctxt.cur == 0x2F
            ctxt.error = 1
            return
          end
          ctxt.comp.flags |= PAT_FROM_CUR

          if ctxt.cur == 0x2E
            ctxt.next!
            ctxt.skip_blanks
            if ctxt.cur == 0
              push(ctxt, XML_OP_ELEM, nil, nil)
              return
            end
            if ctxt.cur != 0x2F
              ctxt.error = 1
              return
            end
            ctxt.next!
            ctxt.skip_blanks
            if ctxt.cur == 0x2F
              if blank_ch?(ctxt.peekprev(1))
                ctxt.error = 1
                return
              end
              push(ctxt, XML_OP_ANCESTOR, nil, nil)
              ctxt.next!
              ctxt.skip_blanks
            end
            if ctxt.cur == 0
              ctxt.error = 1
              return
            end
          end
          loop do
            compile_step_pattern(ctxt)
            if ctxt.error != 0
              ctxt.error = 1
              return
            end
            ctxt.skip_blanks
            break if ctxt.cur != 0x2F

            push(ctxt, XML_OP_PARENT, nil, nil)
            ctxt.next!
            ctxt.skip_blanks
            if ctxt.cur == 0x2F
              ctxt.error = 1
              return
            end
            if ctxt.cur == 0
              ctxt.error = 1
              return
            end
            break if ctxt.cur == 0
          end
          ctxt.error = 1 if ctxt.cur != 0
        end

        # xmlStreamCompAddStep
        def stream_comp_add_step(stream, name, ns, node_type, flags)
          stream.steps << StreamStep.new(flags, name, ns, node_type)
          stream.steps.size - 1
        end

        # xmlStreamCompile
        def stream_compile(comp)
          steps = comp.steps
          if steps.size == 1 && steps[0].op == XML_OP_ELEM && steps[0].value.nil? && steps[0].value2.nil?
            stream = StreamComp.new([], 0)
            stream.flags |= XML_STREAM_FINAL_IS_ANY_NODE
            comp.stream = stream
            return 0
          end
          stream = StreamComp.new([], 0)
          s = 0
          root = false
          flags = 0
          prevs = -1
          stream.flags |= XML_STREAM_FROM_ROOT if (comp.flags & PAT_FROM_ROOT) != 0
          nb = steps.size
          i = 0
          while i < nb
            step = steps[i]
            case step.op
            when XML_OP_END
              nil
            when XML_OP_ROOT
              return 0 if i != 0 # error: stream freed, comp.stream stays nil

              root = true
            when XML_OP_NS
              s = stream_comp_add_step(stream, nil, step.value, ELEMENT_NODE, flags)
              prevs = s
              flags = 0
            when XML_OP_ATTR
              flags |= XML_STREAM_STEP_ATTR
              prevs = -1
              s = stream_comp_add_step(stream, step.value, step.value2, ATTRIBUTE_NODE, flags)
              flags = 0
            when XML_OP_ELEM
              if step.value.nil? && step.value2.nil?
                if nb == i + 1 && (flags & XML_STREAM_STEP_DESC) != 0
                  stream.flags |= XML_STREAM_FINAL_IS_ANY_NODE if nb == i + 1
                  flags |= XML_STREAM_STEP_NODE
                  s = stream_comp_add_step(stream, nil, nil, XML_STREAM_ANY_NODE, flags)
                  flags = 0
                  if prevs != -1
                    stream.steps[prevs].flags |= XML_STREAM_STEP_IN_SET
                    prevs = -1
                  end
                else
                  i += 1
                  next
                end
              else
                s = stream_comp_add_step(stream, step.value, step.value2, ELEMENT_NODE, flags)
                prevs = s
                flags = 0
              end
            when XML_OP_CHILD
              s = stream_comp_add_step(stream, step.value, step.value2, ELEMENT_NODE, flags)
              prevs = s
              flags = 0
            when XML_OP_ALL
              s = stream_comp_add_step(stream, nil, nil, ELEMENT_NODE, flags)
              prevs = s
              flags = 0
            when XML_OP_PARENT
              nil
            when XML_OP_ANCESTOR
              if (flags & XML_STREAM_STEP_DESC) == 0
                flags |= XML_STREAM_STEP_DESC
                stream.flags |= XML_STREAM_DESC if (stream.flags & XML_STREAM_DESC) == 0
              end
            end
            i += 1
          end
          if !root && (comp.flags & XML_PATTERN_NOTPATTERN) == 0
            stream.flags |= XML_STREAM_DESC if (stream.flags & XML_STREAM_DESC) == 0
            if stream.steps.size > 0 && (stream.steps[0].flags & XML_STREAM_STEP_DESC) == 0
              stream.steps[0].flags |= XML_STREAM_STEP_DESC
            end
          end
          return 0 if stream.steps.size <= s

          stream.steps[s].flags |= XML_STREAM_STEP_FINAL
          stream.steps[0].flags |= XML_STREAM_STEP_ROOT if root
          comp.stream = stream
          0
        end

        # xmlReversePattern
        def reverse_pattern(comp)
          steps = comp.steps
          steps.shift if steps.size > 0 && steps[0].op == XML_OP_ANCESTOR
          steps.reverse!
          steps << StepOp.new(XML_OP_END, nil, nil)
          0
        end

        # xmlPatterncompile(pattern, dict, flags, namespaces) -> PatternC or nil
        # namespaces: flat Array [href, prefix, href, prefix, ...] (or nil)
        def pattern_compile(pattern, _dict, flags, namespaces)
          return nil if pattern.nil?

          nb_ns = 0
          if namespaces
            nb_ns += 1 while namespaces[2 * nb_ns]
          end
          ret = nil
          type = 0
          streamable = true
          cps = pattern.unpack("U*")
          start = 0
          while start < cps.size
            orp = start
            orp += 1 while orp < cps.size && cps[orp] != 0x7C
            sub = cps[start...orp]
            ctxt = ParserCtxt.new
            ctxt.cps = sub
            ctxt.pos = 0
            ctxt.error = 0
            ctxt.namespaces = namespaces
            ctxt.nb_namespaces = nb_ns
            cur = PatternC.new(nil, pattern, flags, [], nil)
            if ret.nil?
              ret = cur
            else
              cur.next = ret.next
              ret.next = cur
            end
            ctxt.comp = cur
            if (cur.flags & (XML_PATTERN_XSSEL | XML_PATTERN_XSFIELD)) != 0
              compile_idc_xpath_path(ctxt)
            else
              compile_path_pattern(ctxt)
            end
            return nil if ctxt.error != 0

            if streamable
              if type == 0
                type = cur.flags & (PAT_FROM_ROOT | PAT_FROM_CUR)
              elsif type == PAT_FROM_ROOT
                streamable = false if (cur.flags & PAT_FROM_CUR) != 0
              elsif type == PAT_FROM_CUR
                streamable = false if (cur.flags & PAT_FROM_ROOT) != 0
              end
            end
            stream_compile(cur) if streamable
            reverse_pattern(cur)
            start = orp < cps.size ? orp + 1 : orp
          end
          unless streamable
            c = ret
            while c
              c.stream = nil
              c = c.next
            end
          end
          ret
        end

        # xmlPatternGetStreamCtxt
        def pattern_get_stream_ctxt(comp)
          return nil if comp.nil? || comp.stream.nil?

          ret = nil
          while comp
            return nil if comp.stream.nil?

            cur = StreamCtxt.new(nil, comp.stream, [], 0, 0, comp.flags, -1)
            if ret.nil?
              ret = cur
            else
              cur.next = ret.next
              ret.next = cur
            end
            comp = comp.next
          end
          ret
        end

        # xmlStreamCtxtAddState
        def stream_ctxt_add_state(comp, idx, level)
          states = comp.states
          i = 0
          while i < comp.nb_state
            if states[2 * i] < 0
              states[2 * i] = idx
              states[2 * i + 1] = level
              return i
            end
            i += 1
          end
          states[2 * comp.nb_state] = idx
          states[2 * comp.nb_state + 1] = level
          comp.nb_state += 1
          comp.nb_state - 1
        end

        def step_match(step, name, ns)
          if step.node_type == XML_STREAM_ANY_NODE
            true
          elsif step.name.nil?
            if step.ns.nil?
              true
            elsif !ns.nil?
              step.ns == ns
            else
              false
            end
          else
            (!step.ns.nil?) == (!ns.nil?) && !name.nil? && step.name == name && step.ns == ns
          end
        end

        # xmlStreamPushInternal
        def stream_push_internal(stream, name, ns, node_type)
          return -1 if stream.nil? || stream.nb_state < 0

          ret = 0
          while stream
            comp = stream.comp
            if node_type == ELEMENT_NODE && name.nil? && ns.nil?
              stream.nb_state = 0
              stream.level = 0
              stream.block_level = -1
              if (comp.flags & XML_STREAM_FROM_ROOT) != 0
                if comp.steps.empty?
                  ret = 1
                elsif comp.steps.size == 1 && comp.steps[0].node_type == XML_STREAM_ANY_NODE &&
                    (comp.steps[0].flags & XML_STREAM_STEP_DESC) != 0
                  ret = 1
                elsif (comp.steps[0].flags & XML_STREAM_STEP_ROOT) != 0
                  stream_ctxt_add_state(stream, 0, 0)
                end
              end
              stream = stream.next
              next
            end

            catch(:stream_next) do
              if comp.steps.empty?
                if (stream.flags & XML_PATTERN_XPATH) != 0
                  throw :stream_next
                end
                if node_type != ATTRIBUTE_NODE &&
                    ((stream.flags & XML_PATTERN_NOTPATTERN) == 0 || stream.level == 0)
                  ret = 1
                end
                stream.level += 1
                throw :stream_next
              end
              if stream.block_level != -1
                stream.level += 1
                throw :stream_next
              end
              if node_type != ELEMENT_NODE && node_type != ATTRIBUTE_NODE &&
                  (comp.flags & XML_STREAM_FINAL_IS_ANY_NODE) == 0
                stream.level += 1
                throw :stream_next
              end

              i = 0
              m = stream.nb_state
              while i < m
                if (comp.flags & XML_STREAM_DESC) == 0
                  step_nr = stream.states[2 * (stream.nb_state - 1)]
                  return -1 if stream.states[2 * (stream.nb_state - 1) + 1] < stream.level

                  i = m
                else
                  step_nr = stream.states[2 * i]
                  if step_nr < 0
                    i += 1
                    next
                  end
                  tmp = stream.states[2 * i + 1]
                  if tmp > stream.level
                    i += 1
                    next
                  end
                  desc = comp.steps[step_nr].flags & XML_STREAM_STEP_DESC
                  if tmp < stream.level && desc == 0
                    i += 1
                    next
                  end
                end
                step = comp.steps[step_nr]
                if step.node_type != node_type
                  if step.node_type == ATTRIBUTE_NODE
                    stream.block_level = stream.level + 1 if (comp.flags & XML_STREAM_DESC) == 0
                    i += 1
                    next
                  elsif step.node_type != XML_STREAM_ANY_NODE
                    i += 1
                    next
                  end
                end
                match = step_match(step, name, ns)
                final = 0
                if match
                  final = step.flags & XML_STREAM_STEP_FINAL
                  if final != 0
                    ret = 1
                  else
                    stream_ctxt_add_state(stream, step_nr + 1, stream.level + 1)
                  end
                  ret = 1 if ret != 1 && (step.flags & XML_STREAM_STEP_IN_SET) != 0
                end
                if (comp.flags & XML_STREAM_DESC) == 0 && (!match || final != 0)
                  stream.block_level = stream.level + 1
                end
                i += 1
              end

              stream.level += 1

              step = comp.steps[0]
              throw :stream_next if (step.flags & XML_STREAM_STEP_ROOT) != 0

              desc = step.flags & XML_STREAM_STEP_DESC
              if (stream.flags & XML_PATTERN_NOTPATTERN) != 0
                idc = (stream.flags & (XML_PATTERN_XSSEL | XML_PATTERN_XSFIELD)) != 0
                if stream.level == 1
                  throw :stream_next if idc
                elsif desc != 0
                  # goto compare
                elsif stream.level == 2 && idc
                  # goto compare
                else
                  throw :stream_next
                end
              end

              # compare:
              if step.node_type != node_type
                throw :stream_next if node_type == ATTRIBUTE_NODE
                throw :stream_next if step.node_type != XML_STREAM_ANY_NODE
              end
              match = step_match(step, name, ns)
              final = step.flags & XML_STREAM_STEP_FINAL
              if match
                if final != 0
                  ret = 1
                else
                  stream_ctxt_add_state(stream, 1, stream.level)
                end
                ret = 1 if ret != 1 && (step.flags & XML_STREAM_STEP_IN_SET) != 0
              end
              if (comp.flags & XML_STREAM_DESC) == 0 && (!match || final != 0)
                stream.block_level = stream.level
              end
            end
            stream = stream.next
          end
          ret
        end

        # xmlStreamPush
        def stream_push(stream, name, ns) = stream_push_internal(stream, name, ns, ELEMENT_NODE)

        # xmlStreamPushAttr
        def stream_push_attr(stream, name, ns) = stream_push_internal(stream, name, ns, ATTRIBUTE_NODE)

        # xmlStreamPop
        def stream_pop(stream)
          return -1 if stream.nil?

          while stream
            stream.block_level = -1 if stream.block_level == stream.level
            stream.level -= 1 if stream.level > 0
            i = stream.nb_state - 1
            while i >= 0
              lev = stream.states[2 * i + 1]
              stream.nb_state -= 1 if lev > stream.level
              break if lev <= stream.level

              i -= 1
            end
            stream = stream.next
          end
          0
        end
      end

      # xmlPatterncompile, as called from xmlschemas.c
      def pattern_compile(pattern, dict, flags, namespaces) = Pattern.pattern_compile(pattern, dict, flags, namespaces)
      def pattern_get_stream_ctxt(comp) = Pattern.pattern_get_stream_ctxt(comp)
      def stream_push(stream, name, ns) = Pattern.stream_push(stream, name, ns)
      def stream_push_attr(stream, name, ns) = Pattern.stream_push_attr(stream, name, ns)
      def stream_pop(stream) = Pattern.stream_pop(stream)
      def free_stream_ctxt(_s) = nil
      def free_pattern(_p) = nil
    end
  end
end
