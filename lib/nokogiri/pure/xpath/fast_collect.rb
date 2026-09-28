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
          elem_name: "cur.type == ELEMENT_NODE && cur.name == name && cur.ns.nil?",
          elem_name_uri: "cur.type == ELEMENT_NODE && cur.name == name && (ns = cur.ns) && ns.href == uri",
          elem_name_wild: "cur.type == ELEMENT_NODE && cur.name == name",
          elem_all: "cur.type == ELEMENT_NODE",
          elem_all_uri: "cur.type == ELEMENT_NODE && (ns = cur.ns) && ns.href == uri",
          attr_name: "cur.type == ATTRIBUTE_NODE && cur.name == name && ((ns = cur.ns).nil? || ns.prefix.nil?)",
          attr_name_uri: "cur.type == ATTRIBUTE_NODE && cur.name == name && (ns = cur.ns) && ns.href == uri",
          attr_all: "cur.type == ATTRIBUTE_NODE",
          attr_all_uri: "cur.type == ATTRIBUTE_NODE && (ns = cur.ns) && ns.href == uri",
          node: "NODE_TYPE_SET[cur.type]",
          text: "(t = cur.type) == TEXT_NODE || t == CDATA_SECTION_NODE",
          comment: "cur.type == COMMENT_NODE",
          pi: "cur.type == PI_NODE",
          pi_name: "cur.type == PI_NODE && cur.name == name",
        }.freeze

        # node types matched by node() (namespace nodes are handled by the generic collector)
        NODE_TYPE_SET = [].tap do |a|
          [DOCUMENT_NODE, HTML_DOCUMENT_NODE, ELEMENT_NODE, ATTRIBUTE_NODE, PI_NODE, COMMENT_NODE,
           CDATA_SECTION_NODE, TEXT_NODE].each { |t| a[t] = true }
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
              t = ctxnode.type
              if include_self
                cur = ctxnode
                seq << cur if #{cond}
              end
              return if t == ATTRIBUTE_NODE || t == NAMESPACE_DECL

              cur = ctxnode.equal?(doc) ? doc.children : ctxnode.children
              while cur
                seq << cur if #{cond}
                # advance (xmlXPathNextDescendant)
                ch = cur.children
                if ch && ch.type != ENTITY_DECL
                  cur = ch
                  next if cur.type != DTD_NODE
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
              case ctxnode.type
              when ELEMENT_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE, ENTITY_NODE, PI_NODE,
                   COMMENT_NODE, NOTATION_NODE, DTD_NODE, DOCUMENT_NODE, DOCUMENT_TYPE_NODE,
                   DOCUMENT_FRAG_NODE, HTML_DOCUMENT_NODE
                cur = ctxnode.children
                while cur
                  seq << cur if #{cond}
                  t = cur.type
                  break if t == DOCUMENT_NODE || t == HTML_DOCUMENT_NODE

                  cur = cur.next
                end
              end
            end

            # xmlXPathNextChildElement
            def self.child_elem_#{m}(ctxnode, doc, name, uri, seq, _unused)
              case ctxnode.type
              when ELEMENT_NODE, DOCUMENT_FRAG_NODE, ENTITY_REF_NODE, ENTITY_NODE, DOCUMENT_NODE,
                   HTML_DOCUMENT_NODE
                cur = ctxnode.children
                while cur
                  seq << cur if cur.type == ELEMENT_NODE && (#{cond})
                  cur = cur.next
                end
              end
            end

            # xmlXPathNextAttribute
            def self.attribute_#{m}(ctxnode, doc, name, uri, seq, _unused)
              return if ctxnode.type != ELEMENT_NODE || ctxnode.equal?(doc)

              cur = ctxnode.properties
              while cur
                seq << cur if #{cond}
                cur = cur.next
              end
            end

            # xmlXPathNextSelf
            def self.self_#{m}(ctxnode, doc, name, uri, seq, _unused)
              cur = ctxnode
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
        }.freeze

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
          [method("#{meth}_#{m}"), kind[1]]
        end
      end
    end
  end
end
