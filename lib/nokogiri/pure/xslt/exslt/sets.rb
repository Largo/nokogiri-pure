# frozen_string_literal: true

# Port of libexslt/sets.c: set:difference/intersection/distinct/has-same-node/leading/trailing,
# including the libxml2 xpath.c helpers they use (xmlXPathDifference & friends).

module Nokogiri
  module Pure
    module XSLT
      module EXSLT
        module_function

        # xmlXPathDifference
        def xpath_difference(nodes1, nodes2)
          return nodes1 if nodes2.nil? || nodes2.empty?

          ret = []
          return ret if nodes1.nil? || nodes1.empty?

          nodes1.each do |cur|
            XPath.node_set_add_unique(ret, cur) unless XPath.node_set_contains(nodes2, cur)
          end
          ret
        end

        # xmlXPathIntersection
        def xpath_intersection(nodes1, nodes2)
          ret = []
          return ret if nodes1.nil? || nodes1.empty?
          return ret if nodes2.nil? || nodes2.empty?

          nodes1.each do |cur|
            XPath.node_set_add_unique(ret, cur) if XPath.node_set_contains(nodes2, cur)
          end
          ret
        end

        # xmlXPathDistinctSorted
        def xpath_distinct_sorted(nodes)
          return nodes if nodes.nil? || nodes.empty?

          ret = []
          seen = {}
          nodes.each do |cur|
            strval = XPath.cast_node_to_string(cur)
            next if seen.key?(strval)

            seen[strval] = true
            XPath.node_set_add_unique(ret, cur)
          end
          ret
        end

        # xmlXPathHasSameNodes
        def xpath_has_same_nodes(nodes1, nodes2)
          return false if nodes1.nil? || nodes1.empty? || nodes2.nil? || nodes2.empty?

          nodes1.any? { |cur| XPath.node_set_contains(nodes2, cur) }
        end

        # xmlXPathNodeLeadingSorted
        def xpath_node_leading_sorted(nodes, node)
          return nodes if node.nil?

          ret = []
          return ret if nodes.nil? || nodes.empty? || !XPath.node_set_contains(nodes, node)

          nodes.each do |cur|
            break if cur.equal?(node)

            XPath.node_set_add_unique(ret, cur)
          end
          ret
        end

        # xmlXPathNodeTrailingSorted
        def xpath_node_trailing_sorted(nodes, node)
          return nodes if node.nil?

          ret = []
          return ret if nodes.nil? || nodes.empty? || !XPath.node_set_contains(nodes, node)

          i = nodes.length - 1
          while i >= 0
            cur = nodes[i]
            break if cur.equal?(node)

            XPath.node_set_add_unique(ret, cur)
            i -= 1
          end
          XPath.node_set_sort(ret) # bug 413451
          ret
        end

        # pops the two node-set arguments of a set:* function; nil after an error
        def sets_pop_two(ctxt, nargs)
          if nargs != 2
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return nil
          end
          arg2 = ctxt.pop_node_set
          return nil if ctxt.error != XPath::EXPRESSION_OK

          arg1 = ctxt.pop_node_set
          return nil if ctxt.error != XPath::EXPRESSION_OK

          [arg1, arg2]
        end

        # exsltSetsDifferenceFunction
        def sets_difference_function(ctxt, nargs)
          arg1, arg2 = sets_pop_two(ctxt, nargs)
          return if arg1.nil?

          ctxt.value_push(plain_node_set(xpath_difference(arg1, arg2)))
        end

        # exsltSetsIntersectionFunction
        def sets_intersection_function(ctxt, nargs)
          arg1, arg2 = sets_pop_two(ctxt, nargs)
          return if arg1.nil?

          ctxt.value_push(xpath_intersection(arg1, arg2))
        end

        # exsltSetsDistinctFunction
        def sets_distinct_function(ctxt, nargs)
          if nargs != 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          ns = ctxt.pop_node_set
          return if ctxt.error != XPath::EXPRESSION_OK

          # !!! must be sorted !!!
          ctxt.value_push(plain_node_set(xpath_distinct_sorted(ns)))
        end

        # exsltSetsHasSameNodesFunction
        def sets_has_same_nodes_function(ctxt, nargs)
          arg1, arg2 = sets_pop_two(ctxt, nargs)
          return if arg1.nil?

          ctxt.value_push(xpath_has_same_nodes(arg1, arg2))
        end

        # exsltSetsLeadingFunction
        def sets_leading_function(ctxt, nargs)
          arg1, arg2 = sets_pop_two(ctxt, nargs)
          return if arg1.nil?

          # If the second node set is empty, then the first node set is returned.
          if arg2.empty?
            ctxt.value_push(plain_node_set(arg1))
            return
          end
          # !!! must be sorted
          ctxt.value_push(xpath_node_leading_sorted(arg1, arg2[0]))
        end

        # exsltSetsTrailingFunction
        def sets_trailing_function(ctxt, nargs)
          arg1, arg2 = sets_pop_two(ctxt, nargs)
          return if arg1.nil?

          if arg2.empty?
            ctxt.value_push(plain_node_set(arg1))
            return
          end
          ctxt.value_push(xpath_node_trailing_sorted(arg1, arg2[0]))
        end

        SETS_FUNCTIONS = [
          ["difference", :sets_difference_function],
          ["intersection", :sets_intersection_function],
          ["distinct", :sets_distinct_function],
          ["has-same-node", :sets_has_same_nodes_function],
          ["leading", :sets_leading_function],
          ["trailing", :sets_trailing_function],
        ].freeze

        # exsltSetsRegister
        def sets_register
          SETS_FUNCTIONS.each do |name, fn|
            XSLT.register_ext_module_function(name, SETS_NAMESPACE, method(fn))
          end
        end

        # exsltSetsXpathCtxtRegister
        def sets_xpath_ctxt_register(ctxt, prefix)
          xpath_ctxt_register(ctxt, prefix, SETS_NAMESPACE, SETS_FUNCTIONS)
        end
      end
    end
  end
end
