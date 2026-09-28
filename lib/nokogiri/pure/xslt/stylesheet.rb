# frozen_string_literal: true

# Port of libxslt xslt.c: stylesheet compilation (top-level elements, templates, output,
# decimal formats, whitespace handling, exclude/extension prefixes, literal result stylesheets).

module Nokogiri
  module Pure
    module XSLT
      module_function

      def each_token(str)
        return if str.nil?

        str.scan(/[^ \t\n\r]+/) { |t| yield t }
      end

      # xsltParseContentError
      def parse_content_error(style, node)
        return if style.nil? || node.nil?

        if xslt_elem?(node)
          transform_error(nil, style, node, "The XSLT-element '#{node.name}' is not allowed at this position.\n")
        else
          transform_error(nil, style, node, "The element '#{node.name}' is not allowed at this position.\n")
        end
        style.errors += 1
      end

      # exclPrefixPush: returns index or -1
      def excl_prefix_push(style, orig)
        return -1 if style.excl_prefix_tab.include?(orig)

        style.excl_prefix_tab << orig
        style.excl_prefix = orig
        style.excl_prefix_tab.length - 1
      end

      def excl_prefix_pop(style)
        return nil if style.excl_prefix_tab.empty?

        ret = style.excl_prefix_tab.pop
        style.excl_prefix = style.excl_prefix_tab.last
        ret
      end

      # xsltDecimalFormatGetByName
      def decimal_format_get_by_name(style, name)
        return style.decimal_format if name.nil?

        result = nil
        while style
          result = style.decimal_format.next
          while result
            return result if result.ns_uri.nil? && result.name == name

            result = result.next
          end
          style = next_import(style)
        end
        result
      end

      # xsltDecimalFormatGetByQName
      def decimal_format_get_by_qname(style, ns_uri, name)
        return style.decimal_format if name.nil?

        result = nil
        while style
          result = style.decimal_format.next
          while result
            return result if ns_uri == result.ns_uri && name == result.name

            result = result.next
          end
          style = next_import(style)
        end
        result
      end

      # xsltGetInheritedNsList
      def get_inherited_ns_list(style, template, node)
        return 0 if style.nil? || template.nil? || node.nil? || template.inherited_ns

        ret = []
        while node
          if node.type == ELEMENT_NODE
            cur = node.ns_def
            while cur
              skip = cur.href == NAMESPACE ||
                (cur.prefix && check_ext_prefix(style, cur.prefix)) ||
                style.excl_prefix_tab.include?(cur.href)
              if !skip && ret.none? { |r| r.prefix == cur.prefix }
                ret << cur
              end
              cur = cur.next
            end
          end
          node = node.parent
        end
        template.inherited_ns = ret unless ret.empty?
        ret.length
      end

      # xsltParseStylesheetOutput
      def parse_stylesheet_output(style, cur)
        return if cur.nil? || style.nil? || cur.type != ELEMENT_NODE

        prop = get_prop(cur, "version")
        style.version = prop if prop
        prop = get_prop(cur, "encoding")
        style.encoding = prop if prop
        prop = get_prop(cur, "method")
        if prop
          style.method = nil
          style.method_uri = nil
          uri, prop = get_qname_uri(cur, prop)
          if prop.nil?
            style.errors += 1
          elsif uri.nil?
            if %w[xml html text].include?(prop)
              style.method = prop
            else
              transform_error(nil, style, cur, "invalid value for method: #{prop}\n")
              style.warnings += 1
            end
          else
            style.method = prop
            style.method_uri = uri
          end
        end
        prop = get_prop(cur, "doctype-system")
        style.doctype_system = prop if prop
        prop = get_prop(cur, "doctype-public")
        style.doctype_public = prop if prop
        prop = get_prop(cur, "standalone")
        if prop
          if prop == "yes"
            style.standalone = 1
          elsif prop == "no"
            style.standalone = 0
          else
            transform_error(nil, style, cur, "invalid value for standalone: #{prop}\n")
            style.errors += 1
          end
        end
        prop = get_prop(cur, "indent")
        if prop
          if prop == "yes"
            style.indent = 1
          elsif prop == "no"
            style.indent = 0
          else
            transform_error(nil, style, cur, "invalid value for indent: #{prop}\n")
            style.errors += 1
          end
        end
        prop = get_prop(cur, "omit-xml-declaration")
        if prop
          if prop == "yes"
            style.omit_xml_declaration = 1
          elsif prop == "no"
            style.omit_xml_declaration = 0
          else
            transform_error(nil, style, cur, "invalid value for omit-xml-declaration: #{prop}\n")
            style.errors += 1
          end
        end
        elements = get_prop(cur, "cdata-section-elements")
        if elements
          style.cdata_section ||= {}
          each_token(elements) do |element|
            if !valid_qname?(element)
              transform_error(nil, style, cur,
                "Attribute 'cdata-section-elements': The value '#{element}' is not a valid QName.\n")
              style.errors += 1
            else
              uri, element = get_qname_uri(cur, element)
              if element.nil?
                transform_error(nil, style, cur, "Attribute 'cdata-section-elements': Not a valid QName.\n")
                style.errors += 1
              else
                if uri.nil?
                  ns = Tree.search_ns(style.doc, cur, nil)
                  uri = ns.href if ns
                end
                key = [element, uri]
                style.cdata_section[key] = "cdata" unless style.cdata_section.key?(key)
              end
            end
          end
        end
        prop = get_prop(cur, "media-type")
        style.media_type = prop if prop
        parse_content_error(style, cur.children) if cur.children
      end

      # xsltParseStylesheetDecimalFormat
      def parse_stylesheet_decimal_format(style, cur)
        return if cur.nil? || style.nil? || cur.type != ELEMENT_NODE

        format = style.decimal_format
        prop = get_prop(cur, "name")
        if prop
          unless valid_qname?(prop)
            transform_error(nil, style, cur, "xsl:decimal-format: Invalid QName '#{prop}'.\n")
            style.warnings += 1
            return
          end
          ns_uri, prop = get_qname_uri(cur, prop)
          if prop.nil?
            style.warnings += 1
            return
          end
          format = decimal_format_get_by_qname(style, ns_uri, prop)
          if format
            transform_error(nil, style, cur, "xsltParseStylestyleDecimalFormat: #{prop} already exists\n")
            style.warnings += 1
            return
          end
          format = DecimalFormat.new(ns_uri, prop)
          iter = style.decimal_format
          iter = iter.next while iter.next
          iter.next = format
        end
        {
          "decimal-separator" => :decimal_point=, "grouping-separator" => :grouping=,
          "infinity" => :infinity=, "minus-sign" => :minus_sign=, "NaN" => :no_number=,
          "percent" => :percent=, "per-mille" => :permille=, "zero-digit" => :zero_digit=,
          "digit" => :digit=, "pattern-separator" => :pattern_separator=,
        }.each do |attr, setter|
          prop = get_prop(cur, attr)
          format.__send__(setter, prop) if prop
        end
        parse_content_error(style, cur.children) if cur.children
      end

      # xsltParseStylesheetPreserveSpace
      def parse_stylesheet_preserve_space(style, cur)
        return if cur.nil? || style.nil? || cur.type != ELEMENT_NODE

        elements = get_prop(cur, "elements")
        if elements.nil?
          transform_error(nil, style, cur, "xsltParseStylesheetPreserveSpace: missing elements attribute\n")
          style.warnings += 1
          return
        end
        style.strip_spaces ||= {}
        each_token(elements) do |element|
          if element == "*"
            style.strip_all = -1
          else
            uri, element = get_qname_uri(cur, element)
            key = [element, uri]
            style.strip_spaces[key] = "preserve" unless style.strip_spaces.key?(key)
          end
        end
        parse_content_error(style, cur.children) if cur.children
      end

      # xsltParseStylesheetExtPrefix
      def parse_stylesheet_ext_prefix(style, cur, is_xslt_elem)
        return if cur.nil? || style.nil? || cur.type != ELEMENT_NODE

        prefixes = if is_xslt_elem
          get_prop(cur, "extension-element-prefixes")
        else
          Tree.get_ns_prop(cur, "extension-element-prefixes", NAMESPACE)
        end
        return if prefixes.nil?

        each_token(prefixes) do |prefix|
          ns = if prefix == "#default"
            Tree.search_ns(style.doc, cur, nil)
          else
            Tree.search_ns(style.doc, cur, prefix)
          end
          if ns.nil?
            transform_error(nil, style, cur, "xsl:extension-element-prefix : undefined namespace #{prefix}\n")
            style.warnings += 1
          else
            register_ext_prefix(style, prefix, ns.href)
          end
        end
      end

      # xsltParseStylesheetStripSpace
      def parse_stylesheet_strip_space(style, cur)
        return if cur.nil? || style.nil? || cur.type != ELEMENT_NODE

        style.strip_spaces ||= {}
        elements = get_prop(cur, "elements")
        if elements.nil?
          transform_error(nil, style, cur, "xsltParseStylesheetStripSpace: missing elements attribute\n")
          style.warnings += 1
          return
        end
        each_token(elements) do |element|
          if element == "*"
            style.strip_all = 1
          else
            uri, element = get_qname_uri(cur, element)
            key = [element, uri]
            style.strip_spaces[key] = "strip" unless style.strip_spaces.key?(key)
          end
        end
        parse_content_error(style, cur.children) if cur.children
      end

      # xsltParseStylesheetExcludePrefix
      def parse_stylesheet_exclude_prefix(style, cur, is_xslt_elem)
        return 0 if cur.nil? || style.nil? || cur.type != ELEMENT_NODE

        prefixes = if is_xslt_elem
          get_prop(cur, "exclude-result-prefixes")
        else
          Tree.get_ns_prop(cur, "exclude-result-prefixes", NAMESPACE)
        end
        return 0 if prefixes.nil?

        nb = 0
        each_token(prefixes) do |prefix|
          ns = if prefix == "#default"
            Tree.search_ns(style.doc, cur, nil)
          else
            Tree.search_ns(style.doc, cur, prefix)
          end
          if ns.nil?
            transform_error(nil, style, cur, "xsl:exclude-result-prefixes : undefined namespace #{prefix}\n")
            style.warnings += 1
          elsif excl_prefix_push(style, ns.href) >= 0
            nb += 1
          end
        end
        nb
      end

      # xsltPreprocessStylesheet
      def preprocess_stylesheet(style, cur)
        return if style.nil? || cur.nil?

        style.internalized = false
        styleelem = xslt_elem?(cur) && cur.name == "stylesheet" ? cur : nil
        delete_node = nil
        while cur
          if delete_node
            Tree.unlink_node(delete_node)
            delete_node = nil
          end
          skip_children = false
          if cur.type == ELEMENT_NODE
            excl_prefixes = 0
            if xslt_elem?(cur)
              if cur.name == "text"
                skip_children = true
              end
            else
              excl_prefixes = parse_stylesheet_exclude_prefix(style, cur, false)
            end
            unless skip_children
              if cur.ns_def && style.excl_prefix_nr > 0
                root = Tree.doc_get_root_element(cur.doc)
                if root && !root.equal?(cur)
                  ns = cur.ns_def
                  prev = nil
                  while ns
                    moved = false
                    nxt = ns.next
                    if ns.prefix && style.excl_prefix_tab.include?(ns.href)
                      if prev.nil?
                        cur.ns_def = ns.next
                      else
                        prev.next = ns.next
                      end
                      ns.next = root.ns_def
                      root.ns_def = ns
                      moved = true
                    end
                    prev = ns unless moved
                    ns = nxt
                  end
                end
              end
              if excl_prefixes > 0
                preprocess_stylesheet(style, cur.children)
                excl_prefixes.times { excl_prefix_pop(style) }
                skip_children = true
              end
            end
          elsif cur.type == TEXT_NODE
            if blank_node?(cur)
              delete_node = cur if Tree.node_get_space_preserve(cur.parent) != 1
            end
          elsif cur.type != CDATA_SECTION_NODE
            delete_node = cur
            skip_children = true
          end

          unless skip_children
            if cur.type == ELEMENT_NODE && cur.ns && styleelem && cur.parent.equal?(styleelem) &&
                cur.ns.href != NAMESPACE && !check_ext_uri(style, cur.ns.href)
              skip_children = true
            elsif cur.children
              cur = cur.children
              next
            end
          end

          # skip_children:
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
        Tree.unlink_node(delete_node) if delete_node
      end

      # xsltGatherNamespaces
      def gather_namespaces(style)
        return if style.nil?

        cur = Tree.doc_get_root_element(style.doc)
        while cur
          if cur.type == ELEMENT_NODE
            ns = cur.ns_def
            while ns
              if ns.prefix
                style.ns_hash ||= {}
                uri = style.ns_hash[ns.prefix]
                if uri && uri != ns.href
                  transform_error(nil, style, cur, "Namespaces prefix #{ns.prefix} used for multiple namespaces\n")
                  style.warnings += 1
                elsif uri.nil?
                  style.ns_hash[ns.prefix] = ns.href
                end
              end
              ns = ns.next
            end
          end
          if cur.children && cur.children.type != ENTITY_DECL
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
      end

      # xsltParseTemplateContent
      def parse_template_content(style, templ)
        return if style.nil? || templ.nil? || templ.is_a?(XmlNs)

        cur = templ.children
        delete = nil
        while cur
          style.principal.op_count += 1
          if delete
            Tree.unlink_node(delete)
            delete = nil
          end
          skip_children = false
          if xslt_elem?(cur)
            style_pre_compute(style, cur)
            if cur.name == "text"
              if cur.children
                text = cur.children
                noesc = false
                prop = get_prop(cur, "disable-output-escaping")
                if prop
                  if prop == "yes"
                    noesc = true
                  elsif prop != "no"
                    transform_error(nil, style, cur, "xsl:text: disable-output-escaping allows only yes or no\n")
                    style.warnings += 1
                  end
                end
                while text
                  if text.type == COMMENT_NODE
                    text = text.next
                    next
                  end
                  if text.type != TEXT_NODE && text.type != CDATA_SECTION_NODE
                    transform_error(nil, style, cur, "xsltParseTemplateContent: xslt:text content problem\n")
                    style.errors += 1
                    break
                  end
                  text.name = STRING_TEXT_NOENC if noesc && text.type != CDATA_SECTION_NODE
                  text = text.next
                end
                if text.nil?
                  text = cur.children
                  while text
                    nxt = text.next
                    Tree.unlink_node(text)
                    Tree.add_prev_sibling(cur, text)
                    text = nxt
                  end
                end
              end
              delete = cur
              skip_children = true
            end
          elsif cur.ns && style.ns_defs && check_ext_prefix(style, cur.ns.prefix)
            style_pre_compute(style, cur)
          elsif cur.type == ELEMENT_NODE
            if cur.ns.nil? && style.default_alias
              cur.ns = Tree.search_ns_by_href(cur.doc, cur, style.default_alias)
            end
            attr = cur.properties
            while attr
              compile_attr(style, attr)
              attr = attr.next
            end
          end

          if !skip_children && cur.children && cur.children.type != ENTITY_DECL
            cur = cur.children
            next
          end
          # skip_children:
          if cur.next
            cur = cur.next
            next
          end
          loop do
            cur = cur.parent
            break if cur.nil?
            if cur.equal?(templ)
              cur = nil
              break
            end
            if cur.next
              cur = cur.next
              break
            end
          end
        end
        Tree.unlink_node(delete) if delete

        # Skip the first params
        cur = templ.children
        while cur
          break if xslt_elem?(cur) && cur.name != "param"

          cur = cur.next
        end
        # Browse the remainder of the template
        while cur
          if xslt_elem?(cur) && cur.name == "param"
            param = cur
            transform_error(nil, style, cur, "xsltParseTemplateContent: ignoring misplaced param element\n")
            style.warnings += 1
            cur = cur.next
            Tree.unlink_node(param)
          else
            break
          end
        end
      end

      # xsltParseStylesheetKey
      def parse_stylesheet_key(style, key)
        return if style.nil? || key.nil? || key.type != ELEMENT_NODE

        begin
          prop = get_prop(key, "name")
          if prop
            uri, prop = get_qname_uri(key, prop)
            if prop.nil?
              style.errors += 1
              break
            end
            name = prop
            name_uri = uri
          else
            transform_error(nil, style, key, "xsl:key : error missing name\n")
            style.errors += 1
            break
          end
          match = get_prop(key, "match")
          if match.nil?
            transform_error(nil, style, key, "xsl:key : error missing match\n")
            style.errors += 1
            break
          end
          use = get_prop(key, "use")
          if use.nil?
            transform_error(nil, style, key, "xsl:key : error missing use\n")
            style.errors += 1
            break
          end
          add_key(style, name, name_uri, match, use, key)
        end while false # rubocop:disable Lint/Loop
        parse_content_error(style, key.children) if key.children
      end

      # xsltParseStylesheetTemplate
      def parse_stylesheet_template(style, template)
        return if style.nil? || template.nil? || template.type != ELEMENT_NODE

        if style.principal.op_limit > 0 && style.principal.op_count > style.principal.op_limit
          transform_error(nil, style, nil, "XSLT parser operation limit exceeded\n")
          style.errors += 1
          return
        end

        ret = Template.new
        ret.next = style.templates
        style.templates = ret
        ret.style = style

        get_inherited_ns_list(style, ret, template)

        prop = get_prop(template, "mode")
        if prop
          uri, prop = get_qname_uri(template, prop)
          if prop.nil?
            style.errors += 1
            return
          end
          ret.mode = prop
          ret.mode_uri = uri
        end
        prop = get_prop(template, "match")
        ret.match = prop if prop
        prop = get_prop(template, "priority")
        if prop
          ret.priority = XPath.string_eval_number(prop)
          ret.priority = [ret.priority].pack("e").unpack1("e") # (float) cast
        end
        prop = get_prop(template, "name")
        if prop
          uri, prop = get_qname_uri(template, prop)
          if prop.nil?
            style.errors += 1
            return
          end
          unless valid_ncname?(prop)
            transform_error(nil, style, template, "xsl:template : error invalid name '#{prop}'\n")
            style.errors += 1
            return
          end
          ret.name = prop
          ret.name_uri = uri
        end

        parse_template_content(style, template)
        ret.elem = template
        ret.content = template.children
        add_template(style, ret, ret.mode, ret.mode_uri)
      end

      # xsltParseStylesheetTop
      def parse_stylesheet_top(style, top)
        return if top.nil? || top.type != ELEMENT_NODE

        if style.principal.op_limit > 0 && style.principal.op_count > style.principal.op_limit
          transform_error(nil, style, nil, "XSLT parser operation limit exceeded\n")
          style.errors += 1
          return
        end

        prop = get_prop(top, "version")
        if prop.nil?
          transform_error(nil, style, top, "xsl:version is missing: document may not be a stylesheet\n")
          style.warnings += 1
        elsif prop != "1.0" && prop != "1.1"
          transform_error(nil, style, top, "xsl:version: only 1.1 features are supported\n")
          style.forwards_compatible = true
          style.warnings += 1
        end

        cur = top.children
        while cur
          style.principal.op_count += 1
          if blank_node?(cur)
            cur = cur.next
            next
          end
          break unless xslt_elem?(cur) && cur.name == "import"

          style.errors += 1 if parse_stylesheet_import(style, cur) != 0
          cur = cur.next
        end

        while cur
          style.principal.op_count += 1
          if blank_node?(cur)
            cur = cur.next
            next
          end
          if cur.type == TEXT_NODE
            transform_error(nil, style, cur, "misplaced text node: '#{cur.content}'\n") if cur.content
            style.errors += 1
            cur = cur.next
            next
          end
          if cur.type == ELEMENT_NODE && cur.ns.nil?
            generic_error("Found a top-level element #{cur.name} with null namespace URI\n")
            style.errors += 1
            cur = cur.next
            next
          end
          if cur.type == ELEMENT_NODE && !xslt_elem?(cur)
            function = ext_module_top_level_lookup(cur.name, cur.ns.href)
            function&.call(style, cur)
            cur = cur.next
            next
          end
          case cur.name
          when "import"
            transform_error(nil, style, cur, "xsltParseStylesheetTop: ignoring misplaced import element\n")
            style.errors += 1
          when "include"
            style.errors += 1 if parse_stylesheet_include(style, cur) != 0
          when "strip-space" then parse_stylesheet_strip_space(style, cur)
          when "preserve-space" then parse_stylesheet_preserve_space(style, cur)
          when "output" then parse_stylesheet_output(style, cur)
          when "key" then parse_stylesheet_key(style, cur)
          when "decimal-format" then parse_stylesheet_decimal_format(style, cur)
          when "attribute-set" then parse_stylesheet_attribute_set(style, cur)
          when "variable" then parse_global_variable(style, cur)
          when "param" then parse_global_param(style, cur)
          when "template" then parse_stylesheet_template(style, cur)
          when "namespace-alias" then namespace_alias(style, cur)
          else
            unless style.forwards_compatible
              transform_error(nil, style, cur, "xsltParseStylesheetTop: unknown #{cur.name} element\n")
              style.errors += 1
            end
          end
          cur = cur.next
        end
      end

      # xsltParseStylesheetProcess
      def parse_stylesheet_process(ret, doc)
        return nil if doc.nil? || ret.nil?

        cur = Tree.doc_get_root_element(doc)
        if cur.nil?
          transform_error(nil, ret, doc, "xsltParseStylesheetProcess : empty stylesheet\n")
          return nil
        end
        if xslt_elem?(cur) && (cur.name == "stylesheet" || cur.name == "transform")
          ret.literal_result = false
          parse_stylesheet_exclude_prefix(ret, cur, true)
          parse_stylesheet_ext_prefix(ret, cur, true)
        else
          parse_stylesheet_exclude_prefix(ret, cur, false)
          parse_stylesheet_ext_prefix(ret, cur, false)
          ret.literal_result = true
        end
        preprocess_stylesheet(ret, cur) unless ret.nopreproc
        if !ret.literal_result
          parse_stylesheet_top(ret, cur)
        else
          prop = Tree.get_ns_prop(cur, "version", NAMESPACE)
          if prop.nil?
            transform_error(nil, ret, cur, "xsltParseStylesheetProcess : document is not a stylesheet\n")
            return nil
          end
          if prop != "1.0" && prop != "1.1"
            transform_error(nil, ret, cur, "xsl:version: only 1.1 features are supported\n")
            ret.forwards_compatible = true
            ret.warnings += 1
          end
          template = Template.new
          template.next = ret.templates
          ret.templates = template
          template.match = +"/"
          parse_template_content(ret, doc)
          template.elem = doc
          template.content = doc.children
          add_template(ret, template, nil, nil)
          ret.literal_result = true
        end
        ret
      end

      # xsltParseStylesheetImportedDoc
      def parse_stylesheet_imported_doc(doc, parent_style)
        return nil if doc.nil?

        ret_style = Stylesheet.new(parent_style)
        return nil if parse_stylesheet_user(ret_style, doc) != 0

        ret_style
      end

      # xsltParseStylesheetUser
      def parse_stylesheet_user(style, doc)
        return -1 if style.nil? || doc.nil?

        # xsltGatherNamespaces(style) runs while style->doc is still NULL: a no-op
        gather_namespaces(style) if style.doc
        style.doc = doc
        if parse_stylesheet_process(style, doc).nil?
          style.doc = nil
          return -1
        end
        resolve_stylesheet_attribute_set(style) if style.parent.nil?
        if style.errors != 0
          style.doc = nil
          return -1
        end
        0
      end

      # xsltParseStylesheetDoc
      def parse_stylesheet_doc(doc)
        parse_stylesheet_imported_doc(doc, nil)
      end
    end
  end
end
