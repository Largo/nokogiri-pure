# frozen_string_literal: true

# Port of libxslt attributes.c (attribute sets, xsl:attribute) and namespaces.c.

module Nokogiri
  module Pure
    module XSLT
      ATTRSET_UNRESOLVED = 0
      ATTRSET_RESOLVING = 1
      ATTRSET_RESOLVED = 2

      # xsltAttrSet: +attrs+ is an Array of xsl:attribute nodes, +use_attr_sets+ an Array of
      # [ncname, ns]
      class AttrSet
        attr_accessor :state, :attrs, :use_attr_sets

        def initialize
          @state = ATTRSET_UNRESOLVED
          @attrs = []
          @use_attr_sets = []
        end
      end

      module_function

      # xsltMergeAttrSets
      def merge_attr_sets(set, other)
        other.attrs.each do |old|
          old_comp = old.psvi
          dup = set.attrs.any? do |cur|
            cur_comp = cur.psvi
            cur_comp.name == old_comp.name && cur_comp.ns == old_comp.ns
          end
          set.attrs << old unless dup
        end
      end

      # xsltParseStylesheetAttributeSet
      def parse_stylesheet_attribute_set(style, cur)
        return if cur.nil? || style.nil? || cur.type != ELEMENT_NODE

        value = get_prop(cur, "name")
        if value.nil? || value.empty?
          generic_error("xsl:attribute-set : name is missing\n")
          return
        end
        unless valid_qname?(value)
          transform_error(nil, style, cur, "xsl:attribute-set : The name '#{value}' is not a valid QName.\n")
          style.errors += 1
          return
        end
        ncname, prefix = split_qname(value)
        ns_uri = nil
        if prefix
          ns = Tree.search_ns(style.doc, cur, prefix)
          if ns.nil?
            transform_error(nil, style, cur, "xsl:attribute-set : No namespace found for QName '#{prefix}:#{ncname}'\n")
            style.errors += 1
            return
          end
          ns_uri = ns.href
        end
        style.attribute_sets ||= {}
        set = (style.attribute_sets[[ncname, ns_uri]] ||= AttrSet.new)

        child = cur.children
        while child
          if child.type != ELEMENT_NODE || child.ns.nil? || !xslt_elem?(child)
            if child.type == ELEMENT_NODE
              transform_error(nil, style, child, "xsl:attribute-set : unexpected child #{child.name}\n")
            else
              transform_error(nil, style, child, "xsl:attribute-set : child of unexpected type\n")
            end
          elsif child.name != "attribute"
            transform_error(nil, style, child, "xsl:attribute-set : unexpected child xsl:#{child.name}\n")
          else
            style_pre_compute(style, child)
            parse_template_content(style, child) if child.children
            if child.psvi.nil?
              transform_error(nil, style, child,
                "xsl:attribute-set : internal error, attribute #{child.name} not compiled\n")
            else
              set.attrs << child
            end
          end
          child = child.next
        end

        value = get_prop(cur, "use-attribute-sets")
        if value
          each_token(value) do |curval|
            unless valid_qname?(curval)
              transform_error(nil, style, cur,
                "xsl:attribute-set : The name '#{curval}' in use-attribute-sets is not a valid QName.\n")
              style.errors += 1
              return
            end
            ncname2, prefix2 = split_qname(curval)
            ns_uri2 = nil
            if prefix2
              ns2 = Tree.search_ns(style.doc, cur, prefix2)
              if ns2.nil?
                transform_error(nil, style, cur,
                  "xsl:attribute-set : No namespace found for QName '#{prefix2}:#{ncname2}' in use-attribute-sets\n")
                style.errors += 1
                return
              end
              ns_uri2 = ns2.href
            end
            set.use_attr_sets << [ncname2, ns_uri2] unless set.use_attr_sets.include?([ncname2, ns_uri2])
          end
        end
      end

      # xsltResolveUseAttrSets
      def resolve_use_attr_sets(set, top_style, depth)
        set.use_attr_sets.each do |ncname, ns|
          cur = top_style
          while cur
            if cur.attribute_sets && (other = cur.attribute_sets[[ncname, ns]])
              resolve_attr_set(other, top_style, cur, ncname, ns, depth + 1)
              merge_attr_sets(set, other)
              break
            end
            cur = next_import(cur)
          end
        end
        set.use_attr_sets = []
      end

      # xsltResolveAttrSet
      def resolve_attr_set(set, top_style, style, name, ns, depth)
        return if set.state == ATTRSET_RESOLVED

        if set.state == ATTRSET_RESOLVING
          transform_error(nil, top_style, nil, "xsl:attribute-set : use-attribute-sets recursion detected on #{name}\n")
          top_style.errors += 1
          set.state = ATTRSET_RESOLVED
          return
        end
        if depth > 100
          transform_error(nil, top_style, nil,
            "xsl:attribute-set : use-attribute-sets maximum recursion depth exceeded on #{name}\n")
          top_style.errors += 1
          return
        end
        set.state = ATTRSET_RESOLVING
        resolve_use_attr_sets(set, top_style, depth)
        cur = next_import(style)
        while cur
          if cur.attribute_sets && (other = cur.attribute_sets[[name, ns]])
            resolve_use_attr_sets(other, top_style, depth)
            merge_attr_sets(set, other)
            cur.attribute_sets.delete([name, ns])
          end
          cur = next_import(cur)
        end
        set.state = ATTRSET_RESOLVED
      end

      # xsltResolveStylesheetAttributeSet
      def resolve_stylesheet_attribute_set(style)
        cur = style
        while cur
          if cur.attribute_sets
            style.attribute_sets ||= {}
            cur.attribute_sets.to_a.each do |(name, ns), set|
              # an entry may have been removed (merged into another set) during the scan
              next if cur != style && !cur.attribute_sets.key?([name, ns])

              resolve_attr_set(set, style, cur, name, ns, 1)
              if !cur.equal?(style) && !style.attribute_sets.key?([name, ns])
                style.attribute_sets[[name, ns]] = set
              end
            end
            cur.attribute_sets = nil unless cur.equal?(style)
          end
          cur = next_import(cur)
        end
      end

      # xsltAttribute
      def attribute(ctxt, context_node, inst, comp)
        return if ctxt.nil? || context_node.nil? || inst.nil? || inst.type != ELEMENT_NODE

        if comp.nil?
          transform_error(ctxt, nil, inst,
            "Internal error in xsltAttribute(): The XSLT 'attribute' instruction was not compiled.\n")
          return
        end
        return unless comp.has_name
        return if ctxt.insert.nil?

        target_elem = ctxt.insert
        return if target_elem.type != ELEMENT_NODE

        if target_elem.children
          transform_error(ctxt, nil, inst,
            "xsl:attribute: Cannot add attributes to an element if children have been already added to the element.\n")
          return
        end

        if comp.name.nil?
          prop = eval_attr_value_template(ctxt, inst, "name", NAMESPACE)
          if prop.nil?
            transform_error(ctxt, nil, inst, "xsl:attribute: The attribute 'name' is missing.\n")
            return
          end
          unless valid_qname?(prop)
            transform_error(ctxt, nil, inst, "xsl:attribute: The effective name '#{prop}' is not a valid QName.\n")
          end
          if prop == "xmlns"
            transform_error(ctxt, nil, inst, "xsl:attribute: The effective name 'xmlns' is not allowed.\n")
            return
          end
          name, prefix = split_qname(prop)
        else
          name, prefix = split_qname(comp.name)
        end

        ns_name = nil
        if comp.has_ns
          if comp.ns
            ns_name = comp.ns unless comp.ns.empty?
          else
            tmp = eval_attr_value_template(ctxt, inst, "namespace", NAMESPACE)
            ns_name = tmp if tmp && !tmp.empty?
          end
          if ns_name == "http://www.w3.org/2000/xmlns/"
            transform_error(ctxt, nil, inst, "xsl:attribute: Namespace http://www.w3.org/2000/xmlns/ forbidden.\n")
            return
          end
          if ns_name == XML_XML_NAMESPACE
            prefix = "xml"
          elsif prefix == "xml"
            prefix = nil
          end
        elsif prefix
          ns = Tree.search_ns(inst.doc, inst, prefix)
          if ns.nil?
            transform_error(ctxt, nil, inst,
              "xsl:attribute: The QName '#{prefix}:#{name}' has no namespace binding in scope in the stylesheet; " \
              "this is an error, since the namespace was not specified by the instruction itself.\n")
          else
            ns_name = ns.href
          end
        end

        ns = nil
        if ns_name
          ns = if prefix.nil? || prefix == "xmlns"
            get_special_namespace(ctxt, inst, ns_name, "ns_1", target_elem)
          else
            get_special_namespace(ctxt, inst, ns_name, prefix, target_elem)
          end
          if ns.nil?
            transform_error(ctxt, nil, inst,
              "Namespace fixup error: Failed to acquire an in-scope namespace binding for the generated attribute '{#{ns_name}}#{name}'.\n")
            return
          end
        end

        if inst.children.nil?
          Tree.set_ns_prop(ctxt.insert, ns, name, "")
        elsif inst.children.next.nil? &&
            (inst.children.type == TEXT_NODE || inst.children.type == CDATA_SECTION_NODE)
          attr = Tree.set_ns_prop(ctxt.insert, ns, name, nil)
          return if attr.nil?

          copy_txt = Tree.new_text(inst.children.content)
          attr.children = attr.last = copy_txt
          copy_txt.parent = attr
          copy_txt.doc = attr.doc
          copy_txt.name = STRING_TEXT_NOENC if inst.children.name == STRING_TEXT_NOENC
          if copy_txt.content && Tree.is_id(attr.doc, attr.parent, attr)
            Tree.add_id(attr, copy_txt.content)
          end
        else
          value = eval_template_string(ctxt, context_node, inst)
          Tree.set_ns_prop(ctxt.insert, ns, name, value.nil? ? "" : value)
        end
      end

      # xsltApplyAttributeSet
      def apply_attribute_set(ctxt, node, inst, attr_sets)
        if attr_sets.nil?
          return if inst.nil?

          attr_sets = inst.children&.content if inst.type == ATTRIBUTE_NODE
          return if attr_sets.nil?
        end
        each_token(attr_sets) do |curstr|
          unless valid_qname?(curstr)
            transform_error(ctxt, nil, inst, "The name '#{curstr}' in use-attribute-sets is not a valid QName.\n")
            return
          end
          ncname, prefix = split_qname(curstr)
          ns_uri = nil
          if prefix
            ns = Tree.search_ns(inst.doc, inst, prefix)
            if ns.nil?
              transform_error(ctxt, nil, inst, "use-attribute-set : No namespace found for QName '#{prefix}:#{ncname}'\n")
              return
            end
            ns_uri = ns.href
          end
          set = ctxt.style.attribute_sets&.[]([ncname, ns_uri])
          set&.attrs&.each do |a|
            attribute(ctxt, node, a, a.psvi)
          end
        end
      end

      # ---- namespaces.c -------------------------------------------------------------------------

      # xsltNamespaceAlias
      def namespace_alias(style, node)
        return if style.nil? || node.nil?

        style_prefix = get_prop(node, "stylesheet-prefix")
        if style_prefix.nil?
          transform_error(nil, style, node, "namespace-alias: stylesheet-prefix attribute missing\n")
          return
        end
        result_prefix = get_prop(node, "result-prefix")
        if result_prefix.nil?
          transform_error(nil, style, node, "namespace-alias: result-prefix attribute missing\n")
          return
        end
        if style_prefix == "#default"
          literal_ns = Tree.search_ns(node.doc, node, nil)
          literal_ns_name = literal_ns&.href
        else
          literal_ns = Tree.search_ns(node.doc, node, style_prefix)
          if literal_ns.nil? || literal_ns.href.nil?
            transform_error(nil, style, node, "namespace-alias: prefix #{style_prefix} not bound to any namespace\n")
            return
          end
          literal_ns_name = literal_ns.href
        end
        if result_prefix == "#default"
          target_ns = Tree.search_ns(node.doc, node, nil)
          target_ns_name = target_ns.nil? ? UNDEFINED_DEFAULT_NS : target_ns.href
        else
          target_ns = Tree.search_ns(node.doc, node, result_prefix)
          if target_ns.nil? || target_ns.href.nil?
            transform_error(nil, style, node, "namespace-alias: prefix #{result_prefix} not bound to any namespace\n")
            return
          end
          target_ns_name = target_ns.href
        end
        if literal_ns_name.nil?
          style.default_alias = target_ns.href if target_ns
        else
          style.ns_aliases ||= {}
          style.ns_aliases[literal_ns_name] = target_ns_name unless style.ns_aliases.key?(literal_ns_name)
        end
      end

      # xsltGetSpecialNamespace
      def get_special_namespace(ctxt, invoc_node, ns_name, ns_prefix, target)
        return nil if ctxt.nil? || target.nil? || target.type != ELEMENT_NODE

        if ns_prefix.nil? && (ns_name.nil? || ns_name.empty?)
          ns = target.ns_def
          while ns
            if ns.prefix.nil?
              if ns.href && !ns.href.empty?
                transform_error(ctxt, nil, invoc_node,
                  "Namespace normalization error: Cannot undeclare the default namespace, since the default " \
                  "namespace '#{ns.href}' is already declared on the result element '#{target.name}'.\n")
              end
              return nil
            end
            ns = ns.next
          end
          if target.parent && target.parent.type == ELEMENT_NODE
            return nil if target.parent.ns.nil?

            ns = Tree.search_ns(target.doc, target.parent, nil)
            return nil if ns.nil? || ns.href.nil? || ns.href.empty?

            Tree.new_ns(target, "", nil)
            return nil
          end
          return nil
        end

        return Tree.search_ns(target.doc, target, ns_prefix) if ns_prefix == "xml"

        prefix_occupied = false
        ns = target.ns_def
        while ns
          if ns.prefix.nil? == ns_prefix.nil? && ns.prefix == ns_prefix
            return ns if ns.href == ns_name

            prefix_occupied = true
            break
          end
          ns = ns.next
        end
        if prefix_occupied
          ns = Tree.search_ns_by_href(target.doc, target, ns_name)
          return ns if ns
          # fall through to declare_new_prefix
        elsif target.parent && target.parent.type == ELEMENT_NODE
          if target.parent.ns && (!target.parent.ns.prefix.nil?) == (!ns_prefix.nil?)
            ns = target.parent.ns
            if ns_prefix.nil?
              return ns if ns.href == ns_name
            elsif ns.prefix == ns_prefix && ns.href == ns_name
              return ns
            end
          end
          ns = Tree.search_ns(target.doc, target.parent, ns_prefix)
          if ns
            return ns if ns.href == ns_name

            attr = target.properties
            used = false
            while attr
              if attr.ns && attr.ns.prefix == ns_prefix
                ns = Tree.search_ns_by_href(target.doc, target, ns_name)
                return ns if ns

                used = true
                break
              end
              attr = attr.next
            end
            return Tree.new_ns(target, ns_name, ns_prefix) unless used
          else
            return Tree.new_ns(target, ns_name, ns_prefix)
          end
        else
          return Tree.new_ns(target, ns_name, ns_prefix)
        end

        # declare_new_prefix:
        ns_prefix ||= "ns"
        counter = 1
        loop do
          pref = "#{ns_prefix}_#{counter}"
          counter += 1
          ns = Tree.search_ns(target.doc, target, pref)
          if counter > 1000
            transform_error(ctxt, nil, invoc_node,
              "Internal error in xsltAcquireResultInScopeNs(): Failed to compute a unique ns-prefix for the generated element")
            return nil
          end
          return Tree.new_ns(target, ns_name, pref) if ns.nil?
        end
      end

      def ns_alias_lookup(style, href)
        uri = nil
        while style
          uri = style.ns_aliases[href] if style.ns_aliases
          break unless uri.nil?

          style = next_import(style)
        end
        uri
      end

      # xsltGetNamespace
      def get_namespace(ctxt, cur, ns, out)
        return nil if ns.nil?
        return nil if ctxt.nil? || cur.nil? || out.nil?

        uri = ns_alias_lookup(ctxt.style, ns.href)
        if uri.equal?(UNDEFINED_DEFAULT_NS)
          return get_special_namespace(ctxt, cur, nil, nil, out)
        elsif uri.nil?
          uri = ns.href
        end
        get_special_namespace(ctxt, cur, uri, ns.prefix, out)
      end

      # xsltCopyNamespaceList
      def copy_namespace_list(ctxt, node, cur)
        return nil if cur.nil? || !cur.is_a?(XmlNs)

        node = nil if node && node.type != ELEMENT_NODE
        ret = nil
        p = nil
        while cur
          break unless cur.is_a?(XmlNs)

          if node
            if node.ns && node.ns.prefix == cur.prefix && node.ns.href == cur.href
              cur = cur.next
              next
            end
            tmp = Tree.search_ns(node.doc, node, cur.prefix)
            if tmp && tmp.href == cur.href
              cur = cur.next
              next
            end
          end
          if cur.href != NAMESPACE
            uri = ctxt.style.ns_aliases&.[](cur.href)
            if uri.equal?(UNDEFINED_DEFAULT_NS)
              cur = cur.next
              next
            end
            q = Tree.new_ns(node, uri || cur.href, cur.prefix)
            if p.nil?
              ret = p = q
            else
              p.next = q
              p = q
            end
          end
          cur = cur.next
        end
        ret
      end

      # xsltCopyNamespace
      def copy_namespace(_ctxt, elem, ns)
        return nil if ns.nil? || !ns.is_a?(XmlNs)

        if elem && elem.type != ELEMENT_NODE
          Tree.new_ns(nil, ns.href, ns.prefix)
        else
          Tree.new_ns(elem, ns.href, ns.prefix)
        end
      end
    end
  end
end
