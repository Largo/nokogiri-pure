# frozen_string_literal: true

# Port of libxslt keys.c, documents.c and imports.c.

module Nokogiri
  module Pure
    module XSLT
      module_function

      # ---- keys.c -------------------------------------------------------------------------------

      def skip_string(cur, pos)
        c = cur.getbyte(pos)
        return pos unless c == 0x27 || c == 0x22

        limit = c
        pos += 1
        while (c = cur.getbyte(pos))
          return pos + 1 if c == limit

          pos += 1
        end
        -1
      end

      def skip_predicate(cur, pos)
        return pos if cur.getbyte(pos) != 0x5B

        level = 0
        pos += 1
        while (c = cur.getbyte(pos))
          if c == 0x27 || c == 0x22
            pos = skip_string(cur, pos)
            return -1 if pos <= 0

            next
          elsif c == 0x5B
            level += 1
          elsif c == 0x5D
            return pos + 1 if level == 0

            level -= 1
          end
          pos += 1
        end
        -1
      end

      # xsltAddKey
      def add_key(style, name, name_uri, match, use, inst)
        return -1 if style.nil? || name.nil? || match.nil? || use.nil?

        key = KeyDef.new
        key.name = name
        key.name_uri = name_uri
        key.match = match
        key.use = use
        key.inst = inst
        key.ns_list = Tree.get_ns_list(inst.doc, inst)

        m = match.b
        len = m.bytesize
        pattern = nil
        current = 0
        while current < len
          start = current
          current += 1 while current < len && BLANK_BYTES.include?(m.getbyte(current))
          endp = current
          while endp < len && m.getbyte(endp) != 0x7C
            if m.getbyte(endp) == 0x5B
              endp = skip_predicate(m, endp)
              if endp <= 0
                transform_error(nil, style, inst, "xsl:key : 'match' pattern is malformed: #{key.match}")
                style.errors += 1
                return 0
              end
            else
              endp += 1
            end
          end
          if current == endp
            transform_error(nil, style, inst, "xsl:key : 'match' pattern is empty\n")
            style.errors += 1
            return 0
          end
          pattern ||= +"".b
          pattern << "//" if m.getbyte(start) != 0x2F
          pattern << m.byteslice(start, endp - start)
          if m.getbyte(endp) == 0x7C
            pattern << "|"
            endp += 1
          end
          current = endp
        end
        if pattern.nil?
          transform_error(nil, style, inst, "xsl:key : 'match' pattern is empty\n")
          style.errors += 1
          return 0
        end
        pattern.force_encoding(Encoding::UTF_8)
        key.comp = xpath_compile_flags(style, pattern, XPath::XML_XPATH_NOVAR)
        if key.comp.nil?
          transform_error(nil, style, inst, "xsl:key : 'match' pattern compilation failed '#{pattern}'\n")
          style.errors += 1
        end
        key.usecomp = xpath_compile_flags(style, use, XPath::XML_XPATH_NOVAR)
        if key.usecomp.nil?
          transform_error(nil, style, inst, "xsl:key : 'use' expression compilation failed '#{use}'\n")
          style.errors += 1
        end
        if style.keys.nil?
          style.keys = key
        else
          prev = style.keys
          prev = prev.next while prev.next
          prev.next = key
        end
        key.next = nil
        0
      end

      # xsltGetKey
      def get_key(ctxt, name, name_uri, value)
        return nil if ctxt.nil? || name.nil? || value.nil? || ctxt.document.nil?

        if ctxt.document.nb_keys_computed < ctxt.nb_keys && ctxt.key_init_level == 0
          return nil if init_all_doc_keys(ctxt) != 0
        end
        init_table = false
        loop do
          table = ctxt.document.keys
          while table
            if (!name_uri.nil?) == (!table.name_uri.nil?) && table.name == name && table.name_uri == name_uri
              return table.keys[value]
            end

            table = table.next
          end
          if ctxt.key_init_level != 0 && !init_table
            init_doc_key_table(ctxt, name, name_uri)
            init_table = true
            next
          end
          return nil
        end
      end

      # xsltInitDocKeyTable
      def init_doc_key_table(ctxt, name, name_uri)
        found = false
        keyd = nil
        style = ctxt.style
        while style
          keyd = style.keys
          while keyd
            if (!keyd.name_uri.nil?) == (!name_uri.nil?) && keyd.name == name && keyd.name_uri == name_uri
              init_ctxt_key(ctxt, ctxt.document, keyd)
              return 0 if ctxt.document.nb_keys_computed == ctxt.nb_keys

              found = true
            end
            keyd = keyd.next
          end
          style = next_import(style)
        end
        unless found
          transform_error(ctxt, nil, keyd&.inst, "Failed to find key definition for #{name}\n")
          ctxt.state = STATE_STOPPED
          return -1
        end
        0
      end

      # xsltInitAllDocKeys
      def init_all_doc_keys(ctxt)
        return -1 if ctxt.nil?
        return 0 if ctxt.document.nb_keys_computed == ctxt.nb_keys

        style = ctxt.style
        while style
          keyd = style.keys
          while keyd
            table = ctxt.document.keys
            while table
              if (!keyd.name_uri.nil?) == (!table.name_uri.nil?) && keyd.name == table.name &&
                  keyd.name_uri == table.name_uri
                break
              end

              table = table.next
            end
            init_doc_key_table(ctxt, keyd.name, keyd.name_uri) if table.nil?
            keyd = keyd.next
          end
          style = next_import(style)
        end
        0
      end

      # xsltInitCtxtKey
      def init_ctxt_key(ctxt, idoc, key_def)
        return -1 if key_def.comp.nil? || key_def.usecomp.nil?

        if ctxt.key_init_level > ctxt.nb_keys
          transform_error(ctxt, nil, key_def.inst, "Key definition for #{key_def.name} is recursive\n")
          ctxt.state = STATE_STOPPED
          return -1
        end
        ctxt.key_init_level += 1
        xp = ctxt.xpath_ctxt
        idoc.nb_keys_computed += 1
        old_inst = ctxt.inst
        old_doc_info = ctxt.document
        old_context_node = ctxt.node
        old_xp_node = xp.node
        old_xp_doc = xp.doc
        old_xp_pos = xp.proximity_position
        old_xp_size = xp.context_size
        old_xp_ns = xp.namespaces

        ctxt.document = idoc
        ctxt.node = idoc.doc
        ctxt.inst = key_def.inst
        xp.doc = idoc.doc
        xp.node = idoc.doc
        xp.namespaces = key_def.ns_list

        begin
          match_res = XPath.compiled_eval(key_def.comp, xp)
          if match_res.nil?
            transform_error(ctxt, nil, key_def.inst, "Failed to evaluate the 'match' expression.\n")
            ctxt.state = STATE_STOPPED
            break
          end
          unless match_res.is_a?(Array) && !match_res.is_a?(XPath::ValueTree)
            transform_error(ctxt, nil, key_def.inst, "The 'match' expression did not evaluate to a node set.\n")
            ctxt.state = STATE_STOPPED
            break
          end
          match_list = match_res
          break if match_list.empty?

          table = idoc.keys
          while table
            if table.name == key_def.name &&
                ((key_def.name_uri.nil? && table.name_uri.nil?) ||
                 (key_def.name_uri && table.name_uri && table.name_uri == key_def.name_uri))
              break
            end

            table = table.next
          end
          if table.nil?
            table = KeyTable.new(key_def.name, key_def.name_uri)
            table.next = idoc.keys
            idoc.keys = table
          end

          xp.context_size = 1
          xp.proximity_position = 1
          match_list.each do |cur|
            next unless real_node?(cur)

            ctxt.node = cur
            xp.node = cur
            use_res = XPath.compiled_eval(key_def.usecomp, xp)
            if use_res.nil?
              transform_error(ctxt, nil, key_def.inst, "Failed to evaluate the 'use' expression.\n")
              ctxt.state = STATE_STOPPED
              break
            end
            strs = if use_res.is_a?(Array) && !use_res.is_a?(XPath::ValueTree)
              next if use_res.empty?

              use_res.map { |n| XPath.cast_node_to_string(n) }
            else
              [use_res.is_a?(String) ? use_res : XPath.cast_to_string(use_res)]
            end
            strs.each do |str|
              next if str.nil?

              keylist = table.keys[str]
              if keylist.nil?
                table.keys[str] = [cur]
                (table.members[str] = {}.compare_by_identity)[cur] = true
              else
                members = table.members[str]
                unless members.key?(cur)
                  members[cur] = true
                  keylist << cur
                end
              end
              set_source_node_flags(ctxt, cur, SOURCE_NODE_HAS_KEY)
            end
          end
        end while false # rubocop:disable Lint/Loop
        ctxt.key_init_level -= 1
        xp.node = old_xp_node
        xp.doc = old_xp_doc
        xp.namespaces = old_xp_ns
        xp.proximity_position = old_xp_pos
        xp.context_size = old_xp_size
        ctxt.node = old_context_node
        ctxt.document = old_doc_info
        ctxt.inst = old_inst
        0
      end

      # xsltInitCtxtKeys
      def init_ctxt_keys(ctxt, idoc)
        return if ctxt.nil? || idoc.nil?

        style = ctxt.style
        while style
          key_def = style.keys
          while key_def
            init_ctxt_key(ctxt, idoc, key_def)
            key_def = key_def.next
          end
          style = next_import(style)
        end
      end

      # ---- documents.c --------------------------------------------------------------------------

      # xsltDocDefaultLoader: parse the document at +uri+ (nil on failure)
      def doc_default_loader(uri, options, _ctxt, _type)
        loader = @doc_loader
        return loader.call(uri, options) if loader

        Pure.respond_to?(:xslt_load_document) ? Pure.xslt_load_document(uri, options) : nil
      end

      # xsltSetLoaderFunc
      def set_loader_func(f)
        @doc_loader = f
      end

      # xsltNewDocument
      def new_document(ctxt, doc)
        cur = Document.new(doc)
        if ctxt && !res_tree_frag?(doc)
          cur.next = ctxt.doc_list
          ctxt.doc_list = cur
        end
        cur
      end

      # xsltNewStyleDocument
      def new_style_document(style, doc)
        cur = Document.new(doc)
        if style
          cur.next = style.doc_list
          style.doc_list = cur
        end
        cur
      end

      # xsltLoadDocument
      def load_document(ctxt, uri)
        return nil if ctxt.nil? || uri.nil?

        if ctxt.sec
          res = check_read(ctxt.sec, ctxt, uri)
          if res <= 0
            transform_error(ctxt, nil, nil, "xsltLoadDocument: read rights for #{uri} denied\n") if res == 0
            return nil
          end
        end
        ret = ctxt.doc_list
        while ret
          return ret if ret.doc && ret.doc.url && ret.doc.url == uri

          ret = ret.next
        end
        doc = doc_default_loader(uri, ctxt.parser_options, ctxt, :document)
        return nil if doc.nil?

        apply_strip_spaces(ctxt, Tree.doc_get_root_element(doc)) if need_elem_space_handling(ctxt)
        XPath.order_doc_elems(doc)
        new_document(ctxt, doc)
      end

      # xsltLoadStyleDocument
      def load_style_document(style, uri)
        return nil if style.nil? || uri.nil?

        sec = default_security_prefs
        if sec
          res = check_read(sec, nil, uri)
          if res <= 0
            transform_error(nil, nil, nil, "xsltLoadStyleDocument: read rights for #{uri} denied\n") if res == 0
            return nil
          end
        end
        ret = style.doc_list
        while ret
          return ret if ret.doc && ret.doc.url && ret.doc.url == uri

          ret = ret.next
        end
        doc = doc_default_loader(uri, PARSE_OPTIONS, style, :stylesheet)
        return nil if doc.nil?

        new_style_document(style, doc)
      end

      # xsltFindDocument
      def find_document(ctxt, doc)
        return nil if ctxt.nil? || doc.nil?

        ret = ctxt.doc_list
        while ret
          return ret if ret.doc.equal?(doc)

          ret = ret.next
        end
        return ctxt.document if doc.equal?(ctxt.style.doc)

        nil
      end

      # ---- imports.c ------------------------------------------------------------------------------

      MAX_NESTING = 40

      # xsltCheckCycle
      def check_cycle(style, cur, uri)
        depth = 0
        ancestor = style
        while ancestor
          depth += 1
          if depth >= MAX_NESTING
            transform_error(nil, style, cur, "maximum nesting depth exceeded: #{uri}\n")
            return -1
          end
          if ancestor.doc&.url == uri
            transform_error(nil, style, cur, "recursion detected on imported URL #{uri}\n")
            return -1
          end
          docptr = ancestor.includes
          while docptr
            depth += 1
            if depth >= MAX_NESTING
              transform_error(nil, style, cur, "maximum nesting depth exceeded: #{uri}\n")
              return -1
            end
            if docptr.doc.url == uri
              transform_error(nil, style, cur, "recursion detected on included URL #{uri}\n")
              return -1
            end
            docptr = docptr.includes
          end
          ancestor = ancestor.parent
        end
        0
      end

      # xsltParseStylesheetImport
      def parse_stylesheet_import(style, cur)
        return -1 if cur.nil? || style.nil?

        uri_ref = get_prop(cur, "href")
        if uri_ref.nil?
          transform_error(nil, style, cur, "xsl:import : missing href attribute\n")
          return -1
        end
        base = Tree.node_get_base(style.doc, cur)
        uri = Util.build_uri(uri_ref, base)
        if uri.nil?
          transform_error(nil, style, cur, "xsl:import : invalid URI reference #{uri_ref}\n")
          return -1
        end
        return -1 if check_cycle(style, cur, uri) < 0

        sec = default_security_prefs
        if sec
          secres = check_read(sec, nil, uri)
          if secres <= 0
            transform_error(nil, nil, nil, "xsl:import: read rights for #{uri} denied\n") if secres == 0
            return -1
          end
        end
        import = doc_default_loader(uri, PARSE_OPTIONS, style, :stylesheet)
        if import.nil?
          transform_error(nil, style, cur, "xsl:import : unable to load #{uri}\n")
          return -1
        end
        res = parse_stylesheet_imported_doc(import, style)
        return -1 if res.nil?

        res.next = style.imports
        style.imports = res
        0
      end

      # xsltParseStylesheetInclude
      def parse_stylesheet_include(style, cur)
        return -1 if cur.nil? || style.nil?

        uri_ref = get_prop(cur, "href")
        if uri_ref.nil?
          transform_error(nil, style, cur, "xsl:include : missing href attribute\n")
          return -1
        end
        base = Tree.node_get_base(style.doc, cur)
        uri = Util.build_uri(uri_ref, base)
        if uri.nil?
          transform_error(nil, style, cur, "xsl:include : invalid URI reference #{uri_ref}\n")
          return -1
        end
        return -1 if check_cycle(style, cur, uri) < 0

        include = load_style_document(style, uri)
        if include.nil?
          transform_error(nil, style, cur, "xsl:include : unable to load #{uri}\n")
          return -1
        end
        old_doc = style.doc
        style.doc = include.doc
        include.includes = style.includes
        style.includes = include
        old_nopreproc = style.nopreproc
        style.nopreproc = include.preproc
        result = parse_stylesheet_process(style, include.doc)
        style.nopreproc = old_nopreproc
        include.preproc = true
        style.includes = include.includes
        style.doc = old_doc
        result.nil? ? -1 : 0
      end

      # xsltNeedElemSpaceHandling
      def need_elem_space_handling(ctxt)
        return false if ctxt.nil?

        style = ctxt.style
        while style
          return true if style.strip_spaces

          style = next_import(style)
        end
        false
      end

      # xsltFindElemSpaceHandling
      def find_elem_space_handling(ctxt, node)
        return false if ctxt.nil? || node.nil?

        style = ctxt.style
        while style
          ss = style.strip_spaces
          val = nil
          if ss
            if node.ns
              val = ss[[node.name, node.ns.href]] || ss[["*", node.ns.href]]
            else
              val = ss[[node.name, nil]]
            end
          end
          if val
            return true if val == "strip"
            return false if val == "preserve"
          end
          return true if style.strip_all == 1
          return false if style.strip_all == -1

          style = next_import(style)
        end
        false
      end

      # xsltFindTemplate
      def find_template(ctxt, name, name_uri)
        return nil if ctxt.nil? || name.nil?

        style = ctxt.style
        while style
          if style.named_templates && (cur = style.named_templates[[name, name_uri]])
            return cur
          end

          style = next_import(style)
        end
        nil
      end
    end
  end
end
