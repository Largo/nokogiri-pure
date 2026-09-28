# frozen_string_literal: true

require_relative "html_parser/tables"

module Nokogiri
  module Pure
    # Serialisation: a port of libxml2's xmlsave.c and HTMLtree.c
    module Save
      # xmlSaveOption
      SAVE_FORMAT = 1
      SAVE_NO_DECL = 2
      SAVE_NO_EMPTY = 4
      SAVE_NO_XHTML = 8
      SAVE_XHTML = 16
      SAVE_AS_XML = 32
      SAVE_AS_HTML = 64
      SAVE_WSNONSIG = 128

      MAX_INDENT = 60
      XHTML_NS_NAME = "http://www.w3.org/1999/xhtml"

      # xmlOutputBuffer: accumulates UTF-8 text; the attached encoder converts it on flush.
      class OutBuf
        attr_accessor :encoder, :error

        def initialize(encoder = nil)
          @encoder = encoder
          @segments = [] # [[encoder, string], ...]
          @cur = +""
          @init_pending = !encoder.nil?
          @error = 0
        end

        def write(str)
          @cur << str if str
        end

        alias_method :<<, :write

        def switch_encoding(handler)
          flush_segment
          @encoder = handler
          @init_pending = true
        end

        def clear_encoding
          flush_segment
          @encoder = nil
          @init_pending = false
        end

        def flush_segment
          return if @cur.empty? && !@init_pending

          @segments << [@encoder, @cur, @init_pending]
          @cur = +""
          @init_pending = false
        end

        # final bytes (binary)
        def result
          flush_segment
          out = +"".b
          @segments.each do |enc, s, init|
            if enc
              out << enc.encode_output(s, init: init)
            else
              out << s.b
            end
          end
          out
        end
      end

      class SaveCtxt
        attr_accessor :buf, :encoding, :handler, :escape, :escape_attr, :options, :format, :level,
          :indent, :indent_size, :indent_nr

        def initialize(encoding, options, indent_string)
          @encoding = nil
          @handler = nil
          @escape = nil
          @escape_attr = nil
          if encoding
            @handler = Enc.find_handler(encoding, output: true)
            raise UnknownEncoding, encoding if @handler.nil?

            @encoding = encoding
          end
          @escape = :entities if @encoding.nil?
          indent_string ||= "  "
          if indent_string.empty?
            @indent = ""
            @indent_size = 0
            @indent_nr = 0
          else
            @indent_size = indent_string.length
            @indent_nr = MAX_INDENT / @indent_size
            @indent = indent_string * @indent_nr
          end
          @options = options
          @format = if (options & SAVE_FORMAT) != 0
            1
          elsif (options & SAVE_WSNONSIG) != 0
            2
          else
            0
          end
          @level = 0
          @buf = OutBuf.new(@handler)
        end

        def write_indent(level)
          n = level > @indent_nr ? @indent_nr : level
          @buf.write(@indent[0, @indent_size * n]) if n > 0
        end
      end

      class UnknownEncoding < StandardError; end

      module_function

      # ---- escaping ------------------------------------------------------------

      ENTITIES_RE = /[<>&\r\x00-\x08\x0B\x0C\x0E-\x1F]|[^\x00-\x7F]/
      CONTENT_RE = /[<>&\r]/
      CONTENT_MAP = { "<" => "&lt;", ">" => "&gt;", "&" => "&amp;", "\r" => "&#13;" }.freeze

      def scrubbed(str)
        str = str.dup.force_encoding(Encoding::UTF_8) unless str.encoding == Encoding::UTF_8
        str.valid_encoding? ? str : str.scrub("�")
      end

      def hex_char_ref(cp)
        "&#x#{cp.to_s(16).upcase};"
      end

      # xmlEscapeEntities
      def escape_entities(str)
        str = scrubbed(str)
        return str unless str.match?(ENTITIES_RE)

        str.gsub(ENTITIES_RE) do |m|
          case m
          when "<" then "&lt;"
          when ">" then "&gt;"
          when "&" then "&amp;"
          when "\r" then "&#xD;"
          else
            cp = m.ord
            if cp < 0x80
              "&#xFFFD;"
            else
              hex_char_ref(Encoding_.xml_char?(cp) ? cp : 0xFFFD)
            end
          end
        end
      end

      # xmlEscapeContent
      def escape_content(str)
        str.gsub(CONTENT_RE, CONTENT_MAP)
      end

      def write_escape(buf, str, escape)
        buf.write(escape == :entities ? escape_entities(str) : escape_content(str))
      end

      # xmlOutputBufferWriteQuotedString
      def write_quoted(buf, string)
        string = string.to_s
        if string.include?('"')
          if string.include?("'")
            buf << '"' << string.gsub('"', "&quot;") << '"'
          else
            buf << "'" << string << "'"
          end
        else
          buf << '"' << string << '"'
        end
      end

      ATTR_TXT_RE = /[\n\r\t"<>&]/
      ATTR_TXT_MAP = {
        "\n" => "&#10;", "\r" => "&#13;", "\t" => "&#9;", "\"" => "&quot;",
        "<" => "&lt;", ">" => "&gt;", "&" => "&amp;",
      }.freeze
      ATTR_TXT_NONASCII_RE = /[\n\r\t"<>&]|[^\x00-\x7F]/

      # xmlBufAttrSerializeTxtContent
      def attr_serialize_txt_content(buf, doc, string)
        return if string.nil?

        if doc.nil? || doc.encoding.nil?
          s = scrubbed(string)
          buf << s.gsub(ATTR_TXT_NONASCII_RE) do |m|
            ATTR_TXT_MAP[m] || hex_char_ref(Encoding_.xml_char?(m.ord) ? m.ord : 0xFFFD)
          end
        else
          buf << string.gsub(ATTR_TXT_RE, ATTR_TXT_MAP)
        end
      end

      # xmlAttrSerializeContent
      def attr_serialize_content(buf, attr)
        child = attr.children
        while child
          case child.type
          when TEXT_NODE
            attr_serialize_txt_content(buf, attr.doc, child.content)
          when ENTITY_REF_NODE
            buf << "&" << child.name << ";"
          end
          child = child.next
        end
      end

      # ---- DTD pieces -------------------------------------------------------------

      def dump_notation_decl(buf, nota)
        buf << "<!NOTATION " << nota.name
        if nota.public_id
          buf << " PUBLIC "
          write_quoted(buf, nota.public_id)
          if nota.system_id
            buf << " "
            write_quoted(buf, nota.system_id)
          end
        else
          buf << " SYSTEM "
          write_quoted(buf, nota.system_id)
        end
        buf << " >\n"
      end

      def dump_element_occur(buf, cur)
        case cur.ocur
        when ELEMENT_CONTENT_OPT then buf << "?"
        when ELEMENT_CONTENT_MULT then buf << "*"
        when ELEMENT_CONTENT_PLUS then buf << "+"
        end
      end

      def dump_element_content(buf, content)
        return if content.nil?

        buf << "("
        cur = content
        loop do
          return if cur.nil?

          case cur.type
          when ELEMENT_CONTENT_PCDATA
            buf << "#PCDATA"
          when ELEMENT_CONTENT_ELEMENT
            buf << cur.prefix << ":" if cur.prefix
            buf << cur.name
          when ELEMENT_CONTENT_SEQ, ELEMENT_CONTENT_OR
            if !cur.equal?(content) && cur.parent &&
                (cur.type != cur.parent.type || cur.ocur != ELEMENT_CONTENT_ONCE)
              buf << "("
            end
            cur = cur.c1
            next
          end
          until cur.equal?(content)
            parent = cur.parent
            return if parent.nil?

            if (cur.type == ELEMENT_CONTENT_OR || cur.type == ELEMENT_CONTENT_SEQ) &&
                (cur.type != parent.type || cur.ocur != ELEMENT_CONTENT_ONCE)
              buf << ")"
            end
            dump_element_occur(buf, cur)
            if cur.equal?(parent.c1)
              if parent.type == ELEMENT_CONTENT_SEQ
                buf << " , "
              elsif parent.type == ELEMENT_CONTENT_OR
                buf << " | "
              end
              cur = parent.c2
              break
            end
            cur = parent
          end
          break if cur.equal?(content)
        end
        buf << ")"
        dump_element_occur(buf, content)
      end

      def dump_element_decl(buf, elem)
        buf << "<!ELEMENT "
        buf << elem.prefix << ":" if elem.prefix
        buf << elem.name << " "
        case elem.etype
        when ELEMENT_TYPE_EMPTY then buf << "EMPTY"
        when ELEMENT_TYPE_ANY then buf << "ANY"
        when ELEMENT_TYPE_MIXED, ELEMENT_TYPE_ELEMENT then dump_element_content(buf, elem.econtent)
        end
        buf << ">\n"
      end

      def dump_enumeration(buf, cur)
        while cur
          buf << cur.name
          buf << " | " if cur.next
          cur = cur.next
        end
        buf << ")"
      end

      ATYPE_NAMES = {
        ATTRIBUTE_CDATA => " CDATA", ATTRIBUTE_ID => " ID", ATTRIBUTE_IDREF => " IDREF",
        ATTRIBUTE_IDREFS => " IDREFS", ATTRIBUTE_ENTITY => " ENTITY", ATTRIBUTE_ENTITIES => " ENTITIES",
        ATTRIBUTE_NMTOKEN => " NMTOKEN", ATTRIBUTE_NMTOKENS => " NMTOKENS",
      }.freeze

      def dump_attribute_decl(buf, attr)
        buf << "<!ATTLIST " << attr.elem.to_s << " "
        buf << attr.prefix << ":" if attr.prefix
        buf << attr.name
        case attr.atype
        when ATTRIBUTE_ENUMERATION
          buf << " ("
          dump_enumeration(buf, attr.tree)
        when ATTRIBUTE_NOTATION
          buf << " NOTATION ("
          dump_enumeration(buf, attr.tree)
        else
          buf << ATYPE_NAMES[attr.atype].to_s
        end
        case attr.def
        when ATTRIBUTE_REQUIRED then buf << " #REQUIRED"
        when ATTRIBUTE_IMPLIED then buf << " #IMPLIED"
        when ATTRIBUTE_FIXED then buf << " #FIXED"
        end
        if attr.default_value
          buf << " \""
          attr_serialize_txt_content(buf, attr.doc, attr.default_value)
          buf << "\""
        end
        buf << ">\n"
      end

      def dump_entity_content(buf, content)
        if content.include?("%")
          buf << '"' << content.gsub(/["%]/, '"' => "&quot;", "%" => "&#x25;") << '"'
        else
          write_quoted(buf, content)
        end
      end

      def dump_entity_decl(buf, ent)
        if ent.etype == INTERNAL_PARAMETER_ENTITY || ent.etype == EXTERNAL_PARAMETER_ENTITY
          buf << "<!ENTITY % "
        else
          buf << "<!ENTITY "
        end
        buf << ent.name << " "
        if [EXTERNAL_GENERAL_PARSED_ENTITY, EXTERNAL_GENERAL_UNPARSED_ENTITY, EXTERNAL_PARAMETER_ENTITY].include?(ent.etype)
          if ent.external_id
            buf << "PUBLIC "
            write_quoted(buf, ent.external_id)
            buf << " "
          else
            buf << "SYSTEM "
          end
          write_quoted(buf, ent.system_id)
        end
        if ent.etype == EXTERNAL_GENERAL_UNPARSED_ENTITY && ent.content
          buf << " NDATA "
          buf << (ent.orig || ent.content)
        end
        if ent.etype == INTERNAL_GENERAL_ENTITY || ent.etype == INTERNAL_PARAMETER_ENTITY
          if ent.orig
            write_quoted(buf, ent.orig)
          else
            dump_entity_content(buf, ent.content.to_s)
          end
        end
        buf << ">\n"
      end

      # ---- XML node output ----------------------------------------------------------

      def write_ws_non_sig(ctxt, extra)
        buf = ctxt.buf
        buf << "\n"
        i = 0
        total = ctxt.level + extra
        while i < total
          n = (total - i) > ctxt.indent_nr ? ctxt.indent_nr : (total - i)
          buf << ctxt.indent[0, ctxt.indent_size * n]
          i += ctxt.indent_nr
          break if ctxt.indent_nr <= 0
        end
      end

      def ns_dump_output(buf, doc, cur, ctxt)
        return if cur.nil?
        return unless cur.href
        return if cur.prefix == "xml"

        if ctxt && ctxt.format == 2
          write_ws_non_sig(ctxt, 2)
        else
          buf << " "
        end
        if cur.prefix
          buf << "xmlns:" << cur.prefix
        else
          buf << "xmlns"
        end
        buf << "=\""
        attr_serialize_txt_content(buf, doc, cur.href)
        buf << "\""
      end

      def ns_list_dump_output_ctxt(ctxt, doc, cur)
        while cur
          ns_dump_output(ctxt.buf, doc, cur, ctxt)
          cur = cur.next
        end
      end

      def ns_list_dump_output(buf, cur)
        while cur
          ns_dump_output(buf, nil, cur, nil)
          cur = cur.next
        end
      end

      def dtd_dump_output(ctxt, dtd)
        return if dtd.nil?

        buf = ctxt.buf
        buf << "<!DOCTYPE " << dtd.name.to_s
        if dtd.external_id
          buf << " PUBLIC "
          write_quoted(buf, dtd.external_id)
          buf << " "
          write_quoted(buf, dtd.system_id)
        elsif dtd.system_id
          buf << " SYSTEM "
          write_quoted(buf, dtd.system_id)
        end
        if dtd.entities.nil? && dtd.elements.nil? && dtd.attributes.nil? && dtd.notations.nil? && dtd.pentities.nil?
          buf << ">"
          return
        end
        buf << " [\n"
        if dtd.notations && (dtd.doc.nil? || dtd.doc.int_subset.equal?(dtd))
          dtd.notations.each_value { |n| dump_notation_decl(buf, n) }
        end
        format = ctxt.format
        level = ctxt.level
        ctxt.format = 0
        ctxt.level = -1
        cur = dtd.children
        while cur
          node_dump_output_internal(ctxt, cur)
          cur = cur.next
        end
        ctxt.format = format
        ctxt.level = level
        buf << "]>"
      end

      BOOLEAN_ATTRS = %w[checked compact declare defer disabled ismap multiple nohref noresize noshade
        nowrap readonly selected].freeze

      def html_is_boolean_attr(name)
        BOOLEAN_ATTRS.any? { |b| b.casecmp?(name) }
      end

      def attr_dump_output(ctxt, cur)
        return if cur.nil?

        buf = ctxt.buf
        if ctxt.format == 2
          write_ws_non_sig(ctxt, 2)
        else
          buf << " "
        end
        buf << cur.ns.prefix << ":" if cur.ns&.prefix
        buf << cur.name << "=\""
        if (ctxt.options & SAVE_XHTML) != 0 && cur.ns.nil? &&
            (cur.children.nil? || cur.children.content.nil? || cur.children.content.empty?) &&
            html_is_boolean_attr(cur.name)
          buf << cur.name
        else
          attr_serialize_content(buf, cur)
        end
        buf << "\""
      end

      def write_cdata(buf, content)
        if content.nil? || content.empty?
          buf << "<![CDATA[]]>"
        else
          start = 0
          while (idx = content.index("]]>", start))
            buf << "<![CDATA[" << content[start...idx + 2] << "]]>"
            start = idx + 2
          end
          buf << "<![CDATA[" << content[start..] << "]]>" if start < content.length
        end
      end

      def qname_write(buf, node)
        buf << node.ns.prefix << ":" if node.ns&.prefix
        buf << node.name
      end

      # xmlNodeDumpOutputInternal
      def node_dump_output_internal(ctxt, cur)
        return if cur.nil?

        format = ctxt.format
        buf = ctxt.buf
        root = cur
        parent = cur.parent
        unformatted_node = nil
        loop do
          case cur.type
          when DOCUMENT_NODE, HTML_DOCUMENT_NODE
            doc_content_dump_output(ctxt, cur)
          when DTD_NODE
            dtd_dump_output(ctxt, cur)
          when DOCUMENT_FRAG_NODE
            if cur.parent.equal?(parent) && cur.children
              parent = cur
              cur = cur.children
              next
            end
          when ELEMENT_DECL
            dump_element_decl(buf, cur)
          when ATTRIBUTE_DECL
            dump_attribute_decl(buf, cur)
          when ENTITY_DECL
            dump_entity_decl(buf, cur)
          when ELEMENT_NODE
            ctxt.write_indent(ctxt.level) if !cur.equal?(root) && ctxt.format == 1
            if !cur.parent.equal?(parent) && cur.children
              node_dump_output_internal(ctxt, cur)
            else
              buf << "<"
              qname_write(buf, cur)
              ns_list_dump_output_ctxt(ctxt, cur.doc, cur.ns_def) if cur.ns_def
              attr = cur.properties
              while attr
                attr_dump_output(ctxt, attr)
                attr = attr.next
              end
              if cur.children.nil?
                if (ctxt.options & SAVE_NO_EMPTY) == 0
                  write_ws_non_sig(ctxt, 0) if ctxt.format == 2
                  buf << "/>"
                else
                  write_ws_non_sig(ctxt, 1) if ctxt.format == 2
                  buf << "></"
                  qname_write(buf, cur)
                  write_ws_non_sig(ctxt, 0) if ctxt.format == 2
                  buf << ">"
                end
              else
                if ctxt.format == 1
                  tmp = cur.children
                  while tmp
                    if tmp.type == TEXT_NODE || tmp.type == CDATA_SECTION_NODE || tmp.type == ENTITY_REF_NODE
                      ctxt.format = 0
                      unformatted_node = cur
                      break
                    end
                    tmp = tmp.next
                  end
                end
                write_ws_non_sig(ctxt, 1) if ctxt.format == 2
                buf << ">"
                buf << "\n" if ctxt.format == 1
                ctxt.level += 1 if ctxt.level >= 0
                parent = cur
                cur = cur.children
                next
              end
            end
          when TEXT_NODE
            if cur.content
              if cur.name != STRING_TEXT_NOENC
                write_escape(buf, cur.content, ctxt.escape)
              else
                buf << cur.content
              end
            end
          when PI_NODE
            ctxt.write_indent(ctxt.level) if !cur.equal?(root) && ctxt.format == 1
            if cur.content
              buf << "<?" << cur.name
              if ctxt.format == 2
                write_ws_non_sig(ctxt, 0)
              else
                buf << " "
              end
              buf << cur.content << "?>"
            else
              buf << "<?" << cur.name
              write_ws_non_sig(ctxt, 0) if ctxt.format == 2
              buf << "?>"
            end
          when COMMENT_NODE
            ctxt.write_indent(ctxt.level) if !cur.equal?(root) && ctxt.format == 1
            buf << "<!--" << cur.content << "-->" if cur.content
          when ENTITY_REF_NODE
            buf << "&" << cur.name << ";"
          when CDATA_SECTION_NODE
            write_cdata(buf, cur.content)
          when ATTRIBUTE_NODE
            attr_dump_output(ctxt, cur)
          when NAMESPACE_DECL
            ns_dump_output(buf, nil, cur, ctxt)
          end

          loop do
            return if cur.equal?(root)

            buf << "\n" if ctxt.format == 1 && cur.type != XINCLUDE_START && cur.type != XINCLUDE_END
            if cur.next
              cur = cur.next
              break
            end
            cur = parent
            parent = cur.parent
            next unless cur.type == ELEMENT_NODE

            ctxt.level -= 1 if ctxt.level > 0
            ctxt.write_indent(ctxt.level) if ctxt.format == 1
            buf << "</"
            qname_write(buf, cur)
            write_ws_non_sig(ctxt, 0) if ctxt.format == 2
            buf << ">"
            if cur.equal?(unformatted_node)
              ctxt.format = format
              unformatted_node = nil
            end
          end
        end
      end

      XHTML_IDS = {
        public: ["-//W3C//DTD XHTML 1.0 Strict//EN", "-//W3C//DTD XHTML 1.0 Frameset//EN",
                 "-//W3C//DTD XHTML 1.0 Transitional//EN"],
        system: ["http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd", "http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd",
                 "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd"],
      }.freeze

      def is_xhtml(system_id, public_id)
        return -1 if system_id.nil? && public_id.nil?
        return 1 if public_id && XHTML_IDS[:public].include?(public_id)
        return 1 if system_id && XHTML_IDS[:system].include?(system_id)

        0
      end

      def parse_char_encoding_kind(encoding)
        return :none if encoding.nil?

        case encoding.upcase
        when "UTF-8", "UTF8" then :utf8
        when "ASCII", "US-ASCII" then :ascii
        else :other
        end
      end

      # xmlDocContentDumpOutput
      def doc_content_dump_output(ctxt, cur)
        oldenc = cur.encoding
        oldctxtenc = ctxt.encoding
        encoding = ctxt.encoding
        oldescape = ctxt.escape
        oldescape_attr = ctxt.escape_attr
        buf = ctxt.buf
        switched_encoding = false

        return -1 if cur.type != HTML_DOCUMENT_NODE && cur.type != DOCUMENT_NODE

        if ctxt.encoding
          cur.encoding = ctxt.encoding
        elsif cur.encoding
          encoding = cur.encoding
        end

        if (cur.type == HTML_DOCUMENT_NODE && (ctxt.options & SAVE_AS_XML) == 0 && (ctxt.options & SAVE_XHTML) == 0) ||
            (ctxt.options & SAVE_AS_HTML) != 0
          html_set_meta_encoding(cur, encoding) if encoding
          encoding ||= html_get_meta_encoding(cur)
          encoding ||= "HTML"
          if encoding && oldctxtenc.nil? && buf.encoder.nil?
            h = Enc.find_handler(encoding, output: true)
            if h.nil?
              cur.encoding = oldenc
              return -1
            end
            buf.switch_encoding(h)
          end
          html_doc_content_dump_format_output(buf, cur, encoding, (ctxt.options & SAVE_FORMAT) != 0 ? 1 : 0)
          cur.encoding = oldenc if ctxt.encoding
          return 0
        end

        enc = parse_char_encoding_kind(encoding)
        if encoding && oldctxtenc.nil? && buf.encoder.nil? && (ctxt.options & SAVE_NO_DECL) == 0
          if enc != :utf8 && enc != :none && enc != :ascii
            h = Enc.find_handler(encoding, output: true)
            if h.nil?
              cur.encoding = oldenc
              return -1
            end
            buf.switch_encoding(h)
            switched_encoding = true
          end
          ctxt.escape = nil if ctxt.escape == :entities
          ctxt.escape_attr = nil if ctxt.escape_attr == :entities
        end
        if (ctxt.options & SAVE_NO_DECL) == 0
          buf << "<?xml version="
          if cur.version
            write_quoted(buf, cur.version)
          else
            buf << "\"1.0\""
          end
          if encoding
            buf << " encoding="
            write_quoted(buf, encoding)
          end
          case cur.standalone
          when 0 then buf << " standalone=\"no\""
          when 1 then buf << " standalone=\"yes\""
          end
          buf << "?>\n"
        end

        is_x = (ctxt.options & SAVE_XHTML) != 0
        if (ctxt.options & SAVE_NO_XHTML) == 0
          dtd = Tree.get_int_subset(cur)
          if dtd
            r = is_xhtml(dtd.system_id, dtd.external_id)
            is_x = r > 0
          end
        end
        child = cur.children
        while child
          ctxt.level = 0
          if is_x
            xhtml_node_dump_output(ctxt, child)
          else
            node_dump_output_internal(ctxt, child)
          end
          buf << "\n" if child.type != XINCLUDE_START && child.type != XINCLUDE_END
          child = child.next
        end

        if switched_encoding && oldctxtenc.nil?
          buf.clear_encoding
          ctxt.escape = oldescape
          ctxt.escape_attr = oldescape_attr
        end
        cur.encoding = oldenc
        0
      end

      XHTML_EMPTY = %w[area br base basefont col frame hr img input isindex link meta param].freeze

      def xhtml_is_empty(node)
        return -1 if node.nil?
        return 0 if node.type != ELEMENT_NODE
        return 0 if node.ns && node.ns.href != XHTML_NS_NAME
        return 0 if node.children

        XHTML_EMPTY.include?(node.name) ? 1 : 0
      end

      def xhtml_attr_list_dump_output(ctxt, cur)
        return if cur.nil?

        xml_lang = lang = name = id = nil
        buf = ctxt.buf
        parent = cur.parent
        while cur
          if cur.ns.nil? && cur.name == "id"
            id = cur
          elsif cur.ns.nil? && cur.name == "name"
            name = cur
          elsif cur.ns.nil? && cur.name == "lang"
            lang = cur
          elsif cur.ns && cur.name == "lang" && cur.ns.prefix == "xml"
            xml_lang = cur
          end
          attr_dump_output(ctxt, cur)
          cur = cur.next
        end
        if name && id.nil? && parent&.name && %w[a p div img map applet form frame iframe].include?(parent.name)
          buf << " id=\""
          attr_serialize_content(buf, name)
          buf << "\""
        end
        if lang && xml_lang.nil?
          buf << " xml:lang=\""
          attr_serialize_content(buf, lang)
          buf << "\""
        elsif xml_lang && lang.nil?
          buf << " lang=\""
          attr_serialize_content(buf, xml_lang)
          buf << "\""
        end
      end

      def write_meta(ctxt)
        buf = ctxt.buf
        buf << "<meta http-equiv=\"Content-Type\" content=\"text/html; charset="
        buf << (ctxt.encoding || "UTF-8")
        buf << "\" />"
      end

      # xhtmlNodeDumpOutput
      def xhtml_node_dump_output(ctxt, cur)
        return if cur.nil?

        format = ctxt.format
        buf = ctxt.buf
        oldoptions = ctxt.options
        ctxt.options |= SAVE_XHTML
        root = cur
        parent = cur.parent
        unformatted_node = nil
        loop do
          case cur.type
          when DOCUMENT_NODE, HTML_DOCUMENT_NODE
            doc_content_dump_output(ctxt, cur)
          when NAMESPACE_DECL
            ns_dump_output(buf, nil, cur, ctxt)
          when DTD_NODE
            dtd_dump_output(ctxt, cur)
          when DOCUMENT_FRAG_NODE
            if cur.parent.equal?(parent) && cur.children
              parent = cur
              cur = cur.children
              next
            end
          when ELEMENT_DECL
            dump_element_decl(buf, cur)
          when ATTRIBUTE_DECL
            dump_attribute_decl(buf, cur)
          when ENTITY_DECL
            dump_entity_decl(buf, cur)
          when ELEMENT_NODE
            addmeta = false
            ctxt.write_indent(ctxt.level) if !cur.equal?(root) && ctxt.format == 1
            if !cur.parent.equal?(parent) && cur.children
              xhtml_node_dump_output(ctxt, cur)
            else
              buf << "<"
              qname_write(buf, cur)
              ns_list_dump_output_ctxt(ctxt, cur.doc, cur.ns_def) if cur.ns_def
              if cur.name == "html" && cur.ns.nil? && cur.ns_def.nil?
                buf << " xmlns=\"http://www.w3.org/1999/xhtml\""
              end
              xhtml_attr_list_dump_output(ctxt, cur.properties) if cur.properties
              if parent && parent.parent.equal?(cur.doc) && cur.name == "head" && parent.name == "html"
                tmp = cur.children
                while tmp
                  if tmp.name == "meta"
                    httpequiv = Tree.get_prop(tmp, "http-equiv")
                    break if httpequiv && httpequiv.casecmp?("Content-Type")
                  end
                  tmp = tmp.next
                end
                addmeta = true if tmp.nil?
              end
              if cur.children.nil?
                if (cur.ns.nil? || cur.ns.prefix.nil?) && xhtml_is_empty(cur) == 1 && !addmeta
                  buf << " />"
                else
                  if addmeta
                    buf << ">"
                    if ctxt.format == 1
                      buf << "\n"
                      ctxt.write_indent(ctxt.level + 1)
                    end
                    write_meta(ctxt)
                    buf << "\n" if ctxt.format == 1
                  else
                    buf << ">"
                  end
                  buf << "</"
                  qname_write(buf, cur)
                  buf << ">"
                end
              else
                buf << ">"
                if addmeta
                  if ctxt.format == 1
                    buf << "\n"
                    ctxt.write_indent(ctxt.level + 1)
                  end
                  write_meta(ctxt)
                end
                if ctxt.format == 1
                  tmp = cur.children
                  while tmp
                    if tmp.type == TEXT_NODE || tmp.type == ENTITY_REF_NODE
                      unformatted_node = cur
                      ctxt.format = 0
                      break
                    end
                    tmp = tmp.next
                  end
                end
                buf << "\n" if ctxt.format == 1
                ctxt.level += 1 if ctxt.level >= 0
                parent = cur
                cur = cur.children
                next
              end
            end
          when TEXT_NODE
            if cur.content
              if cur.name != STRING_TEXT_NOENC
                write_escape(buf, cur.content, ctxt.escape)
              else
                buf << cur.content
              end
            end
          when PI_NODE
            if cur.content
              buf << "<?" << cur.name << " " << cur.content << "?>"
            else
              buf << "<?" << cur.name << "?>"
            end
          when COMMENT_NODE
            buf << "<!--" << cur.content << "-->" if cur.content
          when ENTITY_REF_NODE
            buf << "&" << cur.name << ";"
          when CDATA_SECTION_NODE
            write_cdata(buf, cur.content)
          when ATTRIBUTE_NODE
            attr_dump_output(ctxt, cur)
          end

          done = false
          loop do
            if cur.equal?(root)
              done = true
              break
            end
            buf << "\n" if ctxt.format == 1
            if cur.next
              cur = cur.next
              break
            end
            cur = parent
            parent = cur.parent
            next unless cur.type == ELEMENT_NODE

            ctxt.level -= 1 if ctxt.level > 0
            ctxt.write_indent(ctxt.level) if ctxt.format == 1
            buf << "</"
            qname_write(buf, cur)
            buf << ">"
            if cur.equal?(unformatted_node)
              ctxt.format = format
              unformatted_node = nil
            end
          end
          break if done
        end
        ctxt.options = oldoptions
      end

      # xmlSaveTree
      def save_tree(ctxt, cur)
        return -1 if cur.nil?

        if (ctxt.options & SAVE_XHTML) != 0
          xhtml_node_dump_output(ctxt, cur)
          return 0
        end
        if (!cur.is_a?(XmlNs) && cur.doc && cur.doc.type == HTML_DOCUMENT_NODE && (ctxt.options & SAVE_AS_XML) == 0) ||
            (ctxt.options & SAVE_AS_HTML) != 0
          html_node_dump_output_internal(ctxt, cur)
          return 0
        end
        node_dump_output_internal(ctxt, cur)
        0
      end

      # the glue's native_write_to: xmlSaveToIO + xmlSaveTree + xmlSaveClose
      def native_write_to(node, io, encoding, indent_string, options)
        begin
          ctxt = SaveCtxt.new(encoding, options, indent_string)
        rescue UnknownEncoding
          Errors.report(XmlError.new(domain: Domain::OUTPUT, code: 1403, level: Level::ERROR,
            message: "unknown encoding #{encoding}\n", str1: encoding))
          return io
        end
        save_tree(ctxt, node)
        bytes = ctxt.buf.result
        write_to_io(io, bytes)
        io
      end

      # noko_io_write, called the way libxml2's output buffer flushes: ~4000-byte chunks
      # (MINLEN), the remainder, then a final empty write when the buffer is closed.
      IO_CHUNK = 4000

      def write_to_io(io, bytes)
        enc = io.respond_to?(:external_encoding) ? io.external_encoding : nil
        enc ||= Encoding::BINARY
        off = 0
        while off < bytes.bytesize
          io.write(bytes.byteslice(off, IO_CHUNK).force_encoding(enc))
          off += IO_CHUNK
        end
        io.write(String.new(encoding: enc))
      end

      # xmlNodeDumpOutput-style helper returning a UTF-8 string (used internally, e.g. inner_xml)
      def node_to_s(node, format: false, options: 0, indent: "  ", encoding: nil)
        opts = options | (format ? SAVE_FORMAT : 0)
        ctxt = SaveCtxt.new(encoding, opts, indent)
        ctxt.escape = :content if encoding.nil?
        node_dump_output_internal(ctxt, node)
        ctxt.buf.result.force_encoding(Encoding::UTF_8)
      end

      # ---- HTML output (HTMLtree.c) ------------------------------------------------------

      def html_get_meta_encoding(doc)
        return nil if doc.nil?

        cur = doc.children
        found = nil
        while cur
          if cur.type == ELEMENT_NODE && cur.name
            break if cur.name == "html"
            if cur.name == "head"
              found = :head
              break
            end
            if cur.name == "meta"
              found = :meta
              break
            end
          end
          cur = cur.next
        end
        if found.nil?
          return nil if cur.nil?

          cur = cur.children
          while cur
            if cur.type == ELEMENT_NODE && cur.name
              if cur.name == "head"
                found = :head
                break
              end
              if cur.name == "meta"
                found = :meta
                break
              end
            end
            cur = cur.next
          end
          return nil if cur.nil?

          found ||= :head
        end
        cur = cur.children if found == :head
        content = nil
        while cur
          if cur.type == ELEMENT_NODE && cur.name == "meta"
            attr = cur.properties
            http = false
            content = nil
            while attr
              if attr.children && attr.children.type == TEXT_NODE && attr.children.next.nil?
                value = attr.children.content
                if attr.name.casecmp?("http-equiv") && value&.casecmp?("Content-Type")
                  http = true
                elsif value && attr.name.casecmp?("content")
                  content = value
                end
                if http && content
                  return charset_from_content(content)
                end
              end
              attr = attr.next
            end
          end
          cur = cur.next
        end
        nil
      end

      def charset_from_content(content)
        idx = content.index("charset=") || content.index("Charset=") || content.index("CHARSET=")
        if idx
          enc = content[idx + 8..]
        else
          idx = content.index("charset =") || content.index("Charset =") || content.index("CHARSET =")
          enc = idx ? content[idx + 9..] : nil
        end
        enc&.sub(/\A[ \t]+/, "")
      end

      def html_set_meta_encoding(doc, encoding)
        return -1 if doc.nil?
        return -1 if encoding&.casecmp?("html")

        newcontent = encoding ? "text/html; charset=#{encoding}" : nil
        meta = nil
        head = nil
        content = nil
        cur = doc.children
        state = nil
        while cur
          if cur.type == ELEMENT_NODE && cur.name
            break if cur.name.casecmp?("html")
            if cur.name.casecmp?("head")
              state = :found_head
              break
            end
            if cur.name.casecmp?("meta")
              state = :found_meta
              break
            end
          end
          cur = cur.next
        end
        if state.nil?
          return -1 if cur.nil?

          cur = cur.children
          while cur
            if cur.type == ELEMENT_NODE && cur.name
              break if cur.name.casecmp?("head")
              if cur.name.casecmp?("meta")
                head = cur.parent
                state = :found_meta
                break
              end
            end
            cur = cur.next
          end
          return -1 if cur.nil?

          state ||= :found_head
        end
        if state == :found_head
          head = cur
          if cur.children.nil?
            state = :create
          else
            cur = cur.children
            state = :found_meta
          end
        end
        if state == :found_meta
          while cur
            if cur.type == ELEMENT_NODE && cur.name&.casecmp?("meta")
              attr = cur.properties
              http = false
              content = nil
              while attr
                if attr.children && attr.children.type == TEXT_NODE && attr.children.next.nil?
                  value = attr.children.content
                  if attr.name.casecmp?("http-equiv") && value&.casecmp?("Content-Type")
                    http = true
                  elsif value && attr.name.casecmp?("content")
                    content = value
                  end
                  break if http && content
                end
                attr = attr.next
              end
              if http && content
                meta = cur
                break
              end
            end
            cur = cur.next
          end
        end
        if meta.nil?
          if encoding && head
            meta = Tree.new_doc_node(doc, nil, "meta", nil)
            if head.children.nil?
              Tree.add_child(head, meta)
            else
              Tree.add_prev_sibling(head.children, meta)
            end
            Tree.new_prop(meta, "http-equiv", "Content-Type")
            Tree.new_prop(meta, "content", newcontent)
          end
        elsif encoding.nil?
          Tree.unlink_node(meta)
        elsif !content.downcase.include?(encoding.downcase)
          Tree.set_prop(meta, "content", newcontent)
        end
        0
      end

      def html_dtd_dump_output(buf, doc)
        cur = doc.int_subset
        if cur.nil?
          Errors.report(XmlError.new(domain: Domain::OUTPUT, code: 1404, level: Level::ERROR,
            message: "HTML has no DOCTYPE\n", node: doc))
          return
        end
        buf << "<!DOCTYPE " << cur.name.to_s
        if cur.external_id
          buf << " PUBLIC "
          write_quoted(buf, cur.external_id)
          if cur.system_id
            buf << " "
            write_quoted(buf, cur.system_id)
          end
        elsif cur.system_id && cur.system_id != "about:legacy-compat"
          buf << " SYSTEM "
          write_quoted(buf, cur.system_id)
        end
        buf << ">\n"
      end

      URI_ESCAPE_KEEP = "\"#$%&+,/:;<=>?@[\\]^`{|}"

      # xmlURIEscapeStr
      def uri_escape_str(str, list)
        return str if str.empty?

        out = +""
        str.b.each_byte do |ch|
          c = ch.chr
          if ch != 0x40 && !(c.match?(/[A-Za-z0-9\-_.!~*'()]/)) && !list.include?(c)
            out << format("%%%02X", ch)
          else
            out << c
          end
        end
        out.force_encoding(Encoding::UTF_8)
      end

      def html_attr_dump_output(buf, doc, cur)
        return if cur.nil?

        buf << " "
        buf << cur.ns.prefix << ":" if cur.ns&.prefix
        buf << cur.name
        if cur.children && !html_is_boolean_attr(cur.name)
          value = Tree.node_list_get_string(doc, cur.children, false)
          if value
            buf << "="
            if cur.ns.nil? && cur.parent && cur.parent.ns.nil? &&
                (cur.name.casecmp?("href") || cur.name.casecmp?("action") || cur.name.casecmp?("src") ||
                 (cur.name.casecmp?("name") && cur.parent.name.casecmp?("a")))
              tmp = value.sub(/\A[ \t\n\r]+/, "")
              write_quoted(buf, uri_escape_str(tmp, URI_ESCAPE_KEEP))
            else
              write_quoted(buf, value)
            end
          end
        end
      end

      def html_info(name)
        HTMLParser.tag_lookup(name)
      end

      def inline?(info)
        info.isinline != 0
      end

      # htmlNodeDumpFormatOutput
      def html_node_dump_format_output(buf, doc, cur, encoding, format)
        return if cur.nil?

        root = cur
        parent = cur.parent
        loop do
          case cur.type
          when HTML_DOCUMENT_NODE, DOCUMENT_NODE
            html_dtd_dump_output(buf, cur) if cur.int_subset
            if cur.children
              if cur.parent.equal?(parent)
                parent = cur
                cur = cur.children
                next
              end
            else
              buf << "\n"
            end
          when ELEMENT_NODE
            if !cur.parent.equal?(parent) && cur.children
              html_node_dump_format_output(buf, doc, cur, encoding, format)
            else
              info = cur.ns.nil? ? html_info(cur.name) : nil
              buf << "<"
              qname_write(buf, cur)
              ns_list_dump_output(buf, cur.ns_def) if cur.ns_def
              attr = cur.properties
              while attr
                html_attr_dump_output(buf, doc, attr)
                attr = attr.next
              end
              if info && info.empty != 0
                buf << ">"
              elsif cur.children.nil?
                if info && info.save_end_tag != 0 && info.name != "html" && info.name != "body"
                  buf << ">"
                else
                  buf << "></"
                  qname_write(buf, cur)
                  buf << ">"
                end
              else
                buf << ">"
                if format != 0 && info && !inline?(info) && cur.children.type != TEXT_NODE &&
                    cur.children.type != ENTITY_REF_NODE && !cur.children.equal?(cur.last) &&
                    cur.name && !cur.name.start_with?("p")
                  buf << "\n"
                end
                parent = cur
                cur = cur.children
                next
              end
              if format != 0 && cur.next && info && !inline?(info)
                if cur.next.type != TEXT_NODE && cur.next.type != ENTITY_REF_NODE &&
                    parent && parent.name && !parent.name.start_with?("p")
                  buf << "\n"
                end
              end
            end
          when ATTRIBUTE_NODE
            html_attr_dump_output(buf, doc, cur)
          when TEXT_NODE
            if cur.content
              if cur.name != STRING_TEXT_NOENC &&
                  (parent.nil? || (!parent.name.to_s.casecmp?("script") && !parent.name.to_s.casecmp?("style")))
                buf << Tree.encode_entities_reentrant(doc, cur.content)
              else
                buf << cur.content
              end
            end
          when COMMENT_NODE
            buf << "<!--" << cur.content << "-->" if cur.content
          when PI_NODE
            if cur.name
              buf << "<?" << cur.name
              buf << " " << cur.content if cur.content
              buf << ">"
            end
          when ENTITY_REF_NODE
            buf << "&" << cur.name << ";"
          when CDATA_SECTION_NODE
            buf << cur.content if cur.content
          end

          loop do
            return if cur.equal?(root)

            if cur.next
              cur = cur.next
              break
            end
            cur = parent
            parent = cur.parent
            if cur.type == HTML_DOCUMENT_NODE || cur.type == DOCUMENT_NODE
              buf << "\n"
            else
              info = format != 0 && cur.ns.nil? ? html_info(cur.name) : nil
              if format != 0 && info && !inline?(info) && cur.last.type != TEXT_NODE &&
                  cur.last.type != ENTITY_REF_NODE && !cur.children.equal?(cur.last) &&
                  cur.name && !cur.name.start_with?("p")
                buf << "\n"
              end
              buf << "</"
              qname_write(buf, cur)
              buf << ">"
              if format != 0 && info && !inline?(info) && cur.next
                if cur.next.type != TEXT_NODE && cur.next.type != ENTITY_REF_NODE &&
                    parent && parent.name && !parent.name.start_with?("p")
                  buf << "\n"
                end
              end
            end
          end
        end
      end

      def html_doc_content_dump_format_output(buf, cur, encoding, format)
        type = cur.type
        cur.type = HTML_DOCUMENT_NODE
        begin
          html_node_dump_format_output(buf, cur, cur, nil, format)
        ensure
          cur.type = type
        end
      end

      # htmlNodeDumpOutputInternal
      def html_node_dump_output_internal(ctxt, cur)
        oldctxtenc = ctxt.encoding
        encoding = ctxt.encoding
        buf = ctxt.buf
        switched_encoding = false
        doc = cur.doc
        oldenc = nil
        if doc
          oldenc = doc.encoding
          if ctxt.encoding
            doc.encoding = ctxt.encoding
          elsif doc.encoding
            encoding = doc.encoding
          end
        end
        html_set_meta_encoding(doc, encoding) if encoding && doc
        encoding = html_get_meta_encoding(doc) if encoding.nil? && doc
        encoding ||= "HTML"
        if encoding && oldctxtenc.nil? && buf.encoder.nil?
          h = Enc.find_handler(encoding, output: true)
          if h.nil?
            doc.encoding = oldenc if doc
            return -1
          end
          buf.switch_encoding(h)
          switched_encoding = true
        end
        html_node_dump_format_output(buf, doc, cur, encoding, (ctxt.options & SAVE_FORMAT) != 0 ? 1 : 0)
        buf.clear_encoding if switched_encoding && oldctxtenc.nil?
        doc.encoding = oldenc if doc
        0
      end

      # htmlNodeDump (used by the glue's dump_html)
      def html_node_dump(doc, cur)
        buf = OutBuf.new(nil)
        html_node_dump_format_output(buf, doc, cur, nil, 1)
        buf.result.force_encoding(Encoding::UTF_8)
      end

      # ---- Nokogiri's own HTML5 serialiser (xml_node.c output_node & co.) --------------

      HTML5_VOID = %w[area base basefont bgsound br col embed frame hr img input keygen link meta param source track wbr].freeze
      HTML5_UNESCAPED = %w[style script xmp iframe noembed noframes plaintext noscript].freeze

      def should_prepend_newline(node)
        name = node.name
        child = node.children
        return false if name.nil? || child.nil? || !%w[pre textarea listing].include?(name)

        child.type == TEXT_NODE && child.content && child.content.start_with?("\n")
      end

      def h5_is_one_of(node, names)
        return false if node.name.nil?
        return false if node.ns

        names.include?(node.name)
      end

      def h5_output_tagname(out, elem)
        name = elem.name
        ns = elem.ns
        if ns && ns.href && ns.prefix && ns.href != "http://www.w3.org/1999/xhtml" &&
            ns.href != "http://www.w3.org/1998/Math/MathML" && ns.href != "http://www.w3.org/2000/svg"
          out << ns.prefix << ":"
          colon = name.index(":")
          name = name[colon + 1..] if colon
        end
        out << name
      end

      def h5_output_attr_name(out, attr)
        ns = attr.ns
        name = attr.name
        if ns && ns.href
          uri = ns.href
          colon = name.index(":")
          localname = colon ? name[colon + 1..] : name
          if uri == "http://www.w3.org/XML/1998/namespace"
            out << "xml:"
            name = localname
          elsif uri == "http://www.w3.org/2000/xmlns/"
            out << "xmlns:" if localname != "xmlns"
            name = localname
          elsif uri == "http://www.w3.org/1999/xlink"
            out << "xlink:"
            name = localname
          elsif ns.prefix
            out << ns.prefix << ":"
            name = localname
          end
        end
        out << name
      end

      H5_TEXT_RE = /[&<>]| /
      H5_TEXT_MAP = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", " " => "&nbsp;" }.freeze
      H5_ATTR_RE = /[&"]| /
      H5_ATTR_MAP = { "&" => "&amp;", "\"" => "&quot;", " " => "&nbsp;" }.freeze

      def h5_escaped(out, str, attr)
        return if str.nil?

        s = scrubbed(str)
        out << (attr ? s.gsub(H5_ATTR_RE, H5_ATTR_MAP) : s.gsub(H5_TEXT_RE, H5_TEXT_MAP))
      end

      def h5_output_node(out, node, preserve_newline)
        case node.type
        when ELEMENT_NODE
          out << "<"
          h5_output_tagname(out, node)
          attr = node.properties
          while attr
            out << " "
            h5_output_node(out, attr, preserve_newline)
            attr = attr.next
          end
          out << ">"
          unless h5_is_one_of(node, HTML5_VOID)
            out << "\n" if preserve_newline && should_prepend_newline(node)
            child = node.children
            while child
              h5_output_node(out, child, preserve_newline)
              child = child.next
            end
            out << "</"
            h5_output_tagname(out, node)
            out << ">"
          end
        when ATTRIBUTE_NODE
          h5_output_attr_name(out, node)
          if node.children
            out << "=\""
            value = Tree.node_list_get_string(node.doc, node.children, true)
            h5_escaped(out, value, true)
            out << "\""
          else
            out << "=\"\""
          end
        when TEXT_NODE
          if node.parent && node.parent.type == ELEMENT_NODE && h5_is_one_of(node.parent, HTML5_UNESCAPED)
            out << node.content.to_s
          else
            h5_escaped(out, node.content, false)
          end
        when CDATA_SECTION_NODE
          out << "<![CDATA[" << node.content.to_s << "]]>"
        when COMMENT_NODE
          out << "<!--" << node.content.to_s << "-->"
        when PI_NODE
          out << "<?" << node.content.to_s << ">"
        when DOCUMENT_TYPE_NODE, DTD_NODE
          out << "<!DOCTYPE " << node.name.to_s << ">"
        when DOCUMENT_NODE, DOCUMENT_FRAG_NODE, HTML_DOCUMENT_NODE
          child = node.children
          while child
            h5_output_node(out, child, preserve_newline)
            child = child.next
          end
        else
          raise RuntimeError, "Unsupported document node (#{node.type}); this is a bug in Nokogiri"
        end
      end

      def html_standard_serialize(node, preserve_newline)
        out = String.new(capacity: 4096, encoding: Encoding::UTF_8)
        h5_output_node(out, node, preserve_newline)
        out
      end
    end
  end
end
