# frozen_string_literal: true

# Port of ext/nokogiri/gumbo.c: Nokogiri::Gumbo.parse and Nokogiri::Gumbo.fragment.
#
# The HTML5 input is parsed by the gumbo port (Nokogiri::Pure::Gumbo) into a gumbo tree, which is
# then walked to build a libxml2-style tree (Nokogiri::Pure::Tree structs), exactly like gumbo.c.

require_relative "../gumbo/parser"

module Nokogiri
  module Pure
    module GumboGlue
      G = Pure::Gumbo

      HTML_NS = "http://www.w3.org/1999/xhtml"
      SVG_NS = "http://www.w3.org/2000/svg"
      MATHML_NS = "http://www.w3.org/1998/Math/MathML"
      XLINK_NS = "http://www.w3.org/1999/xlink"
      XML_NS = "http://www.w3.org/XML/1998/namespace"
      XMLNS_NS = "http://www.w3.org/2000/xmlns/"

      UTF8_TAG_NAMES = G::TAG_NAMES.map { |n| -n.dup.force_encoding(Encoding::UTF_8) }.freeze

      UNDEF = Object.new.freeze
      private_constant :UNDEF

      module_function

      def utf8(s)
        s.force_encoding(Encoding::UTF_8)
      end

      # C strings stop at the first NUL
      def cstr(s)
        i = s.index("\0")
        i ? s.byteslice(0, i) : s
      end

      # new_html_doc (htmlNewDocNoDtD + xmlCreateIntSubset)
      def new_html_doc(dtd_name, system, public)
        doc = Tree.new_html_doc
        doc.standalone = 1
        doc.compression = 0
        doc.charset = 1
        doc.doc_properties = (1 << 7) | (1 << 5) # XML_DOC_HTML | XML_DOC_USERBUILT
        Tree.create_int_subset(doc, dtd_name, public, system) if dtd_name
        doc
      end

      def lookup_or_add_ns(doc, root, href, prefix)
        Tree.search_ns(doc, root, prefix) || Tree.new_ns(root, href, prefix)
      end

      def set_line(node, line)
        node.line = line if line < 65535
      end

      # build_tree: construct the libxml2 tree rooted at xml_output_node from the gumbo tree rooted
      # at gumbo_node.
      def build_tree(doc, xml_output_node, gumbo_node)
        xml_root = nil
        xml_node = xml_output_node
        child_index = 0

        while true
          children = gumbo_node.children
          if child_index >= children.length
            return if xml_node.equal?(xml_output_node)

            child_index = gumbo_node.index_within_parent + 1
            gumbo_node = gumbo_node.parent
            xml_node = xml_node.parent
            xml_root = nil if xml_node.equal?(xml_output_node)
            next
          end
          gumbo_child = children[child_index]
          child_index += 1

          case gumbo_child.type
          when G::NODE_TEXT, G::NODE_WHITESPACE
            xml_child = Tree.new_doc_text(doc, utf8(cstr(gumbo_child.text)))
            set_line(xml_child, gumbo_child.line)
            Tree.add_child(xml_node, xml_child)
          when G::NODE_CDATA
            xml_child = Tree.new_cdata_block(doc, utf8(gumbo_child.text))
            set_line(xml_child, gumbo_child.line)
            Tree.add_child(xml_node, xml_child)
          when G::NODE_COMMENT
            xml_child = Tree.new_doc_comment(doc, utf8(cstr(gumbo_child.text)))
            set_line(xml_child, gumbo_child.line)
            Tree.add_child(xml_node, xml_child)
          when G::NODE_ELEMENT, G::NODE_TEMPLATE
            name = gumbo_child.name
            name = if name.frozen? && G::TAG_NAMES[gumbo_child.tag].equal?(name)
              UTF8_TAG_NAMES[gumbo_child.tag]
            else
              utf8(cstr(name.dup))
            end
            xml_child = Tree.new_doc_node(doc, nil, name, nil)
            set_line(xml_child, gumbo_child.line)
            xml_root = xml_child if xml_root.nil?
            ns = case gumbo_child.tag_namespace
            when G::NAMESPACE_SVG
              lookup_or_add_ns(doc, xml_root, SVG_NS, "svg")
            when G::NAMESPACE_MATHML
              lookup_or_add_ns(doc, xml_root, MATHML_NS, "math")
            end
            Tree.set_ns(xml_child, ns) if ns
            Tree.add_child(xml_node, xml_child)

            gumbo_child.attributes.each do |attr|
              ns = case attr.attr_namespace
              when G::ATTR_NAMESPACE_XLINK
                lookup_or_add_ns(doc, xml_root, XLINK_NS, "xlink")
              when G::ATTR_NAMESPACE_XML
                lookup_or_add_ns(doc, xml_root, XML_NS, "xml")
              when G::ATTR_NAMESPACE_XMLNS
                lookup_or_add_ns(doc, xml_root, XMLNS_NS, "xmlns")
              end
              Tree.new_ns_prop(xml_child, ns, utf8(cstr(attr.name.dup)), utf8(cstr(attr.value.dup)))
            end

            child_index = 0
            gumbo_node = gumbo_child
            xml_node = xml_child
          end
        end
      end

      # add_errors
      def add_errors(output, rdoc, input, url)
        return if output.errors.empty?

        source = input.b
        rerrors = output.errors.map do |err|
          msg = utf8(err.caret_diagnostic(source))
          syntax_error = Nokogiri::XML::SyntaxError.new(msg)
          syntax_error.instance_variable_set(:@domain, 1) # XML_FROM_PARSER
          syntax_error.instance_variable_set(:@code, 1) # XML_ERR_INTERNAL_ERROR
          syntax_error.instance_variable_set(:@level, 2) # XML_ERR_ERROR
          syntax_error.instance_variable_set(:@file, url)
          syntax_error.instance_variable_set(:@line, err.line)
          syntax_error.instance_variable_set(:@str1, err.code.dup.force_encoding(Encoding::UTF_8))
          syntax_error.instance_variable_set(:@str2, nil)
          syntax_error.instance_variable_set(:@str3, nil)
          syntax_error.instance_variable_set(:@int1, 0)
          syntax_error.instance_variable_set(:@column, err.column)
          syntax_error
        end
        rdoc.instance_variable_set(:@errors, rerrors)
      end

      # NUM2INT
      def num2int(value)
        v = case value
        when Integer
          value
        when Float
          raise FloatDomainError, value.to_s if value.nan? || value.infinite?

          value.to_i
        when nil
          raise TypeError, "no implicit conversion from nil to integer"
        when true, false
          raise TypeError, "no implicit conversion of #{value} into Integer"
        else
          unless value.respond_to?(:to_int)
            raise TypeError, "no implicit conversion of #{value.class} into Integer"
          end

          value.to_int
        end
        if v < -2**31 || v >= 2**31
          raise RangeError, "integer #{v} too #{v < 0 ? "small" : "big"} to convert to 'int'"
        end

        v
      end

      def common_options_kw(max_attributes:, max_errors:, max_tree_depth:, parse_noscript_content_as_text: UNDEF)
        options = G::Options.new
        options.max_attributes = num2int(max_attributes)
        options.max_errors = num2int(max_errors)
        depth = num2int(max_tree_depth)
        options.max_tree_depth = depth < 0 ? G::UINT_MAX : depth
        options.parse_noscript_content_as_text = !parse_noscript_content_as_text.equal?(UNDEF) &&
          parse_noscript_content_as_text ? true : false
        options
      end

      def common_options(kwargs)
        common_options_kw(**kwargs)
      end

      def check_string(value)
        return if value.is_a?(String)

        raise TypeError, "wrong argument type #{type_name(value)} (expected String)"
      end

      def type_name(value)
        case value
        when nil then "nil"
        when true then "true"
        when false then "false"
        else value.class.to_s
        end
      end

      # perform_parse
      def perform_parse(options, input)
        check_string(input)
        output = G.parse_with_options(options, input)
        case output.status
        when G::STATUS_TOO_MANY_ATTRIBUTES, G::STATUS_TREE_TOO_DEEP
          raise ArgumentError, G.status_to_string(output.status)
        when G::STATUS_OUT_OF_MEMORY
          raise NoMemoryError, G.status_to_string(output.status)
        end
        output
      end

      def parse(input, url, klass, kwargs)
        options = common_options(kwargs)
        output = perform_parse(options, input)

        document = output.document
        doc = if document.has_doctype
          name = utf8(cstr(document.doc_name.dup))
          public = document.public_identifier
          system = document.system_identifier
          public = public.empty? ? nil : utf8(cstr(public.dup))
          system = system.empty? ? nil : utf8(cstr(system.dup))
          new_html_doc(name, system, public)
        else
          new_html_doc(nil, nil, nil)
        end
        build_tree(doc, doc, document)
        rdoc = Pure.wrap_document(klass, doc)
        rdoc.instance_variable_set(:@url, url)
        rdoc.instance_variable_set(:@quirks_mode, document.doc_type_quirks_mode)
        add_errors(output, rdoc, input, url)
        rdoc
      end

      # lookup_namespace
      def lookup_namespace(node, require_known_ns)
        ns = node.namespace
        return G::NAMESPACE_HTML if ns.nil?

        href = ns.href
        check_string(href)
        case href
        when HTML_NS then return G::NAMESPACE_HTML
        when MATHML_NS then return G::NAMESPACE_MATHML
        when SVG_NS then return G::NAMESPACE_SVG
        end
        raise ArgumentError, "Unexpected namespace URI \"#{cstr(href)}\"" if require_known_ns

        -1
      end

      def string_value_cstr(str)
        raise ArgumentError, "string contains null byte" if str.include?("\0")

        str
      end

      def fragment(doc_fragment, tags, ctx, kwargs)
        options = common_options(kwargs)
        form = false
        encoding = nil

        if ctx.nil?
          ctx_tag = "body"
          ctx_ns = G::NAMESPACE_HTML
        elsif ctx.is_a?(String)
          ctx_tag = string_value_cstr(ctx)
          ctx_ns = G::NAMESPACE_HTML
          colon = ctx_tag.b.index(":")
          if colon
            prefix = ctx_tag.b.byteslice(0, colon)
            case colon
            when 3
              raise ArgumentError, "Invalid context namespace '#{ctx_tag}'" unless prefix.casecmp("svg") == 0

              ctx_ns = G::NAMESPACE_SVG
            when 4
              if prefix.casecmp("html") == 0
                ctx_ns = G::NAMESPACE_HTML
              elsif prefix.casecmp("math") == 0
                ctx_ns = G::NAMESPACE_MATHML
              else
                raise ArgumentError, "Invalid context namespace '#{ctx_tag}'"
              end
            else
              raise ArgumentError, "Invalid context namespace '#{ctx_tag}'"
            end
            ctx_tag = ctx_tag.b.byteslice(colon + 1..)
          elsif ctx_tag.bytesize == 3 && ctx_tag.b.casecmp("svg") == 0
            ctx_ns = G::NAMESPACE_SVG
          elsif ctx_tag.bytesize == 4 && ctx_tag.b.casecmp("math") == 0
            ctx_ns = G::NAMESPACE_MATHML
          end

          form = ctx_ns == G::NAMESPACE_HTML && ctx_tag.b.casecmp("form") == 0
        else
          tag_name = ctx.name
          check_string(tag_name)
          ctx_tag = string_value_cstr(tag_name)

          ctx_ns = lookup_namespace(ctx, true)

          node = ctx
          until node.nil?
            if node.element?
              element_name = node.name
              if element_name.bytesize == 4 && cstr(element_name).b.casecmp("form") == 0 &&
                  lookup_namespace(node, false) == G::NAMESPACE_HTML
                form = true
                break
              end
            end
            node = node.respond_to?(:parent) ? node.parent : nil
          end

          if ctx_ns == G::NAMESPACE_MATHML && tag_name.bytesize == 14 &&
              cstr(ctx_tag).b.casecmp("annotation-xml") == 0
            enc = ctx["encoding"]
            if enc
              check_string(enc)
              encoding = string_value_cstr(enc)
            end
          end
        end

        # Quirks mode.
        doc = doc_fragment.document
        dtd = doc.internal_subset
        doc_quirks_mode = doc.instance_variable_get(:@quirks_mode)
        quirks_mode = if ctx.nil? || ctx.is_a?(String) || doc_quirks_mode.nil?
          G::DOCTYPE_NO_QUIRKS
        elsif dtd.nil?
          G::DOCTYPE_QUIRKS
        else
          dtd_name = dtd.name
          pubid = dtd.external_id
          sysid = dtd.system_id
          G.compute_quirks_mode(
            dtd_name.nil? ? nil : string_value_cstr(dtd_name),
            pubid.nil? ? nil : string_value_cstr(pubid),
            sysid.nil? ? nil : string_value_cstr(sysid),
          )
        end

        options.fragment_context = cstr(ctx_tag)
        options.fragment_namespace = ctx_ns
        options.fragment_encoding = encoding
        options.quirks_mode = quirks_mode
        options.fragment_context_has_form_ancestor = form

        options.max_tree_depth += 1 if options.max_tree_depth < G::UINT_MAX

        output = perform_parse(options, tags)

        xml_doc = Pure.unwrap(doc)
        xml_frag = Pure.unwrap(doc_fragment)
        build_tree(xml_doc, xml_frag, output.root)
        doc_fragment.instance_variable_set(:@quirks_mode, output.document.doc_type_quirks_mode)
        add_errors(output, doc_fragment, tags, "#fragment")
        nil
      end
    end
  end

  module Gumbo
    class << self
      # @!visibility protected
      def parse(input, url, klass, **kwargs)
        Pure::GumboGlue.parse(input, url, klass, kwargs)
      end

      # @!visibility protected
      def fragment(doc_fragment, tags, ctx, **kwargs)
        Pure::GumboGlue.fragment(doc_fragment, tags, ctx, kwargs)
      end
    end
  end
end
