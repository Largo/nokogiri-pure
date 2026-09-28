# frozen_string_literal: true

require_relative "../schemas/types_names"

# relaxng.c: document loading (include / externalRef), the preprocessing of the schema tree
# (xmlRelaxNGCleanupTree), parsing of patterns / name classes / grammars, and xmlRelaxNGParse.
module Nokogiri
  module Pure
    module RelaxNG
      class << self
        # test hook used before the pure XML parser exists: callable(content, url) -> XmlDoc
        attr_accessor :parse_memory_override
      end

      module_function

      def blank_ch?(c) = c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D

      # IS_RELAXNG(node, typ)
      def is_relaxng(node, typ)
        !node.nil? && !node.ns.nil? && node.type == ELEMENT_NODE && node.name == typ &&
          node.ns.href == XML_RELAXNG_NS
      end

      # xmlValidateNCName(value, 0) != 0
      def invalid_ncname?(value)
        Schemas::Types.validate_nc_name(value, 0) != 0
      end

      def uri_parser
        Pure.const_defined?(:Parser) && Pure::Parser.const_defined?(:URIParser) ? Pure::Parser::URIParser : nil
      end

      # xmlParseURI: nil or {scheme:, fragment:, ...}
      def parse_uri(str)
        if (up = uri_parser)
          u = up.parse(str)
          return u && { scheme: u.scheme, fragment: u.fragment }
        end
        return nil unless Schemas::Types.parse_uri_ok(str)

        URI_.parse(str) || {}
      end

      # xmlBuildURI
      def build_uri(uri, base)
        (up = uri_parser) ? up.build_uri(uri, base) : URI_.build_uri(uri, base)
      end

      # xmlRelaxNGNormExtSpace (returns the normalized copy)
      def norm_ext_space(value)
        return nil if value.nil?

        b = value.b
        n = b.bytesize
        cur = 0
        cur += 1 while cur < n && blank_ch?(b.getbyte(cur))
        if cur == 0
          loop do
            cur += 1 while cur < n && !blank_ch?(b.getbyte(cur))
            return value if cur == n

            start = cur
            cur += 1 while cur < n && blank_ch?(b.getbyte(cur))
            return b.byteslice(0, start).force_encoding(Encoding::UTF_8) if cur == n
          end
        else
          out = +"".b
          loop do
            while cur < n && !blank_ch?(b.getbyte(cur))
              out << b.getbyte(cur)
              cur += 1
            end
            return out.force_encoding(Encoding::UTF_8) if cur == n

            # don't try to normalize the inner spaces
            cur += 1 while cur < n && blank_ch?(b.getbyte(cur))
            return out.force_encoding(Encoding::UTF_8) if cur == n

            out << b.getbyte(cur)
            cur += 1
          end
        end
      end

      # xmlRelaxNGNewDefine
      def new_define(ctxt, node)
        ret = Define.new(node)
        ctxt.def_tab << ret
        ret
      end

      # ---- loading documents ------------------------------------------------------------

      def load_doc_file(filename)
        if Pure.const_defined?(:Parser) && Pure::Parser.respond_to?(:read_file) && parse_memory_override.nil?
          return Pure::Parser.read_file(filename, nil, 0)
        end

        path = Schemas.respond_to?(:location_to_path) ? Schemas.location_to_path(filename) : filename
        content = begin
          path && File.binread(path)
        rescue SystemCallError
          nil
        end
        if content.nil?
          Errors.report(XmlError.new(domain: Domain::IO, code: ErrCode::IO_LOAD_ERROR, level: Level::WARNING,
            message: "failed to load \"#{filename}\": No such file or directory\n", str1: filename))
          return nil
        end
        parse_memory_override ? parse_memory_override.call(content, filename) : Pure::Parser.read_memory(content, filename, nil, 0)
      end

      def load_doc_memory(buffer)
        if parse_memory_override
          parse_memory_override.call(buffer, nil)
        else
          Pure::Parser.read_memory(buffer, nil, nil, 0)
        end
      end

      # xmlRelaxReadFile: errors of the XML parser go to the context's structured handler
      def relax_read_file(ctxt, filename)
        if ctxt.serror
          Errors.with_handler(ctxt.serror) { load_doc_file(filename) }
        else
          load_doc_file(filename)
        end
      end

      # xmlRelaxReadMemory
      def relax_read_memory(ctxt, buffer)
        if ctxt.serror
          Errors.with_handler(ctxt.serror) { load_doc_memory(buffer) }
        else
          load_doc_memory(buffer)
        end
      end

      # xmlRelaxNGIncludePush
      def include_push(ctxt, value)
        ctxt.inc_tab << value
        ctxt.inc = value
        ctxt.inc_tab.size - 1
      end

      # xmlRelaxNGIncludePop
      def include_pop(ctxt)
        return nil if ctxt.inc_tab.empty?

        ret = ctxt.inc_tab.pop
        ctxt.inc = ctxt.inc_tab.last
        ret
      end

      # xmlRelaxNGRemoveRedefine
      def remove_redefine(ctxt, url, target, name)
        found = 0
        tmp = target
        while tmp
          tmp2 = tmp.next
          if name.nil? && is_relaxng(tmp, "start")
            found = 1
            Tree.unlink_node(tmp)
          elsif !name.nil? && is_relaxng(tmp, "define")
            name2 = norm_ext_space(Tree.get_prop(tmp, "name"))
            if name2 && name == name2
              found = 1
              Tree.unlink_node(tmp)
            end
          elsif is_relaxng(tmp, "include")
            inc = tmp.psvi
            if inc.is_a?(Include) || inc.is_a?(Document)
              if inc.doc && inc.doc.children && inc.doc.children.name == "grammar"
                root = Tree.doc_get_root_element(inc.doc)
                found = 1 if remove_redefine(ctxt, nil, root&.children, name) == 1
              end
            end
            found = 1 if remove_redefine(ctxt, url, tmp.children, name) == 1
          end
          tmp = tmp2
        end
        found
      end

      # xmlRelaxNGLoadInclude
      def load_include(ctxt, url, node, ns)
        ctxt.inc_tab.each do |inc|
          if inc.href == url
            p_err(ctxt, nil, ErrCode::RNGP_INCLUDE_RECURSE, "Detected an Include recursion for %s\n", url)
            return nil
          end
        end

        doc = relax_read_file(ctxt, url)
        if doc.nil?
          p_err(ctxt, node, ErrCode::RNGP_PARSE_ERROR, "xmlRelaxNG: could not load %s\n", url)
          return nil
        end

        ret = Include.new
        ret.doc = doc
        ret.href = url.dup
        ret.next = ctxt.includes
        ctxt.includes = ret

        # transmit the ns if needed
        if ns
          root = Tree.doc_get_root_element(doc)
          Tree.set_prop(root, "ns", ns) if root && Tree.has_prop(root, "ns").nil?
        end

        include_push(ctxt, ret)
        doc = cleanup_doc(ctxt, doc)
        if doc.nil?
          ctxt.inc = nil
          return nil
        end
        include_pop(ctxt)

        root = Tree.doc_get_root_element(doc)
        if root.nil?
          p_err(ctxt, node, ErrCode::RNGP_EMPTY, "xmlRelaxNG: included document is empty %s\n", url)
          return nil
        end
        unless is_relaxng(root, "grammar")
          p_err(ctxt, node, ErrCode::RNGP_GRAMMAR_MISSING,
            "xmlRelaxNG: included document %s root is not a grammar\n", url)
          return nil
        end

        # Elimination of redefined rules in the include.
        cur = node.children
        while cur
          if is_relaxng(cur, "start")
            found = remove_redefine(ctxt, url, root.children, nil)
            if found == 0
              p_err(ctxt, node, ErrCode::RNGP_START_MISSING,
                "xmlRelaxNG: include %s has a start but not the included grammar\n", url)
            end
          elsif is_relaxng(cur, "define")
            name = Tree.get_prop(cur, "name")
            if name.nil?
              p_err(ctxt, node, ErrCode::RNGP_NAME_MISSING,
                "xmlRelaxNG: include %s has define without name\n", url)
            else
              name = norm_ext_space(name)
              found = remove_redefine(ctxt, url, root.children, name)
              if found == 0
                p_err(ctxt, node, ErrCode::RNGP_DEFINE_MISSING,
                  "xmlRelaxNG: include %s has a define %s but not the included grammar\n", url, name)
              end
            end
          end
          if is_relaxng(cur, "div") && cur.children
            cur = cur.children
          elsif cur.next
            cur = cur.next
          else
            cur = cur.parent while !cur.parent.equal?(node) && cur.parent.next.nil?
            cur = cur.parent.equal?(node) ? nil : cur.parent.next
          end
        end
        ret
      end

      # xmlRelaxNGDocumentPush
      def document_push(ctxt, value)
        ctxt.doc_tab << value
        ctxt.doc = value
        ctxt.doc_tab.size - 1
      end

      # xmlRelaxNGDocumentPop
      def document_pop(ctxt)
        return nil if ctxt.doc_tab.empty?

        ret = ctxt.doc_tab.pop
        ctxt.doc = ctxt.doc_tab.last
        ret
      end

      # xmlRelaxNGLoadExternalRef
      def load_external_ref(ctxt, url, ns)
        ctxt.doc_tab.each do |d|
          if d.href == url
            p_err(ctxt, nil, ErrCode::RNGP_EXTERNALREF_RECURSE,
              "Detected an externalRef recursion for %s\n", url)
            return nil
          end
        end

        doc = relax_read_file(ctxt, url)
        if doc.nil?
          p_err(ctxt, nil, ErrCode::RNGP_PARSE_ERROR, "xmlRelaxNG: could not load %s\n", url)
          return nil
        end

        ret = Document.new
        ret.doc = doc
        ret.href = url.dup
        ret.next = ctxt.documents
        ret.external_ref = 1
        ctxt.documents = ret

        if ns
          root = Tree.doc_get_root_element(doc)
          Tree.set_prop(root, "ns", ns) if root && Tree.has_prop(root, "ns").nil?
        end

        document_push(ctxt, ret)
        doc = cleanup_doc(ctxt, doc)
        if doc.nil?
          ctxt.doc = nil
          return nil
        end
        document_pop(ctxt)
        ret
      end

      # ---- preprocessing ------------------------------------------------------------------

      # xmlRelaxNGCleanupAttributes
      def cleanup_attributes(ctxt, node)
        cur = node.properties
        while cur
          nxt = cur.next
          if cur.ns.nil? || cur.ns.href == XML_RELAXNG_NS
            case cur.name
            when "name"
              unless %w[element attribute ref parentRef param define].include?(node.name)
                p_err(ctxt, node, ErrCode::RNGP_FORBIDDEN_ATTRIBUTE,
                  "Attribute %s is not allowed on %s\n", cur.name, node.name)
              end
            when "type"
              unless %w[value data].include?(node.name)
                p_err(ctxt, node, ErrCode::RNGP_FORBIDDEN_ATTRIBUTE,
                  "Attribute %s is not allowed on %s\n", cur.name, node.name)
              end
            when "href"
              unless %w[externalRef include].include?(node.name)
                p_err(ctxt, node, ErrCode::RNGP_FORBIDDEN_ATTRIBUTE,
                  "Attribute %s is not allowed on %s\n", cur.name, node.name)
              end
            when "combine"
              unless %w[start define].include?(node.name)
                p_err(ctxt, node, ErrCode::RNGP_FORBIDDEN_ATTRIBUTE,
                  "Attribute %s is not allowed on %s\n", cur.name, node.name)
              end
            when "datatypeLibrary"
              val = Tree.node_list_get_string(node.doc, cur.children, true)
              if val && !val.empty?
                uri = parse_uri(val)
                if uri.nil?
                  p_err(ctxt, node, ErrCode::RNGP_INVALID_URI,
                    "Attribute %s contains invalid URI %s\n", cur.name, val)
                else
                  if uri[:scheme].nil?
                    p_err(ctxt, node, ErrCode::RNGP_URI_NOT_ABSOLUTE,
                      "Attribute %s URI %s is not absolute\n", cur.name, val)
                  end
                  unless uri[:fragment].nil?
                    p_err(ctxt, node, ErrCode::RNGP_URI_FRAGMENT,
                      "Attribute %s URI %s has a fragment ID\n", cur.name, val)
                  end
                end
              end
            when "ns"
              # allowed
            else
              p_err(ctxt, node, ErrCode::RNGP_UNKNOWN_ATTRIBUTE,
                "Unknown attribute %s on %s\n", cur.name, node.name)
            end
          end
          cur = nxt
        end
      end

      # the value of the "ns" attribute of +node+ or its nearest element ancestor
      def inherited_ns(node)
        while node && node.type == ELEMENT_NODE
          ns = Tree.get_prop(node, "ns")
          return ns if ns

          node = node.parent
        end
        nil
      end

      # xmlRelaxNGCleanupTree
      def cleanup_tree(ctxt, root)
        delete = nil
        cur = root
        while cur
          if delete
            Tree.unlink_node(delete)
            delete = nil
          end
          skip_children = false
          if cur.type == ELEMENT_NODE
            # Simplification 4.1. Annotations
            if cur.ns.nil? || cur.ns.href != XML_RELAXNG_NS
              if cur.parent && cur.parent.type == ELEMENT_NODE &&
                  %w[name value param].include?(cur.parent.name)
                p_err(ctxt, cur, ErrCode::RNGP_FOREIGN_ELEMENT,
                  "element %s doesn't allow foreign elements\n", cur.parent.name)
              end
              delete = cur
              skip_children = true
            else
              cleanup_attributes(ctxt, cur)
              if cur.name == "externalRef"
                ns = Tree.get_prop(cur, "ns")
                ns = inherited_ns(cur.parent) if ns.nil?
                href = Tree.get_prop(cur, "href")
                if href.nil?
                  p_err(ctxt, cur, ErrCode::RNGP_MISSING_HREF,
                    "xmlRelaxNGParse: externalRef has no href attribute\n")
                  delete = cur
                  skip_children = true
                else
                  uri = parse_uri(href)
                  if uri.nil?
                    p_err(ctxt, cur, ErrCode::RNGP_HREF_ERROR, "Incorrect URI for externalRef %s\n", href)
                    delete = cur
                    skip_children = true
                  elsif !uri[:fragment].nil?
                    p_err(ctxt, cur, ErrCode::RNGP_HREF_ERROR,
                      "Fragment forbidden in URI for externalRef %s\n", href)
                    delete = cur
                    skip_children = true
                  else
                    base = Tree.node_get_base(cur.doc, cur)
                    url = build_uri(href, base)
                    if url.nil?
                      p_err(ctxt, cur, ErrCode::RNGP_HREF_ERROR,
                        "Failed to compute URL for externalRef %s\n", href)
                      delete = cur
                      skip_children = true
                    else
                      docu = load_external_ref(ctxt, url, ns)
                      if docu.nil?
                        p_err(ctxt, cur, ErrCode::RNGP_EXTERNAL_REF_FAILURE,
                          "Failed to load externalRef %s\n", url)
                        delete = cur
                        skip_children = true
                      else
                        cur.psvi = docu
                      end
                    end
                  end
                end
              elsif cur.name == "include"
                href = Tree.get_prop(cur, "href")
                if href.nil?
                  p_err(ctxt, cur, ErrCode::RNGP_MISSING_HREF,
                    "xmlRelaxNGParse: include has no href attribute\n")
                  delete = cur
                  skip_children = true
                else
                  base = Tree.node_get_base(cur.doc, cur)
                  url = build_uri(href, base)
                  if url.nil?
                    p_err(ctxt, cur, ErrCode::RNGP_HREF_ERROR, "Failed to compute URL for include %s\n", href)
                    delete = cur
                    skip_children = true
                  else
                    ns = Tree.get_prop(cur, "ns")
                    ns = inherited_ns(cur.parent) if ns.nil?
                    incl = load_include(ctxt, url, cur, ns)
                    if incl.nil?
                      p_err(ctxt, cur, ErrCode::RNGP_INCLUDE_FAILURE, "Failed to load include %s\n", url)
                      delete = cur
                      skip_children = true
                    else
                      cur.psvi = incl
                    end
                  end
                end
              elsif cur.name == "element" || cur.name == "attribute"
                # Simplification 4.8. name attribute of element and attribute elements
                name = Tree.get_prop(cur, "name")
                if name
                  text = nil
                  if cur.children.nil?
                    text = Tree.new_doc_node(cur.doc, cur.ns, "name", name)
                    Tree.add_child(cur, text) if text
                  else
                    node = Tree.new_doc_node(cur.doc, cur.ns, "name", nil)
                    if node
                      Tree.add_prev_sibling(cur.children, node)
                      text = Tree.new_doc_text(node.doc, name)
                      Tree.add_child(node, text)
                      text = node
                    end
                  end
                  if text.nil?
                    p_err(ctxt, cur, ErrCode::RNGP_CREATE_FAILURE, "Failed to create a name %s element\n", name)
                  end
                  Tree.unset_prop(cur, "name")
                  ns = Tree.get_prop(cur, "ns")
                  if ns
                    Tree.set_prop(text, "ns", ns) if text
                  elsif cur.name == "attribute"
                    Tree.set_prop(text, "ns", "")
                  end
                end
              elsif cur.name == "name" || cur.name == "nsName" || cur.name == "value"
                # Simplification 4.8. name attribute of element and attribute elements
                if Tree.has_prop(cur, "ns").nil?
                  ns = inherited_ns(cur.parent)
                  Tree.set_prop(cur, "ns", ns.nil? ? "" : ns)
                end
                if cur.name == "name"
                  # Simplification: 4.10. QNames
                  name = Tree.node_get_content(cur)
                  if name
                    local, prefix = Tree.split_qname2(name)
                    if local
                      ns = Tree.search_ns(cur.doc, cur, prefix)
                      if ns.nil?
                        p_err(ctxt, cur, ErrCode::RNGP_PREFIX_UNDEFINED,
                          "xmlRelaxNGParse: no namespace for prefix %s\n", prefix)
                      else
                        Tree.set_prop(cur, "ns", ns.href)
                        Tree.node_set_content(cur, local)
                      end
                    end
                  end
                end
                # 4.16
                if cur.name == "nsName" && ctxt.flags & IN_NSEXCEPT != 0
                  p_err(ctxt, cur, ErrCode::RNGP_PAT_NSNAME_EXCEPT_NSNAME,
                    "Found nsName/except//nsName forbidden construct\n")
                end
              elsif cur.name == "except" && !cur.equal?(root)
                oldflags = ctxt.flags
                # 4.16
                if cur.parent && cur.parent.name == "anyName"
                  ctxt.flags |= IN_ANYEXCEPT
                  cleanup_tree(ctxt, cur)
                  ctxt.flags = oldflags
                  skip_children = true
                elsif cur.parent && cur.parent.name == "nsName"
                  ctxt.flags |= IN_NSEXCEPT
                  cleanup_tree(ctxt, cur)
                  ctxt.flags = oldflags
                  skip_children = true
                end
              elsif cur.name == "anyName"
                # 4.16
                if ctxt.flags & IN_ANYEXCEPT != 0
                  p_err(ctxt, cur, ErrCode::RNGP_PAT_ANYNAME_EXCEPT_ANYNAME,
                    "Found anyName/except//anyName forbidden construct\n")
                elsif ctxt.flags & IN_NSEXCEPT != 0
                  p_err(ctxt, cur, ErrCode::RNGP_PAT_NSNAME_EXCEPT_ANYNAME,
                    "Found nsName/except//anyName forbidden construct\n")
                end
              end
              # This is not an else since "include" is transformed into a div
              if !skip_children && cur.name == "div"
                # implements rule 4.11
                ns = Tree.get_prop(cur, "ns")
                child = cur.children
                ins = cur
                while child
                  if ns && Tree.has_prop(child, "ns").nil?
                    Tree.set_prop(child, "ns", ns)
                  end
                  tmp = child.next
                  Tree.unlink_node(child)
                  ins = Tree.add_next_sibling(ins, child)
                  child = tmp
                end
                # preserve the namespace definitions of the div (bug 143738)
                if cur.ns_def && cur.parent
                  if cur.parent.ns_def.nil?
                    cur.parent.ns_def = cur.ns_def
                  else
                    par_def = cur.parent.ns_def
                    par_def = par_def.next while par_def.next
                    par_def.next = cur.ns_def
                  end
                  cur.ns_def = nil
                end
                delete = cur
                skip_children = true
              end
            end
          elsif cur.type == TEXT_NODE || cur.type == CDATA_SECTION_NODE
            # Simplification 4.2 whitespaces
            if is_blank(cur.content)
              if cur.parent && cur.parent.type == ELEMENT_NODE
                delete = cur if cur.parent.name != "value" && cur.parent.name != "param"
              else
                delete = cur
                skip_children = true
              end
            end
          else
            delete = cur
            skip_children = true
          end

          # Skip to next node
          if !skip_children && cur.children &&
              cur.children.type != ENTITY_DECL && cur.children.type != ENTITY_REF_NODE &&
              cur.children.type != ENTITY_NODE
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

            if cur.equal?(root)
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
      end

      # xmlRelaxNGIsBlank
      def is_blank(str)
        return true if str.nil?

        !str.match?(/[^ \t\n\r]/)
      end

      # xmlRelaxNGCleanupDoc
      def cleanup_doc(ctxt, doc)
        root = Tree.doc_get_root_element(doc)
        if root.nil?
          p_err(ctxt, doc, ErrCode::RNGP_EMPTY, "xmlRelaxNGParse: %s is empty\n", ctxt.url)
          return nil
        end
        cleanup_tree(ctxt, root)
        doc
      end

      # ---- parsing ------------------------------------------------------------------------

      # xmlRelaxNGGetDataTypeLibrary
      def get_data_type_library(_ctxt, node)
        return nil if node.nil?

        if is_relaxng(node, "data") || is_relaxng(node, "value")
          ret = Tree.get_prop(node, "datatypeLibrary")
          if ret
            return nil if ret.empty?

            return Save.uri_escape_str(ret, ":/#?")
          end
        end
        node = node.parent
        while node && node.type == ELEMENT_NODE
          ret = Tree.get_prop(node, "datatypeLibrary")
          if ret
            return nil if ret.empty?

            return Save.uri_escape_str(ret, ":/#?")
          end
          node = node.parent
        end
        nil
      end

      # xmlRelaxNGParseValue
      def parse_value(ctxt, node)
        lib = nil
        success = 0
        defn = new_define(ctxt, node)
        defn.type = VALUE

        type = Tree.get_prop(node, "type")
        if type
          type = norm_ext_space(type)
          if invalid_ncname?(type)
            p_err(ctxt, node, ErrCode::RNGP_TYPE_VALUE, "value type '%s' is not an NCName\n", type)
          end
          library = get_data_type_library(ctxt, node)
          library = XML_RELAXNG_NS.dup if library.nil?

          defn.name = type
          defn.ns = library

          lib = REGISTERED_TYPES.lookup(library)
          if lib.nil?
            p_err(ctxt, node, ErrCode::RNGP_UNKNOWN_TYPE_LIB, "Use of unregistered type library '%s'\n", library)
            defn.data = nil
          else
            defn.data = lib
            if lib.have.nil?
              p_err(ctxt, node, ErrCode::RNGP_ERROR_TYPE_LIB,
                "Internal error with type library '%s': no 'have'\n", library)
            else
              success = lib.have.call(lib.data, defn.name)
              if success != 1
                p_err(ctxt, node, ErrCode::RNGP_TYPE_NOT_FOUND,
                  "Error type '%s' is not exported by type library '%s'\n", defn.name, library)
              end
            end
          end
        end
        if node.children.nil?
          defn.value = +""
        elsif (node.children.type != TEXT_NODE && node.children.type != CDATA_SECTION_NODE) ||
            node.children.next
          p_err(ctxt, node, ErrCode::RNGP_TEXT_EXPECTED, "Expecting a single text value for <value>content\n")
        else
          defn.value = Tree.node_get_content(node)
          if defn.value.nil?
            p_err(ctxt, node, ErrCode::RNGP_VALUE_NO_CONTENT, "Element <value> has no content\n")
          elsif lib && lib.check && success == 1
            success, val = lib.check.call(lib.data, defn.name, defn.value, true, node)
            if success != 1
              p_err(ctxt, node, ErrCode::RNGP_INVALID_VALUE,
                "Value '%s' is not acceptable for type '%s'\n", defn.value, defn.name)
            else
              defn.attrs = val unless val.nil?
            end
          end
        end
        defn
      end

      # xmlRelaxNGParseData
      def parse_data(ctxt, node)
        type = Tree.get_prop(node, "type")
        if type.nil?
          p_err(ctxt, node, ErrCode::RNGP_TYPE_MISSING, "data has no type\n")
          return nil
        end
        type = norm_ext_space(type)
        if invalid_ncname?(type)
          p_err(ctxt, node, ErrCode::RNGP_TYPE_VALUE, "data type '%s' is not an NCName\n", type)
        end
        library = get_data_type_library(ctxt, node)
        library = XML_RELAXNG_NS.dup if library.nil?

        defn = new_define(ctxt, node)
        defn.type = DATATYPE
        defn.name = type
        defn.ns = library

        lib = REGISTERED_TYPES.lookup(library)
        if lib.nil?
          p_err(ctxt, node, ErrCode::RNGP_UNKNOWN_TYPE_LIB, "Use of unregistered type library '%s'\n", library)
          defn.data = nil
        else
          defn.data = lib
          if lib.have.nil?
            p_err(ctxt, node, ErrCode::RNGP_ERROR_TYPE_LIB,
              "Internal error with type library '%s': no 'have'\n", library)
          else
            tmp = lib.have.call(lib.data, defn.name)
            if tmp != 1
              p_err(ctxt, node, ErrCode::RNGP_TYPE_NOT_FOUND,
                "Error type '%s' is not exported by type library '%s'\n", defn.name, library)
            elsif library == XSD_DATATYPES_NS && (defn.name == "IDREF" || defn.name == "IDREFS")
              ctxt.idref = 1
            end
          end
        end
        content = node.children

        # Handle optional params
        lastparam = nil
        while content
          break if content.name != "param"

          if library == XML_RELAXNG_NS
            p_err(ctxt, node, ErrCode::RNGP_PARAM_FORBIDDEN,
              "Type library '%s' does not allow type parameters\n", library)
            content = content.next
            content = content.next while content && content.name == "param"
          else
            param = new_define(ctxt, node)
            param.type = PARAM
            param.name = Tree.get_prop(content, "name")
            if param.name.nil?
              p_err(ctxt, node, ErrCode::RNGP_PARAM_NAME_MISSING, "param has no name\n")
            end
            param.value = Tree.node_get_content(content)
            if lastparam.nil?
              defn.attrs = lastparam = param
            else
              lastparam.next = param
              lastparam = param
            end
            content = content.next
          end
        end

        # Handle optional except
        if content && content.name == "except"
          last = nil
          except = new_define(ctxt, node)
          except.type = EXCEPT
          child = content.children
          defn.content = except
          if child.nil?
            p_err(ctxt, content, ErrCode::RNGP_EXCEPT_NO_CONTENT, "except has no content\n")
          end
          while child
            tmp2 = parse_pattern(ctxt, child)
            if tmp2
              if last.nil?
                except.content = last = tmp2
              else
                last.next = tmp2
                last = tmp2
              end
            end
            child = child.next
          end
          content = content.next
        end

        # Check there is no unhandled data
        if content
          p_err(ctxt, content, ErrCode::RNGP_DATA_CONTENT, "Element data has unexpected content %s\n", content.name)
        end
        defn
      end

      # xmlRelaxNGParseInterleave
      def parse_interleave(ctxt, node)
        last = nil
        defn = new_define(ctxt, node)
        defn.type = INTERLEAVE

        ctxt.interleaves ||= Hash2.new
        name = "interleave#{ctxt.nb_interleaves}"
        ctxt.nb_interleaves += 1
        if ctxt.interleaves.add(name, defn) < 0
          p_err(ctxt, node, ErrCode::RNGP_INTERLEAVE_ADD, "Failed to add %s to hash table\n", name)
        end
        child = node.children
        if child.nil?
          p_err(ctxt, node, ErrCode::RNGP_INTERLEAVE_NO_CONTENT, "Element interleave is empty\n")
        end
        while child
          cur = if is_relaxng(child, "element")
            parse_element(ctxt, child)
          else
            parse_pattern(ctxt, child)
          end
          if cur
            cur.parent = defn
            if last.nil?
              defn.content = last = cur
            else
              last.next = cur
              last = cur
            end
          end
          child = child.next
        end
        defn
      end

      # xmlRelaxNGParseInclude
      def parse_include(ctxt, node)
        ret = 0
        incl = node.psvi
        unless incl.is_a?(Include)
          p_err(ctxt, node, ErrCode::RNGP_INCLUDE_EMPTY, "Include node has no data\n")
          return -1
        end
        root = Tree.doc_get_root_element(incl.doc)
        if root.nil?
          p_err(ctxt, node, ErrCode::RNGP_EMPTY, "Include document is empty\n")
          return -1
        end
        if root.name != "grammar"
          p_err(ctxt, node, ErrCode::RNGP_GRAMMAR_MISSING, "Include document root is not a grammar\n")
          return -1
        end

        # Merge the definition from both the include and the internal list
        if root.children
          tmp = parse_grammar_content(ctxt, root.children)
          ret = -1 if tmp != 0
        end
        if node.children
          tmp = parse_grammar_content(ctxt, node.children)
          ret = -1 if tmp != 0
        end
        ret
      end

      # xmlRelaxNGParseDefine
      def parse_define(ctxt, node)
        ret = 0
        name = Tree.get_prop(node, "name")
        if name.nil?
          p_err(ctxt, node, ErrCode::RNGP_DEFINE_NAME_MISSING, "define has no name\n")
        else
          name = norm_ext_space(name)
          if invalid_ncname?(name)
            p_err(ctxt, node, ErrCode::RNGP_INVALID_DEFINE_NAME, "define name '%s' is not an NCName\n", name)
          end
          defn = new_define(ctxt, node)
          defn.type = DEF
          defn.name = name
          if node.children.nil?
            p_err(ctxt, node, ErrCode::RNGP_DEFINE_EMPTY, "define has no children\n")
          else
            olddefine = ctxt.define
            ctxt.define = name
            defn.content = parse_patterns(ctxt, node.children, 0)
            ctxt.define = olddefine
          end
          ctxt.grammar.defs ||= Hash2.new
          tmp = ctxt.grammar.defs.add(name, defn)
          if tmp < 0
            prev = ctxt.grammar.defs.lookup(name)
            if prev.nil?
              p_err(ctxt, node, ErrCode::RNGP_DEFINE_CREATE_FAILED,
                "Internal error on define aggregation of %s\n", name)
              ret = -1
            else
              prev = prev.next_hash while prev.next_hash
              prev.next_hash = defn
            end
          end
        end
        ret
      end

      # xmlRelaxNGParseImportRef
      def parse_import_ref(ctxt, defn, name)
        defn.dflags |= IS_EXTERNAL_REF
        tmp = ctxt.grammar.refs.add(name, defn)
        if tmp < 0
          prev = ctxt.grammar.refs.lookup(defn.name)
          if prev.nil?
            if defn.name
              p_err(ctxt, nil, ErrCode::RNGP_REF_CREATE_FAILED, "Error refs definitions '%s'\n", defn.name)
            else
              p_err(ctxt, nil, ErrCode::RNGP_REF_CREATE_FAILED, "Error refs definitions\n")
            end
          else
            defn.next_hash = prev.next_hash
            prev.next_hash = defn
          end
        end
      end

      # xmlRelaxNGParseImportRefs
      def parse_import_refs(ctxt, grammar)
        return -1 if ctxt.nil? || grammar.nil? || ctxt.grammar.nil?
        return 0 if grammar.refs.nil?

        ctxt.grammar.refs ||= Hash2.new
        grammar.refs.scan { |defn, name| parse_import_ref(ctxt, defn, name) }
        0
      end

      # xmlRelaxNGProcessExternalRef
      def process_external_ref(ctxt, node)
        docu = node.psvi
        return nil unless docu.is_a?(Document)

        defn = new_define(ctxt, node)
        defn.type = EXTERNALREF

        if docu.content.nil?
          # Then do the parsing for good
          root = Tree.doc_get_root_element(docu.doc)
          if root.nil?
            p_err(ctxt, node, ErrCode::RNGP_EXTERNALREF_EMTPY, "xmlRelaxNGParse: %s is empty\n", ctxt.url)
            return nil
          end
          # ns transmission rules
          new_ns = 0
          ns = Tree.get_prop(root, "ns")
          if ns.nil?
            ns = inherited_ns(node)
            if ns
              Tree.set_prop(root, "ns", ns)
              new_ns = 1
            end
          end

          # Parsing to get a precompiled schemas.
          oldflags = ctxt.flags
          ctxt.flags |= IN_EXTERNALREF
          docu.schema = parse_document(ctxt, root)
          ctxt.flags = oldflags
          if docu.schema && docu.schema.topgrammar
            docu.content = docu.schema.topgrammar.start
            parse_import_refs(ctxt, docu.schema.topgrammar) if docu.schema.topgrammar.refs
          end

          # the externalRef may be reused in a different ns context
          Tree.unset_prop(root, "ns") if new_ns == 1
        end
        defn.content = docu.content
        defn
      end

      # xmlRelaxNGParsePattern
      def parse_pattern(ctxt, node)
        defn = nil
        return nil if node.nil?

        if is_relaxng(node, "element")
          defn = parse_element(ctxt, node)
        elsif is_relaxng(node, "attribute")
          defn = parse_attribute(ctxt, node)
        elsif is_relaxng(node, "empty")
          defn = new_define(ctxt, node)
          defn.type = EMPTY
          if node.children
            p_err(ctxt, node, ErrCode::RNGP_EMPTY_NOT_EMPTY, "empty: had a child node\n")
          end
        elsif is_relaxng(node, "text")
          defn = new_define(ctxt, node)
          defn.type = TEXT
          if node.children
            p_err(ctxt, node, ErrCode::RNGP_TEXT_HAS_CHILD, "text: had a child node\n")
          end
        elsif is_relaxng(node, "zeroOrMore") || is_relaxng(node, "oneOrMore") ||
            is_relaxng(node, "optional") || is_relaxng(node, "choice") || is_relaxng(node, "group") ||
            is_relaxng(node, "list")
          defn = new_define(ctxt, node)
          group = 0
          case node.name
          when "zeroOrMore"
            defn.type = ZEROORMORE
            group = 1
          when "oneOrMore"
            defn.type = ONEORMORE
            group = 1
          when "optional"
            defn.type = OPTIONAL
            group = 1
          when "choice" then defn.type = CHOICE
          when "group" then defn.type = GROUP
          when "list" then defn.type = LIST
          end
          if node.children.nil?
            p_err(ctxt, node, ErrCode::RNGP_EMPTY_CONSTRUCT, "Element %s is empty\n", node.name)
          else
            defn.content = parse_patterns(ctxt, node.children, group)
          end
        elsif is_relaxng(node, "ref")
          defn = new_define(ctxt, node)
          defn.type = REF
          defn.name = Tree.get_prop(node, "name")
          if defn.name.nil?
            p_err(ctxt, node, ErrCode::RNGP_REF_NO_NAME, "ref has no name\n")
          else
            defn.name = norm_ext_space(defn.name)
            if invalid_ncname?(defn.name)
              p_err(ctxt, node, ErrCode::RNGP_REF_NAME_INVALID, "ref name '%s' is not an NCName\n", defn.name)
            end
          end
          if node.children
            p_err(ctxt, node, ErrCode::RNGP_REF_NOT_EMPTY, "ref is not empty\n")
          end
          ctxt.grammar.refs ||= Hash2.new
          tmp = ctxt.grammar.refs.add(defn.name, defn)
          if tmp < 0
            prev = ctxt.grammar.refs.lookup(defn.name)
            if prev.nil?
              if defn.name
                p_err(ctxt, node, ErrCode::RNGP_REF_CREATE_FAILED, "Error refs definitions '%s'\n", defn.name)
              else
                p_err(ctxt, node, ErrCode::RNGP_REF_CREATE_FAILED, "Error refs definitions\n")
              end
              defn = nil
            else
              defn.next_hash = prev.next_hash
              prev.next_hash = defn
            end
          end
        elsif is_relaxng(node, "data")
          defn = parse_data(ctxt, node)
        elsif is_relaxng(node, "value")
          defn = parse_value(ctxt, node)
        elsif is_relaxng(node, "interleave")
          defn = parse_interleave(ctxt, node)
        elsif is_relaxng(node, "externalRef")
          defn = process_external_ref(ctxt, node)
        elsif is_relaxng(node, "notAllowed")
          defn = new_define(ctxt, node)
          defn.type = NOT_ALLOWED
          if node.children
            p_err(ctxt, node, ErrCode::RNGP_NOTALLOWED_NOT_EMPTY,
              "xmlRelaxNGParse: notAllowed element is not empty\n")
          end
        elsif is_relaxng(node, "grammar")
          oldparent = ctxt.parentgrammar
          old = ctxt.grammar
          ctxt.parentgrammar = old
          grammar = parse_grammar(ctxt, node.children)
          if old
            ctxt.grammar = old
            ctxt.parentgrammar = oldparent
          end
          defn = grammar&.start
        elsif is_relaxng(node, "parentRef")
          if ctxt.parentgrammar.nil?
            p_err(ctxt, node, ErrCode::RNGP_PARENTREF_NO_PARENT, "Use of parentRef without a parent grammar\n")
            return nil
          end
          defn = new_define(ctxt, node)
          defn.type = PARENTREF
          defn.name = Tree.get_prop(node, "name")
          if defn.name.nil?
            p_err(ctxt, node, ErrCode::RNGP_PARENTREF_NO_NAME, "parentRef has no name\n")
          else
            defn.name = norm_ext_space(defn.name)
            if invalid_ncname?(defn.name)
              p_err(ctxt, node, ErrCode::RNGP_PARENTREF_NAME_INVALID,
                "parentRef name '%s' is not an NCName\n", defn.name)
            end
          end
          if node.children
            p_err(ctxt, node, ErrCode::RNGP_PARENTREF_NOT_EMPTY, "parentRef is not empty\n")
          end
          ctxt.parentgrammar.refs ||= Hash2.new
          if defn.name
            tmp = ctxt.parentgrammar.refs.add(defn.name, defn)
            if tmp < 0
              prev = ctxt.parentgrammar.refs.lookup(defn.name)
              if prev.nil?
                p_err(ctxt, node, ErrCode::RNGP_PARENTREF_CREATE_FAILED,
                  "Internal error parentRef definitions '%s'\n", defn.name)
                defn = nil
              else
                defn.next_hash = prev.next_hash
                prev.next_hash = defn
              end
            end
          end
        elsif is_relaxng(node, "mixed")
          if node.children.nil?
            p_err(ctxt, node, ErrCode::RNGP_EMPTY_CONSTRUCT, "Mixed is empty\n")
            defn = nil
          else
            defn = parse_interleave(ctxt, node)
            if defn
              if defn.content && defn.content.next
                tmp = new_define(ctxt, node)
                tmp.type = GROUP
                tmp.content = defn.content
                defn.content = tmp
              end
              tmp = new_define(ctxt, node)
              tmp.type = TEXT
              tmp.next = defn.content
              defn.content = tmp
            end
          end
        else
          p_err(ctxt, node, ErrCode::RNGP_UNKNOWN_CONSTRUCT, "Unexpected node %s is not a pattern\n", node.name)
          defn = nil
        end
        defn
      end

      ATTRIBUTE_CONTENT_OK = [EMPTY, NOT_ALLOWED, TEXT, ELEMENT, DATATYPE, VALUE, LIST, REF, PARENTREF,
        EXTERNALREF, DEF, ONEORMORE, ZEROORMORE, OPTIONAL, CHOICE, GROUP, INTERLEAVE, ATTRIBUTE].freeze

      # xmlRelaxNGParseAttribute
      def parse_attribute(ctxt, node)
        ret = new_define(ctxt, node)
        ret.type = ATTRIBUTE
        ret.parent = ctxt.def
        child = node.children
        if child.nil?
          p_err(ctxt, node, ErrCode::RNGP_ATTRIBUTE_EMPTY, "xmlRelaxNGParseattribute: attribute has no children\n")
          return ret
        end
        old_flags = ctxt.flags
        ctxt.flags |= IN_ATTRIBUTE
        cur = parse_name_class(ctxt, child, ret)
        child = child.next if cur

        if child
          cur = parse_pattern(ctxt, child)
          if cur
            if ATTRIBUTE_CONTENT_OK.include?(cur.type)
              ret.content = cur
              cur.parent = ret
            elsif cur.type == START || cur.type == PARAM || cur.type == EXCEPT
              p_err(ctxt, node, ErrCode::RNGP_ATTRIBUTE_CONTENT, "attribute has invalid content\n")
            elsif cur.type == NOOP
              p_err(ctxt, node, ErrCode::RNGP_ATTRIBUTE_NOOP, "RNG Internal error, noop found in attribute\n")
            end
          end
          child = child.next
        end
        if child
          p_err(ctxt, node, ErrCode::RNGP_ATTRIBUTE_CHILDREN, "attribute has multiple children\n")
        end
        ctxt.flags = old_flags
        ret
      end

      # xmlRelaxNGParseExceptNameClass
      def parse_except_name_class(ctxt, node, attr)
        last = nil
        unless is_relaxng(node, "except")
          p_err(ctxt, node, ErrCode::RNGP_EXCEPT_MISSING, "Expecting an except node\n")
          return nil
        end
        if node.next
          p_err(ctxt, node, ErrCode::RNGP_EXCEPT_MULTIPLE, "exceptNameClass allows only a single except node\n")
        end
        if node.children.nil?
          p_err(ctxt, node, ErrCode::RNGP_EXCEPT_EMPTY, "except has no content\n")
          return nil
        end

        ret = new_define(ctxt, node)
        ret.type = EXCEPT
        child = node.children
        while child
          cur = new_define(ctxt, child)
          cur.type = attr ? ATTRIBUTE : ELEMENT
          if parse_name_class(ctxt, child, cur)
            if last.nil?
              ret.content = cur
            else
              last.next = cur
            end
            last = cur
          end
          child = child.next
        end
        ret
      end

      # xmlRelaxNGParseNameClass
      def parse_name_class(ctxt, node, defn)
        ret = defn
        if is_relaxng(node, "name") || is_relaxng(node, "anyName") || is_relaxng(node, "nsName")
          if defn.type != ELEMENT && defn.type != ATTRIBUTE
            ret = new_define(ctxt, node)
            ret.parent = defn
            ret.type = ctxt.flags & IN_ATTRIBUTE != 0 ? ATTRIBUTE : ELEMENT
          end
        end
        if is_relaxng(node, "name")
          val = norm_ext_space(Tree.node_get_content(node))
          if invalid_ncname?(val)
            if node.parent
              p_err(ctxt, node, ErrCode::RNGP_ELEMENT_NAME, "Element %s name '%s' is not an NCName\n",
                node.parent.name, val)
            else
              p_err(ctxt, node, ErrCode::RNGP_ELEMENT_NAME, "name '%s' is not an NCName\n", val)
            end
          end
          ret.name = val
          val = Tree.get_prop(node, "ns")
          ret.ns = val
          if ctxt.flags & IN_ATTRIBUTE != 0 && val && val == "http://www.w3.org/2000/xmlns"
            p_err(ctxt, node, ErrCode::RNGP_XML_NS, "Attribute with namespace '%s' is not allowed\n", val)
          end
          if ctxt.flags & IN_ATTRIBUTE != 0 && val && val.empty? && ret.name == "xmlns"
            p_err(ctxt, node, ErrCode::RNGP_XMLNS_NAME, "Attribute with QName 'xmlns' is not allowed\n", val)
          end
        elsif is_relaxng(node, "anyName")
          ret.name = nil
          ret.ns = nil
          if node.children
            ret.name_class = parse_except_name_class(ctxt, node.children, defn.type == ATTRIBUTE)
          end
        elsif is_relaxng(node, "nsName")
          ret.name = nil
          ret.ns = Tree.get_prop(node, "ns")
          if ret.ns.nil?
            p_err(ctxt, node, ErrCode::RNGP_NSNAME_NO_NS, "nsName has no ns attribute\n")
          end
          if ctxt.flags & IN_ATTRIBUTE != 0 && ret.ns && ret.ns == "http://www.w3.org/2000/xmlns"
            p_err(ctxt, node, ErrCode::RNGP_XML_NS, "Attribute with namespace '%s' is not allowed\n", ret.ns)
          end
          if node.children
            ret.name_class = parse_except_name_class(ctxt, node.children, defn.type == ATTRIBUTE)
          end
        elsif is_relaxng(node, "choice")
          last = nil
          if defn.type == CHOICE
            ret = defn
          else
            ret = new_define(ctxt, node)
            ret.parent = defn
            ret.type = CHOICE
          end
          if node.children.nil?
            p_err(ctxt, node, ErrCode::RNGP_CHOICE_EMPTY, "Element choice is empty\n")
          else
            child = node.children
            while child
              tmp = parse_name_class(ctxt, child, ret)
              if tmp
                if last.nil?
                  last = tmp
                elsif !tmp.equal?(ret)
                  last.next = tmp
                  last = tmp
                end
              end
              child = child.next
            end
          end
        else
          p_err(ctxt, node, ErrCode::RNGP_CHOICE_CONTENT, "expecting name, anyName, nsName or choice : got %s\n",
            node.nil? ? "nothing" : node.name)
          return nil
        end
        unless ret.equal?(defn)
          if defn.name_class.nil?
            defn.name_class = ret
          else
            tmp = defn.name_class
            tmp = tmp.next while tmp.next
            tmp.next = ret
          end
        end
        ret
      end

      ELEMENT_CONTENT_OK = [EMPTY, NOT_ALLOWED, TEXT, ELEMENT, DATATYPE, VALUE, LIST, REF, PARENTREF,
        EXTERNALREF, DEF, ZEROORMORE, ONEORMORE, OPTIONAL, CHOICE, GROUP, INTERLEAVE].freeze

      # xmlRelaxNGParseElement
      def parse_element(ctxt, node)
        ret = new_define(ctxt, node)
        ret.type = ELEMENT
        ret.parent = ctxt.def
        child = node.children
        if child.nil?
          p_err(ctxt, node, ErrCode::RNGP_ELEMENT_EMPTY, "xmlRelaxNGParseElement: element has no children\n")
          return ret
        end
        cur = parse_name_class(ctxt, child, ret)
        child = child.next if cur

        if child.nil?
          p_err(ctxt, node, ErrCode::RNGP_ELEMENT_NO_CONTENT, "xmlRelaxNGParseElement: element has no content\n")
          return ret
        end
        olddefine = ctxt.define
        ctxt.define = nil
        last = nil
        while child
          cur = parse_pattern(ctxt, child)
          if cur
            cur.parent = ret
            if ELEMENT_CONTENT_OK.include?(cur.type)
              if last.nil?
                ret.content = last = cur
              else
                if last.type == ELEMENT && ret.content.equal?(last)
                  ret.content = new_define(ctxt, node)
                  ret.content.type = GROUP
                  ret.content.content = last
                end
                last.next = cur
                last = cur
              end
            elsif cur.type == ATTRIBUTE
              cur.next = ret.attrs
              ret.attrs = cur
            elsif cur.type == START
              p_err(ctxt, node, ErrCode::RNGP_ELEMENT_CONTENT, "RNG Internal error, start found in element\n")
            elsif cur.type == PARAM
              p_err(ctxt, node, ErrCode::RNGP_ELEMENT_CONTENT, "RNG Internal error, param found in element\n")
            elsif cur.type == EXCEPT
              p_err(ctxt, node, ErrCode::RNGP_ELEMENT_CONTENT, "RNG Internal error, except found in element\n")
            elsif cur.type == NOOP
              p_err(ctxt, node, ErrCode::RNGP_ELEMENT_CONTENT, "RNG Internal error, noop found in element\n")
            end
          end
          child = child.next
        end
        ctxt.define = olddefine
        ret
      end

      # xmlRelaxNGParsePatterns
      def parse_patterns(ctxt, nodes, group)
        defn = last = nil
        parent = ctxt.def
        while nodes
          if is_relaxng(nodes, "element")
            cur = parse_element(ctxt, nodes)
            return nil if cur.nil?

            if defn.nil?
              defn = last = cur
            else
              if group == 1 && defn.type == ELEMENT && defn.equal?(last)
                defn = new_define(ctxt, nodes)
                defn.type = GROUP
                defn.content = last
              end
              last.next = cur
              last = cur
            end
            cur.parent = parent
          else
            cur = parse_pattern(ctxt, nodes)
            if cur
              if defn.nil?
                defn = last = cur
              else
                last.next = cur
                last = cur
              end
            end
          end
          nodes = nodes.next
        end
        defn
      end

      # xmlRelaxNGParseStart
      def parse_start(ctxt, nodes)
        ret = 0
        if nodes.nil?
          p_err(ctxt, nodes, ErrCode::RNGP_START_EMPTY, "start has no children\n")
          return -1
        end
        if is_relaxng(nodes, "empty")
          defn = new_define(ctxt, nodes)
          defn.type = EMPTY
          if nodes.children
            p_err(ctxt, nodes, ErrCode::RNGP_EMPTY_CONTENT, "element empty is not empty\n")
          end
        elsif is_relaxng(nodes, "notAllowed")
          defn = new_define(ctxt, nodes)
          defn.type = NOT_ALLOWED
          if nodes.children
            p_err(ctxt, nodes, ErrCode::RNGP_NOTALLOWED_NOT_EMPTY, "element notAllowed is not empty\n")
          end
        else
          defn = parse_patterns(ctxt, nodes, 1)
        end
        if ctxt.grammar.start
          last = ctxt.grammar.start
          last = last.next while last.next
          last.next = defn
        else
          ctxt.grammar.start = defn
        end
        nodes = nodes.next
        if nodes
          p_err(ctxt, nodes, ErrCode::RNGP_START_CONTENT, "start more than one children\n")
          return -1
        end
        ret
      end

      # xmlRelaxNGParseGrammarContent
      def parse_grammar_content(ctxt, nodes)
        ret = 0
        if nodes.nil?
          p_err(ctxt, nodes, ErrCode::RNGP_GRAMMAR_EMPTY, "grammar has no children\n")
          return -1
        end
        while nodes
          if is_relaxng(nodes, "start")
            if nodes.children.nil?
              p_err(ctxt, nodes, ErrCode::RNGP_START_EMPTY, "start has no children\n")
            else
              tmp = parse_start(ctxt, nodes.children)
              ret = -1 if tmp != 0
            end
          elsif is_relaxng(nodes, "define")
            tmp = parse_define(ctxt, nodes)
            ret = -1 if tmp != 0
          elsif is_relaxng(nodes, "include")
            tmp = parse_include(ctxt, nodes)
            ret = -1 if tmp != 0
          else
            p_err(ctxt, nodes, ErrCode::RNGP_GRAMMAR_CONTENT, "grammar has unexpected child %s\n", nodes.name)
            ret = -1
          end
          nodes = nodes.next
        end
        ret
      end

      # xmlRelaxNGCheckReference
      def check_reference(ctxt, ref, name)
        # Those rules don't apply to imported ref from xmlRelaxNGParseImportRef
        return if ref.dflags & IS_EXTERNAL_REF != 0

        grammar = ctxt.grammar
        if grammar.nil?
          p_err(ctxt, ref.node, ErrCode::ERR_INTERNAL_ERROR, "Internal error: no grammar in CheckReference %s\n", name)
          return
        end
        if ref.content
          p_err(ctxt, ref.node, ErrCode::ERR_INTERNAL_ERROR,
            "Internal error: reference has content in CheckReference %s\n", name)
          return
        end
        if grammar.defs
          defn = grammar.defs.lookup(name)
          if defn
            cur = ref
            while cur
              cur.content = defn
              cur = cur.next_hash
            end
          else
            p_err(ctxt, ref.node, ErrCode::RNGP_REF_NO_DEF, "Reference %s has no matching definition\n", name)
          end
        else
          p_err(ctxt, ref.node, ErrCode::RNGP_REF_NO_DEF, "Reference %s has no matching definition\n", name)
        end
      end

      # register a new interleave in ctxt.interleaves (xmlRelaxNGCheckCombine/CombineStart)
      def add_interleave(ctxt, node, cur)
        ctxt.interleaves ||= Hash2.new
        tmpname = "interleave#{ctxt.nb_interleaves}"
        ctxt.nb_interleaves += 1
        if ctxt.interleaves.add(tmpname, cur) < 0
          p_err(ctxt, node, ErrCode::RNGP_INTERLEAVE_CREATE_FAILED, "Failed to add %s to hash table\n", tmpname)
        end
      end

      # xmlRelaxNGCheckCombine
      def check_combine(ctxt, define, name)
        return if define.next_hash.nil?

        choice_or_interleave = -1
        missing = 0
        cur = define
        while cur
          combine = Tree.get_prop(cur.node, "combine")
          if combine
            if combine == "choice"
              if choice_or_interleave == -1
                choice_or_interleave = 1
              elsif choice_or_interleave == 0
                p_err(ctxt, define.node, ErrCode::RNGP_DEF_CHOICE_AND_INTERLEAVE,
                  "Defines for %s use both 'choice' and 'interleave'\n", name)
              end
            elsif combine == "interleave"
              if choice_or_interleave == -1
                choice_or_interleave = 0
              elsif choice_or_interleave == 1
                p_err(ctxt, define.node, ErrCode::RNGP_DEF_CHOICE_AND_INTERLEAVE,
                  "Defines for %s use both 'choice' and 'interleave'\n", name)
              end
            else
              p_err(ctxt, define.node, ErrCode::RNGP_UNKNOWN_COMBINE,
                "Defines for %s use unknown combine value '%s''\n", name, combine)
            end
          elsif missing == 0
            missing = 1
          else
            p_err(ctxt, define.node, ErrCode::RNGP_NEED_COMBINE,
              "Some defines for %s needs the combine attribute\n", name)
          end
          cur = cur.next_hash
        end
        choice_or_interleave = 0 if choice_or_interleave == -1
        cur = new_define(ctxt, define.node)
        cur.type = choice_or_interleave == 0 ? INTERLEAVE : CHOICE
        tmp = define
        last = nil
        while tmp
          if tmp.content
            if tmp.content.next
              # we need first to create a wrapper.
              tmp2 = new_define(ctxt, tmp.content.node)
              tmp2.type = GROUP
              tmp2.content = tmp.content
            else
              tmp2 = tmp.content
            end
            if last.nil?
              cur.content = tmp2
            else
              last.next = tmp2
            end
            last = tmp2
          end
          tmp.content = cur
          tmp = tmp.next_hash
        end
        define.content = cur
        add_interleave(ctxt, define.node, cur) if choice_or_interleave == 0
      end

      # xmlRelaxNGCombineStart
      def combine_start(ctxt, grammar)
        starts = grammar.start
        return if starts.nil? || starts.next.nil?

        choice_or_interleave = -1
        missing = 0
        cur = starts
        while cur
          if cur.node.nil? || cur.node.parent.nil? || cur.node.parent.name != "start"
            combine = nil
            p_err(ctxt, cur.node, ErrCode::RNGP_START_MISSING, "Internal error: start element not found\n")
          else
            combine = Tree.get_prop(cur.node.parent, "combine")
          end

          if combine
            if combine == "choice"
              if choice_or_interleave == -1
                choice_or_interleave = 1
              elsif choice_or_interleave == 0
                p_err(ctxt, cur.node, ErrCode::RNGP_START_CHOICE_AND_INTERLEAVE,
                  "<start> use both 'choice' and 'interleave'\n")
              end
            elsif combine == "interleave"
              if choice_or_interleave == -1
                choice_or_interleave = 0
              elsif choice_or_interleave == 1
                p_err(ctxt, cur.node, ErrCode::RNGP_START_CHOICE_AND_INTERLEAVE,
                  "<start> use both 'choice' and 'interleave'\n")
              end
            else
              p_err(ctxt, cur.node, ErrCode::RNGP_UNKNOWN_COMBINE,
                "<start> uses unknown combine value '%s''\n", combine)
            end
          elsif missing == 0
            missing = 1
          else
            p_err(ctxt, cur.node, ErrCode::RNGP_NEED_COMBINE, "Some <start> element miss the combine attribute\n")
          end
          cur = cur.next
        end
        choice_or_interleave = 0 if choice_or_interleave == -1
        cur = new_define(ctxt, starts.node)
        cur.type = choice_or_interleave == 0 ? INTERLEAVE : CHOICE
        cur.content = grammar.start
        grammar.start = cur
        add_interleave(ctxt, cur.node, cur) if choice_or_interleave == 0
      end

      # xmlRelaxNGParseGrammar
      def parse_grammar(ctxt, nodes)
        ret = Grammar.new
        # Link the new grammar in the tree
        ret.parent = ctxt.grammar
        if ctxt.grammar
          tmp = ctxt.grammar.children
          if tmp.nil?
            ctxt.grammar.children = ret
          else
            tmp = tmp.next while tmp.next
            tmp.next = ret
          end
        end

        old = ctxt.grammar
        ctxt.grammar = ret
        parse_grammar_content(ctxt, nodes)
        ctxt.grammar = ret
        if ctxt.grammar.start.nil?
          p_err(ctxt, nodes, ErrCode::RNGP_GRAMMAR_NO_START, "Element <grammar> has no <start>\n")
        end

        # Apply 4.17 merging rules to defines and starts
        combine_start(ctxt, ret)
        ret.defs&.scan { |defn, name| check_combine(ctxt, defn, name) }

        # link together defines and refs in this grammar
        ret.refs&.scan { |ref, name| check_reference(ctxt, ref, name) }

        ctxt.grammar = old
        ret
      end

      # xmlRelaxNGParseDocument
      def parse_document(ctxt, node)
        return nil if ctxt.nil? || node.nil?

        schema = Schema.new
        olddefine = ctxt.define
        ctxt.define = nil
        if is_relaxng(node, "grammar")
          schema.topgrammar = parse_grammar(ctxt, node.children)
          return nil if schema.topgrammar.nil?
        else
          schema.topgrammar = ret = Grammar.new
          # Link the new grammar in the tree
          ret.parent = ctxt.grammar
          if ctxt.grammar
            tmp = ctxt.grammar.children
            if tmp.nil?
              ctxt.grammar.children = ret
            else
              tmp = tmp.next while tmp.next
              tmp.next = ret
            end
          end
          old = ctxt.grammar
          ctxt.grammar = ret
          parse_start(ctxt, node)
          ctxt.grammar = old if old
        end
        ctxt.define = olddefine
        if schema.topgrammar.start
          check_cycles(ctxt, schema.topgrammar.start, 0)
          if ctxt.flags & IN_EXTERNALREF == 0
            simplify(ctxt, schema.topgrammar.start, nil)
            while schema.topgrammar.start && schema.topgrammar.start.type == NOOP &&
                schema.topgrammar.start.next
              schema.topgrammar.start = schema.topgrammar.start.content
            end
            check_rules(ctxt, schema.topgrammar.start, IN_START, NOOP)
          end
        end
        schema
      end

      # ---- contexts -----------------------------------------------------------------------

      # xmlRelaxNGNewParserCtxt
      def new_parser_ctxt(url)
        return nil if url.nil?

        ret = ParserCtxt.new
        ret.url = url.dup
        ret
      end

      # xmlRelaxNGNewMemParserCtxt
      def new_mem_parser_ctxt(buffer)
        return nil if buffer.nil? || buffer.empty?

        ret = ParserCtxt.new
        ret.buffer = buffer
        ret
      end

      # xmlRelaxNGNewDocParserCtxt
      def new_doc_parser_ctxt(doc)
        return nil if doc.nil?

        copy = Tree.copy_doc(doc, true)
        return nil if copy.nil?

        ret = ParserCtxt.new
        ret.document = copy
        ret.freedoc = 1
        ret
      end

      # xmlRelaxNGFreeParserCtxt
      def free_parser_ctxt(_ctxt) = nil

      # xmlRelaxNGParse
      def parse(ctxt)
        init_types
        return nil if ctxt.nil?

        # First step is to parse the input document into an DOM/Infoset
        if ctxt.url
          doc = relax_read_file(ctxt, ctxt.url)
          if doc.nil?
            p_err(ctxt, nil, ErrCode::RNGP_PARSE_ERROR, "xmlRelaxNGParse: could not load %s\n", ctxt.url)
            return nil
          end
        elsif ctxt.buffer
          doc = relax_read_memory(ctxt, ctxt.buffer)
          if doc.nil?
            p_err(ctxt, nil, ErrCode::RNGP_PARSE_ERROR, "xmlRelaxNGParse: could not parse schemas\n")
            return nil
          end
          doc.url = "in_memory_buffer"
          ctxt.url = "in_memory_buffer"
        elsif ctxt.document
          doc = ctxt.document
        else
          p_err(ctxt, nil, ErrCode::RNGP_EMPTY, "xmlRelaxNGParse: nothing to parse\n")
          return nil
        end
        ctxt.document = doc

        # Some preprocessing of the document content
        doc = cleanup_doc(ctxt, doc)
        if doc.nil?
          ctxt.document = nil
          return nil
        end

        # Then do the parsing for good
        root = Tree.doc_get_root_element(doc)
        if root.nil?
          p_err(ctxt, doc, ErrCode::RNGP_EMPTY, "xmlRelaxNGParse: %s is empty\n", ctxt.url || "schemas")
          ctxt.document = nil
          return nil
        end
        ret = parse_document(ctxt, root)
        if ret.nil?
          ctxt.document = nil
          return nil
        end

        # try to preprocess interleaves
        ctxt.interleaves&.scan { |defn, _name| compute_interleaves(ctxt, defn) }

        # if there was a parsing error return NULL
        if ctxt.nb_errors > 0
          ctxt.document = nil
          return nil
        end

        # try to compile (parts of) the schemas
        if ret.topgrammar && ret.topgrammar.start
          if ret.topgrammar.start.type != START
            defn = new_define(ctxt, nil)
            defn.type = START
            defn.content = ret.topgrammar.start
            ret.topgrammar.start = defn
          end
          try_compile(ctxt, ret.topgrammar.start)
        end

        # Transfer the pointer for cleanup at the schema level.
        ret.doc = doc
        ctxt.document = nil
        ret.documents = ctxt.documents
        ctxt.documents = nil
        ret.includes = ctxt.includes
        ctxt.includes = nil
        ret.def_nr = ctxt.def_nr
        ret.def_tab = ctxt.def_tab
        ctxt.def_tab = []
        ret.idref = 1 if ctxt.idref == 1
        ret
      end
    end
  end
end
