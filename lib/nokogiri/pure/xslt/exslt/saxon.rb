# frozen_string_literal: true

# Port of libexslt/saxon.c: saxon:expression, saxon:eval, saxon:evaluate, saxon:line-number
# and saxon:systemId.

module Nokogiri
  module Pure
    module XSLT
      module EXSLT
        module_function

        # exsltSaxonInit: the per-transformation cache of compiled expressions
        def saxon_init(_ctxt, _uri)
          {}
        end

        # exsltSaxonShutdown
        def saxon_shutdown(_ctxt, _uri, _data)
          nil
        end

        # exsltSaxonExpressionFunction
        def saxon_expression_function(ctxt, nargs)
          tctxt = XSLT.xpath_get_transform_context(ctxt)

          if nargs != 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          arg = ctxt.pop_string
          if ctxt.error != XPath::EXPRESSION_OK || arg.nil?
            ctxt.xpath_err(XPath::INVALID_TYPE)
            return
          end

          hash = XSLT.get_ext_data(tctxt, ctxt.context.function_uri)

          ret = hash[arg]
          if ret.nil?
            ret = XPath.ctxt_compile(tctxt.xpath_ctxt, arg)
            if ret.nil?
              ctxt.xpath_err(XPath::EXPR_ERROR)
              return
            end
            hash[arg.frozen? ? arg : arg.dup.freeze] = ret
          end

          ctxt.value_push(XPath::UserObject.new(ret))
        end

        # exsltSaxonEvalFunction
        def saxon_eval_function(ctxt, nargs)
          if nargs != 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          unless ctxt.value.is_a?(XPath::UserObject) # xmlXPathStackIsExternal
            ctxt.xpath_err(XPath::INVALID_TYPE)
            return
          end

          expr = ctxt.pop_external

          saved_depth = sync_xpath_depth(ctxt)
          ret = XPath.compiled_eval(expr, ctxt.context)
          ctxt.context.depth = saved_depth
          if ret.nil?
            ctxt.xpath_err(XPath::EXPR_ERROR)
            return
          end

          ctxt.value_push(ret)
        end

        # exsltSaxonEvaluateFunction
        def saxon_evaluate_function(ctxt, nargs)
          if nargs != 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          saxon_expression_function(ctxt, 1)
          saxon_eval_function(ctxt, 1)
        end

        # exsltSaxonSystemIdFunction
        def saxon_system_id_function(ctxt, nargs)
          return if ctxt.nil?

          if nargs != 0
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          c = ctxt.context
          if c && c.doc && c.doc.url
            ctxt.value_push(c.doc.url.dup)
          else
            ctxt.value_push(+"")
          end
        end

        # exsltSaxonLineNumberFunction
        def saxon_line_number_function(ctxt, nargs)
          cur = nil
          line_no = -1

          if nargs == 0
            cur = ctxt.context.node
          elsif nargs == 1
            v = ctxt.value
            if v.nil? || !v.instance_of?(Array) # XPATH_NODESET only (not a result tree fragment)
              XSLT.transform_error(XSLT.xpath_get_transform_context(ctxt), nil, nil,
                "saxon:line-number() : invalid arg expecting a node-set\n")
              ctxt.error = XPath::INVALID_TYPE
              return
            end

            nodelist = ctxt.value_pop
            unless nodelist.empty?
              cur = nodelist[0]
              i = 1
              while i < nodelist.length
                cur = nodelist[i] if XPath.cmp_nodes(cur, nodelist[i]) == -1
                i += 1
              end
            end
          else
            XSLT.transform_error(XSLT.xpath_get_transform_context(ctxt), nil, nil,
              "saxon:line-number() : invalid number of args #{nargs}\n")
            ctxt.error = XPath::INVALID_ARITY
            return
          end

          if cur && cur.type == NAMESPACE_DECL
            # The XPath module sets the owner element of a ns-node on the ns->next field.
            cur = cur.next
            if cur.nil? || cur.type != ELEMENT_NODE
              XSLT.generic_error("Internal error in exsltSaxonLineNumberFunction: " \
                                 "Cannot retrieve the doc of a namespace node.\n")
              cur = nil
            end
          end

          line_no = Tree.get_line_no(cur) if cur

          ctxt.value_push(line_no.to_f)
        end

        # exsltSaxonRegister
        def saxon_register
          XSLT.register_ext_module(SAXON_NAMESPACE, method(:saxon_init), method(:saxon_shutdown))
          XSLT.register_ext_module_function("expression", SAXON_NAMESPACE, method(:saxon_expression_function))
          XSLT.register_ext_module_function("eval", SAXON_NAMESPACE, method(:saxon_eval_function))
          XSLT.register_ext_module_function("evaluate", SAXON_NAMESPACE, method(:saxon_evaluate_function))
          XSLT.register_ext_module_function("line-number", SAXON_NAMESPACE, method(:saxon_line_number_function))
          XSLT.register_ext_module_function("systemId", SAXON_NAMESPACE, method(:saxon_system_id_function))
        end
      end
    end
  end
end
