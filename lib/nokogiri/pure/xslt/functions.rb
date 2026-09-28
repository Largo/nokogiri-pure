# frozen_string_literal: true

# Port of libxslt functions.c: document(), key(), unparsed-entity-uri(), format-number(),
# generate-id(), system-property(), element-available(), function-available(), current().

module Nokogiri
  module Pure
    module XSLT
      module_function

      def node_set?(v)
        v.is_a?(Array) && !v.is_a?(XPath::ValueTree)
      end

      # xsltXPathFunctionLookup
      def xpath_function_lookup(xp, name, ns_uri)
        return nil if xp.nil? || name.nil? || ns_uri.nil?

        ret = xp.func_hash&.[]([name, ns_uri])
        ret ||= ext_module_function_lookup(name, ns_uri)
        ret
      end

      # xsltDocumentFunctionLoadDocument
      def document_function_load_document(ctxt, uri, fragment)
        tctxt = xpath_get_transform_context(ctxt)
        res_obj = nil
        if tctxt.nil?
          transform_error(nil, nil, nil, "document() : internal error tctxt == NULL\n")
        else
          idoc = load_document(tctxt, uri)
          doc = nil
          if idoc.nil?
            if uri.nil? || uri.start_with?("#") || (tctxt.style.doc && tctxt.style.doc.url == uri)
              doc = tctxt.style.doc
            end
          else
            doc = idoc.doc
          end
          if doc
            if fragment.nil?
              ctxt.value_push([doc])
              return
            end
            xptr = XPath::Context.new(doc)
            res_obj = xpointer_eval(fragment, xptr)
            if res_obj && !node_set?(res_obj)
              transform_error(tctxt, nil, nil, "document() : XPointer does not select a node set: ##{fragment}\n")
              res_obj = nil
            end
          end
        end
        ctxt.value_push(res_obj || [])
      end

      # xmlXPtrEval (subset: shorthand pointers and xpointer()/xpath1() schemes)
      def xpointer_eval(str, ctx)
        if Pure.const_defined?(:XPointer) && Pure::XPointer.respond_to?(:eval)
          return Pure::XPointer.eval(str, ctx)
        end

        if (m = /\A\s*(?:xpointer|xpath1)\((.*)\)\s*\z/m.match(str))
          ctx.node = ctx.doc
          return XPath.eval(m[1], ctx)
        end
        if /\A[^\s()]+\z/.match?(str)
          attr = Tree.get_id(ctx.doc, str)
          return attr ? [attr.parent] : []
        end
        nil
      end

      # xsltDocumentFunction
      def document_function(ctxt, nargs)
        if nargs < 1 || nargs > 2
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "document() : invalid number of args #{nargs}\n")
          ctxt.error = XPath::INVALID_ARITY
          return
        end
        if ctxt.value.nil?
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "document() : invalid arg value\n")
          ctxt.error = XPath::INVALID_TYPE
          return
        end
        obj2 = nil
        if nargs == 2
          unless node_set?(ctxt.value)
            transform_error(xpath_get_transform_context(ctxt), nil, nil, "document() : invalid arg expecting a nodeset\n")
            ctxt.error = XPath::INVALID_TYPE
            return
          end
          obj2 = ctxt.value_pop
        end
        if ctxt.value && node_set?(ctxt.value)
          obj = ctxt.value_pop
          ret = []
          obj.each do |n|
            ctxt.value_push(XPath.new_node_set(n))
            ctxt.fn_string(1)
            if nargs == 2
              ctxt.value_push(XPath.object_copy(obj2))
            else
              ctxt.value_push(XPath.new_node_set(n))
            end
            break if ctxt.error != 0

            document_function(ctxt, 2)
            newobj = ctxt.value_pop
            ret = XPath.node_set_merge(ret, newobj) if newobj.is_a?(Array)
          end
          ctxt.value_push(ret)
          return
        end
        ctxt.fn_string(1)
        if ctxt.value.nil? || !ctxt.value.is_a?(String)
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "document() : invalid arg expecting a string\n")
          ctxt.error = XPath::INVALID_TYPE
          return
        end
        obj = ctxt.value_pop
        tctxt = xpath_get_transform_context(ctxt)
        url = obj
        parsed = URI_.parse(url)
        if parsed.nil?
          transform_error(tctxt, nil, nil, "document() : failed to parse URI '#{url}'\n")
          ctxt.value_push([])
          return
        end
        fragment = nil
        if (idx = url.index("#"))
          fragment = url[(idx + 1)..]
          url = url[0, idx]
        end
        if obj2 && !obj2.empty? && real_node?(obj2[0])
          target = obj2[0]
          target = target.parent if target.type == ATTRIBUTE_NODE || target.type == PI_NODE
          base = Tree.node_get_base(target.doc, target)
        elsif tctxt&.inst
          base = Tree.node_get_base(tctxt.inst.doc, tctxt.inst)
        elsif tctxt&.style&.doc
          base = Tree.node_get_base(tctxt.style.doc, tctxt.style.doc)
        end
        uri = URI_.build_uri(url, base)
        if uri.nil?
          if tctxt&.style&.doc && tctxt.style.doc.url.nil?
            ctxt.value_push([tctxt.style.doc])
          else
            ctxt.value_push([])
          end
        else
          document_function_load_document(ctxt, uri, fragment)
        end
      end

      # xsltKeyFunction
      def key_function(ctxt, nargs)
        if nargs != 2
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "key() : expects two arguments\n")
          ctxt.error = XPath::INVALID_ARITY
          return
        end
        obj2 = ctxt.value_pop
        ctxt.fn_string(1)
        if obj2.nil? || ctxt.value.nil? || !ctxt.value.is_a?(String)
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "key() : invalid arg expecting a string\n")
          ctxt.error = XPath::INVALID_TYPE
          return
        end
        obj1 = ctxt.value_pop
        if obj2.is_a?(Array)
          ret = []
          obj2.each do |n|
            ctxt.value_push(obj1)
            ctxt.value_push(XPath.new_node_set(n))
            ctxt.fn_string(1)
            key_function(ctxt, 2)
            newobj = ctxt.value_pop
            ret = XPath.node_set_merge(ret, newobj) if newobj.is_a?(Array)
          end
          ctxt.value_push(ret)
          return
        end

        nodelist = nil
        tctxt = xpath_get_transform_context(ctxt)
        old_doc_info = tctxt.document
        xp = ctxt.context
        begin
          if xp.node.nil?
            transform_error(tctxt, nil, tctxt.inst,
              "Internal error in xsltKeyFunction(): The context node is not set on the XPath context.\n")
            tctxt.state = STATE_STOPPED
            break
          end
          qname = obj1
          split = split_qname2(qname)
          if split.nil?
            key = qname.dup
            key_uri = nil
          else
            key, prefix = split
            key_uri = xp.ns_lookup(prefix)
            transform_error(tctxt, nil, tctxt.inst, "key() : prefix #{prefix} is not bound\n") if key_uri.nil?
          end
          value = obj2.is_a?(String) ? obj2 : XPath.cast_to_string(obj2)
          tmp_node = nil
          if xp.node.is_a?(XmlNs)
            tmp_node = xp.node.next if xp.node.next && xp.node.next.type == ELEMENT_NODE
          else
            tmp_node = xp.node
          end
          if tmp_node.nil? || tmp_node.doc.nil?
            transform_error(tctxt, nil, tctxt.inst,
              "Internal error in xsltKeyFunction(): Couldn't get the doc of the XPath context node.\n")
            break
          end
          if tctxt.document.nil? || !tctxt.document.doc.equal?(tmp_node.doc)
            if tmp_node.doc.name&.start_with?(" ")
              tmp_node.doc._private = new_document(tctxt, tmp_node.doc) unless tmp_node.doc._private.is_a?(Document)
              tctxt.document = tmp_node.doc._private
            else
              tctxt.document = find_document(tctxt, tmp_node.doc)
            end
            if tctxt.document.nil?
              transform_error(tctxt, nil, tctxt.inst,
                "Internal error in xsltKeyFunction(): Could not get the document info of a context doc.\n")
              tctxt.state = STATE_STOPPED
              break
            end
          end
          nodelist = get_key(tctxt, key, key_uri, value)
        end while false # rubocop:disable Lint/Loop
        tctxt.document = old_doc_info
        ctxt.value_push(XPath.node_set_merge(nil, nodelist || []))
      end

      # xsltUnparsedEntityURIFunction
      def unparsed_entity_uri_function(ctxt, nargs)
        if nargs != 1 || ctxt.value.nil?
          generic_error("unparsed-entity-uri() : expects one string arg\n")
          ctxt.error = XPath::INVALID_ARITY
          return
        end
        obj = ctxt.value_pop
        str = obj.is_a?(String) ? obj : XPath.cast_to_string(obj)
        entity = Tree.get_doc_entity(ctxt.context.doc, str)
        if entity.nil? || entity.uri.nil?
          ctxt.value_push(+"")
        else
          ctxt.value_push(entity.uri.dup)
        end
      end

      # xsltFormatNumberFunction
      def format_number_function(ctxt, nargs)
        tctxt = xpath_get_transform_context(ctxt)
        return if tctxt.nil? || tctxt.inst.nil?

        sheet = tctxt.style
        return if sheet.nil?

        format_values = sheet.decimal_format
        decimal_obj = nil
        case nargs
        when 3, 2
          if nargs == 3
            ctxt.fn_string(1) if ctxt.value && !ctxt.value.is_a?(String)
            decimal_obj = ctxt.value_pop
            ncname, prefix = split_qname(decimal_obj)
            ns_uri = nil
            if prefix
              ns = Tree.search_ns(tctxt.inst.doc, tctxt.inst, prefix)
              if ns.nil?
                transform_error(tctxt, nil, nil, "format-number : No namespace found for QName '#{prefix}:#{ncname}'\n")
                sheet.errors += 1
                ncname = nil
              else
                ns_uri = ns.href
              end
            end
            format_values = decimal_format_get_by_qname(sheet, ns_uri, ncname) if ncname
            if format_values.nil?
              transform_error(tctxt, nil, nil, "format-number() : undeclared decimal format '#{decimal_obj}'\n")
            end
          end
          ctxt.fn_string(1) if ctxt.value && !ctxt.value.is_a?(String)
          format_obj = ctxt.value_pop
          ctxt.fn_number(1) if ctxt.value && !ctxt.value.is_a?(Float)
          number_obj = ctxt.value_pop
        else
          ctxt.xpath_err(XPath::INVALID_ARITY)
          return
        end
        if ctxt.error == 0 && format_values && format_obj && number_obj
          status, result = format_number_conversion(format_values, format_obj, number_obj)
          ctxt.value_push(result) if status == XPath::EXPRESSION_OK
        end
      end

      # xsltGenerateIdFunction
      def generate_id_function(ctxt, nargs)
        tctxt = xpath_get_transform_context(ctxt)
        if nargs == 0
          cur = ctxt.context.node
        elsif nargs == 1
          if ctxt.value.nil? || !node_set?(ctxt.value)
            ctxt.error = XPath::INVALID_TYPE
            transform_error(tctxt, nil, nil, "generate-id() : invalid arg expecting a node-set\n")
            return
          end
          nodelist = ctxt.value_pop
          if nodelist.empty?
            ctxt.value_push(+"")
            return
          end
          cur = nodelist[0]
          (1...nodelist.length).each do |i|
            cur = nodelist[i] if XPath.cmp_nodes(cur, nodelist[i]) == -1
          end
        else
          transform_error(tctxt, nil, nil, "generate-id() : invalid number of args #{nargs}\n")
          ctxt.error = XPath::INVALID_ARITY
          return
        end
        ns_prefix = nil
        if cur.is_a?(XmlNs)
          ns_prefix = cur.prefix || ""
          cur = cur.next
        end
        unless [DOCUMENT_NODE, HTML_DOCUMENT_NODE, ATTRIBUTE_NODE, ELEMENT_NODE, TEXT_NODE,
                CDATA_SECTION_NODE, PI_NODE, COMMENT_NODE].include?(cur.type)
          transform_error(tctxt, nil, nil, "generate-id(): invalid node type #{cur.type}\n")
          ctxt.error = XPath::INVALID_TYPE
          return
        end
        if (get_source_node_flags(tctxt, cur) & SOURCE_NODE_HAS_ID) != 0
          id = tctxt.source_ids[cur]
        else
          unless cur.psvi.nil?
            transform_error(tctxt, nil, nil, "generate-id(): psvi already set\n")
            ctxt.error = XPath::MEMORY_ERROR
            return
          end
          tctxt.current_id += 1
          id = tctxt.current_id
          tctxt.source_ids[cur] = id
          set_source_node_flags(tctxt, cur, SOURCE_NODE_HAS_ID)
        end
        str = +"id#{id}"
        if ns_prefix
          str << "ns"
          ns_prefix.each_byte { |b| str << format("%02X", b) }
        end
        ctxt.value_push(str)
      end

      # xsltSystemPropertyFunction
      def system_property_function(ctxt, nargs)
        if nargs != 1
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "system-property() : expects one string arg\n")
          ctxt.error = XPath::INVALID_ARITY
          return
        end
        if ctxt.value.nil? || !ctxt.value.is_a?(String)
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "system-property() : invalid arg expecting a string\n")
          ctxt.error = XPath::INVALID_TYPE
          return
        end
        obj = ctxt.value_pop
        ns_uri = nil
        split = split_qname2(obj)
        if split.nil?
          name = obj
        else
          name, prefix = split
          ns_uri = ctxt.context.ns_lookup(prefix)
          if ns_uri.nil?
            transform_error(xpath_get_transform_context(ctxt), nil, nil, "system-property() : prefix #{prefix} is not bound\n")
          end
        end
        if ns_uri == NAMESPACE
          if name == "vendor"
            tctxt = xpath_get_transform_context(ctxt)
            sheet = if tctxt&.inst && tctxt.inst.name == "variable" && tctxt.inst.parent &&
                tctxt.inst.parent.name == "template"
              tctxt.style
            end
            if sheet&.doc&.url&.include?("chunk")
              ctxt.value_push(+"libxslt (SAXON 6.2 compatible)")
            else
              ctxt.value_push(+DEFAULT_VENDOR)
            end
          elsif name == "version"
            ctxt.value_push(+DEFAULT_VERSION)
          elsif name == "vendor-url"
            ctxt.value_push(+DEFAULT_URL)
          else
            ctxt.value_push(+"")
          end
        else
          ctxt.value_push(+"")
        end
      end

      # xsltElementAvailableFunction
      def element_available_function(ctxt, nargs)
        if nargs != 1
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "element-available() : expects one string arg\n")
          ctxt.error = XPath::INVALID_ARITY
          return
        end
        ctxt.fn_string(1)
        if ctxt.value.nil? || !ctxt.value.is_a?(String)
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "element-available() : invalid arg expecting a string\n")
          ctxt.error = XPath::INVALID_TYPE
          return
        end
        obj = ctxt.value_pop
        tctxt = xpath_get_transform_context(ctxt)
        if tctxt.nil? || tctxt.inst.nil?
          transform_error(tctxt, nil, nil, "element-available() : internal error tctxt == NULL\n")
          ctxt.value_push(false)
          return
        end
        ns_uri = nil
        split = split_qname2(obj)
        if split.nil?
          name = obj
          ns = Tree.search_ns(tctxt.inst.doc, tctxt.inst, nil)
          ns_uri = ns.href if ns
        else
          name, prefix = split
          ns_uri = ctxt.context.ns_lookup(prefix)
          if ns_uri.nil?
            transform_error(tctxt, nil, nil, "element-available() : prefix #{prefix} is not bound\n")
          end
        end
        ctxt.value_push(!ext_element_lookup(tctxt, name, ns_uri).nil?)
      end

      # xsltFunctionAvailableFunction
      def function_available_function(ctxt, nargs)
        if nargs != 1
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "function-available() : expects one string arg\n")
          ctxt.error = XPath::INVALID_ARITY
          return
        end
        ctxt.fn_string(1)
        if ctxt.value.nil? || !ctxt.value.is_a?(String)
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "function-available() : invalid arg expecting a string\n")
          ctxt.error = XPath::INVALID_TYPE
          return
        end
        obj = ctxt.value_pop
        ns_uri = nil
        split = split_qname2(obj)
        if split.nil?
          name = obj
        else
          name, prefix = split
          ns_uri = ctxt.context.ns_lookup(prefix)
          if ns_uri.nil?
            transform_error(xpath_get_transform_context(ctxt), nil, nil, "function-available() : prefix #{prefix} is not bound\n")
          end
        end
        ctxt.value_push(!ctxt.context.function_lookup_ns(name, ns_uri).nil?)
      end

      # xsltCurrentFunction
      def current_function(ctxt, nargs)
        if nargs != 0
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "current() : function uses no argument\n")
          ctxt.error = XPath::INVALID_ARITY
          return
        end
        tctxt = xpath_get_transform_context(ctxt)
        if tctxt.nil?
          transform_error(nil, nil, nil, "current() : internal error tctxt == NULL\n")
          ctxt.value_push([])
        else
          ctxt.value_push(XPath.new_node_set(tctxt.node))
        end
      end

      FUNCTIONS = {
        "current" => :current_function, "document" => :document_function, "key" => :key_function,
        "unparsed-entity-uri" => :unparsed_entity_uri_function, "format-number" => :format_number_function,
        "generate-id" => :generate_id_function, "system-property" => :system_property_function,
        "element-available" => :element_available_function, "function-available" => :function_available_function,
      }.freeze

      def xpath_fn(sym)
        @xpath_fns ||= {}
        @xpath_fns[sym] ||= ->(ctxt, nargs) { XSLT.__send__(sym, ctxt, nargs) }
      end

      # xsltRegisterAllFunctions
      def register_all_functions(xp)
        FUNCTIONS.each { |name, sym| xp.register_func(name, xpath_fn(sym)) }
      end
    end
  end
end
