# frozen_string_literal: true

# Port of libxslt variables.c: result tree fragments, variable/param stack, global variables,
# user parameters and the XPath variable lookup hook.

module Nokogiri
  module Pure
    module XSLT
      COMPUTING_GLOBAL_VAR_MARKER = " var/param being computed"
      VAR_GLOBAL = 1 << 0
      VAR_IN_SELECT = 1 << 1

      module_function

      # xsltCreateRVT
      def create_rvt(ctxt)
        return nil if ctxt.nil?

        container = Tree.new_doc(nil)
        container.version = nil
        container.name = RES_TREE_FRAG_NAME
        container.doc = container
        container.parent = nil
        container
      end

      # xsltRegisterTmpRVT
      def register_tmp_rvt(ctxt, rvt)
        return -1 if ctxt.nil? || rvt.nil?

        rvt.prev = nil
        rvt.compression = RVT_LOCAL
        if ctxt.context_variable
          var = ctxt.context_variable
          rvt.next = var.fragment
          var.fragment = rvt
          return 0
        end
        rvt.next = ctxt.tmp_rvt
        ctxt.tmp_rvt.prev = rvt if ctxt.tmp_rvt
        ctxt.tmp_rvt = rvt
        0
      end

      # xsltRegisterLocalRVT
      def register_local_rvt(ctxt, rvt)
        return -1 if ctxt.nil? || rvt.nil?

        rvt.prev = nil
        rvt.compression = RVT_LOCAL
        if ctxt.context_variable && (ctxt.context_variable.flags & VAR_IN_SELECT) != 0
          var = ctxt.context_variable
          rvt.next = var.fragment
          var.fragment = rvt
          return 0
        end
        rvt.next = ctxt.local_rvt
        ctxt.local_rvt.prev = rvt if ctxt.local_rvt
        ctxt.local_rvt = rvt
        0
      end

      # xsltExtensionInstructionResultFinalize
      def extension_instruction_result_finalize(_ctxt)
        xml_generic_error("xsltExtensionInstructionResultFinalize is unsupported in this release of libxslt.\n")
        -1
      end

      # xsltExtensionInstructionResultRegister
      def extension_instruction_result_register(_ctxt, _obj)
        0
      end

      # xsltFlagRVTs
      def flag_rvts(ctxt, obj, val)
        return -1 if ctxt.nil? || obj.nil?
        return 0 unless obj.is_a?(Array)

        obj.each do |cur|
          if cur.is_a?(XmlNs)
            if cur.next && cur.next.type == ELEMENT_NODE
              doc = cur.next.doc
            else
              transform_error(ctxt, nil, ctxt.inst,
                "Internal error in xsltFlagRVTs(): Cannot retrieve the doc of a namespace node.\n")
              return -1
            end
          else
            doc = cur.doc
          end
          if doc.nil?
            transform_error(ctxt, nil, ctxt.inst, "Internal error in xsltFlagRVTs(): Cannot retrieve the doc of a node.\n")
            return -1
          end
          next unless doc.name&.start_with?(" ") && doc.compression != RVT_GLOBAL

          if val == RVT_LOCAL
            doc.compression = RVT_LOCAL if doc.compression == RVT_FUNC_RESULT
          elsif val == RVT_GLOBAL
            if doc.compression != RVT_LOCAL
              xml_generic_error("xsltFlagRVTs: Invalid transition #{doc.compression} => GLOBAL\n")
              doc.compression = RVT_GLOBAL
              return -1
            end
            doc.compression = RVT_GLOBAL
          elsif val == RVT_FUNC_RESULT
            doc.compression = val
          end
        end
        0
      end

      # xsltReleaseRVT: fragments are garbage collected; nothing to recycle
      def release_rvt(_ctxt, rvt)
        return if rvt.nil?

        rvt._private = nil if rvt._private.is_a?(Document)
      end

      # xsltRegisterPersistRVT
      def register_persist_rvt(ctxt, rvt)
        return -1 if ctxt.nil? || rvt.nil?

        rvt.compression = RVT_GLOBAL
        rvt.prev = nil
        rvt.next = ctxt.persist_rvt
        ctxt.persist_rvt.prev = rvt if ctxt.persist_rvt
        ctxt.persist_rvt = rvt
        0
      end

      # xsltFreeRVTs
      def free_rvts(ctxt)
        return if ctxt.nil?

        ctxt.local_rvt = nil
        ctxt.tmp_rvt = nil
        ctxt.persist_rvt = nil
      end

      # xsltNewStackElem
      def new_stack_elem(ctxt)
        StackElem.new(ctxt)
      end

      # xsltCopyStackElem
      def copy_stack_elem(elem)
        cur = StackElem.new(elem.context)
        cur.name = elem.name
        cur.name_uri = elem.name_uri
        cur.select = elem.select
        cur.tree = elem.tree
        cur.comp = elem.comp
        cur
      end

      # xsltFreeStackElem: release the fragments bound to the variable
      def free_stack_elem(elem)
        return if elem.nil?

        if elem.context
          while (cur = elem.fragment)
            elem.fragment = cur.next
            if cur.compression == RVT_LOCAL
              release_rvt(elem.context, cur)
            elsif cur.compression == RVT_FUNC_RESULT
              register_local_rvt(elem.context, cur)
              cur.compression = RVT_FUNC_RESULT
            else
              xml_generic_error("xsltFreeStackElem: Unexpected RVT flag #{cur.compression}\n")
            end
          end
        end
      end

      # xsltFreeStackElemList
      def free_stack_elem_list(elem)
        while elem
          nxt = elem.next
          free_stack_elem(elem)
          elem = nxt
        end
      end

      # xsltStackLookup
      def stack_lookup(ctxt, name, name_uri)
        return nil if ctxt.nil? || name.nil? || ctxt.vars_nr == 0

        tab = ctxt.vars_tab
        i = tab.length
        base = ctxt.vars_base
        while i > base
          cur = tab[i - 1]
          while cur
            return cur if cur.name == name && cur.name_uri == name_uri

            cur = cur.next
          end
          i -= 1
        end
        nil
      end

      # xsltCheckStackElem
      def check_stack_elem(ctxt, name, name_uri)
        return -1 if ctxt.nil? || name.nil?

        cur = stack_lookup(ctxt, name, name_uri)
        return 0 if cur.nil?

        if cur.comp
          return 3 if cur.comp.type == FUNC_WITHPARAM
          return 2 if cur.comp.type == FUNC_PARAM
        end
        1
      end

      # xsltAddStackElem
      def add_stack_elem(ctxt, elem)
        return -1 if ctxt.nil? || elem.nil?

        while elem
          ctxt.vars_tab << elem
          ctxt.vars = elem
          elem = elem.next
        end
        0
      end

      # xsltAddStackElemList
      def add_stack_elem_list(ctxt, elems)
        add_stack_elem(ctxt, elems)
      end

      # xsltEvalVariable
      def eval_variable(ctxt, variable, comp)
        return nil if ctxt.nil? || variable.nil?

        result = nil
        old_inst = ctxt.inst
        if variable.select
          xp = ctxt.xpath_ctxt
          old_var = ctxt.context_variable
          xp_expr = comp&.comp || XPath.ctxt_compile(xp, variable.select)
          return nil if xp_expr.nil?

          old_doc = xp.doc
          old_node = xp.node
          old_pos = xp.proximity_position
          old_size = xp.context_size
          old_ns = xp.namespaces
          xp.node = ctxt.node
          xp.doc = ctxt.node.doc if !ctxt.node.is_a?(XmlNs) && ctxt.node.doc
          xp.namespaces = comp&.ns_list
          ctxt.context_variable = variable
          variable.flags |= VAR_IN_SELECT
          result = XPath.compiled_eval(xp_expr, xp)
          variable.flags ^= VAR_IN_SELECT
          ctxt.context_variable = old_var
          xp.doc = old_doc
          xp.node = old_node
          xp.context_size = old_size
          xp.proximity_position = old_pos
          xp.namespaces = old_ns
          if result.nil?
            transform_error(ctxt, nil, comp&.inst,
              "Failed to evaluate the expression of variable '#{variable.name}'.\n")
            ctxt.state = STATE_STOPPED
          end
        elsif variable.tree.nil?
          result = +""
        else
          old_var = ctxt.context_variable
          container = create_rvt(ctxt)
          if container
            variable.fragment = container
            container.compression = RVT_LOCAL
            old_output = ctxt.output
            old_insert = ctxt.insert
            old_last_text = ctxt.lasttext
            ctxt.output = container
            ctxt.insert = container
            ctxt.context_variable = variable
            apply_one_template(ctxt, ctxt.node, variable.tree, nil, nil)
            ctxt.context_variable = old_var
            ctxt.insert = old_insert
            ctxt.output = old_output
            ctxt.lasttext = old_last_text
            result = XPath.new_value_tree(container)
            result = +"" if result.nil?
          end
        end
        ctxt.inst = old_inst
        result
      end

      # xsltEvalGlobalVariable
      def eval_global_variable(elem, ctxt)
        return nil if ctxt.nil? || elem.nil?
        return elem.value if elem.computed

        old_inst = ctxt.inst
        comp = elem.comp
        old_var_name = elem.name
        elem.name = COMPUTING_GLOBAL_VAR_MARKER
        result = nil
        begin
          if elem.select
            xp = ctxt.xpath_ctxt
            xp_expr = comp&.comp || XPath.ctxt_compile(xp, elem.select)
            break if xp_expr.nil?

            ctxt.inst = comp&.inst
            old_doc = xp.doc
            old_node = xp.node
            old_pos = xp.proximity_position
            old_size = xp.context_size
            old_ns = xp.namespaces
            xp.node = ctxt.initial_context_node
            xp.doc = ctxt.initial_context_doc
            xp.context_size = 1
            xp.proximity_position = 1
            xp.namespaces = comp&.ns_list
            result = XPath.compiled_eval(xp_expr, xp)
            xp.doc = old_doc
            xp.node = old_node
            xp.context_size = old_size
            xp.proximity_position = old_pos
            xp.namespaces = old_ns
            if result.nil?
              transform_error(ctxt, nil, comp&.inst, "Evaluating global variable #{elem.name} failed\n")
              ctxt.state = STATE_STOPPED
              break
            end
            flag_rvts(ctxt, result, RVT_GLOBAL)
          elsif elem.tree.nil?
            result = +""
          else
            container = create_rvt(ctxt)
            break if container.nil?

            register_persist_rvt(ctxt, container)
            old_output = ctxt.output
            old_insert = ctxt.insert
            old_xp_doc = ctxt.xpath_ctxt.doc
            ctxt.output = container
            ctxt.insert = container
            ctxt.xpath_ctxt.doc = ctxt.initial_context_doc
            apply_one_template(ctxt, ctxt.node, elem.tree, nil, nil)
            ctxt.xpath_ctxt.doc = old_xp_doc
            ctxt.insert = old_insert
            ctxt.output = old_output
            result = XPath.new_value_tree(container)
            result = +"" if result.nil?
          end
        end while false # rubocop:disable Lint/Loop
        elem.name = old_var_name
        ctxt.inst = old_inst
        unless result.nil?
          elem.value = result
          elem.computed = true
        end
        result
      end

      # xsltEvalGlobalVariables
      def eval_global_variables(ctxt)
        return -1 if ctxt.nil? || ctxt.document.nil?

        head = nil
        style = ctxt.style
        while style
          elem = style.variables
          while elem
            key = [elem.name, elem.name_uri]
            defn = ctxt.global_vars[key]
            if defn.nil?
              defn = copy_stack_elem(elem)
              ctxt.global_vars[key] = defn
              defn.next = head
              head = defn
            elsif elem.comp && elem.comp.type == FUNC_VARIABLE
              if elem.comp.inst && defn.comp && defn.comp.inst && elem.comp.inst.doc.equal?(defn.comp.inst.doc)
                transform_error(ctxt, style, elem.comp.inst, "Global variable #{elem.name} already defined\n")
                style.errors += 1
              end
            end
            elem = elem.next
          end
          style = next_import(style)
        end
        elem = head
        while elem
          eval_global_variable(elem, ctxt)
          nxt = elem.next
          elem.next = nil
          elem = nxt
        end
        0
      end

      # xsltRegisterGlobalVariable
      def register_global_variable(style, name, ns_uri, sel, tree, comp, value)
        return -1 if style.nil? || name.nil? || comp.nil?

        elem = new_stack_elem(nil)
        elem.comp = comp
        elem.name = name
        elem.select = sel
        elem.name_uri = ns_uri if ns_uri
        elem.tree = tree
        tmp = style.variables
        while tmp
          if elem.comp.type == FUNC_VARIABLE && tmp.comp.type == FUNC_VARIABLE &&
              elem.name == tmp.name && elem.name_uri == tmp.name_uri
            transform_error(nil, style, comp.inst, "redefinition of global variable #{elem.name}\n")
            style.errors += 1
          end
          tmp = tmp.next
        end
        elem.next = style.variables
        style.variables = elem
        if value
          elem.computed = true
          elem.value = value
        end
        0
      end

      # xsltProcessUserParamInternal
      def process_user_param_internal(ctxt, name, value, eval)
        return -1 if ctxt.nil?
        return 0 if name.nil? || value.nil?

        style = ctxt.style
        href = nil
        if name.start_with?("{")
          idx = name.index("}")
          if idx.nil?
            transform_error(ctxt, style, nil, "user param : malformed parameter name : #{name}\n")
          else
            href = name[1...idx]
            name = name[(idx + 1)..]
          end
        else
          name, prefix = split_qname(name)
          if prefix
            ns = Tree.search_ns(style.doc, Tree.doc_get_root_element(style.doc), prefix)
            if ns.nil?
              transform_error(ctxt, style, nil, "user param : no namespace bound to prefix #{prefix}\n")
              href = nil
            else
              href = ns.href
            end
          end
        end
        return -1 if name.nil?

        if ctxt.global_vars.key?([name, href])
          transform_error(ctxt, style, nil, "Global parameter #{name} already defined\n")
        end

        while style
          elem = ctxt.style.variables
          while elem
            if elem.comp && elem.comp.type == FUNC_VARIABLE && elem.name == name && elem.name_uri == href
              return 0
            end

            elem = elem.next
          end
          style = next_import(style)
        end
        style = ctxt.style

        result = nil
        if eval
          xp_expr = XPath.ctxt_compile(ctxt.xpath_ctxt, value)
          if xp_expr
            xp = ctxt.xpath_ctxt
            old_doc = xp.doc
            old_node = xp.node
            old_pos = xp.proximity_position
            old_size = xp.context_size
            old_ns = xp.namespaces
            xp.doc = ctxt.initial_context_doc
            xp.node = ctxt.initial_context_node
            xp.context_size = 1
            xp.proximity_position = 1
            xp.namespaces = nil
            result = XPath.compiled_eval(xp_expr, xp)
            xp.doc = old_doc
            xp.node = old_node
            xp.context_size = old_size
            xp.proximity_position = old_pos
            xp.namespaces = old_ns
          end
          if result.nil?
            transform_error(ctxt, style, nil, "Evaluating user parameter #{name} failed\n")
            ctxt.state = STATE_STOPPED
            return -1
          end
        end

        elem = new_stack_elem(nil)
        elem.name = name
        elem.select = value
        elem.name_uri = href if href
        elem.tree = nil
        elem.computed = true
        elem.value = eval ? result : value.dup

        if ctxt.global_vars.key?([name, href])
          transform_error(ctxt, style, nil, "Global parameter #{name} already defined\n")
        else
          ctxt.global_vars[[name, href]] = elem
        end
        0
      end

      # xsltEvalUserParams: +params+ is a flat Array [name, value, ...]
      def eval_user_params(ctxt, params)
        return 0 if params.nil?

        params.each_slice(2) do |name, value|
          return -1 if eval_one_user_param(ctxt, name, value) != 0
        end
        0
      end

      # xsltQuoteUserParams
      def quote_user_params(ctxt, params)
        return 0 if params.nil?

        params.each_slice(2) do |name, value|
          return -1 if quote_one_user_param(ctxt, name, value) != 0
        end
        0
      end

      def eval_one_user_param(ctxt, name, value)
        process_user_param_internal(ctxt, name, value, true)
      end

      def quote_one_user_param(ctxt, name, value)
        process_user_param_internal(ctxt, name, value, false)
      end

      # xsltBuildVariable
      def build_variable(ctxt, comp, tree)
        elem = new_stack_elem(ctxt)
        elem.comp = comp
        elem.name = comp.name
        elem.select = comp.select
        elem.name_uri = comp.ns
        elem.tree = tree
        elem.value = eval_variable(ctxt, elem, comp)
        elem.computed = true
        elem
      end

      # xsltRegisterVariable
      def register_variable(ctxt, comp, tree, is_param)
        present = check_stack_elem(ctxt, comp.name, comp.ns)
        if !is_param
          if present != 0 && present != 3
            transform_error(ctxt, nil, comp.inst, "XSLT-variable: Redefinition of variable '#{comp.name}'.\n")
            return 0
          end
        elsif present != 0
          if present == 1 || present == 2
            transform_error(ctxt, nil, comp.inst, "XSLT-param: Redefinition of parameter '#{comp.name}'.\n")
            return 0
          end
          return 0
        end
        variable = build_variable(ctxt, comp, tree)
        add_stack_elem(ctxt, variable)
        0
      end

      # xsltGlobalVariableLookup
      def global_variable_lookup(ctxt, name, ns_uri)
        return nil if ctxt.xpath_ctxt.nil? || ctxt.global_vars.nil?

        elem = ctxt.global_vars[[name, ns_uri]]
        return nil if elem.nil?

        if !elem.computed
          if elem.name.equal?(COMPUTING_GLOBAL_VAR_MARKER)
            transform_error(ctxt, nil, elem.comp&.inst, "Recursive definition of #{name}\n")
            return nil
          end
          ret = eval_global_variable(elem, ctxt)
        else
          ret = elem.value
        end
        ret.nil? ? nil : XPath.object_copy(ret)
      end

      # xsltVariableLookup
      def variable_lookup(ctxt, name, ns_uri)
        return nil if ctxt.nil?

        elem = stack_lookup(ctxt, name, ns_uri)
        return global_variable_lookup(ctxt, name, ns_uri) if elem.nil?

        unless elem.computed
          elem.value = eval_variable(ctxt, elem, nil)
          elem.computed = true
        end
        elem.value.nil? ? nil : XPath.object_copy(elem.value)
      end

      # xsltParseStylesheetCallerParam
      def parse_stylesheet_caller_param(ctxt, inst)
        return nil if ctxt.nil? || inst.nil? || inst.type != ELEMENT_NODE

        comp = inst.psvi
        if comp.nil?
          transform_error(ctxt, nil, inst,
            "Internal error in xsltParseStylesheetCallerParam(): The XSLT 'with-param' instruction was not compiled.\n")
          return nil
        end
        if comp.name.nil?
          transform_error(ctxt, nil, inst,
            "Internal error in xsltParseStylesheetCallerParam(): XSLT 'with-param': The attribute 'name' was not compiled.\n")
          return nil
        end
        tree = comp.select.nil? ? inst.children : inst
        build_variable(ctxt, comp, tree)
      end

      # xsltParseGlobalVariable
      def parse_global_variable(style, cur)
        return if cur.nil? || style.nil? || cur.type != ELEMENT_NODE

        style_pre_compute(style, cur)
        comp = cur.psvi
        if comp.nil?
          transform_error(nil, style, cur, "xsl:variable : compilation failed\n")
          return
        end
        if comp.name.nil?
          transform_error(nil, style, cur, "xsl:variable : missing name attribute\n")
          return
        end
        parse_template_content(style, cur) if cur.children
        register_global_variable(style, comp.name, comp.ns, comp.select, cur.children, comp, nil)
      end

      # xsltParseGlobalParam
      def parse_global_param(style, cur)
        return if cur.nil? || style.nil? || cur.type != ELEMENT_NODE

        style_pre_compute(style, cur)
        comp = cur.psvi
        if comp.nil?
          transform_error(nil, style, cur, "xsl:param : compilation failed\n")
          return
        end
        if comp.name.nil?
          transform_error(nil, style, cur, "xsl:param : missing name attribute\n")
          return
        end
        parse_template_content(style, cur) if cur.children
        register_global_variable(style, comp.name, comp.ns, comp.select, cur.children, comp, nil)
      end

      # xsltParseStylesheetVariable
      def parse_stylesheet_variable(ctxt, inst)
        return if inst.nil? || ctxt.nil? || inst.type != ELEMENT_NODE

        comp = inst.psvi
        if comp.nil?
          transform_error(ctxt, nil, inst,
            "Internal error in xsltParseStylesheetVariable(): The XSLT 'variable' instruction was not compiled.\n")
          return
        end
        if comp.name.nil?
          transform_error(ctxt, nil, inst,
            "Internal error in xsltParseStylesheetVariable(): The attribute 'name' was not compiled.\n")
          return
        end
        register_variable(ctxt, comp, inst.children, false)
      end

      # xsltParseStylesheetParam
      def parse_stylesheet_param(ctxt, cur)
        return if cur.nil? || ctxt.nil? || cur.type != ELEMENT_NODE

        comp = cur.psvi
        if comp.nil? || comp.name.nil?
          transform_error(ctxt, nil, cur,
            "Internal error in xsltParseStylesheetParam(): The XSLT 'param' declaration was not compiled correctly.\n")
          return
        end
        register_variable(ctxt, comp, cur.children, true)
      end

      # xsltXPathVariableLookup
      def xpath_variable_lookup(tctxt, name, ns_uri)
        return nil if tctxt.nil? || name.nil?

        if tctxt.vars_nr != 0
          variable = nil
          tab = tctxt.vars_tab
          i = tab.length
          base = tctxt.vars_base
          while i > base
            cur = tab[i - 1]
            if cur.name == name && cur.name_uri == ns_uri
              variable = cur
              break
            end
            i -= 1
          end
          if variable
            unless variable.computed
              variable.value = eval_variable(tctxt, variable, nil)
              variable.computed = true
            end
            return variable.value.nil? ? nil : XPath.object_copy(variable.value)
          end
        end
        value = nil
        value = global_variable_lookup(tctxt, name, ns_uri) if tctxt.global_vars
        if value.nil?
          if ns_uri
            transform_error(tctxt, nil, tctxt.inst, "Variable '{#{ns_uri}}#{name}' has not been declared.\n")
          else
            transform_error(tctxt, nil, tctxt.inst, "Variable '#{name}' has not been declared.\n")
          end
        end
        value
      end
    end
  end
end
