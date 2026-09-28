# frozen_string_literal: true

# Port of libexslt/functions.c: the EXSLT Functions module (func:function, func:result).
#
# Stylesheet data (xsltStyleGetExtData) is a Hash {[namespace URI, local name] =>
# FuncFunctionData}; the per-transformation data (xsltGetExtData) is a FuncData.

module Nokogiri
  module Pure
    module XSLT
      module EXSLT
        # exsltFuncFunctionData
        class FuncFunctionData
          attr_accessor :nargs, :content

          def initialize
            @nargs = 0
            @content = nil
          end
        end

        # exsltFuncData
        class FuncData
          attr_accessor :funcs, :result, :ctxt_var, :error

          def initialize
            @funcs = nil
            @result = nil
            @ctxt_var = nil
            @error = 0
          end
        end

        # exsltFuncResultPreComp
        class FuncResultPreComp < XSLT::ElemPreComp
          attr_accessor :select, :ns_list, :ns_nr

          def initialize
            super(XSLT::FUNC_EXTENSION)
            @select = nil
            @ns_list = nil
            @ns_nr = 0
          end
        end

        module_function

        # exsltFuncRegisterFunc
        def func_register_func(data, ctxt, uri, name)
          return if data.nil? || ctxt.nil? || uri.nil? || name.nil?

          XSLT.register_ext_function(ctxt, name, uri, method(:func_function_function))
        end

        # exsltFuncRegisterImportFunc (+ch+ is [ctxt, hash])
        def func_register_import_func(data, ch, uri, name)
          return if data.nil? || ch.nil? || uri.nil? || name.nil?

          ctxt, hash = ch
          return if ctxt.nil? || hash.nil?

          # Check if already present
          key = [uri, name]
          return if hash.key?(key)

          # Not yet present - copy it in
          func = FuncFunctionData.new
          func.nargs = data.nargs
          func.content = data.content
          hash[key] = func
          # Do the registration
          XSLT.register_ext_function(ctxt, name, uri, method(:func_function_function))
        end

        # exsltFuncInit
        def func_init(ctxt, uri)
          ret = FuncData.new
          ret.result = nil
          ret.error = 0

          hash = XSLT.style_get_ext_data(ctxt.style, uri)
          ret.funcs = hash
          hash&.each { |(u, n), data| func_register_func(data, ctxt, u, n) }
          tmp = ctxt.style
          while (tmp = XSLT.next_import(tmp))
            h = XSLT.get_ext_info(tmp, uri)
            h&.to_a&.each { |(u, n), data| func_register_import_func(data, [ctxt, hash], u, n) }
          end

          ret
        end

        # exsltFuncShutdown
        def func_shutdown(_ctxt, _uri, data)
          data.result = nil if data
          nil
        end

        # exsltFuncStyleInit
        def func_style_init(_style, _uri)
          {}
        end

        # exsltFuncStyleShutdown
        def func_style_shutdown(_style, _uri, _data)
          nil
        end

        # exsltFuncFunctionFunction: calls a func:function
        def func_function_function(ctxt, nargs)
          tctxt = XSLT.xpath_get_transform_context(ctxt)

          # retrieve func:function template
          data = XSLT.get_ext_data(tctxt, FUNCTIONS_NAMESPACE)
          old_result = data.result
          data.result = nil

          function_uri = ctxt.context.function_uri
          function = ctxt.context.function
          func = data.funcs&.[]([function_uri, function])
          if func.nil?
            # Should never happen
            XSLT.generic_error("{#{function_uri}}#{function}: not found\n")
            ctxt.error = XPath::UNKNOWN_FUNC_ERROR
            return
          end

          # params handling
          if nargs > func.nargs
            XSLT.generic_error("{#{function_uri}}#{function}: called with too many arguments\n")
            ctxt.error = XPath::INVALID_ARITY
            return
          end
          param_node = func.content&.prev
          if param_node.nil? && func.nargs != 0
            XSLT.generic_error("exsltFuncFunctionFunction: nargs != 0 and param == NULL\n")
            return
          end

          # When a function is called recursively during evaluation of its arguments, the
          # recursion check in xsltApplySequenceConstructor isn't reached.
          if tctxt.depth >= tctxt.max_template_depth
            XSLT.transform_error(tctxt, nil, nil,
              "exsltFuncFunctionFunction: Potentially infinite recursion detected in " \
              "function {#{function_uri}}#{function}.\n")
            tctxt.state = XSLT::STATE_STOPPED
            return
          end
          tctxt.depth += 1

          begin
            # Evaluating templates can change the XPath context node.
            old_xp_node = tctxt.xpath_ctxt.node

            fake = Tree.new_doc_node(tctxt.output, nil, "fake", nil)
            return if fake.nil?

            # The caller's argument values are on the XPath stack in reverse order; the params
            # must be evaluated in lexical order (a variable is in scope as soon as it is
            # declared), so pop them first.
            # In order to give the function params and variables a new 'scope' we change
            # varsBase in the context.
            new_base = tctxt.vars_nr
            params = nil
            # If there are any parameters
            if param_node
              args = Array.new(nargs)
              (nargs - 1).downto(0) { |i| args[i] = ctxt.value_pop }

              # Prepare to process params in reverse order. First, go to the beginning of the
              # param chain.
              i = 1
              while i <= func.nargs
                break if param_node.prev.nil?

                param_node = param_node.prev
                i += 1
              end
              # i has total # params found, nargs is number which are present as arguments
              # from the caller. Calculate the number of un-set parameters
              func.nargs.times do |j|
                param = XSLT.parse_stylesheet_caller_param(tctxt, param_node)
                if param.nil?
                  XSLT.local_variable_pop(tctxt, new_base, -2)
                  return
                end
                if j < nargs # if parameter value set
                  param.computed = true
                  param.value = args[j]
                end
                XSLT.local_variable_push(tctxt, param, -1)
                param.next = params
                params = param
                param_node = param_node.next
              end
            end

            # Actual processing. The context variable is cleared and restored when func:result
            # is evaluated.
            old_base = tctxt.vars_base
            old_insert = tctxt.insert
            old_ctxt_var = data.ctxt_var
            data.ctxt_var = tctxt.context_variable
            tctxt.vars_base = new_base
            tctxt.insert = fake
            tctxt.context_variable = nil
            XSLT.apply_one_template(tctxt, tctxt.node, func.content, nil, nil)
            XSLT.local_variable_pop(tctxt, tctxt.vars_base, -2)
            tctxt.insert = old_insert
            tctxt.context_variable = data.ctxt_var
            tctxt.vars_base = old_base # restore original scope
            data.ctxt_var = old_ctxt_var
            tctxt.xpath_ctxt.node = old_xp_node

            return if data.error != 0

            if data.result
              ret = data.result
              # IMPORTANT: This enables previously tree fragments marked as being results of a
              # function, to be garbage-collected after the calling process exits.
              XSLT.flag_rvts(tctxt, ret, XSLT::RVT_LOCAL)
            else
              ret = +""
            end

            data.result = old_result

            # It is an error if the instantiation of the template results in the generation
            # of result nodes.
            if fake.children
              XSLT.generic_error("{#{function_uri}}#{function}: cannot write to result tree " \
                                 "while executing a function\n")
              return
            end
            ctxt.value_push(ret)
          rescue SystemStackError
            # The Ruby stack runs out long before libxslt's limits would be reached. Report the
            # limit native libxslt would hit first, extrapolating from the current depths: the
            # template depth (xsltMaxDepth, checked above) or the XPath recursion depth.
            xdepth = ctxt.context.depth.to_f / XPath::XPATH_MAX_RECURSION_DEPTH
            if xdepth > tctxt.depth.to_f / tctxt.max_template_depth
              ctxt.xp_error(XPath::RECURSION_LIMIT_EXCEEDED) unless tctxt.stack_overflow_reported
              tctxt.stack_overflow_reported = true
              throw :xpath_abort
            end
            unless tctxt.stack_overflow_reported
              XSLT.transform_error(tctxt, nil, nil,
                "exsltFuncFunctionFunction: Potentially infinite recursion detected in " \
                "function {#{function_uri}}#{function}.\n")
              tctxt.stack_overflow_reported = true
            end
            tctxt.state = XSLT::STATE_STOPPED
            nil
          ensure
            tctxt.depth -= 1
          end
        end

        # exsltFuncFunctionComp: the func:function top-level element
        def func_function_comp(style, inst)
          return if style.nil? || inst.nil? || inst.type != ELEMENT_NODE

          qname = Tree.get_prop(inst, "name")
          name, prefix = Tree.split_qname2(qname) if qname
          if name.nil? || prefix.nil?
            XSLT.generic_error("func:function: not a QName\n")
            return
          end
          # namespace lookup
          ns = Tree.search_ns(inst.doc, inst, prefix)
          if ns.nil?
            XSLT.generic_error("func:function: undeclared prefix #{prefix}\n")
            return
          end

          XSLT.parse_template_content(style, inst)

          # Create function data
          func = FuncFunctionData.new
          func.content = inst.children
          while XSLT.xslt_elem?(func.content) && func.content.name == "param"
            func.content = func.content.next
            func.nargs += 1
          end

          # Register the function data such that it can be retrieved by
          # exslFuncFunctionFunction
          data = XSLT.style_get_ext_data(style, FUNCTIONS_NAMESPACE)
          if data.nil?
            XSLT.generic_error("exsltFuncFunctionComp: no stylesheet data\n")
            return
          end

          key = [ns.href, name]
          if data.key?(key)
            XSLT.transform_error(nil, style, inst, "Failed to register function {#{ns.href}}#{name}\n")
            style.errors += 1
          else
            data[key] = func
          end
        end

        # exsltFuncResultComp
        def func_result_comp(style, inst, function)
          return nil if style.nil? || inst.nil? || inst.type != ELEMENT_NODE

          # "Validity" checking
          # it is an error to have any following sibling elements aside from the xsl:fallback
          # element.
          test = inst.next
          while test
            if test.type == ELEMENT_NODE && !(XSLT.xslt_elem?(test) && test.name == "fallback")
              XSLT.generic_error("exsltFuncResultElem: only xsl:fallback is allowed to follow func:result\n")
              style.errors += 1
              return nil
            end
            test = test.next
          end
          # it is an error for a func:result element to not be a descendant of func:function.
          # it is an error if a func:result occurs within a func:result element.
          # it is an error if instanciating the content of a variable binding element (i.e.
          # xsl:variable, xsl:param) results in the instanciation of a func:result element.
          test = inst.parent
          while test
            if XSLT.xslt_elem?(test) && test.name == "stylesheet"
              XSLT.generic_error("func:result element not a descendant of a func:function\n")
              style.errors += 1
              return nil
            end
            if test.ns && test.ns.href == FUNCTIONS_NAMESPACE
              break if test.name == "function"

              if test.name == "result"
                XSLT.generic_error("func:result element not allowed within another func:result element\n")
                style.errors += 1
                return nil
              end
            end
            if XSLT.xslt_elem?(test) && (test.name == "variable" || test.name == "param")
              XSLT.generic_error("func:result element not allowed within a variable binding element\n")
              style.errors += 1
              return nil
            end
            test = test.parent
          end

          # Precomputation
          ret = FuncResultPreComp.new
          XSLT.init_elem_pre_comp(ret, style, inst, function, nil)
          ret.select = nil

          # Precompute the select attribute
          sel = Tree.get_ns_prop(inst, "select", nil)
          ret.select = XSLT.xpath_compile_flags(style, sel, 0) if sel
          # Precompute the namespace list
          ret.ns_list = Tree.get_ns_list(inst.doc, inst)
          ret.ns_nr = ret.ns_list ? ret.ns_list.length : 0
          ret
        end

        # exsltFuncResultElem
        def func_result_elem(ctxt, _node, inst, comp)
          # It is an error if instantiating the content of the func:function element results
          # in the instantiation of more than one func:result elements.
          data = XSLT.get_ext_data(ctxt, FUNCTIONS_NAMESPACE)
          if data.nil?
            XSLT.generic_error("exsltFuncReturnElem: data == NULL\n")
            return
          end
          if data.result
            XSLT.generic_error("func:result already instanciated\n")
            data.error = 1
            return
          end
          # Restore context variable, so that it will receive the function result RVTs.
          ctxt.context_variable = data.ctxt_var
          # Processing
          if comp.select
            # If the func:result element has a select attribute, then the value of the
            # attribute must be an expression and the returned value is the object that
            # results from evaluating the expression. In this case, the content must be empty.
            if inst.children
              XSLT.generic_error("func:result content must be empty if the function has a select attribute\n")
              data.error = 1
              return
            end
            xp = ctxt.xpath_ctxt
            old_xp_ns_list = xp.namespaces
            old_xp_context_node = xp.node

            xp.namespaces = comp.ns_list
            xp.node = ctxt.node

            ret = XPath.compiled_eval(comp.select, xp)

            xp.node = old_xp_context_node
            xp.namespaces = old_xp_ns_list

            if ret.nil?
              XSLT.generic_error("exsltFuncResultElem: ret == NULL\n")
              return
            end
            # Mark it as a function result in order to avoid garbage collecting of tree
            # fragments before the function exits.
            XSLT.flag_rvts(ctxt, ret, XSLT::RVT_FUNC_RESULT)
          elsif inst.children
            # If the func:result element does not have a select attribute and has non-empty
            # content (i.e. the func:result element has one or more child nodes), then the
            # content of the func:result element specifies the value.
            container = XSLT.create_rvt(ctxt)
            if container.nil?
              XSLT.generic_error("exsltFuncResultElem: out of memory\n")
              data.error = 1
              return
            end
            # Mark as function result.
            XSLT.register_local_rvt(ctxt, container)
            container.compression = XSLT::RVT_FUNC_RESULT

            old_insert = ctxt.insert
            ctxt.insert = container
            XSLT.apply_one_template(ctxt, ctxt.node, inst.children, nil, nil)
            ctxt.insert = old_insert

            ret = XPath.new_value_tree(container)
            ret.boolval = false
          else
            # If the func:result element has empty content and does not have a select
            # attribute, then the returned value is an empty string.
            ret = +""
          end
          data.result = ret
        end

        # exsltFuncRegister
        def func_register
          XSLT.register_ext_module_full(FUNCTIONS_NAMESPACE,
            method(:func_init), method(:func_shutdown),
            method(:func_style_init), method(:func_style_shutdown))

          XSLT.register_ext_module_top_level("function", FUNCTIONS_NAMESPACE, method(:func_function_comp))
          XSLT.register_ext_module_element("result", FUNCTIONS_NAMESPACE,
            method(:func_result_comp), method(:func_result_elem))
        end
      end
    end
  end
end
