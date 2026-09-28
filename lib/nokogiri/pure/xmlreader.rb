# frozen_string_literal: true

# Port of libxml2 2.13.9 xmlreader.c: the xmlTextReader streaming API, mapped on top of the
# progressive (push) parser building a tree (Parser.create_push_parser_ctxt / Ctxt#parse_chunk).
# Only the parts reachable from Nokogiri are ported (no walker, no RelaxNG/XSD, no patterns).

require_relative "xmlreader/valid_push"

module Nokogiri
  module Pure
    module XmlReader
      CHUNK_SIZE = 512
      MINLEN = 4000

      # xmlTextReaderMode
      MODE_INITIAL = 0
      MODE_INTERACTIVE = 1
      MODE_ERROR = 2
      MODE_EOF = 3
      MODE_CLOSED = 4
      MODE_READING = 5

      # xmlTextReaderState
      STATE_NONE = -1
      STATE_START = 0
      STATE_ELEMENT = 1
      STATE_END = 2
      STATE_EMPTY = 3
      STATE_BACKTRACK = 4
      STATE_DONE = 5
      STATE_ERROR = 6

      # xmlTextReaderValidate
      NOT_VALIDATE = 0
      VALIDATE_DTD = 1
      VALIDATE_RNG = 2
      VALIDATE_XSD = 4

      NODE_IS_EMPTY = 0x1
      NODE_IS_PRESERVED = 0x2
      NODE_IS_SPRESERVED = 0x4

      # xmlReaderTypes
      TYPE_NONE = 0
      TYPE_ELEMENT = 1
      TYPE_ATTRIBUTE = 2
      TYPE_TEXT = 3
      TYPE_CDATA = 4
      TYPE_ENTITY_REFERENCE = 5
      TYPE_ENTITY = 6
      TYPE_PROCESSING_INSTRUCTION = 7
      TYPE_COMMENT = 8
      TYPE_DOCUMENT = 9
      TYPE_DOCUMENT_TYPE = 10
      TYPE_DOCUMENT_FRAGMENT = 11
      TYPE_NOTATION = 12
      TYPE_WHITESPACE = 13
      TYPE_SIGNIFICANT_WHITESPACE = 14
      TYPE_END_ELEMENT = 15
      TYPE_END_ENTITY = 16
      TYPE_XML_DECLARATION = 17

      XML_PARSE_READER = 5 # xmlParserMode

      XINCLUDE_NS = "http://www.w3.org/2001/XInclude"
      XINCLUDE_OLD_NS = "http://www.w3.org/2003/XInclude"

      # xmlParserInputBuffer without an encoder: raw bytes accumulate in +buffer+.
      class InputBuffer
        attr_accessor :buffer, :error, :readcallback

        # +reader+ is a callable (len) -> Integer (<0 error) | String
        def initialize(readcallback)
          @buffer = +"".b
          @error = 0
          @readcallback = readcallback
        end

        # xmlParserInputBufferGrow / xmlParserInputBufferRead
        def read(len)
          return -1 if @error != 0

          len = MINLEN if len <= MINLEN && len != 4
          return 0 if @readcallback.nil?

          res = @readcallback.call(len)
          if res.is_a?(String)
            @buffer << res
            n = res.bytesize
            @readcallback = END_OF_INPUT if n <= 0
            n
          else
            @readcallback = END_OF_INPUT
            if res < 0
              @error = res == -1 ? ErrCode::IO_UNKNOWN : -res
              return -1
            end
            0
          end
        end

        def use
          @buffer.bytesize
        end

        # xmlBufShrink
        def shrink(n)
          n = @buffer.bytesize if n > @buffer.bytesize
          @buffer = @buffer.byteslice(n, @buffer.bytesize - n)
          n
        end

        END_OF_INPUT = ->(_len) { 0 }
      end

      # xmlMemRead over a private copy of the input
      def self.memory_input(bytes)
        data = bytes.b
        pos = 0
        InputBuffer.new(lambda do |len|
          n = data.bytesize - pos
          n = len if len < n
          s = data.byteslice(pos, n)
          pos += n
          s
        end)
      end

      # noko_io_read
      def self.io_input(io)
        InputBuffer.new(lambda do |len|
          str = begin
            io.read(len)
          rescue StandardError
            next -1
          end
          next 0 if str.nil?
          next -1 unless str.is_a?(String)

          s = str.b
          s = s.byteslice(0, len) if s.bytesize > len
          s
        end)
      end

      # xmlReaderForMemory
      def self.for_memory(buffer, url, encoding, options)
        reader = TextReader.new(memory_input(buffer), url)
        reader.setup(url, encoding, options)
        reader
      end

      # xmlReaderForIO
      def self.for_io(io, url, encoding, options)
        reader = TextReader.new(io_input(io), url)
        reader.setup(url, encoding, options)
        reader
      end

      # struct _xmlTextReader
      class TextReader
        attr_accessor :mode, :validate, :state, :ctxt, :sax, :input, :start_element, :end_element,
          :start_element_ns, :end_element_ns, :characters, :cdata_block, :base, :cur, :node, :curnode,
          :depth, :faketext, :preserve, :ent, :ent_nr, :ent_tab, :xinclude, :xincctxt, :in_xinclude,
          :preserves, :parser_flags

        # xmlNewTextReader
        def initialize(input, uri)
          @doc = nil
          @ent_tab = []
          @ent_nr = 0
          @ent = nil
          @input = input
          @validate = NOT_VALIDATE
          @state = STATE_START
          @depth = 0
          @preserve = 0
          @preserves = 0
          @parser_flags = 0
          @xinclude = 0
          @xincctxt = nil
          @in_xinclude = 0
          @sax = Parser::SAX2.default_handler
          wrap_sax
          @mode = MODE_INITIAL
          @node = nil
          @curnode = nil
          @input.read(4) if @input.use < 4
          if @input.use >= 4
            @ctxt = Parser.create_push_parser_ctxt(@sax, nil, @input.buffer.byteslice(0, 4), uri)
            @base = 0
            @cur = 4
          else
            @ctxt = Parser.create_push_parser_ctxt(@sax, nil, nil, uri)
            @base = 0
            @cur = 0
          end
          @ctxt.parse_mode = XML_PARSE_READER
          @ctxt._private = self
          @ctxt.linenumbers = 1
          @ctxt.dict_names = 1
        end

        # the reader's SAX interposition (xmlTextReaderStartElement & co)
        def wrap_sax
          sax = @sax
          @start_element = sax.start_element
          sax.start_element = START_ELEMENT
          @end_element = sax.end_element
          sax.end_element = END_ELEMENT
          if sax.initialized == Parser::SAX2::XML_SAX2_MAGIC
            @start_element_ns = sax.start_element_ns
            sax.start_element_ns = START_ELEMENT_NS
            @end_element_ns = sax.end_element_ns
            sax.end_element_ns = END_ELEMENT_NS
          else
            @start_element_ns = nil
            @end_element_ns = nil
          end
          @characters = sax.characters
          sax.characters = CHARACTERS
          sax.ignorable_whitespace = CHARACTERS
          @cdata_block = sax.cdata_block
          sax.cdata_block = CDATA_BLOCK
        end

        def self.mark_empty(ctxt)
          if ctxt.node && ctxt.input && ctxt.cur_byte == 0x2F && ctxt.nxt(1) == 0x3E
            ctxt.node.extra = NODE_IS_EMPTY
          end
        end

        START_ELEMENT = lambda do |ctxt, fullname, atts|
          reader = ctxt._private
          if reader && reader.start_element
            reader.start_element.call(ctxt, fullname, atts)
            TextReader.mark_empty(ctxt)
          end
          reader.state = STATE_ELEMENT if reader
        end

        END_ELEMENT = lambda do |ctxt, fullname|
          reader = ctxt._private
          reader.end_element.call(ctxt, fullname) if reader && reader.end_element
        end

        START_ELEMENT_NS = lambda do |ctxt, localname, prefix, uri, nb_namespaces, namespaces, nb_attributes,
          nb_defaulted, attributes|
          reader = ctxt._private
          if reader && reader.start_element_ns
            reader.start_element_ns.call(ctxt, localname, prefix, uri, nb_namespaces, namespaces, nb_attributes,
              nb_defaulted, attributes)
            TextReader.mark_empty(ctxt)
          end
          reader.state = STATE_ELEMENT if reader
        end

        END_ELEMENT_NS = lambda do |ctxt, localname, prefix, uri|
          reader = ctxt._private
          reader.end_element_ns.call(ctxt, localname, prefix, uri) if reader && reader.end_element_ns
        end

        CHARACTERS = lambda do |ctxt, ch|
          reader = ctxt._private
          reader.characters.call(ctxt, ch) if reader && reader.characters
        end

        CDATA_BLOCK = lambda do |ctxt, ch|
          reader = ctxt._private
          reader.cdata_block.call(ctxt, ch) if reader && reader.cdata_block
        end

        # xmlTextReaderSetup (input == NULL: the input was set by xmlNewTextReader)
        def setup(url, encoding, options)
          options |= Parser::PARSE_COMPACT
          @doc = nil
          @ent_nr = 0
          @parser_flags = options
          @validate = NOT_VALIDATE
          @sax = Parser::SAX2.default_handler
          wrap_sax
          @mode = MODE_INITIAL
          @node = nil
          @curnode = nil
          @ctxt._private = self
          @ctxt.linenumbers = 1
          @ctxt.dict_names = 1
          @ctxt.parse_mode = XML_PARSE_READER
          @xincctxt = nil
          if (options & Parser::PARSE_XINCLUDE) != 0
            @xinclude = 1
            options -= Parser::PARSE_XINCLUDE
          else
            @xinclude = 0
          end
          @in_xinclude = 0
          @validate = VALIDATE_DTD if (options & Parser::PARSE_DTDVALID) != 0
          @ctxt.use_options(options)
          @ctxt.switch_encoding_name(encoding) if encoding
          if url && @ctxt.input && @ctxt.input.filename.nil?
            @ctxt.input.filename = url.dup
          end
          @doc = nil
          0
        end

        # ---- node freeing ------------------------------------------------------------------

        # xmlTextReaderFreeProp: the attribute goes away; an ID keeps only its name
        def free_prop(cur)
          free_node_list(cur.children) if cur.children
          if cur.respond_to?(:id) && (id = cur.id)
            if id.respond_to?(:attr=)
              id.attr = nil
              id.name = cur.name
            end
          end
        end

        def free_prop_list(cur)
          while cur
            nxt = cur.next
            free_prop(cur)
            cur = nxt
          end
        end

        # xmlTextReaderFreeNodeList (only what is observable: attributes/IDs)
        def free_node_list(cur)
          return if cur.nil? || cur.is_a?(XmlNs)

          while cur
            nxt = cur.next
            if cur.type != DTD_NODE
              if (cur.type == ELEMENT_NODE || cur.type == XINCLUDE_START || cur.type == XINCLUDE_END) &&
                  cur.properties
                free_prop_list(cur.properties)
              end
              if cur.type != ENTITY_REF_NODE && cur.children && cur.children.parent.equal?(cur)
                free_node_list(cur.children)
              end
            end
            cur = nxt
          end
        end

        # xmlTextReaderFreeNode (the node is already unlinked)
        def free_node(cur)
          return if cur.type == DTD_NODE || cur.is_a?(XmlNs)
          return free_prop(cur) if cur.type == ATTRIBUTE_NODE

          if cur.children && cur.type != ENTITY_REF_NODE
            free_node_list(cur.children) if cur.children.parent.equal?(cur)
          end
          if (cur.type == ELEMENT_NODE || cur.type == XINCLUDE_START || cur.type == XINCLUDE_END) && cur.properties
            free_prop_list(cur.properties)
          end
        end

        def unlink_and_free(tmp)
          Tree.unlink_node(tmp)
          free_node(tmp)
        end

        # ---- core ----------------------------------------------------------------------------

        def ent_push(value)
          @ent_tab[@ent_nr] = value
          @ent = value
          @ent_nr += 1
          @ent_nr - 1
        end

        def ent_pop
          return nil if @ent_nr <= 0

          @ent_nr -= 1
          @ent = @ent_nr > 0 ? @ent_tab[@ent_nr - 1] : nil
          ret = @ent_tab[@ent_nr]
          @ent_tab[@ent_nr] = nil
          ret
        end

        def parse_chunk(bytes, terminate)
          @ctxt.parse_chunk(bytes, terminate)
        end

        # xmlTextReaderPushData
        def push_data
          return -1 if @input.nil?

          oldstate = @state
          @state = STATE_NONE
          inbuf = @input

          while @state == STATE_NONE
            if inbuf.use < @cur + CHUNK_SIZE
              if @mode != MODE_EOF
                val = inbuf.read(4096)
                if val == 0
                  if inbuf.use == @cur
                    @mode = MODE_EOF
                    break
                  end
                elsif val < 0
                  @ctxt.err_io(@input.error, nil)
                  @mode = MODE_ERROR
                  @state = STATE_ERROR
                  return -1
                end
              else
                break
              end
            end
            if inbuf.use >= @cur + CHUNK_SIZE
              val = parse_chunk(inbuf.buffer.byteslice(@cur, CHUNK_SIZE), false)
              @cur += CHUNK_SIZE
              @ctxt.well_formed = 0 if val != 0
              break if @ctxt.well_formed == 0
            else
              s = inbuf.use - @cur
              val = parse_chunk(inbuf.buffer.byteslice(@cur, s), false)
              @cur += s
              @ctxt.well_formed = 0 if val != 0
              break
            end
          end
          @state = oldstate

          if @mode == MODE_INTERACTIVE
            if @input.readcallback && @cur >= 4096 && inbuf.use - @cur <= CHUNK_SIZE
              val = inbuf.shrink(@cur)
              @cur -= val if val >= 0
            end
          elsif @mode == MODE_EOF
            if @state != STATE_DONE
              s = inbuf.use - @cur
              val = parse_chunk(inbuf.buffer.byteslice(@cur, s), true)
              @cur = inbuf.use
              @state = STATE_DONE
              if val != 0
                if @ctxt.well_formed != 0
                  @ctxt.well_formed = 0
                else
                  return -1
                end
              end
            end
          end
          if @ctxt.well_formed == 0
            @mode = MODE_EOF
            return -1
          end
          0
        end

        # ---- validation (DTD only; RelaxNG/XSD are not reachable from Nokogiri) -------------

        def dtd_validating?
          @validate == VALIDATE_DTD && @ctxt && @ctxt.validate == 1
        end

        def qname_of(node)
          if node.ns.nil? || node.ns.prefix.nil?
            node.name
          else
            Tree.build_qname(node.name, node.ns.prefix)
          end
        end

        # xmlTextReaderValidatePush
        def validate_push
          node = @node
          if dtd_validating?
            @ctxt.valid &= ValidPush.push_element(@ctxt.vctxt, @ctxt.my_doc, node, qname_of(node))
          end
          0
        end

        # xmlTextReaderValidateCData
        def validate_cdata(data)
          if dtd_validating?
            data ||= ""
            @ctxt.valid &= ValidPush.push_cdata(@ctxt.vctxt, data, data.bytesize)
          end
        end

        # xmlTextReaderValidatePop
        def validate_pop
          node = @node
          if dtd_validating?
            @ctxt.valid &= ValidPush.pop_element(@ctxt.vctxt, @ctxt.my_doc, node, qname_of(node))
          end
          0
        end

        # xmlTextReaderValidateEntity
        def validate_entity
          oldnode = @node
          node = @node
          loop do
            skip_children = false
            if node.type == ENTITY_REF_NODE
              if node.children && node.children.type == ENTITY_DECL && node.children.children
                ent_push(node)
                node = node.children.children
                break if node.nil? || node.equal?(oldnode)

                next
              else
                break if node.equal?(oldnode)

                skip_children = true
              end
            elsif node.type == ELEMENT_NODE
              @node = node
              return -1 if validate_push < 0
            elsif node.type == TEXT_NODE || node.type == CDATA_SECTION_NODE
              validate_cdata(node.content)
            end

            unless skip_children
              if node.children
                node = node.children
                break if node.nil? || node.equal?(oldnode)

                next
              elsif node.type == ELEMENT_NODE
                return -1 if validate_pop < 0
              end
            end
            # skip_children:
            if node.next
              node = node.next
              break if node.nil? || node.equal?(oldnode)

              next
            end
            loop do
              node = node.parent
              if node.type == ELEMENT_NODE
                if @ent_nr == 0
                  while (tmp = node.last)
                    if (tmp.extra & NODE_IS_PRESERVED) == 0
                      unlink_and_free(tmp)
                    else
                      break
                    end
                  end
                end
                @node = node
                return -1 if validate_pop < 0
              end
              if node.type == ENTITY_DECL && @ent && @ent.children.equal?(node)
                node = ent_pop
              end
              break if node.equal?(oldnode)

              if node.next
                node = node.next
                break
              end
              break if node.nil? || node.equal?(oldnode)
            end
            break if node.nil? || node.equal?(oldnode)
          end
          @node = oldnode
          0
        end

        # xmlTextReaderGetSuccessor
        def get_successor(cur)
          return nil if cur.nil?
          return cur.next if cur.next

          loop do
            cur = cur.parent
            break if cur.nil?
            return cur.next if cur.next
          end
          cur
        end

        # xmlTextReaderDoExpand
        def do_expand
          return -1 if @node.nil? || @ctxt.nil?

          loop do
            return 1 if @ctxt.stopped?
            return 1 if get_successor(@node)
            return 1 if @ctxt.node_nr < @depth
            return 1 if @mode == MODE_EOF

            val = push_data
            if val < 0
              @mode = MODE_ERROR
              @state = STATE_ERROR
              return -1
            end
            break if @mode == MODE_EOF
          end
          1
        end

        # xmlTextReaderExpand
        def expand
          return nil if @node.nil?
          return @node if @doc
          return nil if @ctxt.nil?
          return nil if do_expand < 0

          @node
        end

        def error!
          @mode = MODE_ERROR
          @state = STATE_ERROR
          -1
        end

        # xmlTextReaderRead
        def read
          olddepth = 0
          oldstate = STATE_START
          oldnode = nil

          return -1 if @state == STATE_ERROR

          @curnode = nil
          return -1 if @ctxt.nil?

          label = :get_next_node
          if @mode == MODE_INITIAL
            @mode = MODE_INTERACTIVE
            loop do
              val = push_data
              return error! if val < 0
              break unless @ctxt.node.nil? && @mode != MODE_EOF && @state != STATE_DONE
            end
            if @ctxt.node.nil?
              @node = @ctxt.my_doc.children if @ctxt.my_doc
              return error! if @node.nil?

              @state = STATE_ELEMENT
            else
              @node = @ctxt.my_doc.children if @ctxt.my_doc
              @node = @ctxt.node_tab[0] if @node.nil?
              @state = STATE_ELEMENT
            end
            @depth = 0
            @ctxt.parse_mode = XML_PARSE_READER
            label = :node_found
          else
            oldstate = @state
            olddepth = @ctxt.node_nr
            oldnode = @node
          end

          loop do
            if label == :get_next_node
              label = get_next_node(oldstate, olddepth, oldnode)
              return label if label.is_a?(Integer)

              oldnode = nil if label == :node_found_clear_oldnode
              label = :node_found if label == :node_found_clear_oldnode
            end

            if label == :node_end
              @state = STATE_DONE
              return 0
            end

            # node_found:
            if @node && @node.next.nil? && (@node.type == TEXT_NODE || @node.type == CDATA_SECTION_NODE)
              return -1 if expand.nil?
            end

            if @xinclude != 0 && @in_xinclude == 0 && @state != STATE_BACKTRACK && @node &&
                @node.type == ELEMENT_NODE && @node.ns &&
                (@node.ns.href == XINCLUDE_NS || @node.ns.href == XINCLUDE_OLD_NS)
              if @xincctxt.nil?
                @xincctxt = XInclude::Ctxt.new(@ctxt.my_doc)
                @xincctxt.parse_flags = @parser_flags & ~Parser::PARSE_NOXINCNODE
                @xincctxt.is_stream = true
              end
              return -1 if expand.nil?
              return -1 if xinclude_process_node(@xincctxt, @node) < 0
            end
            if @node && @node.type == XINCLUDE_START
              @in_xinclude += 1
              label = :get_next_node
              next
            end
            if @node && @node.type == XINCLUDE_END
              @in_xinclude -= 1
              label = :get_next_node
              next
            end

            if @node && @node.type == ENTITY_REF_NODE && @ctxt && @ctxt.replace_entities == 1
              if @node.children && @node.children.type == ENTITY_DECL && @node.children.children
                ent_push(@node)
                @node = @node.children.children
              end
            elsif @node && @node.type == ENTITY_REF_NODE && @ctxt && @validate != 0
              return -1 if validate_entity < 0
            end
            if @node && @node.type == ENTITY_DECL && @ent && @ent.children.equal?(@node)
              @node = ent_pop
              @depth += 1
              label = :get_next_node
              next
            end
            if @validate != NOT_VALIDATE && @node
              node = @node
              if node.type == ELEMENT_NODE && @state != STATE_END && @state != STATE_BACKTRACK
                return -1 if validate_push < 0
              elsif node.type == TEXT_NODE || node.type == CDATA_SECTION_NODE
                validate_cdata(node.content)
              end
            end
            return 1
          end
        end

        # the get_next_node block of xmlTextReaderRead; returns an Integer (return value) or a label
        def get_next_node(oldstate, olddepth, oldnode)
          if @node.nil?
            return 0 if @mode == MODE_EOF

            return error!
          end

          while @node && @node.next.nil? && @ctxt.node_nr == olddepth &&
              (oldstate == STATE_BACKTRACK || @node.children.nil? || @node.type == ENTITY_REF_NODE ||
                (@node.children && @node.children.type == TEXT_NODE && @node.children.next.nil?) ||
                @node.type == DTD_NODE || @node.type == DOCUMENT_NODE || @node.type == HTML_DOCUMENT_NODE) &&
              (@ctxt.node.nil? || @ctxt.node.equal?(@node) || @ctxt.node.equal?(@node.parent)) &&
              @ctxt.instate != Parser::XML_PARSER_EOF && !@ctxt.stopped?
            val = push_data
            return error! if val < 0
            return :node_end if @node.nil?
          end
          if oldstate != STATE_BACKTRACK
            if @node.children && @node.type != ENTITY_REF_NODE && @node.type != XINCLUDE_START &&
                @node.type != DTD_NODE
              @node = @node.children
              @depth += 1
              @state = STATE_ELEMENT
              return :node_found
            end
          end
          if @node.next
            if oldstate == STATE_ELEMENT && @node.type == ELEMENT_NODE && @node.children.nil? &&
                (@node.extra & NODE_IS_EMPTY) == 0 && @in_xinclude <= 0
              @state = STATE_END
              return :node_found
            end
            if @validate != 0 && @node.type == ELEMENT_NODE
              return -1 if validate_pop < 0
            end
            @preserves -= 1 if @preserves > 0 && (@node.extra & NODE_IS_SPRESERVED) != 0
            @node = @node.next
            @state = STATE_ELEMENT

            # Cleanup of the old node
            cleared = false
            if @preserves == 0 && @in_xinclude == 0 && @ent_nr == 0 && @node.prev && @node.prev.type != DTD_NODE
              tmp = @node.prev
              if (tmp.extra & NODE_IS_PRESERVED) == 0
                cleared = true if oldnode.equal?(tmp)
                unlink_and_free(tmp)
              end
            end
            return cleared ? :node_found_clear_oldnode : :node_found
          end
          if oldstate == STATE_ELEMENT && @node.type == ELEMENT_NODE && @node.children.nil? &&
              (@node.extra & NODE_IS_EMPTY) == 0
            @state = STATE_END
            return :node_found
          end
          if @validate != NOT_VALIDATE && @node.type == ELEMENT_NODE
            return -1 if validate_pop < 0
          end
          @preserves -= 1 if @preserves > 0 && (@node.extra & NODE_IS_SPRESERVED) != 0
          @node = @node.parent
          if @node.nil? || @node.type == DOCUMENT_NODE || @node.type == HTML_DOCUMENT_NODE
            if @mode != MODE_EOF
              val = parse_chunk("", true)
              @state = STATE_DONE
              return error! if val != 0
            end
            @node = nil
            @depth = -1

            # Cleanup of the old node
            if oldnode && @preserves == 0 && @in_xinclude == 0 && @ent_nr == 0 &&
                oldnode.type != DTD_NODE && (oldnode.extra & NODE_IS_PRESERVED) == 0
              unlink_and_free(oldnode)
            end
            return :node_end
          end
          if @preserves == 0 && @in_xinclude == 0 && @ent_nr == 0 && @node.last &&
              (@node.last.extra & NODE_IS_PRESERVED) == 0
            unlink_and_free(@node.last)
          end
          @depth -= 1
          @state = STATE_BACKTRACK
          :node_found
        end

        # xmlXIncludeProcessNode
        def xinclude_process_node(xctxt, node)
          return -1 if node.nil? || node.is_a?(XmlNs) || node.doc.nil? || xctxt.nil?

          ret = XInclude.do_process(xctxt, node)
          ret = -1 if ret >= 0 && xctxt.nb_errors > 0
          ret
        end

        # xmlTextReaderReadState
        def read_state
          @mode
        end

        # xmlTextReaderNext
        def next_node
          cur = @node
          return read if cur.nil? || cur.type != ELEMENT_NODE
          return read if @state == STATE_END || @state == STATE_BACKTRACK
          return read if (cur.extra & NODE_IS_EMPTY) != 0

          loop do
            ret = read
            return ret if ret != 1
            break if @node.equal?(cur)
          end
          read
        end

        # ---- serialisation -------------------------------------------------------------------

        # xmlNodeDumpOutput(output, doc, node, 0, 0, NULL)
        def node_dump_output(buf, doc, cur)
          ctxt = Save::SaveCtxt.new(nil, Save::SAVE_AS_XML, "  ")
          ctxt.encoding = "UTF-8"
          ctxt.escape = nil
          ctxt.escape_attr = nil
          ctxt.buf = buf
          ctxt.level = 0
          ctxt.format = 0
          dtd = doc && Tree.get_int_subset(doc)
          is_xhtml = dtd ? Save.is_xhtml(dtd.system_id, dtd.external_id) > 0 : false
          if is_xhtml
            Save.xhtml_node_dump_output(ctxt, cur)
          else
            Save.node_dump_output_internal(ctxt, cur)
          end
        end

        # xmlTextReaderDumpCopy
        def dump_copy(output, node)
          return if node.type == DTD_NODE || node.type == ELEMENT_DECL || node.type == ATTRIBUTE_DECL ||
            node.type == ENTITY_DECL

          if node.type == DOCUMENT_NODE || node.type == HTML_DOCUMENT_NODE
            node_dump_output(output, node.doc, node)
          else
            copy = Tree.doc_copy_node(node, node.doc, 1)
            return if copy.nil?

            node_dump_output(output, copy.doc, copy)
          end
        end

        # xmlTextReaderReadInnerXml
        def read_inner_xml
          return nil if expand.nil?
          return nil if @node.nil?

          output = Save::OutBuf.new
          cur = @node.children
          while cur
            dump_copy(output, cur)
            cur = cur.next
          end
          output.result.force_encoding(Encoding::UTF_8)
        end

        # xmlTextReaderReadOuterXml
        def read_outer_xml
          return nil if expand.nil?

          node = @node
          return nil if node.nil?

          output = Save::OutBuf.new
          dump_copy(output, node)
          output.result.force_encoding(Encoding::UTF_8)
        end

        # ---- accessors -----------------------------------------------------------------------

        def current_node
          @curnode || @node
        end

        # xmlTextReaderCurrentDoc
        def current_doc
          return @doc if @doc
          return nil if @ctxt.nil? || @ctxt.my_doc.nil?

          @preserve = 1
          @ctxt.my_doc
        end

        # xmlTextReaderGetAttributeNo
        def get_attribute_no(no)
          return nil if @node.nil? || @curnode
          return nil if @node.type != ELEMENT_NODE

          ns = @node.ns_def
          i = 0
          while i < no && ns
            ns = ns.next
            i += 1
          end
          return ns.href&.dup if ns

          cur = @node.properties
          return nil if cur.nil?

          while i < no
            cur = cur.next
            return nil if cur.nil?

            i += 1
          end
          return nil if cur.children.nil?

          Tree.node_list_get_string(@node.doc, cur.children, 1)
        end

        # xmlTextReaderGetAttribute
        def get_attribute(name)
          return nil if name.nil? || @node.nil? || @curnode
          return nil if @node.type != ELEMENT_NODE

          localname, prefix = Tree.split_qname4(name)
          if prefix.nil?
            if name == "xmlns"
              ns = @node.ns_def
              while ns
                return ns.href&.dup if ns.prefix.nil?

                ns = ns.next
              end
              return nil
            end
            return Tree.node_get_attr_value(@node, name, nil)
          end

          ret = nil
          if prefix == "xmlns"
            ns = @node.ns_def
            while ns
              if ns.prefix && ns.prefix == localname
                ret = ns.href&.dup
                break
              end
              ns = ns.next
            end
          else
            ns = Tree.search_ns(@node.doc, @node, prefix)
            ret = Tree.node_get_attr_value(@node, localname, ns.href) if ns
          end
          ret
        end

        # xmlTextReaderConstEncoding
        def const_encoding
          if @ctxt
            @ctxt.input ? @ctxt.actual_encoding : nil
          elsif @doc
            @doc.encoding
          end
        end

        # xmlTextReaderAttributeCount
        def attribute_count
          return 0 if @node.nil?

          node = current_node
          return 0 if node.type != ELEMENT_NODE
          return 0 if @state == STATE_END || @state == STATE_BACKTRACK

          ret = 0
          attr = node.properties
          while attr
            ret += 1
            attr = attr.next
          end
          ns = node.ns_def
          while ns
            ret += 1
            ns = ns.next
          end
          ret
        end

        # xmlTextReaderNodeType
        def node_type
          return TYPE_NONE if @node.nil?

          node = current_node
          return TYPE_ATTRIBUTE if node.is_a?(XmlNs)

          case node.type
          when ELEMENT_NODE
            return TYPE_END_ELEMENT if @state == STATE_END || @state == STATE_BACKTRACK

            TYPE_ELEMENT
          when NAMESPACE_DECL, ATTRIBUTE_NODE
            TYPE_ATTRIBUTE
          when TEXT_NODE
            if Tree.is_blank_node(@node)
              if Tree.node_get_space_preserve(@node) != 0
                TYPE_SIGNIFICANT_WHITESPACE
              else
                TYPE_WHITESPACE
              end
            else
              TYPE_TEXT
            end
          when CDATA_SECTION_NODE then TYPE_CDATA
          when ENTITY_REF_NODE then TYPE_ENTITY_REFERENCE
          when ENTITY_NODE then TYPE_ENTITY
          when PI_NODE then TYPE_PROCESSING_INSTRUCTION
          when COMMENT_NODE then TYPE_COMMENT
          when DOCUMENT_NODE, HTML_DOCUMENT_NODE then TYPE_DOCUMENT
          when DOCUMENT_FRAG_NODE then TYPE_DOCUMENT_FRAGMENT
          when NOTATION_NODE then TYPE_NOTATION
          when DOCUMENT_TYPE_NODE, DTD_NODE then TYPE_DOCUMENT_TYPE
          when ELEMENT_DECL, ATTRIBUTE_DECL, ENTITY_DECL, XINCLUDE_START, XINCLUDE_END then TYPE_NONE
          else -1
          end
        end

        # xmlTextReaderIsEmptyElement
        def is_empty_element
          return -1 if @node.nil?
          return 0 if @node.type != ELEMENT_NODE
          return 0 if @curnode
          return 0 if @node.children
          return 0 if @state == STATE_END
          return 1 if @doc
          return 1 if @in_xinclude > 0

          (@node.extra & NODE_IS_EMPTY) != 0 ? 1 : 0
        end

        # xmlTextReaderConstLocalName
        def const_local_name
          return nil if @node.nil?

          node = current_node
          if node.is_a?(XmlNs)
            return node.prefix.nil? ? "xmlns" : node.prefix
          end
          return const_name if node.type != ELEMENT_NODE && node.type != ATTRIBUTE_NODE

          node.name
        end

        # xmlTextReaderConstName
        def const_name
          return nil if @node.nil?

          node = current_node
          if node.is_a?(XmlNs)
            return node.prefix.nil? ? "xmlns" : "xmlns:#{node.prefix}"
          end

          case node.type
          when ELEMENT_NODE, ATTRIBUTE_NODE
            return node.name if node.ns.nil? || node.ns.prefix.nil?

            "#{node.ns.prefix}:#{node.name}"
          when TEXT_NODE then "#text"
          when CDATA_SECTION_NODE then "#cdata-section"
          when ENTITY_NODE, ENTITY_REF_NODE, PI_NODE, NOTATION_NODE, DOCUMENT_TYPE_NODE, DTD_NODE
            node.name
          when COMMENT_NODE then "#comment"
          when DOCUMENT_NODE, HTML_DOCUMENT_NODE then "#document"
          when DOCUMENT_FRAG_NODE then "#document-fragment"
          end
        end

        # xmlTextReaderConstPrefix
        def const_prefix
          return nil if @node.nil?

          node = current_node
          if node.is_a?(XmlNs)
            return nil if node.prefix.nil?

            return "xmlns"
          end
          return nil if node.type != ELEMENT_NODE && node.type != ATTRIBUTE_NODE
          return node.ns.prefix if node.ns && node.ns.prefix

          nil
        end

        # xmlTextReaderConstNamespaceUri
        def const_namespace_uri
          return nil if @node.nil?

          node = current_node
          return XML_XMLNS_NAMESPACE if node.is_a?(XmlNs)
          return nil if node.type != ELEMENT_NODE && node.type != ATTRIBUTE_NODE
          return node.ns.href if node.ns

          nil
        end

        # xmlTextReaderBaseUri
        def base_uri
          return nil if @node.nil?

          Tree.node_get_base(nil, @node)
        end

        # xmlTextReaderDepth
        def get_depth
          return 0 if @node.nil?

          if @curnode
            return @depth + 1 if @curnode.is_a?(XmlNs) || @curnode.type == ATTRIBUTE_NODE

            return @depth + 2
          end
          @depth
        end

        # xmlTextReaderHasValue
        def has_value
          return 0 if @node.nil?

          node = current_node
          return 1 if node.is_a?(XmlNs)

          case node.type
          when ATTRIBUTE_NODE, TEXT_NODE, CDATA_SECTION_NODE, PI_NODE, COMMENT_NODE, NAMESPACE_DECL then 1
          else 0
          end
        end

        # xmlTextReaderConstValue
        def const_value
          return nil if @node.nil?

          node = current_node
          return node.href if node.is_a?(XmlNs)

          case node.type
          when ATTRIBUTE_NODE
            if node.children && node.children.type == TEXT_NODE && node.children.next.nil?
              node.children.content
            else
              Tree.buf_get_node_content(+"", node)
            end
          when TEXT_NODE, CDATA_SECTION_NODE, PI_NODE, COMMENT_NODE
            node.content
          end
        end

        # xmlTextReaderIsDefault
        def is_default
          0
        end

        # xmlTextReaderConstXmlLang
        def const_xml_lang
          return nil if @node.nil?

          Tree.node_get_lang(@node)
        end

        # xmlTextReaderConstXmlVersion
        def const_xml_version
          doc = @doc || @ctxt&.my_doc
          return nil if doc.nil?

          doc.version
        end
      end
    end
  end
end
