# frozen_string_literal: true

# Port of libxslt xsltutils.c: error reporting, QName helpers, sorting, xsl:message,
# result serialisation (xsltSaveResultTo) and XPath compilation helpers.

module Nokogiri
  module Pure
    module XSLT
      module_function

      # ---- generic error channel (xsltGenericError / xsltSetGenericErrorFunc) ----------------

      DEFAULT_ERROR_FUNC = ->(msg) { $stderr.write(msg) }

      def generic_error_func
        Thread.current[:__nokogiri_pure_xslt_error] || DEFAULT_ERROR_FUNC
      end

      # xsltSetGenericErrorFunc: +handler+ is a callable taking a String (or nil for the default)
      def set_generic_error_func(handler)
        Thread.current[:__nokogiri_pure_xslt_error] = handler
      end

      def with_generic_error_func(handler)
        saved = Thread.current[:__nokogiri_pure_xslt_error]
        Thread.current[:__nokogiri_pure_xslt_error] = handler
        yield
      ensure
        Thread.current[:__nokogiri_pure_xslt_error] = saved
      end

      # xsltGenericError(xsltGenericErrorContext, ...)
      def generic_error(msg)
        generic_error_func.call(msg)
      end

      # libxml2's xmlGenericError (used by a few libxslt code paths)
      def xml_generic_error(msg)
        h = Thread.current[:__nokogiri_pure_xml_generic_error]
        if h
          h.call(msg)
        else
          $stderr.write(msg)
        end
      end

      # xsltPrintErrorContext
      def print_error_context(ctxt, style, node)
        line = 0
        file = nil
        name = nil
        type = "error"
        error = generic_error_func
        if ctxt
          ctxt.state = STATE_ERROR if ctxt.state == STATE_OK
          error = ctxt.error if ctxt.error
        end
        node = ctxt.inst if node.nil? && ctxt
        if node
          if node.type == DOCUMENT_NODE || node.type == HTML_DOCUMENT_NODE
            file = node.url
          elsif !node.is_a?(XmlNs)
            line = Tree.get_line_no(node) || 0
            file = node.doc.url if node.doc&.url
            name = node.name if node.name
          end
        end
        if ctxt
          type = "runtime error"
        elsif style
          type = "compilation error"
        end
        if file && line != 0 && name
          error.call("#{type}: file #{file} line #{line} element #{name}\n")
        elsif file && name
          error.call("#{type}: file #{file} element #{name}\n")
        elsif file && line != 0
          error.call("#{type}: file #{file} line #{line}\n")
        elsif file
          error.call("#{type}: file #{file}\n")
        elsif name
          error.call("#{type}: element #{name}\n")
        else
          error.call("#{type}\n")
        end
      end

      # xsltTransformError
      def transform_error(ctxt, style, node, msg)
        error = generic_error_func
        if ctxt
          ctxt.state = STATE_ERROR if ctxt.state == STATE_OK
          error = ctxt.error if ctxt.error
        end
        node = ctxt.inst if node.nil? && ctxt
        print_error_context(ctxt, style, node)
        error.call(msg)
      end

      # ---- attribute helpers -------------------------------------------------------------------

      # xmlGetNsProp (no DTD defaults lookup beyond libxml2's own)
      def get_ns_prop_xml(node, name, ns)
        Tree.get_ns_prop(node, name, ns)
      end

      # xmlGetNsProp(node, name, NULL) as used throughout libxslt
      def get_prop(node, name)
        Tree.get_no_ns_prop(node, name)
      end

      # xsltGetNsProp
      def get_ns_prop(node, name, name_space)
        return nil if node.nil?
        return Tree.get_prop(node, name) if name_space.nil?
        return nil if node.is_a?(XmlNs)

        prop = node.type == ELEMENT_NODE ? node.properties : nil
        while prop
          if prop.name == name &&
              ((prop.ns.nil? && node.ns && node.ns.href == name_space) ||
               (prop.ns && prop.ns.href == name_space))
            ret = Tree.node_list_get_string(node.doc, prop.children, true)
            return ret.nil? ? +"" : ret
          end
          prop = prop.next
        end
        doc = node.doc
        if doc&.int_subset
          attr_decl = Tree.get_dtd_attr_desc(doc.int_subset, node.name, name)
          attr_decl = Tree.get_dtd_attr_desc(doc.ext_subset, node.name, name) if attr_decl.nil? && doc.ext_subset
          if attr_decl&.prefix
            ns = Tree.search_ns(doc, node, attr_decl.prefix)
            return attr_decl.default_value&.dup if ns && ns.href == name_space
          end
        end
        nil
      end

      # xsltGetCNsProp
      def get_cns_prop(_style, node, name, name_space)
        get_ns_prop(node, name, name_space)
      end

      # ---- QNames ----------------------------------------------------------------------------

      # xsltSplitQName: returns [localname, prefix]
      def split_qname(name)
        return [nil, nil] if name.nil?
        return [name, nil] if name.start_with?(":")

        idx = name.index(":")
        return [name, nil] if idx.nil?

        [name[idx + 1..], name[0, idx]]
      end

      # xsltGetQNameURI: returns [uri, localname]; localname nil on error
      def get_qname_uri(node, qname)
        return [nil, qname] if qname.nil? || qname.empty?

        if node.nil?
          generic_error("QName: no element for namespace lookup #{qname}\n")
          return [nil, nil]
        end
        return [nil, qname] if qname.start_with?(":")

        idx = qname.index(":")
        return [nil, qname] if idx.nil?

        if qname.start_with?("xml:")
          return [nil, qname] if qname.length == 4

          return [XML_XML_NAMESPACE, qname[4..]]
        end
        prefix = qname[0, idx]
        ns = Tree.search_ns(node.doc, node, prefix)
        if ns.nil?
          generic_error("#{prefix}:#{qname[idx + 1..]} : no namespace bound to prefix #{prefix}\n")
          return [nil, nil]
        end
        [ns.href, qname[idx + 1..]]
      end

      # xsltGetQNameURI2: returns [uri, localname]; localname nil on error
      def get_qname_uri2(style, node, qname)
        return [nil, qname] if qname.nil? || qname.empty?

        if node.nil?
          generic_error("QName: no element for namespace lookup #{qname}\n")
          return [nil, nil]
        end
        idx = qname.index(":")
        return [nil, qname] if idx.nil?

        if qname.start_with?("xml:")
          return [nil, qname] if qname.length == 4

          return [XML_XML_NAMESPACE, qname[4..]]
        end
        prefix = qname[0, idx]
        ns = Tree.search_ns(node.doc, node, prefix)
        if ns.nil?
          if style
            transform_error(nil, style, node, "No namespace bound to prefix '#{prefix}'.\n")
            style.errors += 1
          else
            generic_error("#{qname} : no namespace bound to prefix #{prefix}\n")
          end
          return [nil, nil]
        end
        [ns.href, qname[idx + 1..]]
      end

      def ncname_scan(cps, i)
        c = cps[i]
        return nil if c.nil? || !(XPath::Chars.letter?(c) || c == 0x5F)

        i += 1
        while (c = cps[i]) && (XPath::Chars.letter?(c) || XPath::Chars.digit?(c) || c == 0x2E || c == 0x2D ||
              c == 0x5F || XPath::Chars.combining?(c) || XPath::Chars.extender?(c))
          i += 1
        end
        i
      end

      # xmlValidateQName(value, 0) == 0
      def valid_qname?(value)
        return false if value.nil?

        cps = value.codepoints
        i = ncname_scan(cps, 0)
        return false if i.nil?

        if cps[i] == 0x3A
          i = ncname_scan(cps, i + 1)
          return false if i.nil?
        end
        i == cps.length
      end

      # xmlValidateNCName(value, 0) == 0
      def valid_ncname?(value)
        return false if value.nil?

        cps = value.codepoints
        ncname_scan(cps, 0) == cps.length
      end

      # xmlSplitQName2: returns [localname, prefix] or nil when not prefixed
      def split_qname2(name)
        Tree.split_qname2(name)
      end

      # ---- xsl:message ----------------------------------------------------------------------------

      # xsltMessage
      def message(ctxt, node, inst)
        return if ctxt.nil? || inst.nil?

        error = ctxt.error || generic_error_func
        terminate = false
        prop = get_prop(inst, "terminate")
        if prop
          if prop == "yes"
            terminate = true
          elsif prop != "no"
            transform_error(ctxt, nil, inst, "xsl:message : terminate expecting 'yes' or 'no'\n")
          end
        end
        msg = eval_template_string(ctxt, node, inst)
        if msg
          error.call(msg)
          error.call("\n") if !msg.empty? && !msg.end_with?("\n")
        end
        ctxt.state = STATE_STOPPED if terminate
      end

      # ---- sorting ------------------------------------------------------------------------------

      # xsltDocumentSortFunction
      def document_sort_function(list)
        return if list.nil? || list.length <= 1

        len = list.length
        (0...(len - 1)).each do |i|
          ((i + 1)...len).each do |j|
            if XPath.cmp_nodes(list[i], list[j]) == -1
              list[i], list[j] = list[j], list[i]
            end
          end
        end
      end

      SortRes = Struct.new(:value, :index)

      # xsltComputeSortResultInternal
      def compute_sort_result_internal(ctxt, sort, number, locale)
        comp = sort.psvi
        if comp.nil?
          generic_error("xsl:sort : compilation failed\n")
          return nil
        end
        return nil if comp.select.nil? || comp.comp.nil?

        list = ctxt.node_list
        return nil if list.nil? || list.length <= 1

        len = list.length
        results = Array.new(len)
        xp = ctxt.xpath_ctxt
        old_inst = ctxt.inst
        old_node = xp.node
        old_pos = xp.proximity_position
        old_size = xp.context_size
        old_ns = xp.namespaces
        len.times do |i|
          ctxt.inst = sort
          xp.context_size = len
          xp.proximity_position = i + 1
          ctxt.node = list[i]
          xp.node = ctxt.node
          xp.namespaces = comp.ns_list
          res = XPath.compiled_eval(comp.comp, xp)
          if !res.nil?
            res = XPath.cast_to_string(res) unless res.is_a?(String)
            res = XPath.string_eval_number(res) if number
            if number
              results[i] = res.is_a?(Float) ? SortRes.new(res, i) : nil
            elsif res.is_a?(String)
              if locale
                key = ctxt.gen_sort_key.call(locale, res)
                if key.nil?
                  transform_error(ctxt, nil, sort, "xsltComputeSortResult: sort key is null\n")
                else
                  res = key
                end
              end
              results[i] = SortRes.new(res, i)
            else
              results[i] = nil
            end
          else
            ctxt.state = STATE_STOPPED
            results[i] = nil
          end
        end
        ctxt.inst = old_inst
        xp.node = old_node
        xp.context_size = old_size
        xp.proximity_position = old_pos
        xp.namespaces = old_ns
        results
      end

      # xsltComputeSortResult
      def compute_sort_result(ctxt, sort)
        comp = sort.psvi
        compute_sort_result_internal(ctxt, sort, comp ? comp.number : false, nil)
      end

      def sort_cmp_values(a, b, number)
        if number
          av = a.value
          bv = b.value
          if av.nan?
            bv.nan? ? 0 : -1
          elsif bv.nan?
            1
          elsif av == bv
            0
          elsif av > bv
            1
          else
            -1
          end
        else
          # xmlStrcmp: byte-wise, result sign only matters
          r = a.value.b <=> b.value.b
          r
        end
      end

      # xsltDefaultSortFunction
      def default_sort_function(ctxt, sorts, nbsorts)
        return if ctxt.nil? || sorts.nil? || nbsorts <= 0 || nbsorts >= MAX_SORT
        return if sorts[0].nil?

        comp = sorts[0].psvi
        return if comp.nil?

        list = ctxt.node_list
        return if list.nil? || list.length <= 1

        number = []
        desc = []
        locale = []
        nbsorts.times do |j|
          comp = sorts[j].psvi
          if comp.stype.nil? && comp.has_stype
            stype = eval_attr_value_template(ctxt, sorts[j], "data-type", nil)
            number[j] = false
            if stype
              if stype == "text"
                # nothing
              elsif stype == "number"
                number[j] = true
              else
                transform_error(ctxt, nil, sorts[j], "xsltDoSortFunction: no support for data-type = #{stype}\n")
              end
            end
          else
            number[j] = comp.number
          end
          if comp.order.nil? && comp.has_order
            order = eval_attr_value_template(ctxt, sorts[j], "order", nil)
            desc[j] = false
            if order
              if order == "ascending"
                # nothing
              elsif order == "descending"
                desc[j] = true
              else
                transform_error(ctxt, nil, sorts[j], "xsltDoSortFunction: invalid value #{order} for order\n")
              end
            end
          else
            desc[j] = comp.descending
          end
          lang = if comp.lang.nil? && comp.has_lang
            eval_attr_value_template(ctxt, sorts[j], "lang", nil)
          else
            comp.lang
          end
          locale[j] = lang ? ctxt.new_locale.call(lang, comp.lower_first) : nil
        end

        len = list.length
        results_tab = Array.new(MAX_SORT)
        results_tab[0] = compute_sort_result_internal(ctxt, sorts[0], number[0], locale[0])
        results = results_tab[0]
        return if results.nil?

        incr = len / 2
        while incr > 0
          i = incr
          while i < len
            j = i - incr
            if results[i].nil?
              i += 1
              next
            end
            while j >= 0
              if results[j].nil?
                tst = 1
              else
                tst = sort_cmp_values(results[j], results[j + incr], number[0])
                tst = -tst if desc[0]
              end
              if tst == 0
                depth = 1
                while depth < nbsorts
                  break if sorts[depth].nil?

                  comp = sorts[depth].psvi
                  break if comp.nil?

                  results_tab[depth] ||= compute_sort_result_internal(ctxt, sorts[depth], number[depth], locale[depth])
                  res = results_tab[depth]
                  break if res.nil?

                  if res[j].nil?
                    tst = 1 unless res[j + incr].nil?
                  elsif res[j + incr].nil?
                    tst = -1
                  else
                    tst = sort_cmp_values(res[j], res[j + incr], number[depth])
                    tst = -tst if desc[depth]
                  end
                  break if tst != 0

                  depth += 1
                end
              end
              if tst == 0
                tst = results[j].index > results[j + incr].index ? 1 : 0
              end
              if tst > 0
                results[j], results[j + incr] = results[j + incr], results[j]
                list[j], list[j + incr] = list[j + incr], list[j]
                depth = 1
                while depth < nbsorts
                  break if sorts[depth].nil?
                  break if results_tab[depth].nil?

                  res = results_tab[depth]
                  res[j], res[j + incr] = res[j + incr], res[j]
                  depth += 1
                end
                j -= incr
              else
                break
              end
            end
            i += 1
          end
          incr /= 2
        end
      ensure
        locale&.each { |l| ctxt.free_locale&.call(l) if l }
      end

      # xsltDoSortFunction
      def do_sort_function(ctxt, sorts, nbsorts)
        if ctxt.sortfunc
          ctxt.sortfunc.call(ctxt, sorts, nbsorts)
        else
          default_sort_function(ctxt, sorts, nbsorts)
        end
      end

      # ---- XPath compilation ---------------------------------------------------------------------

      # xsltXPathCompileFlags
      def xpath_compile_flags(style, str, flags)
        if style
          xp = style.principal.xpath_ctxt
          return nil if xp.nil?
        else
          xp = XPath::Context.new(nil)
        end
        xp.flags = flags
        XPath.ctxt_compile(xp, str)
      end

      # xsltXPathCompile
      def xpath_compile(style, str)
        xpath_compile_flags(style, str, 0)
      end

      # ---- result serialisation ----------------------------------------------------------------

      # xsltSaveResultTo: writes to a Save::OutBuf; returns bytes written or -1
      def save_result_to(buf, result, style)
        return -1 if buf.nil? || result.nil? || style.nil?
        return 0 if result.children.nil? || (result.children.type == DTD_NODE && result.children.next.nil?)

        if style.method_uri && (style.method.nil? || style.method != "xhtml")
          generic_error("xsltSaveResultTo : unknown output method\n")
          return -1
        end

        method = get_import_ptr(style, :method)
        encoding = get_import_ptr(style, :encoding)
        indent = get_import_int(style, :indent)

        method = "html" if method.nil? && result.type == HTML_DOCUMENT_NODE

        if method == "html"
          Save.html_set_meta_encoding(result, encoding || "UTF-8")
          indent = 1 if indent == -1
          Save.html_doc_content_dump_format_output(buf, result, encoding, indent)
        elsif method == "xhtml"
          Save.html_set_meta_encoding(result, encoding || "UTF-8")
          Save.html_doc_content_dump_format_output(buf, result, encoding, 1)
        elsif method == "text"
          cur = result.children
          while cur
            buf.write(cur.content) if cur.type == TEXT_NODE && cur.content
            if cur.children && ![ENTITY_DECL, ENTITY_REF_NODE, ENTITY_NODE].include?(cur.children.type)
              cur = cur.children
              next
            end
            if cur.next
              cur = cur.next
              next
            end
            loop do
              cur = cur.parent
              break if cur.nil?
              if cur.equal?(style.doc)
                cur = nil
                break
              end
              if cur.next
                cur = cur.next
                break
              end
            end
          end
        else
          omit_xml_decl = get_import_int(style, :omit_xml_declaration)
          standalone = get_import_int(style, :standalone)
          if omit_xml_decl != 1
            buf.write("<?xml version=")
            if result.version
              buf.write("\"#{result.version}\"")
            else
              buf.write("\"1.0\"")
            end
            if encoding.nil?
              if result.encoding
                encoding = result.encoding
              elsif result.charset != 1
                encoding = Enc.charset_name(result.charset) if Enc.respond_to?(:charset_name)
              end
            end
            buf.write(" encoding=\"#{encoding}\"") if encoding
            case standalone
            when 0 then buf.write(" standalone=\"no\"")
            when 1 then buf.write(" standalone=\"yes\"")
            end
            buf.write("?>\n")
          end
          if result.children
            children = result.children
            child = children
            result.children = nil
            begin
              while child
                node_dump_output(buf, result, child, 0, indent == 1, encoding)
                if indent != 0 && (child.type == DTD_NODE || (child.type == COMMENT_NODE && child.next))
                  buf.write("\n")
                end
                child = child.next
              end
              buf.write("\n") if indent != 0
            ensure
              result.children = children
            end
          end
        end
        0
      end

      # xmlNodeDumpOutput(buf, doc, cur, level, format, encoding)
      def node_dump_output(buf, doc, cur, level, format, encoding)
        ctxt = Save::SaveCtxt.new(nil, Save::SAVE_AS_XML, "  ")
        ctxt.encoding = encoding || "UTF-8"
        ctxt.escape = nil
        ctxt.escape_attr = nil
        ctxt.buf = buf
        ctxt.level = level
        ctxt.format = format ? 1 : 0
        dtd = Tree.get_int_subset(doc)
        is_xhtml = dtd ? Save.is_xhtml(dtd.system_id, dtd.external_id) > 0 : false
        if is_xhtml
          Save.xhtml_node_dump_output(ctxt, cur)
        else
          Save.node_dump_output_internal(ctxt, cur)
        end
      end

      # xsltSaveResultToString: returns the serialised bytes (binary String)
      def save_result_to_string(result, style)
        return +"".b if result.children.nil?

        encoding = get_import_ptr(style, :encoding)
        encoder = nil
        if encoding && !encoding.casecmp?("UTF-8") && !encoding.casecmp?("UTF8")
          encoder = Enc.find_handler(encoding, output: true)
        end
        buf = Save::OutBuf.new(encoder)
        save_result_to(buf, result, style)
        buf.result
      end

      def uri_parser
        Pure.const_defined?(:Parser) && Pure::Parser.const_defined?(:URIParser) ? Pure::Parser::URIParser : nil
      end

      # xmlBuildURI
      def build_uri(uri, base)
        (up = uri_parser) ? up.build_uri(uri, base) : URI_.build_uri(uri, base)
      end

      # xmlParseURI: nil when the reference is invalid
      def parse_uri(str)
        (up = uri_parser) ? up.parse(str) : URI_.parse(str)
      end

      # xsltGetUTF8Char: returns [codepoint, len] or [-1, 0]
      def get_utf8_char(str, pos = 0)
        c = str.getbyte(pos)
        return [-1, 0] if c.nil?
        return [c, 1] if c < 0x80

        b = str.byteslice(pos, 4)
        if (c & 0xE0) == 0xC0
          len = 2
        elsif (c & 0xF0) == 0xE0
          len = 3
        elsif (c & 0xF8) == 0xF0
          len = 4
        else
          return [-1, 0]
        end
        seq = b.byteslice(0, len)
        return [-1, 0] if seq.bytesize < len

        cp = seq.force_encoding(Encoding::UTF_8)
        return [-1, 0] unless cp.valid_encoding?

        [cp.ord, len]
      end
    end
  end
end
