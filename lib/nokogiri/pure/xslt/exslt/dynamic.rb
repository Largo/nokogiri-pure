# frozen_string_literal: true

# Port of libexslt/dynamic.c: dyn:evaluate and dyn:map.

module Nokogiri
  module Pure
    module XSLT
      module EXSLT
        module_function

        # exsltDynEvaluateFunction
        def dyn_evaluate_function(ctxt, nargs)
          return if ctxt.nil?

          if nargs != 1
            XSLT.print_error_context(XSLT.xpath_get_transform_context(ctxt), nil, nil)
            XSLT.generic_error("dyn:evalute() : invalid number of args #{nargs}\n")
            ctxt.error = XPath::INVALID_ARITY
            return
          end
          str = ctxt.pop_string
          # return an empty node-set if an empty string is passed in
          if str.nil? || str.empty? || str.start_with?("\0")
            ctxt.value_push([])
            return
          end

          # Recursive evaluation can grow the call stack quickly.
          ctxt.context.depth += 5
          ret = XPath.eval(str, ctxt.context)
          ctxt.context.depth -= 5
          if ret.nil?
            XSLT.generic_error("dyn:evaluate() : unable to evaluate expression '#{str}'\n")
            ctxt.value_push([])
          else
            ctxt.value_push(ret)
          end
        end

        # xmlNewTextChild(container, NULL, name, content) followed by
        # newChildNode->ns = xmlNewNs(newChildNode, EXSLT_COMMON_NAMESPACE, "exsl")
        def dyn_new_exsl_text_child(container, name, content)
          cur = Tree.new_doc_raw_node(container.doc, nil, name, content)
          return nil if cur.nil?

          # add the new element at the end of the children list.
          cur.parent = container
          if container.children.nil?
            container.children = cur
            container.last = cur
          else
            prev = container.last
            prev.next = cur
            cur.prev = prev
            container.last = cur
          end
          cur.ns = Tree.new_ns(cur, COMMON_NAMESPACE, "exsl")
          cur
        end

        # exsltDynMapFunction
        def dyn_map_function(ctxt, nargs)
          if nargs != 2
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          ret = nil
          catch(:dyn_map_cleanup) do
            str = ctxt.pop_string
            throw :dyn_map_cleanup if ctxt.error != XPath::EXPRESSION_OK

            nodeset = ctxt.pop_node_set
            throw :dyn_map_cleanup if ctxt.error != XPath::EXPRESSION_OK

            ret = []

            tctxt = XSLT.xpath_get_transform_context(ctxt)
            if tctxt.nil?
              XSLT.transform_error(nil, nil, nil, "dyn:map : internal error tctxt == NULL\n")
              throw :dyn_map_cleanup
            end

            throw :dyn_map_cleanup if str.nil? || str.empty? || str.start_with?("\0")

            comp = XPath.ctxt_compile(tctxt.xpath_ctxt, str)
            throw :dyn_map_cleanup if comp.nil?

            xctxt = ctxt.context
            old_doc = xctxt.doc
            old_node = xctxt.node
            old_context_size = xctxt.context_size
            old_proximity_position = xctxt.proximity_position

            # since we really don't know we're going to be adding node(s) down the road we
            # create the RVT regardless
            container = XSLT.create_rvt(tctxt)
            if container.nil?
              XSLT.transform_error(tctxt, nil, nil, "dyn:map : internal error container == NULL\n")
              throw :dyn_map_cleanup
            end
            XSLT.register_local_rvt(tctxt, container)

            if nodeset && !nodeset.empty?
              XPath.node_set_sort(nodeset)
              xctxt.context_size = nodeset.length
              xctxt.proximity_position = 0
              nodeset.each do |cur|
                xctxt.proximity_position += 1
                xctxt.node = cur

                if cur.type == NAMESPACE_DECL
                  # The XPath module sets the owner element of a ns-node on the ns->next field.
                  cur = cur.next
                  if cur.nil? || cur.type != ELEMENT_NODE
                    XSLT.generic_error("Internal error in exsltDynMapFunction: " \
                                       "Cannot retrieve the doc of a namespace node.\n")
                    next
                  end
                end
                xctxt.doc = cur.doc

                sub_result = XPath.compiled_eval(comp, xctxt)
                next if sub_result.nil?

                case sub_result
                when XPath::ValueTree
                  nil # XPATH_XSLT_TREE: ignored
                when Array
                  sub_result.each { |n| XPath.node_set_add(ret, n) }
                when true, false
                  n = dyn_new_exsl_text_child(container, "boolean", sub_result ? "true" : "")
                  XPath.node_set_add_unique(ret, n) if n
                when Float
                  n = dyn_new_exsl_text_child(container, "number", XPath.cast_number_to_string(sub_result))
                  XPath.node_set_add_unique(ret, n) if n
                when String
                  n = dyn_new_exsl_text_child(container, "string", sub_result)
                  XPath.node_set_add_unique(ret, n) if n
                end
              end
            end
            xctxt.doc = old_doc
            xctxt.node = old_node
            xctxt.context_size = old_context_size
            xctxt.proximity_position = old_proximity_position
          end

          # cleanup: (a NULL ret makes valuePush report a memory error, as in C)
          ctxt.value_push(ret)
        end

        # exsltDynRegister
        def dyn_register
          XSLT.register_ext_module_function("evaluate", DYNAMIC_NAMESPACE, method(:dyn_evaluate_function))
          XSLT.register_ext_module_function("map", DYNAMIC_NAMESPACE, method(:dyn_map_function))
        end
      end
    end
  end
end
