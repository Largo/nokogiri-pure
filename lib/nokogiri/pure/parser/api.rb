# frozen_string_literal: true

module Nokogiri
  module Pure
    module Parser
      class Ctxt
        def current_line
          @line
        end

        def current_col
          @col
        end

        def current_pos
          @cur
        end

        # run the block with an empty input stack (external subset parsing, xmlSAX2ExternalSubset)
        def with_fresh_input_stack
          save_registers
          saved_tab = @input_tab
          saved_input = @input
          saved_encoding = @encoding
          @encoding = nil
          @input_tab = []
          @input = nil
          load_registers
          begin
            yield
          ensure
            @input_tab = saved_tab
            @input = saved_input
            @encoding = saved_encoding
            load_registers
          end
        end

        # run the block with ctxt->input = NULL (xmlValidateDocumentFinal: "Don't print line numbers")
        def without_input
          save_registers
          saved = @input
          @input = nil
          begin
            yield
          ensure
            @input = saved
            load_registers
          end
        end

        # xmlCtxtParseDocument: returns the document or nil
        def parse_document_with(input)
          @input_tab.clear
          @input = nil
          input_push(input)
          parse_document
          if @well_formed != 0 || (@recovery != 0 && @err_no != ErrCode::ERR_NO_MEMORY)
            ret = @my_doc
          else
            fatal_err_msg(ErrCode::ERR_INTERNAL_ERROR, "unknown error\n") if @err_no == 0
            ret = nil
          end
          @my_doc = nil
          ret
        end
      end

      module_function

      # read everything from a Ruby IO like noko_io_read; returns [bytes, error?]
      def read_all_io(io, sizes = nil)
        out = +"".b
        loop do
          chunk = begin
            io.read(4000)
          rescue StandardError
            return [out, true]
          end
          break if chunk.nil?
          return [out, true] unless chunk.is_a?(String)
          break if chunk.empty?

          chunk = chunk.byteslice(0, 4000) if chunk.bytesize > 4000 # noko_io_read copies at most len bytes
          out << chunk.b
          sizes << chunk.bytesize if sizes
        end
        [out, false]
      end

      # xmlReadMemory
      def read_memory(string, url, encoding, options)
        ctxt = Ctxt.new
        ctxt.use_options(options)
        input = ctxt.new_input_from_bytes(string.b, url, encoding)
        ctxt.parse_document_with(input)
      end

      # xmlReadIO
      def read_io(io, url, encoding, options)
        ctxt = Ctxt.new
        ctxt.use_options(options)
        sizes = []
        bytes, err = read_all_io(io, sizes)
        input = ctxt.new_input_from_bytes(bytes, url, encoding, raw_chunks: sizes)
        input.pending_error ||= ErrCode::IO_UNKNOWN if err
        ctxt.parse_document_with(input)
      end

      # xmlReadFile
      def read_file(filename, encoding, options)
        ctxt = Ctxt.new
        ctxt.use_options(options)
        input = Loader.load_external_entity(filename, nil, ctxt)
        return nil if input.nil?

        ctxt.switch_input_encoding_name(input, encoding) if encoding
        ctxt.parse_document_with(input)
      end

      # xinclude.c xmlXIncludeParseFile
      def xinclude_parse_file(url, options)
        ctxt = Ctxt.new
        ctxt.use_options(options | PARSE_DTDLOAD)
        input = Loader.load_external_entity(url, nil, ctxt)
        return nil if input.nil?

        ctxt.input_push(input)
        ctxt.parse_document
        if ctxt.well_formed != 0
          ctxt.my_doc
        end
      end

      # raw bytes of the resource xmlLoadExternalEntity would open (parse="text" includes)
      def load_external_resource(url, options)
        ctxt = Ctxt.new
        ctxt.use_options(options)
        input = Loader.load_external_entity(url, nil, ctxt)
        return nil if input.nil?

        input.raw
      end

      # Document#create_entity failures: libxml2's xmlAddDocEntity reports nothing
      def entity_add_error(_code, _name)
        nil
      end

      # xmlCreateMemoryParserCtxt
      def create_memory_parser_ctxt(bytes, sax = nil, user_data = nil)
        ctxt = Ctxt.new(sax, user_data)
        ctxt.input_push(ctxt.new_input_from_bytes(bytes.b))
        ctxt
      end

      # xmlCreatePushParserCtxt
      def create_push_parser_ctxt(sax, user_data, chunk, filename)
        ctxt = Ctxt.new(sax, user_data)
        ctxt.options &= ~PARSE_NODICT
        ctxt.dict_names = 1
        input = ctxt.new_input_stream
        input.filename = filename&.dup
        input.set_raw("".b, eof: false)
        input.flags |= XML_INPUT_PROGRESSIVE
        ctxt.input_push(input)
        ctxt.push_bytes(chunk) if chunk && !chunk.empty?
        ctxt
      end

      # xmlParseInNodeContext + Nokogiri's in_context glue
      def node_in_context(rb_node, string, options)
        node = Pure.unwrap(rb_node)
        doc = node.doc
        rb_doc = doc._ruby_doc
        errors = rb_doc.instance_variable_get(:@errors)
        unless errors.is_a?(Array)
          errors = []
          rb_doc.instance_variable_set(:@errors, errors)
        end
        doc_is_empty = doc.children.nil?
        node_children = node.children
        doc_children = doc.children
        list = nil
        error = nil
        Errors.collecting_then_clear(errors) do
          error, list = parse_in_node_context(node, string.b, options)
        end
        if error != 0
          doc.children = doc_children
          node.children = node_children
        end
        child = doc.children
        while child
          child.parent = doc
          child = child.next
        end
        if error != 0 && doc_is_empty && doc.children
          top = node
          top = top.parent while top.parent
          doc.children = nil if top.type == DOCUMENT_FRAG_NODE
        end
        if error == ErrCode::ERR_INTERNAL_ERROR || error == ErrCode::ERR_NO_MEMORY
          raise RuntimeError, "error parsing fragment (#{error})"
        end

        nodes = []
        while list
          tmp = list.next
          list.next = nil
          nodes << list
          list = tmp
        end
        Pure.wrap_node_set(nodes, rb_doc)
      end

      # xmlParseInNodeContext: returns [error, list]
      def parse_in_node_context(node, data, options)
        case node.type
        when ELEMENT_NODE, ATTRIBUTE_NODE, TEXT_NODE, CDATA_SECTION_NODE, ENTITY_REF_NODE, PI_NODE,
          COMMENT_NODE, DOCUMENT_NODE, HTML_DOCUMENT_NODE
          nil
        else
          return [ErrCode::ERR_INTERNAL_ERROR, nil]
        end
        node = node.parent while node && node.type != ELEMENT_NODE && node.type != DOCUMENT_NODE &&
          node.type != HTML_DOCUMENT_NODE
        return [ErrCode::ERR_INTERNAL_ERROR, nil] if node.nil?

        doc = node.type == ELEMENT_NODE ? node.doc : node
        return [ErrCode::ERR_INTERNAL_ERROR, nil] if doc.nil?

        if doc.type == HTML_DOCUMENT_NODE
          if defined?(HTMLParser) && HTMLParser.respond_to?(:parse_in_node_context)
            return HTMLParser.parse_in_node_context(node, data, options)
          end

          return [ErrCode::ERR_INTERNAL_ERROR, nil]
        end
        return [ErrCode::ERR_INTERNAL_ERROR, nil] if doc.type != DOCUMENT_NODE

        ctxt = create_memory_parser_ctxt(data)
        options |= PARSE_NODICT
        ctxt.dict_names = 0
        ctxt.switch_encoding_name(doc.encoding) if doc.encoding
        ctxt.use_options(options)
        ctxt.initialize_late
        ctxt.my_doc = doc
        ctxt.input_id = 2

        fake = Tree.new_doc_comment(node.doc, nil)
        Tree.add_child(node, fake)
        ctxt.node_push(node) if node.type == ELEMENT_NODE
        nsnr = 0
        if ctxt.html == 0 && node.type == ELEMENT_NODE
          cur = node
          while cur && cur.type == ELEMENT_NODE
            ns = cur.ns_def
            while ns
              nsnr += 1 if ctxt.ns_push(ns.prefix, ns.href, ns, 1) > 0
              ns = ns.next
            end
            cur = cur.parent
          end
        end
        ctxt.loadsubset |= XML_SKIP_IDS if ctxt.validate != 0 || ctxt.replace_entities != 0
        ctxt.parse_content_internal
        ctxt.fatal_err(ErrCode::ERR_NOT_WELL_BALANCED) if ctxt.current_pos < ctxt.input.buf.bytesize
        ctxt.ns_pop(nsnr)
        ret = if ctxt.well_formed != 0 || (ctxt.recovery != 0 && ctxt.err_no != ErrCode::ERR_NO_MEMORY)
          0
        else
          ctxt.err_no
        end
        cur = fake.next
        fake.next = nil
        node.last = fake
        cur.prev = nil if cur
        lst = cur
        while cur
          cur.parent = nil
          cur = cur.next
        end
        Tree.unlink_node(fake)
        lst = nil if ret != 0
        [ret, lst]
      end
    end
  end
end
