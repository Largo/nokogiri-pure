# frozen_string_literal: true

# Port of libxslt preproc.c: precomputation of XSLT instructions (inst.psvi = StylePreComp).

module Nokogiri
  module Pure
    module XSLT
      module_function

      def same_ns?(a, b)
        a.equal?(b) || (a && b && a.href == b.href)
      end

      # xsltCheckTopLevelElement
      def check_top_level_element(style, inst, err)
        return -1 if style.nil? || inst.nil? || inst.ns.nil?

        parent = inst.parent
        if parent.nil?
          if err
            transform_error(nil, style, inst, "internal problem: element has no parent\n")
            style.errors += 1
          end
          return 0
        end
        if parent.ns.nil? || parent.type != ELEMENT_NODE ||
            (!parent.ns.equal?(inst.ns) && parent.ns.href != inst.ns.href) ||
            (parent.name != "stylesheet" && parent.name != "transform")
          if err
            transform_error(nil, style, inst, "element #{inst.name} only allowed as child of stylesheet\n")
            style.errors += 1
          end
          return 0
        end
        1
      end

      # xsltCheckInstructionElement
      def check_instruction_element(style, inst)
        return if style.nil? || inst.nil? || inst.ns.nil? || style.literal_result

        has_ext = !style.ext_infos.nil?
        parent = inst.parent
        if parent.nil?
          transform_error(nil, style, inst, "internal problem: element has no parent\n")
          style.errors += 1
          return
        end
        while parent && parent.type != DOCUMENT_NODE
          if (parent.ns.equal?(inst.ns) || (parent.ns && parent.ns.href == inst.ns.href)) &&
              %w[template param attribute variable].include?(parent.name)
            return
          end
          return if has_ext && parent.ns && style.ext_infos.key?(parent.ns.href)

          parent = parent.parent
        end
        transform_error(nil, style, inst, "element #{inst.name} only allowed within a template, variable or param\n")
        style.errors += 1
      end

      # xsltCheckParentElement
      def check_parent_element(style, inst, allow1, allow2)
        return if style.nil? || inst.nil? || inst.ns.nil? || style.literal_result

        parent = inst.parent
        if parent.nil?
          transform_error(nil, style, inst, "internal problem: element has no parent\n")
          style.errors += 1
          return
        end
        if (parent.ns.equal?(inst.ns) || (parent.ns && parent.ns.href == inst.ns.href)) &&
            (parent.name == allow1 || (allow2 && parent.name == allow2))
          return
        end
        if style.ext_infos
          while parent && parent.type != DOCUMENT_NODE
            return if parent.ns && style.ext_infos.key?(parent.ns.href)

            parent = parent.parent
          end
        end
        transform_error(nil, style, inst, "element #{inst.name} is not allowed within that context\n")
        style.errors += 1
      end

      INSTR_FUNCS = {
        FUNC_COPY => :copy, FUNC_SORT => :sort, FUNC_TEXT => :text, FUNC_ELEMENT => :element,
        FUNC_ATTRIBUTE => :attribute, FUNC_COMMENT => :comment, FUNC_PI => :processing_instruction,
        FUNC_COPYOF => :copy_of, FUNC_VALUEOF => :value_of, FUNC_NUMBER => :number,
        FUNC_APPLYIMPORTS => :apply_imports, FUNC_CALLTEMPLATE => :call_template,
        FUNC_APPLYTEMPLATES => :apply_templates, FUNC_CHOOSE => :choose, FUNC_IF => :xslt_if,
        FUNC_FOREACH => :for_each, FUNC_DOCUMENT => :document_elem,
      }.freeze

      # a callable for an instruction implementation. A lambda (whose #call the VM dispatches
      # without a native frame), not a Method object (Method#call re-enters the VM from C).
      def instr_func(sym)
        @instr_funcs ||= {}
        @instr_funcs[sym] ||= ->(ctxt, node, inst, comp) { XSLT.__send__(sym, ctxt, node, inst, comp) }
      end

      # xsltNewStylePreComp
      def new_style_pre_comp(style, type)
        return nil if style.nil?

        cur = StylePreComp.new(type)
        if (f = INSTR_FUNCS[type])
          cur.func = instr_func(f)
        end
        cur.next = style.pre_comps
        style.pre_comps = cur
        cur
      end

      # xsltDocumentComp
      def document_comp(style, inst, _function = nil)
        comp = new_style_pre_comp(style, FUNC_DOCUMENT)
        return nil if comp.nil?

        comp.inst = inst
        comp.ver11 = false
        filename = nil
        if inst.name == "output"
          filename, comp.has_filename = eval_static_attr_value_template(style, inst, "file", nil)
        elsif inst.name == "write"
          # nothing
        elsif inst.name == "document"
          comp.ver11 = true if inst.ns && inst.ns.href == NAMESPACE
          filename, comp.has_filename = eval_static_attr_value_template(style, inst, "href", nil)
        end
        comp.filename = filename if comp.has_filename
        comp
      end

      # xsltSortComp
      def sort_comp(style, inst)
        return if style.nil? || inst.nil? || inst.type != ELEMENT_NODE

        comp = new_style_pre_comp(style, FUNC_SORT)
        return if comp.nil?

        inst.psvi = comp
        comp.inst = inst
        comp.stype, comp.has_stype = eval_static_attr_value_template(style, inst, "data-type", nil)
        if comp.stype
          if comp.stype == "text"
            comp.number = false
          elsif comp.stype == "number"
            comp.number = true
          else
            transform_error(nil, style, inst, "xsltSortComp: no support for data-type = #{comp.stype}\n")
            comp.number = false
            style.warnings += 1
          end
        end
        comp.order, comp.has_order = eval_static_attr_value_template(style, inst, "order", nil)
        if comp.order
          if comp.order == "ascending"
            comp.descending = false
          elsif comp.order == "descending"
            comp.descending = true
          else
            transform_error(nil, style, inst, "xsltSortComp: invalid value #{comp.order} for order\n")
            comp.descending = false
            style.warnings += 1
          end
        end
        comp.case_order, comp.has_use = eval_static_attr_value_template(style, inst, "case-order", nil)
        if comp.case_order
          if comp.case_order == "upper-first"
            comp.lower_first = false
          elsif comp.case_order == "lower-first"
            comp.lower_first = true
          else
            transform_error(nil, style, inst, "xsltSortComp: invalid value #{comp.order || "(null)"} for order\n")
            comp.lower_first = false
            style.warnings += 1
          end
        end
        comp.lang, comp.has_lang = eval_static_attr_value_template(style, inst, "lang", nil)
        comp.select = get_cns_prop(style, inst, "select", NAMESPACE)
        comp.select = +"." if comp.select.nil?
        comp.comp = xpath_compile(style, comp.select)
        if comp.comp.nil?
          transform_error(nil, style, inst, "xsltSortComp: could not compile select expression '#{comp.select}'\n")
          style.errors += 1
        end
        if inst.children
          transform_error(nil, style, inst, "xsl:sort : is not empty\n")
          style.errors += 1
        end
      end

      # xsltCopyComp
      def copy_comp(style, inst)
        return if style.nil? || inst.nil? || inst.type != ELEMENT_NODE

        comp = new_style_pre_comp(style, FUNC_COPY)
        inst.psvi = comp
        comp.inst = inst
        comp.use = get_cns_prop(style, inst, "use-attribute-sets", NAMESPACE)
        comp.has_use = !comp.use.nil?
      end

      # xsltTextComp
      def text_comp(style, inst)
        return if style.nil? || inst.nil? || inst.type != ELEMENT_NODE

        comp = new_style_pre_comp(style, FUNC_TEXT)
        inst.psvi = comp
        comp.inst = inst
        comp.noescape = false
        prop = get_cns_prop(style, inst, "disable-output-escaping", NAMESPACE)
        if prop
          if prop == "yes"
            comp.noescape = true
          elsif prop != "no"
            transform_error(nil, style, inst, "xsl:text: disable-output-escaping allows only yes or no\n")
            style.warnings += 1
          end
        end
      end

      # xsltElementComp
      def element_comp(style, inst)
        return if style.nil? || inst.nil? || inst.type != ELEMENT_NODE

        comp = new_style_pre_comp(style, FUNC_ELEMENT)
        inst.psvi = comp
        comp.inst = inst
        comp.name, comp.has_name = eval_static_attr_value_template(style, inst, "name", nil)
        unless comp.has_name
          transform_error(nil, style, inst, "xsl:element: The attribute 'name' is missing.\n")
          style.errors += 1
          return
        end
        comp.ns, comp.has_ns = eval_static_attr_value_template(style, inst, "namespace", nil)
        if comp.name
          if !valid_qname?(comp.name)
            transform_error(nil, style, inst,
              "xsl:element: The value '#{comp.name}' of the attribute 'name' is not a valid QName.\n")
            style.errors += 1
          else
            _name, prefix = split_qname(comp.name)
            unless comp.has_ns
              ns = Tree.search_ns(inst.doc, inst, prefix)
              if ns
                comp.ns = ns.href
                comp.has_ns = true
              elsif prefix
                transform_error(nil, style, inst,
                  "xsl:element: The prefixed QName '#{comp.name}' has no namespace binding in scope in the " \
                  "stylesheet; this is an error, since the namespace was not specified by the instruction itself.\n")
                style.errors += 1
              end
            end
            comp.has_name = false if prefix && prefix[0, 3].casecmp?("xml")
          end
        end
        comp.use, comp.has_use = eval_static_attr_value_template(style, inst, "use-attribute-sets", nil)
      end

      # xsltAttributeComp
      def attribute_comp(style, inst)
        return if style.nil? || inst.nil? || inst.type != ELEMENT_NODE

        comp = new_style_pre_comp(style, FUNC_ATTRIBUTE)
        inst.psvi = comp
        comp.inst = inst
        comp.name, comp.has_name = eval_static_attr_value_template(style, inst, "name", nil)
        unless comp.has_name
          transform_error(nil, style, inst, "XSLT-attribute: The attribute 'name' is missing.\n")
          style.errors += 1
          return
        end
        comp.ns, comp.has_ns = eval_static_attr_value_template(style, inst, "namespace", nil)
        return unless comp.name

        if !valid_qname?(comp.name)
          transform_error(nil, style, inst,
            "xsl:attribute: The value '#{comp.name}' of the attribute 'name' is not a valid QName.\n")
          style.errors += 1
        elsif comp.name == "xmlns"
          transform_error(nil, style, inst, "xsl:attribute: The attribute name 'xmlns' is not allowed.\n")
          style.errors += 1
        else
          _name, prefix = split_qname(comp.name)
          if prefix && !comp.has_ns
            ns = Tree.search_ns(inst.doc, inst, prefix)
            if ns
              comp.ns = ns.href
              comp.has_ns = true
            else
              transform_error(nil, style, inst,
                "xsl:attribute: The prefixed QName '#{comp.name}' has no namespace binding in scope in the " \
                "stylesheet; this is an error, since the namespace was not specified by the instruction itself.\n")
              style.errors += 1
            end
          end
        end
      end

      # xsltCommentComp
      def comment_comp(style, inst)
        return if style.nil? || inst.nil? || inst.type != ELEMENT_NODE

        comp = new_style_pre_comp(style, FUNC_COMMENT)
        inst.psvi = comp
        comp.inst = inst
      end

      # xsltProcessingInstructionComp
      def processing_instruction_comp(style, inst)
        return if style.nil? || inst.nil? || inst.type != ELEMENT_NODE

        comp = new_style_pre_comp(style, FUNC_PI)
        inst.psvi = comp
        comp.inst = inst
        comp.name, comp.has_name = eval_static_attr_value_template(style, inst, "name", NAMESPACE)
      end

      def select_comp(style, inst, type, missing_msg, compile_msg)
        return if style.nil? || inst.nil? || inst.type != ELEMENT_NODE

        comp = new_style_pre_comp(style, type)
        inst.psvi = comp
        comp.inst = inst
        yield comp if block_given?
        comp.select = get_cns_prop(style, inst, "select", NAMESPACE)
        if comp.select.nil?
          transform_error(nil, style, inst, missing_msg)
          style.errors += 1
          return
        end
        comp.comp = xpath_compile(style, comp.select)
        if comp.comp.nil?
          transform_error(nil, style, inst, format(compile_msg, comp.select))
          style.errors += 1
        end
      end

      # xsltCopyOfComp
      def copy_of_comp(style, inst)
        select_comp(style, inst, FUNC_COPYOF, "xsl:copy-of : select is missing\n",
          "xsl:copy-of : could not compile select expression '%s'\n")
      end

      # xsltValueOfComp
      def value_of_comp(style, inst)
        select_comp(style, inst, FUNC_VALUEOF, "xsl:value-of : select is missing\n",
          "xsl:value-of : could not compile select expression '%s'\n") do |comp|
          prop = get_cns_prop(style, inst, "disable-output-escaping", NAMESPACE)
          if prop
            if prop == "yes"
              comp.noescape = true
            elsif prop != "no"
              transform_error(nil, style, inst, "xsl:value-of : disable-output-escaping allows only yes or no\n")
              style.warnings += 1
            end
          end
        end
      end

      # xsltGetQNameProperty: returns [has_prop, ns_name, local_name]
      def get_qname_property(style, inst, prop_name, mandatory)
        prop = get_cns_prop(style, inst, prop_name, NAMESPACE)
        if prop.nil?
          if mandatory
            transform_error(nil, style, inst, "The attribute '#{prop_name}' is missing.\n")
            style.errors += 1
          end
          return [false, nil, nil]
        end
        unless valid_qname?(prop)
          transform_error(nil, style, inst, "The value '#{prop}' of the attribute '#{prop_name}' is not a valid QName.\n")
          style.errors += 1
          return [false, nil, nil]
        end
        uri, local = get_qname_uri2(style, inst, prop)
        if local.nil?
          style.errors += 1
          return [false, nil, nil]
        end
        [true, uri, local]
      end

      # xsltWithParamComp
      def with_param_comp(style, inst)
        return if style.nil? || inst.nil? || inst.type != ELEMENT_NODE

        comp = new_style_pre_comp(style, FUNC_WITHPARAM)
        inst.psvi = comp
        comp.inst = inst
        comp.has_name, comp.ns, comp.name = get_qname_property(style, inst, "name", true)
        comp.has_ns = true if comp.ns
        comp.select = get_cns_prop(style, inst, "select", NAMESPACE)
        if comp.select
          comp.comp = xpath_compile(style, comp.select)
          if comp.comp.nil?
            transform_error(nil, style, inst, "XSLT-with-param: Failed to compile select expression '#{comp.select}'\n")
            style.errors += 1
          end
          if inst.children
            transform_error(nil, style, inst,
              "XSLT-with-param: The content should be empty since the attribute select is present.\n")
            style.warnings += 1
          end
        end
      end

      # xsltNumberComp
      def number_comp(style, cur)
        return if style.nil? || cur.nil? || cur.type != ELEMENT_NODE

        comp = new_style_pre_comp(style, FUNC_NUMBER)
        cur.psvi = comp
        nd = comp.numdata
        nd.doc = cur.doc
        nd.node = cur
        nd.value = get_cns_prop(style, cur, "value", NAMESPACE)
        prop, nd.has_format = eval_static_attr_value_template(style, cur, "format", NAMESPACE)
        nd.format = nd.has_format ? prop : +""
        nd.count = get_cns_prop(style, cur, "count", NAMESPACE)
        nd.from = get_cns_prop(style, cur, "from", NAMESPACE)
        prop = get_cns_prop(style, cur, "count", NAMESPACE)
        nd.count_pat = compile_pattern(prop, cur.doc, cur, style, nil) if prop
        prop = get_cns_prop(style, cur, "from", NAMESPACE)
        nd.from_pat = compile_pattern(prop, cur.doc, cur, style, nil) if prop
        prop = get_cns_prop(style, cur, "level", NAMESPACE)
        if prop
          if %w[single multiple any].include?(prop)
            nd.level = prop
          else
            transform_error(nil, style, cur, "xsl:number : invalid value #{prop} for level\n")
            style.warnings += 1
          end
        end
        prop = get_cns_prop(style, cur, "lang", NAMESPACE)
        transform_error(nil, style, cur, "xsl:number : lang attribute not implemented\n") if prop
        prop = get_cns_prop(style, cur, "letter-value", NAMESPACE)
        if prop
          if prop == "alphabetic"
            transform_error(nil, style, cur, "xsl:number : letter-value 'alphabetic' not implemented\n")
          elsif prop == "traditional"
            transform_error(nil, style, cur, "xsl:number : letter-value 'traditional' not implemented\n")
          else
            transform_error(nil, style, cur, "xsl:number : invalid value #{prop} for letter-value\n")
          end
          style.warnings += 1
        end
        prop = get_cns_prop(style, cur, "grouping-separator", NAMESPACE)
        if prop
          cp, len = get_utf8_char(prop, 0)
          nd.grouping_character_len = len
          nd.grouping_character = cp < 0 ? 0 : cp
        end
        prop = get_cns_prop(style, cur, "grouping-size", NAMESPACE)
        if prop
          m = /\A\s*([+-]?\d+)/.match(prop)
          nd.digits_per_group = m[1].to_i if m
        else
          nd.grouping_character = 0
        end
        if nd.value.nil? && nd.level.nil?
          nd.level = +"single"
        end
      end

      def simple_comp(style, inst, type)
        return if style.nil? || inst.nil? || inst.type != ELEMENT_NODE

        comp = new_style_pre_comp(style, type)
        inst.psvi = comp
        comp.inst = inst
        comp
      end

      # xsltCallTemplateComp
      def call_template_comp(style, inst)
        comp = simple_comp(style, inst, FUNC_CALLTEMPLATE)
        return if comp.nil?

        comp.has_name, comp.ns, comp.name = get_qname_property(style, inst, "name", true)
        comp.has_ns = true if comp.ns
      end

      # xsltApplyTemplatesComp
      def apply_templates_comp(style, inst)
        comp = simple_comp(style, inst, FUNC_APPLYTEMPLATES)
        return if comp.nil?

        _has, comp.mode_uri, comp.mode = get_qname_property(style, inst, "mode", false)
        comp.select = get_cns_prop(style, inst, "select", NAMESPACE)
        if comp.select
          comp.comp = xpath_compile(style, comp.select)
          if comp.comp.nil?
            transform_error(nil, style, inst, "XSLT-apply-templates: could not compile select expression '#{comp.select}'\n")
            style.errors += 1
          end
        end
      end

      def test_comp(style, inst, type, name)
        comp = simple_comp(style, inst, type)
        return if comp.nil?

        comp.test = get_cns_prop(style, inst, "test", NAMESPACE)
        if comp.test.nil?
          transform_error(nil, style, inst, "xsl:#{name} : test is not defined\n")
          style.errors += 1
          return
        end
        comp.comp = xpath_compile(style, comp.test)
        if comp.comp.nil?
          transform_error(nil, style, inst, "xsl:#{name} : could not compile test expression '#{comp.test}'\n")
          style.errors += 1
        end
      end

      # xsltForEachComp
      def for_each_comp(style, inst)
        comp = simple_comp(style, inst, FUNC_FOREACH)
        return if comp.nil?

        comp.select = get_cns_prop(style, inst, "select", NAMESPACE)
        if comp.select.nil?
          transform_error(nil, style, inst, "xsl:for-each : select is missing\n")
          style.errors += 1
        else
          comp.comp = xpath_compile(style, comp.select)
          if comp.comp.nil?
            transform_error(nil, style, inst, "xsl:for-each : could not compile select expression '#{comp.select}'\n")
            style.errors += 1
          end
        end
      end

      # xsltVariableComp
      def variable_comp(style, inst)
        comp = simple_comp(style, inst, FUNC_VARIABLE)
        return if comp.nil?

        comp.has_name, comp.ns, comp.name = get_qname_property(style, inst, "name", true)
        comp.has_ns = true if comp.ns
        comp.select = get_cns_prop(style, inst, "select", NAMESPACE)
        if comp.select
          comp.comp = xpath_compile(style, comp.select)
          if comp.comp.nil?
            transform_error(nil, style, inst, "XSLT-variable: Failed to compile the XPath expression '#{comp.select}'.\n")
            style.errors += 1
          end
          cur = inst.children
          while cur
            if cur.type != COMMENT_NODE && (cur.type != TEXT_NODE || !blank?(cur.content))
              transform_error(nil, style, inst,
                "XSLT-variable: There must be no child nodes, since the attribute 'select' was specified.\n")
              style.errors += 1
            end
            cur = cur.next
          end
        end
      end

      # xsltParamComp
      def param_comp(style, inst)
        comp = simple_comp(style, inst, FUNC_PARAM)
        return if comp.nil?

        comp.has_name, comp.ns, comp.name = get_qname_property(style, inst, "name", true)
        comp.has_ns = true if comp.ns
        comp.select = get_cns_prop(style, inst, "select", NAMESPACE)
        if comp.select
          comp.comp = xpath_compile(style, comp.select)
          if comp.comp.nil?
            transform_error(nil, style, inst, "XSLT-param: could not compile select expression '#{comp.select}'.\n")
            style.errors += 1
          end
          if inst.children
            transform_error(nil, style, inst,
              "XSLT-param: The content should be empty since the attribute 'select' is present.\n")
            style.warnings += 1
          end
        end
      end

      # xsltStylePreCompute
      def style_pre_compute(style, inst)
        return if inst.nil? || inst.type != ELEMENT_NODE || !inst.psvi.nil?

        if xslt_elem?(inst)
          case inst.name
          when "apply-templates"
            check_instruction_element(style, inst)
            apply_templates_comp(style, inst)
          when "with-param"
            check_parent_element(style, inst, "apply-templates", "call-template")
            with_param_comp(style, inst)
          when "value-of"
            check_instruction_element(style, inst)
            value_of_comp(style, inst)
          when "copy"
            check_instruction_element(style, inst)
            copy_comp(style, inst)
          when "copy-of"
            check_instruction_element(style, inst)
            copy_of_comp(style, inst)
          when "if"
            check_instruction_element(style, inst)
            test_comp(style, inst, FUNC_IF, "if")
          when "when"
            check_parent_element(style, inst, "choose", nil)
            test_comp(style, inst, FUNC_WHEN, "when")
          when "choose"
            check_instruction_element(style, inst)
            simple_comp(style, inst, FUNC_CHOOSE)
          when "for-each"
            check_instruction_element(style, inst)
            for_each_comp(style, inst)
          when "apply-imports"
            check_instruction_element(style, inst)
            simple_comp(style, inst, FUNC_APPLYIMPORTS)
          when "attribute"
            parent = inst.parent
            if parent.nil? || parent.type != ELEMENT_NODE || parent.ns.nil? ||
                (!parent.ns.equal?(inst.ns) && parent.ns.href != inst.ns.href) ||
                parent.name != "attribute-set"
              check_instruction_element(style, inst)
            end
            attribute_comp(style, inst)
          when "element"
            check_instruction_element(style, inst)
            element_comp(style, inst)
          when "text"
            check_instruction_element(style, inst)
            text_comp(style, inst)
          when "sort"
            check_parent_element(style, inst, "apply-templates", "for-each")
            sort_comp(style, inst)
          when "comment"
            check_instruction_element(style, inst)
            comment_comp(style, inst)
          when "number"
            check_instruction_element(style, inst)
            number_comp(style, inst)
          when "processing-instruction"
            check_instruction_element(style, inst)
            processing_instruction_comp(style, inst)
          when "call-template"
            check_instruction_element(style, inst)
            call_template_comp(style, inst)
          when "param"
            check_instruction_element(style, inst) if check_top_level_element(style, inst, false) == 0
            param_comp(style, inst)
          when "variable"
            check_instruction_element(style, inst) if check_top_level_element(style, inst, false) == 0
            variable_comp(style, inst)
          when "otherwise"
            check_parent_element(style, inst, "choose", nil)
            check_instruction_element(style, inst)
            return
          when "template", "output", "preserve-space", "strip-space", "key", "attribute-set",
               "namespace-alias", "include", "import", "decimal-format"
            check_top_level_element(style, inst, true)
            return
          when "stylesheet", "transform"
            parent = inst.parent
            if parent.nil? || parent.type != DOCUMENT_NODE
              transform_error(nil, style, inst, "element #{inst.name} only allowed only as root element\n")
              style.errors += 1
            end
            return
          when "message", "fallback"
            check_instruction_element(style, inst)
            return
          when "document"
            check_instruction_element(style, inst)
            inst.psvi = document_comp(style, inst, nil)
          else
            if style.nil? || !style.forwards_compatible
              transform_error(nil, style, inst, "xsltStylePreCompute: unknown xsl:#{inst.name}\n")
              style.warnings += 1 if style
            end
          end
          cur = inst.psvi
          cur.ns_list = Tree.get_ns_list(inst.doc, inst) if cur.is_a?(StylePreComp)
        else
          inst.psvi = pre_compute_ext_module_element(style, inst)
          inst.psvi = EXT_MARKER if inst.psvi.nil?
        end
      end
    end
  end
end
