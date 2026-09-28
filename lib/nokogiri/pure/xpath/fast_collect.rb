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

        MATCHERS.each do |m, cond|
          # xmlXPathNextDescendant / xmlXPathNextDescendantOrSelf
          class_eval <<~RUBY, __FILE__, __LINE__ + 1
            def self.descendant_#{m}(ctxnode, doc, name, uri, seq, include_self)
              ctype = ctxnode.type
              if include_self
                cur = ctxnode
                t = ctype
                seq << cur if #{cond}
              end
              return if ctype == ATTRIBUTE_NODE || ctype == NAMESPACE_DECL

              cur = ctxnode.equal?(doc) ? doc.children : ctxnode.children
              while cur
                t = cur.type
                seq << cur if #{cond}
                # advance (xmlXPathNextDescendant)
                ch = cur.children
                if ch && (ct = ch.type) != ENTITY_DECL
                  cur = ch
                  next if ct != DTD_NODE
                end
                break if cur.equal?(ctxnode)

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
                  break if cur.nil?
                  if cur.equal?(ctxnode)
                    cur = nil
                    break
                  end
                  if (nx = cur.next)
                    cur = nx
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

            # xmlXPathNextAttribute
            def self.attribute_#{m}(ctxnode, doc, name, uri, seq, _unused)
              return if ctxnode.type != ELEMENT_NODE || ctxnode.equal?(doc)

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
                break if cur.equal?(doc)

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
                break if cur.equal?(doc)

                pr = cur.prev
                cur = pr if pr && pr.type == DTD_NODE
                cur = cur.prev
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
            __send__(sym, ctxnode, doc, name, uri, FOUND, arg)
            false
          end
        end

        # [method, extra_arg] for a COLLECT op, or nil
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
