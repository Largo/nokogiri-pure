# frozen_string_literal: true

module Nokogiri
  module Pure
    module XPath
      # Specialised axis traversals for xmlXPathNodeCollectAndTest.
      #
      # The generic collector calls an axis "next" function per node and then runs the node test,
      # like libxml2. For the common axes and node tests, this file generates (per axis x node test)
      # tight loops doing exactly the same traversal and test inline. They are only used when none
      # of the traversal-altering features apply (first/last limits, [n] axis ranges, break on
      # first hit, namespace context nodes), so the resulting node sequence is identical.
      module FastCollect
        # node test kinds (op.matcher)
        MATCHERS = {
          elem_name: "t == ELEMENT_NODE && cur.name == name && cur.ns.nil?",
          elem_name_uri: "t == ELEMENT_NODE && cur.name == name && (ns = cur.ns) && ns.href == uri",
          elem_name_wild: "t == ELEMENT_NODE && cur.name == name",
          elem_all: "t == ELEMENT_NODE",
          elem_all_uri: "t == ELEMENT_NODE && (ns = cur.ns) && ns.href == uri",
          attr_name: "t == ATTRIBUTE_NODE && cur.name == name && ((ns = cur.ns).nil? || ns.prefix.nil?)",
          attr_name_uri: "t == ATTRIBUTE_NODE && cur.name == name && (ns = cur.ns) && ns.href == uri",
          attr_all: "t == ATTRIBUTE_NODE",
          attr_all_uri: "t == ATTRIBUTE_NODE && (ns = cur.ns) && ns.href == uri",
          node: "NODE_TYPE_SET[t]",
          text: "t == TEXT_NODE || t == CDATA_SECTION_NODE",
          comment: "t == COMMENT_NODE",
          pi: "t == PI_NODE",
          pi_name: "t == PI_NODE && cur.name == name",
        }.freeze

        # node types matched by node() (namespace nodes are handled by the generic collector)
        NODE_TYPE_SET = [].tap do |a|
          [DOCUMENT_NODE, HTML_DOCUMENT_NODE, ELEMENT_NODE, ATTRIBUTE_NODE, PI_NODE, COMMENT_NODE,
           CDATA_SECTION_NODE, TEXT_NODE].each { |t| a[t] = true }
        end.freeze

        # context node types xmlXPathNextChild / xmlXPathNextChildElement descend into
        CHILD_CTX = [].tap do |a|
          [ELEMENT_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE, ENTITY_NODE, PI_NODE,
           COMMENT_NODE, NOTATION_NODE, DTD_NODE, DOCUMENT_NODE, DOCUMENT_TYPE_NODE,
           DOCUMENT_FRAG_NODE, HTML_DOCUMENT_NODE].each { |t| a[t] = true }
        end.freeze
        # node types xmlXPathNextParent / xmlXPathNextAncestor step up from through ->parent
        PARENT_CTX = [].tap do |a|
          [ELEMENT_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE, ENTITY_NODE, PI_NODE,
           COMMENT_NODE, NOTATION_NODE, DTD_NODE, ELEMENT_DECL, ATTRIBUTE_DECL, XINCLUDE_START,
           XINCLUDE_END, ENTITY_DECL].each { |t| a[t] = true }
        end.freeze
        CHILD_ELEM_CTX = [].tap do |a|
          [ELEMENT_NODE, DOCUMENT_FRAG_NODE, ENTITY_REF_NODE, ENTITY_NODE, DOCUMENT_NODE,
           HTML_DOCUMENT_NODE].each { |t| a[t] = true }
        end.freeze

        # choose the matcher for a COLLECT op (nil: use the generic collector)
        def self.matcher_for(axis, test, type, prefix, name)
          return nil if axis == AXIS_NAMESPACE

          attr = axis == AXIS_ATTRIBUTE
          case test
          when NODE_TEST_NAME
            if attr
              prefix ? :attr_name_uri : :attr_name
            elsif prefix == WILDCARD_PREFIX
              :elem_name_wild
            else
              prefix ? :elem_name_uri : :elem_name
            end
          when NODE_TEST_ALL
            if attr
              prefix ? :attr_all_uri : :attr_all
            else
              prefix ? :elem_all_uri : :elem_all
            end
          when NODE_TEST_TYPE
            case type
            when NODE_TYPE_NODE then :node
            when NODE_TYPE_TEXT then :text
            when NODE_TYPE_COMMENT then :comment
            when NODE_TYPE_PI then :pi
            end
          when NODE_TEST_PI
            name ? :pi_name : :pi
          end
        end

        # In the generated code, node type constants are literals and nodes are compared with ==
        # (BasicObject#==, the identity like equal?, which the interpreter runs without a method
        # frame): both cheaper in the interpreter.
        LITERAL_TYPES = %w[
          ELEMENT_NODE ATTRIBUTE_NODE TEXT_NODE CDATA_SECTION_NODE ENTITY_REF_NODE PI_NODE
          COMMENT_NODE DOCUMENT_NODE DTD_NODE HTML_DOCUMENT_NODE ENTITY_DECL NAMESPACE_DECL
        ].to_h { |c| [c, Pure.const_get(c).to_s] }.freeze
        LITERAL_TYPES_RE = /\b(?:#{LITERAL_TYPES.keys.join("|")})\b/

        def self.with_literal_types(code)
          code.gsub(LITERAL_TYPES_RE) { |c| LITERAL_TYPES[c] }
        end

        MATCHERS.each do |m, cond|
          # xmlXPathNextDescendant / xmlXPathNextDescendantOrSelf
          class_eval with_literal_types(<<~RUBY), __FILE__, __LINE__ + 1
            def self.descendant_#{m}(ctxnode, doc, name, uri, seq, include_self)
              ctype = ctxnode.type
              return descendant_or_self_#{m}(ctxnode, doc, name, uri, seq) if include_self
              return if ctype == ATTRIBUTE_NODE || ctype == NAMESPACE_DECL

              # (xmlXPathNextDescendant starts with the first child, whatever its type)
              cur = ctxnode == doc ? doc.children : ctxnode.children
              return if cur.nil?

              t = cur.type
              descendant_walk_#{m}(ctxnode, cur, t, name, uri, seq)
            end

            # xmlXPathNextDescendantOrSelf: the node, then xmlXPathNextDescendant from the node
            # itself, which doesn't enter a children list headed by an entity declaration and
            # steps over a DTD heading it
            def self.descendant_or_self_#{m}(ctxnode, doc, name, uri, seq)
              cur = ctxnode
              t = ctxnode.type
              seq << cur if #{cond}
              return if t == ATTRIBUTE_NODE || t == NAMESPACE_DECL

              cur = ctxnode.children
              return if cur.nil? || (t = cur.type) == ENTITY_DECL

              if t == DTD_NODE
                found = false
                while (nx = cur.next)
                  cur = nx
                  t = cur.type
                  if t != ENTITY_DECL && t != DTD_NODE
                    found = true
                    break
                  end
                end
                unless found
                  while true
                    cur = cur.parent
                    return if cur.nil? || cur == ctxnode

                    if (nx = cur.next)
                      cur = nx
                      t = cur.type
                      break
                    end
                  end
                end
              end
              descendant_walk_#{m}(ctxnode, cur, t, name, uri, seq)
            end

            # the rest of the descendant traversal of +ctxnode+ from +cur+ (of type +t+)
            def self.descendant_walk_#{m}(ctxnode, cur, t, name, uri, seq)
              while true
                seq << cur if #{cond}
                # advance (xmlXPathNextDescendant); +t+ is kept as the type of +cur+
                ch = cur.children
                if ch && (t = ch.type) != ENTITY_DECL
                  cur = ch
                  next if t != DTD_NODE
                end
                break if cur == ctxnode

                found = false
                while (nx = cur.next)
                  cur = nx
                  t = cur.type
                  if t != ENTITY_DECL && t != DTD_NODE
                    found = true
                    break
                  end
                end
                next if found

                while true
                  cur = cur.parent
                  return if cur.nil? || cur == ctxnode

                  if (nx = cur.next)
                    cur = nx
                    t = cur.type
                    break
                  end
                end
              end
            end

            # xmlXPathNextChild
            def self.child_#{m}(ctxnode, doc, name, uri, seq, _unused)
              if CHILD_CTX[ctxnode.type]
                cur = ctxnode.children
                while cur
                  t = cur.type
                  seq << cur if #{cond}
                  break if t == DOCUMENT_NODE || t == HTML_DOCUMENT_NODE

                  cur = cur.next
                end
              end
            end

            # xmlXPathNextChildElement
            def self.child_elem_#{m}(ctxnode, doc, name, uri, seq, _unused)
              if CHILD_ELEM_CTX[ctxnode.type]
                cur = ctxnode.children
                while cur
                  t = cur.type
                  seq << cur if t == ELEMENT_NODE && (#{cond})
                  cur = cur.next
                end
              end
            end

            # The child / child-element / attribute traversals from each node of +ctxs+ in turn,
            # appending to +out+ (the result of a step without predicates from a node-set, where
            # these axes need no duplicate checks) ...
            def self.multi_child_#{m}(ctxs, doc, name, uri, out)
              i = 0
              while i < ctxs.length
                ctxnode = ctxs[i]
                i += 1
                next unless CHILD_CTX[ctxnode.type]

                cur = ctxnode.children
                while cur
                  t = cur.type
                  out << cur if #{cond}
                  break if t == DOCUMENT_NODE || t == HTML_DOCUMENT_NODE

                  cur = cur.next
                end
              end
            end

            def self.multi_child_elem_#{m}(ctxs, doc, name, uri, out)
              i = 0
              while i < ctxs.length
                ctxnode = ctxs[i]
                i += 1
                next unless CHILD_ELEM_CTX[ctxnode.type]

                cur = ctxnode.children
                while cur
                  t = cur.type
                  out << cur if t == ELEMENT_NODE && (#{cond})
                  cur = cur.next
                end
              end
            end

            def self.multi_attribute_#{m}(ctxs, doc, name, uri, out)
              i = 0
              while i < ctxs.length
                ctxnode = ctxs[i]
                i += 1
                next if ctxnode.type != ELEMENT_NODE || ctxnode == doc

                cur = ctxnode.properties
                while cur
                  t = cur.type
                  out << cur if #{cond}
                  cur = cur.next
                end
              end
            end

            # ... and with an axis range ([n]): the n-th hit from each node
            def self.multi_range_child_#{m}(ctxs, doc, name, uri, out, pos)
              i = 0
              while i < ctxs.length
                ctxnode = ctxs[i]
                i += 1
                next unless CHILD_CTX[ctxnode.type]

                k = 0
                cur = ctxnode.children
                while cur
                  t = cur.type
                  if #{cond}
                    k += 1
                    if k == pos
                      out << cur
                      break
                    end
                  end
                  break if t == DOCUMENT_NODE || t == HTML_DOCUMENT_NODE

                  cur = cur.next
                end
              end
            end

            def self.multi_range_child_elem_#{m}(ctxs, doc, name, uri, out, pos)
              i = 0
              while i < ctxs.length
                ctxnode = ctxs[i]
                i += 1
                next unless CHILD_ELEM_CTX[ctxnode.type]

                k = 0
                cur = ctxnode.children
                while cur
                  t = cur.type
                  if t == ELEMENT_NODE && (#{cond})
                    k += 1
                    if k == pos
                      out << cur
                      break
                    end
                  end
                  cur = cur.next
                end
              end
            end

            def self.multi_range_attribute_#{m}(ctxs, doc, name, uri, out, pos)
              i = 0
              while i < ctxs.length
                ctxnode = ctxs[i]
                i += 1
                next if ctxnode.type != ELEMENT_NODE || ctxnode == doc

                k = 0
                cur = ctxnode.properties
                while cur
                  t = cur.type
                  if #{cond}
                    k += 1
                    if k == pos
                      out << cur
                      break
                    end
                  end
                  cur = cur.next
                end
              end
            end

            # xmlXPathNextAttribute
            def self.attribute_#{m}(ctxnode, doc, name, uri, seq, _unused)
              return if ctxnode.type != ELEMENT_NODE || ctxnode == doc

              cur = ctxnode.properties
              while cur
                t = cur.type
                seq << cur if #{cond}
                cur = cur.next
              end
            end

            # xmlXPathNextFollowingSibling
            def self.following_sibling_#{m}(ctxnode, doc, name, uri, seq, _unused)
              ctype = ctxnode.type
              return if ctype == ATTRIBUTE_NODE || ctype == NAMESPACE_DECL

              cur = ctxnode.next
              while cur
                t = cur.type
                seq << cur if #{cond}
                break if cur == doc

                cur = cur.next
              end
            end

            # xmlXPathNextPrecedingSibling
            def self.preceding_sibling_#{m}(ctxnode, doc, name, uri, seq, _unused)
              ctype = ctxnode.type
              return if ctype == ATTRIBUTE_NODE || ctype == NAMESPACE_DECL

              cur = ctxnode.prev
              while cur
                t = cur.type
                seq << cur if #{cond}
                break if cur == doc

                pr = cur.prev
                cur = pr if pr && pr.type == DTD_NODE
                cur = cur.prev
              end
            end

            # count(following-sibling::test) from +ctxnode+, memoized in +memo+ (node => number
            # of hits from that node on). The traversal visits cur, cur.next, ... (stopping after
            # the document node), so the count from a node is its own hit plus the count from
            # its next sibling.
            def self.count_following_sibling_#{m}(ctxnode, doc, name, uri, memo)
              ctype = ctxnode.type
              return 0 if ctype == ATTRIBUTE_NODE || ctype == NAMESPACE_DECL

              start = ctxnode.next
              return 0 if start.nil?

              total = memo[start]
              return total if total

              path = []
              total = 0
              cur = start
              while cur
                if (known = memo[cur])
                  total = known
                  break
                end
                path << cur
                break if cur == doc

                cur = cur.next
              end
              i = path.length - 1
              while i >= 0
                cur = path[i]
                t = cur.type
                total += 1 if #{cond}
                memo[cur] = total
                i -= 1
              end
              total
            end

            # count(preceding-sibling::test), memoized like count_following_sibling_*: the
            # traversal from ctxnode visits ctxnode.prev unconditionally, then steps over DTD nodes
            def self.count_preceding_sibling_#{m}(ctxnode, doc, name, uri, memo)
              ctype = ctxnode.type
              return 0 if ctype == ATTRIBUTE_NODE || ctype == NAMESPACE_DECL

              start = ctxnode.prev
              return 0 if start.nil?

              total = memo[start]
              return total if total

              path = []
              total = 0
              cur = start
              while cur
                if (known = memo[cur])
                  total = known
                  break
                end
                path << cur
                break if cur == doc

                pr = cur.prev
                cur = pr if pr && pr.type == DTD_NODE
                cur = cur.prev
              end
              i = path.length - 1
              while i >= 0
                cur = path[i]
                t = cur.type
                total += 1 if #{cond}
                memo[cur] = total
                i -= 1
              end
              total
            end

            # xmlXPathNextParent (at most one node)
            def self.parent_#{m}(ctxnode, doc, name, uri, seq, _unused)
              ctype = ctxnode.type
              if PARENT_CTX[ctype]
                cur = ctxnode.parent
                if cur.nil?
                  cur = doc
                elsif cur.type == ELEMENT_NODE && (nm = cur.name) &&
                    (nm.start_with?(" ") || nm == "fake node libxslt")
                  return
                end
              elsif ctype == ATTRIBUTE_NODE
                cur = ctxnode.parent
              elsif ctype == NAMESPACE_DECL
                cur = ctxnode.next
                return if cur && cur.type == NAMESPACE_DECL
              else
                return
              end
              return if cur.nil?

              t = cur.type
              seq << cur if #{cond}
            end

            # xmlXPathNextAncestor / xmlXPathNextAncestorOrSelf
            def self.ancestor_#{m}(ctxnode, doc, name, uri, seq, include_self)
              cur = ctxnode
              if include_self
                t = cur.type
                seq << cur if #{cond}
              else
                # the first step differs from the following ones
                ctype = ctxnode.type
                if PARENT_CTX[ctype]
                  cur = ctxnode.parent
                  if cur.nil?
                    cur = doc
                  elsif cur.type == ELEMENT_NODE && (nm = cur.name) &&
                      (nm.start_with?(" ") || nm == "fake node libxslt")
                    return
                  end
                elsif ctype == ATTRIBUTE_NODE
                  cur = ctxnode.parent
                elsif ctype == NAMESPACE_DECL
                  cur = ctxnode.next
                  return if cur && cur.type == NAMESPACE_DECL
                else
                  return
                end
                return if cur.nil?

                t = cur.type
                seq << cur if #{cond}
              end
              while true
                if cur == doc.children
                  cur = doc
                else
                  return if cur == doc

                  ctype = cur.type
                  if PARENT_CTX[ctype]
                    par = cur.parent
                    return if par.nil?
                    return if par.type == ELEMENT_NODE && (nm = par.name) &&
                      (nm.start_with?(" ") || nm == "fake node libxslt")

                    cur = par
                  elsif ctype == ATTRIBUTE_NODE
                    cur = cur.parent
                  elsif ctype == NAMESPACE_DECL
                    nx = cur.next
                    return if nx.nil? || nx.type == NAMESPACE_DECL

                    cur = nx
                  else
                    return
                  end
                end
                return if cur.nil?

                t = cur.type
                seq << cur if #{cond}
              end
            end

            # xmlXPathNextSelf
            def self.self_#{m}(ctxnode, doc, name, uri, seq, _unused)
              cur = ctxnode
              t = cur.type
              seq << cur if #{cond}
            end
          RUBY
        end

        AXIS_KINDS = {
          AXIS_DESCENDANT => ["descendant", false],
          AXIS_DESCENDANT_OR_SELF => ["descendant", true],
          AXIS_CHILD => ["child", nil],
          AXIS_ATTRIBUTE => ["attribute", nil],
          AXIS_SELF => ["self", nil],
          AXIS_FOLLOWING_SIBLING => ["following_sibling", nil],
          AXIS_PRECEDING_SIBLING => ["preceding_sibling", nil],
          AXIS_PARENT => ["parent", nil],
          AXIS_ANCESTOR => ["ancestor", false],
          AXIS_ANCESTOR_OR_SELF => ["ancestor", true],
        }.freeze

        # a stand-in for the result sequence that stops the traversal at the first hit
        class FoundSink
          def <<(_node)
            throw :xpath_found, true
          end
        end
        FOUND = FoundSink.new

        # does the traversal +sym+ produce any node? (the toBool/breakOnFirstHit mode)
        def self.exists?(sym, ctxnode, doc, name, uri, arg)
          catch(:xpath_found) do
            run(sym, ctxnode, doc, name, uri, FOUND, arg)
            false
          end
        end

        # FastCollect.run(sym, ...) runs the traversal +sym+ and count_run(sym, ...) the counter
        # +sym+, through a case on the name: __send__ with names varying at one call site makes
        # YJIT give up on the call (and run the traversal in the interpreter), and Method#call
        # costs more in the interpreter.
        traversals = singleton_methods.grep(/\A(?:descendant|child|child_elem|attribute|following_sibling|preceding_sibling|self|parent|ancestor)_(?!or_self_|walk_)/).sort
        counters = singleton_methods.grep(/\Acount_/).sort
        multis = singleton_methods.grep(/\Amulti_(?!range_|run)/).sort
        multi_ranges = singleton_methods.grep(/\Amulti_range_(?!run)/).sort
        class_eval <<~RUBY, __FILE__, __LINE__ + 1
          def self.run(sym, ctxnode, doc, name, uri, seq, arg)
            case sym
            #{traversals.map { |t| "when :#{t} then #{t}(ctxnode, doc, name, uri, seq, arg)" }.join("\n")}
            else raise ArgumentError, "unknown traversal \#{sym}"
            end
          end

          def self.multi_run(sym, ctxs, doc, name, uri, out)
            case sym
            #{multis.map { |t| "when :#{t} then #{t}(ctxs, doc, name, uri, out)" }.join("\n")}
            else raise ArgumentError, "unknown traversal \#{sym}"
            end
          end

          def self.multi_range_run(sym, ctxs, doc, name, uri, out, pos)
            case sym
            #{multi_ranges.map { |t| "when :#{t} then #{t}(ctxs, doc, name, uri, out, pos)" }.join("\n")}
            else raise ArgumentError, "unknown traversal \#{sym}"
            end
          end

          def self.count_run(sym, ctxnode, doc, name, uri, memo)
            case sym
            #{counters.map { |t| "when :#{t} then #{t}(ctxnode, doc, name, uri, memo)" }.join("\n")}
            else raise ArgumentError, "unknown counter \#{sym}"
            end
          end
        RUBY

        # [method name, extra_arg] for a COLLECT op, or nil
        def self.plan_for(axis, test, type, prefix, name)
          kind = AXIS_KINDS[axis]
          return nil if kind.nil?

          m = matcher_for(axis, test, type, prefix, name)
          return nil if m.nil?

          meth = kind[0]
          if axis == AXIS_CHILD && (test == NODE_TEST_NAME || test == NODE_TEST_ALL) && type == NODE_TYPE_NODE
            meth = "child_elem"
          end
          [:"#{meth}_#{m}", kind[1]]
        end
      end
    end
  end
end
