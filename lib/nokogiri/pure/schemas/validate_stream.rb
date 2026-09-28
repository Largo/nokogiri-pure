# frozen_string_literal: true

require_relative "validate"

# xmlSchemaValidateFile / xmlSchemaValidateStreamInternal: streaming (SAX) validation of a file.
# The instance is parsed and the SAX events are fed to the xmlSchemaSAXHandle* handlers; nodes are
# never exposed (errors carry file + line only), exactly like libxml2's streaming mode.
module Nokogiri
  module Pure
    module Schemas
      # stand-in for xmlParserCtxt as seen by the error functions (input->filename/line/col)
      StreamInput = Struct.new(:filename, :line, :col)
      class StreamParserCtxt
        attr_accessor :input, :stopped

        def initialize(filename)
          @input = StreamInput.new(filename, 1, 1)
          @stopped = false
        end

        def stop_parser
          @stopped = true
        end
      end

      # the view of the xmlParserCtxt the schema error functions use (input->filename/line/col)
      class SAXStreamCtxt
        def initialize(ctxt)
          @ctxt = ctxt
        end

        def input
          inp = @ctxt.input
          return nil if inp.nil?

          StreamInput.new(inp.filename, @ctxt.current_line, @ctxt.current_col)
        end

        def line = @ctxt.current_line

        def stop_parser
          @ctxt.stop
        end
      end

      # xmlSchemaSAXPlug with a NULL user SAX handler: only the schema handlers are installed
      def schema_sax_handler(vctxt, pctxt)
        h = Parser::SAXHandler.new
        h.initialized = Parser::SAX2::XML_SAX2_MAGIC
        h.start_element_ns = lambda do |_ud, localname, prefix, uri, nb_ns, namespaces, nb_atts, _nb_def, atts|
          nss = []
          nb_ns.times do |i|
            pr, u = namespaces[i]
            nss << pr << (u || "")
          end
          attrs = []
          nb_atts.times do |i|
            a = atts[i]
            v = a.value.to_s
            v = v.gsub("&#38;", "&") if v.include?("&#38;")
            attrs << [a.name, a.prefix, a.ns, v]
          end
          sax_handle_start_element_ns(vctxt, localname, prefix, uri, nss, attrs, pctxt.current_line)
        end
        h.end_element_ns = ->(_ud, localname, prefix, uri) { sax_handle_end_element_ns(vctxt, localname, prefix, uri) }
        text = ->(_ud, ch) { sax_handle_text(vctxt, ch, -1) }
        h.characters = text
        h.ignorable_whitespace = text
        h.cdata_block = ->(_ud, ch) { sax_handle_c_data_section(vctxt, ch, -1) }
        h.reference = ->(_ud, name) { sax_handle_reference(vctxt, name) }
        h
      end

      # xmlSchemaValidateFile(ctxt, filename, options)
      def validate_file(vctxt, filename, _options)
        return -1 if vctxt.nil? || filename.nil?
        return validate_file_tree(vctxt, filename) if parse_memory_override

        ret = nil
        # parser errors go to the global handler, which Nokogiri does not collect here
        Errors.with_handler(nil) do
          # xmlCreateURLParserCtxt(filename, 0)
          pctxt = Parser::Ctxt.new
          pctxt.linenumbers = 1
          input = Parser::Loader.load_external_entity(filename, nil, pctxt)
          return -1 if input.nil?

          pctxt.input_push(input)
          pctxt.sax = schema_sax_handler(vctxt, pctxt)
          pctxt.user_data = vctxt
          sctxt = SAXStreamCtxt.new(pctxt)
          vctxt.loc_func = -> { [pctxt.input&.filename, pctxt.current_line] }
          vctxt.parser_ctxt = sctxt
          vctxt.sax = pctxt.sax
          vctxt.flags |= XML_SCHEMA_VALID_CTXT_FLAG_STREAM
          ret = v_start(vctxt) do
            pctxt.parse_document
            pctxt.well_formed != 0 ? 0 : -1
          end
          if ret == 0 && pctxt.well_formed == 0
            ret = pctxt.err_no
            ret = 1 if ret == 0
          end
          vctxt.parser_ctxt = nil
          vctxt.sax = nil
          vctxt.loc_func = nil
        end
        ret
      end

      # fallback used by the REXML test shim: walk a parsed tree emitting SAX-like events
      def validate_file_tree(vctxt, filename)
        content = begin
          File.binread(filename)
        rescue SystemCallError
          return -1
        end
        pctxt = StreamParserCtxt.new(filename)
        doc = nil
        parse_errors = []
        Errors.with_handler(->(e) { parse_errors << e }) do
          doc = Schemas.parse_memory(content, filename, 0)
        end
        well_formed = !doc.nil? && parse_errors.none? { |e| e.level == Level::FATAL || (e.domain == Domain::PARSER && e.level >= Level::ERROR) }

        vctxt.parser_ctxt = pctxt
        vctxt.sax = true
        vctxt.flags |= XML_SCHEMA_VALID_CTXT_FLAG_STREAM
        vctxt.loc_func = -> { [pctxt.input.filename, pctxt.input.line] }
        ret = v_start(vctxt) do
          stream_walk(vctxt, pctxt, doc) if doc
          0
        end
        if ret == 0 && !well_formed
          ret = parse_errors.find { |e| e.level >= Level::ERROR }&.code || 1
          ret = 1 if ret == 0
        end
        vctxt.parser_ctxt = nil
        vctxt.sax = nil
        vctxt.loc_func = nil
        ret
      end

      # feed SAX2 events for the parsed document to the schema SAX handlers
      def stream_walk(vctxt, pctxt, doc)
        root = Tree.doc_get_root_element(doc)
        return if root.nil?

        walk = lambda do |node|
          return if pctxt.stopped

          case node.type
          when ELEMENT_NODE
            pctxt.input.line = node.line
            nss = []
            ns = node.ns_def
            while ns
              nss << ns.prefix << ns.href
              ns = ns.next
            end
            attrs = []
            a = node.properties
            while a
              attrs << [a.name, a.ns&.prefix, a.ns&.href, Tree.node_list_get_string(a.doc, a.children, 1)]
              a = a.next
            end
            sax_handle_start_element_ns(vctxt, node.name, node.ns&.prefix, node.ns&.href, nss, attrs, node.line)
            c = node.children
            while c
              walk.call(c)
              c = c.next
            end
            return if pctxt.stopped

            sax_handle_end_element_ns(vctxt, node.name, node.ns&.prefix, node.ns&.href)
          when TEXT_NODE
            sax_handle_text(vctxt, node.content.to_s, -1)
          when CDATA_SECTION_NODE
            sax_handle_c_data_section(vctxt, node.content.to_s, -1)
          when ENTITY_REF_NODE
            sax_handle_reference(vctxt, node.name)
          end
        end
        walk.call(root)
      end
    end
  end
end
