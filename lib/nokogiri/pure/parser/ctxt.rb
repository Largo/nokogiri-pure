# frozen_string_literal: true

require "strscan"

module Nokogiri
  module Pure
    module Parser
      # xmlValidCtxt (only what the parser and valid.rb need)
      class ValidCtxt
        attr_accessor :user_data, :flags, :valid, :node_tab, :node, :vstate_tab, :vstate, :error, :warning,
          :finish_dtd

        XML_VCTXT_DTD_VALIDATED = 1 << 0
        XML_VCTXT_USE_PCTXT = 1 << 1
        XML_VCTXT_IN_ENTITY = 1 << 2

        def initialize
          @user_data = nil
          @flags = 0
          @valid = 1
          @node_tab = []
          @node = nil
          @vstate_tab = []
          @vstate = nil
          @error = nil
          @warning = nil
          @finish_dtd = 0
        end

        def pctxt
          (@flags & XML_VCTXT_USE_PCTXT) != 0 ? @user_data : nil
        end
      end

      # xmlStartTag
      StartTag = Struct.new(:prefix, :uri, :line, :ns_nr)

      # xmlDefAttr
      DefAttr = Struct.new(:prefix, :name, :value, :external, :expanded_size)

      # xmlParserCtxt
      class Ctxt
        attr_accessor :sax, :user_data, :my_doc, :well_formed, :replace_entities, :version, :encoding,
          :standalone, :html, :input, :input_tab, :node, :node_tab, :name, :name_tab, :push_tab,
          :space_tab, :keep_blanks, :disable_sax, :in_subset, :int_sub_name, :ext_sub_uri,
          :ext_sub_system, :validate, :valid, :vctxt, :err_no, :pedantic, :loadsubset, :linenumbers,
          :has_external_subset, :has_pe_refs, :directory, :ns_well_formed, :options, :dict_names,
          :nodelen, :nodemem, :_private, :recovery, :sizeentities, :sizeentcopy, :input_id,
          :max_ampl, :instate, :check_index, :end_check_state, :last_error, :sax2, :atts_default,
          :atts_special, :record_info, :depth, :parse_mode, :nb_errors, :nb_warnings, :ns_tab,
          :ns_extra, :min_ns_index, :catalogs

        def initialize(sax = nil, user_data = nil)
          if sax.nil?
            @sax = SAX2.default_handler
            @user_data = self
          else
            @sax = sax.dup
            @user_data = user_data || self
          end
          @input = nil
          @input_tab = []
          @buf = +""
          @cur = 0
          @end = 0
          @line = 1
          @col = 1
          @ss = StringScanner.new(@buf)
          @version = nil
          @encoding = nil
          @standalone = -1
          @has_external_subset = 0
          @has_pe_refs = 0
          @html = 0
          @instate = XML_PARSER_START
          @node = nil
          @node_tab = []
          @name = nil
          @name_tab = []
          @push_tab = []
          @space_tab = [-1]
          @space_nr = 1
          @my_doc = nil
          @well_formed = 1
          @ns_well_formed = 1
          @valid = 1
          @options = PARSE_NODICT
          @loadsubset = 0
          @validate = 0
          @pedantic = 0
          @linenumbers = 0
          @keep_blanks = 1
          @replace_entities = 0
          @recovery = 0
          @dict_names = 0
          @vctxt = ValidCtxt.new
          @vctxt.flags = ValidCtxt::XML_VCTXT_USE_PCTXT
          @vctxt.user_data = self
          @record_info = 0
          @check_index = 0
          @end_check_state = 0
          @in_subset = 0
          @err_no = 0
          @depth = 0
          @sizeentities = 0
          @sizeentcopy = 0
          @input_id = 1
          @max_ampl = XML_MAX_AMPLIFICATION_DEFAULT
          @disable_sax = 0
          @nodelen = 0
          @nodemem = 0
          @sax2 = 0
          @atts_default = nil
          @atts_special = nil
          @int_sub_name = nil
          @ext_sub_uri = nil
          @ext_sub_system = nil
          @directory = nil
          @_private = nil
          @last_error = nil
          @nb_errors = 0
          @nb_warnings = 0
          @parse_mode = 0
          # namespace database (xmlParserNsData)
          @ns_tab = []   # [prefix, uri] pairs
          @ns_extra = [] # [sax_data, element_id, old_index]
          @ns_hash = {}
          @ns_default_index = INT_MAX
          @ns_element_id = 0
          @min_ns_index = 0
          @catalogs = nil
        end

        def space
          @space_tab[@space_nr > 0 ? @space_nr - 1 : 0]
        end

        def space=(v)
          @space_tab[@space_nr > 0 ? @space_nr - 1 : 0] = v
        end

        # ---- options (xmlCtxtSetOptionsInternal) ---------------------------------------------

        ALL_OPTIONS_MASK = PARSE_RECOVER | PARSE_NOENT | PARSE_DTDLOAD | PARSE_DTDATTR | PARSE_DTDVALID |
          PARSE_NOERROR | PARSE_NOWARNING | PARSE_PEDANTIC | PARSE_NOBLANKS | PARSE_SAX1 | PARSE_NONET |
          PARSE_NODICT | PARSE_NSCLEAN | PARSE_NOCDATA | PARSE_COMPACT | PARSE_OLD10 | PARSE_HUGE |
          PARSE_OLDSAX | PARSE_IGNORE_ENC | PARSE_BIG_LINES | PARSE_NO_XXE

        USE_OPTIONS_KEEP_MASK = PARSE_NOERROR | PARSE_NOWARNING | PARSE_NONET | PARSE_NSCLEAN | PARSE_NOCDATA |
          PARSE_COMPACT | PARSE_OLD10 | PARSE_HUGE | PARSE_OLDSAX | PARSE_IGNORE_ENC | PARSE_BIG_LINES

        def set_options_internal(options, keep_mask)
          @options = (@options & keep_mask) | (options & ALL_OPTIONS_MASK)
          @recovery = (options & PARSE_RECOVER) != 0 ? 1 : 0
          @replace_entities = (options & PARSE_NOENT) != 0 ? 1 : 0
          @loadsubset = (options & PARSE_DTDLOAD) != 0 ? XML_DETECT_IDS : 0
          @loadsubset |= (options & PARSE_DTDATTR) != 0 ? XML_COMPLETE_ATTRS : 0
          @validate = (options & PARSE_DTDVALID) != 0 ? 1 : 0
          @pedantic = (options & PARSE_PEDANTIC) != 0 ? 1 : 0
          @keep_blanks = (options & PARSE_NOBLANKS) != 0 ? 0 : 1
          @dict_names = (options & PARSE_NODICT) != 0 ? 0 : 1
          @sax.ignorable_whitespace = SAX2::IGNORABLE_WHITESPACE if (options & PARSE_NOBLANKS) != 0
          @sax.cdata_block = nil if (options & PARSE_NOCDATA) != 0
          @linenumbers = 1
          options & ~ALL_OPTIONS_MASK
        end

        # xmlCtxtUseOptions
        def use_options(options)
          set_options_internal(options, USE_OPTIONS_KEEP_MASK)
        end

        # xmlCtxtSetOptions
        def set_options(options)
          set_options_internal(options, 0)
        end

        def option?(o)
          (@options & o) != 0
        end

        # ---- errors ----------------------------------------------------------------------------

        def stopped?
          @disable_sax > 1
        end

        # xmlHaltParser
        def halt
          @instate = XML_PARSER_EOF
          @disable_sax = 2
        end

        # xmlStopParser
        def stop
          halt
          @err_no = ErrCode::ERR_USER_STOP if @err_no != ErrCode::ERR_NO_MEMORY
        end

        # current position of an input for error reporting
        def input_position(input)
          if input.equal?(@input)
            [@line, @col]
          else
            [input.line, input.col]
          end
        end

        # xmlCtxtVErr (message already formatted)
        def ctxt_err(node, domain, code, level, str1, str2, str3, int1, msg)
          return if stopped?

          if level == Level::WARNING
            if @nb_warnings >= 100
              deliver = false
            else
              @nb_warnings += 1
              deliver = true
            end
          elsif @nb_errors >= 100 && (level < Level::FATAL || @well_formed == 0)
            deliver = false
          else
            @nb_errors += 1
            deliver = true
          end

          if deliver
            file = nil
            line = 0
            col = 0
            if (input = @input)
              if input.filename.nil? && @input_tab.length > 1
                input = @input_tab[-2]
              end
              file = input.filename
              line, col = input_position(input)
            end
            raise_error(node, domain, code, level, file, line, str1, str2, str3, int1, col, msg)
          end

          @err_no = code if level >= Level::ERROR
          if level == Level::FATAL
            @well_formed = 0
            @disable_sax = 1 if @recovery == 0
          end
          nil
        end

        # xmlVRaiseError for parser errors
        def raise_error(node, domain, code, level, file, line, str1, str2, str3, int1, col, msg)
          if node
            10.times do
              break if node.type == ELEMENT_NODE || node.parent.nil?

              node = node.parent
            end
            file = node.doc&.url if file.nil? && node.respond_to?(:doc) && node.doc
            if line == 0
              line = node.line if node.type == ELEMENT_NODE
              line = Tree.get_line_no(node) if line == 0 || line == 65_535
            end
          end
          msg = msg.b.byteslice(0, 63_999).force_encoding(Encoding::UTF_8) if msg.bytesize >= 64_000
          err = XmlError.new(domain: domain, code: code, message: msg, level: level, file: file, line: line,
            str1: str1&.dup, str2: str2&.dup, str3: str3&.dup, int1: int1, int2: col, node: node)
          @last_error = err
          if Errors.handler
            Errors.report(err)
          elsif !option?(PARSE_NOERROR) && (level != Level::WARNING || !option?(PARSE_NOWARNING))
            if domain == Domain::VALID || domain == Domain::DTD
              ch = level == Level::WARNING ? @vctxt.warning : @vctxt.error
              ch&.call(@user_data, msg)
            else
              ch = level == Level::WARNING ? @sax.warning : @sax.error
              ch&.call(@user_data, msg)
            end
          end
          err
        end

        def err_string(code)
          ERR_STRINGS[code] || "Unregistered error message"
        end

        # xmlFatalErr
        def fatal_err(code, info = nil)
          errmsg = err_string(code)
          if info.nil?
            ctxt_err(nil, Domain::PARSER, code, Level::FATAL, nil, nil, nil, 0, "#{errmsg}\n")
          else
            ctxt_err(nil, Domain::PARSER, code, Level::FATAL, info, nil, nil, 0, "#{errmsg}: #{info}\n")
          end
        end

        # xmlFatalErrMsg
        def fatal_err_msg(code, msg)
          ctxt_err(nil, Domain::PARSER, code, Level::FATAL, nil, nil, nil, 0, msg || "(null)")
        end

        # xmlWarningMsg (msg already formatted)
        def warning_msg(code, msg, str1 = nil, str2 = nil)
          ctxt_err(nil, Domain::PARSER, code, Level::WARNING, str1, str2, nil, 0, msg)
        end

        # xmlValidityError
        def validity_error(code, msg, str1 = nil, str2 = nil)
          @valid = 0
          ctxt_err(nil, Domain::DTD, code, Level::ERROR, str1, str2, nil, 0, msg)
        end

        # xmlFatalErrMsgInt
        def fatal_err_msg_int(code, msg, val)
          ctxt_err(nil, Domain::PARSER, code, Level::FATAL, nil, nil, nil, val, msg)
        end

        # xmlFatalErrMsgStrIntStr
        def fatal_err_msg_str_int_str(code, msg, str1, val, str2)
          ctxt_err(nil, Domain::PARSER, code, Level::FATAL, str1, str2, nil, val, msg)
        end

        # xmlFatalErrMsgStr
        def fatal_err_msg_str(code, msg, val)
          ctxt_err(nil, Domain::PARSER, code, Level::FATAL, val, nil, nil, 0, msg)
        end

        # xmlErrMsgStr
        def err_msg_str(code, msg, val)
          ctxt_err(nil, Domain::PARSER, code, Level::ERROR, val, nil, nil, 0, msg)
        end

        # xmlNsErr
        def ns_err(code, msg, info1 = nil, info2 = nil, info3 = nil)
          @ns_well_formed = 0
          ctxt_err(nil, Domain::NAMESPACE, code, Level::ERROR, info1, info2, info3, 0, msg)
        end

        # xmlNsWarn
        def ns_warn(code, msg, info1 = nil, info2 = nil, info3 = nil)
          ctxt_err(nil, Domain::NAMESPACE, code, Level::WARNING, info1, info2, info3, 0, msg)
        end

        # xmlErrAttributeDup
        def err_attribute_dup(prefix, localname)
          if prefix.nil?
            ctxt_err(nil, Domain::PARSER, ErrCode::ERR_ATTRIBUTE_REDEFINED, Level::FATAL, localname, nil, nil, 0,
              "Attribute #{localname} redefined\n")
          else
            ctxt_err(nil, Domain::PARSER, ErrCode::ERR_ATTRIBUTE_REDEFINED, Level::FATAL, prefix, localname, nil, 0,
              "Attribute #{prefix}:#{localname} redefined\n")
          end
        end

        # xmlCtxtErrIO
        def err_io(code, uri)
          level = if code == ErrCode::IO_ENOENT || code == ErrCode::IO_NETWORK_ATTEMPT || code == ErrCode::IO_UNKNOWN
            @validate == 0 ? Level::WARNING : Level::ERROR
          else
            Level::FATAL
          end
          errstr = err_string(code)
          if uri.nil?
            ctxt_err(nil, Domain::IO, code, level, nil, nil, nil, 0, "#{errstr}\n")
          else
            ctxt_err(nil, Domain::IO, code, level, uri, nil, nil, 0, "failed to load \"#{uri}\": #{errstr}\n")
          end
        end

        # ---- input stack --------------------------------------------------------------------------

        def save_registers
          if (inp = @input)
            inp.cur = @cur
            inp.line = @line
            inp.col = @col
          end
        end

        def load_registers
          if (inp = @input)
            @buf = inp.buf
            @cur = inp.cur
            @end = @buf.bytesize
            @line = inp.line
            @col = inp.col
            ss = inp.scanner
            ss = inp.scanner = StringScanner.new(@buf) unless ss && ss.string.equal?(@buf)
            @ss = ss
          else
            @buf = +""
            @cur = 0
            @end = 0
            @line = 1
            @col = 1
            @ss = StringScanner.new(@buf)
          end
        end

        # call after the current input's buffer was modified/grown
        def refresh_buffer
          inp = @input
          if !@buf.equal?(inp.buf)
            @buf = inp.buf
            @ss = StringScanner.new(@buf)
          end
          @end = @buf.bytesize
        end

        # inputPush
        def input_push(value)
          return -1 if value.nil?

          if @input_tab.empty? && value.filename
            @directory = parser_get_directory(value.filename)
          end
          save_registers
          @input_tab << value
          @input = value
          load_registers
          @input_tab.length - 1
        end

        # inputPop
        def input_pop
          return nil if @input_tab.empty?

          save_registers
          ret = @input_tab.pop
          @input = @input_tab[-1]
          load_registers
          ret
        end

        def input_nr
          @input_tab.length
        end

        # xmlParserGetDirectory
        def parser_get_directory(filename)
          idx = filename.rindex("/")
          return "./" if idx.nil?
          return "/" if idx == 0

          filename[0...idx]
        end

        # xmlNewInputStream
        def new_input_stream
          input = Input.new
          input.id = @input_id
          @input_id += 1
          input
        end

        # xmlNewInputString / xmlNewInputMemory helpers: a new input over +bytes+
        def new_input_from_bytes(bytes, filename = nil, encoding = nil, eof: true, raw_chunks: nil)
          input = new_input_stream
          input.filename = filename&.dup
          input.raw_chunks = raw_chunks
          input.set_raw(bytes, eof: eof)
          switch_input_encoding_name(input, encoding) if encoding
          input
        end

        # new input over an already UTF-8 string (entity content)
        def new_input_string(str, filename = nil)
          input = new_input_stream
          input.filename = filename
          input.raw = nil
          s = str.dup.force_encoding(Encoding::UTF_8)
          unless s.valid_encoding?
            s, bad, _ = EncodingSupport.sanitize_utf8(s, false)
            input.bad = bad
          end
          input.buf = s
          input.compute_windows if s.bytesize > Input::READ_CHUNK
          input
        end

        # xmlPushInput
        def push_input(input)
          return -1 if input.nil?

          max_depth = option?(PARSE_HUGE) ? 40 : 20
          if input_nr > max_depth
            fatal_err_msg(ErrCode::ERR_RESOURCE_LIMIT, "Maximum entity nesting depth exceeded")
            halt
            return -1
          end
          ret = input_push(input)
          grow
          ret
        end

        # xmlPopInput
        def pop_input
          return 0 if input_nr <= 1

          input_pop
          grow if cur_byte == 0
          cur_byte
        end

        # ---- node/name/space stacks ---------------------------------------------------------------

        # nodePush
        def node_push(value)
          max_depth = option?(PARSE_HUGE) ? 2048 : 256
          if @node_tab.length > max_depth
            fatal_err_msg_int(ErrCode::ERR_RESOURCE_LIMIT,
              "Excessive depth in document: #{@node_tab.length} use XML_PARSE_HUGE option\n", @node_tab.length)
            halt
            return -1
          end
          @node_tab << value
          @node = value
          @node_tab.length - 1
        end

        # nodePop
        def node_pop
          return nil if @node_tab.empty?

          ret = @node_tab.pop
          @node = @node_tab[-1]
          ret
        end

        def node_nr
          @node_tab.length
        end

        # nameNsPush
        def name_ns_push(value, prefix, uri, line, ns_nr)
          @name_tab << value
          @name = value
          @push_tab[@name_tab.length - 1] = StartTag.new(prefix, uri, line, ns_nr)
          @name_tab.length - 1
        end

        # nameNsPop
        def name_ns_pop
          return nil if @name_tab.empty?

          ret = @name_tab.pop
          @name = @name_tab[-1]
          ret
        end

        # namePush
        def name_push(value)
          @name_tab << value
          @name = value
          @name_tab.length - 1
        end

        # namePop
        def name_pop
          return nil if @name_tab.empty?

          ret = @name_tab.pop
          @name = @name_tab[-1]
          ret
        end

        def name_nr
          @name_tab.length
        end

        def space_push(val)
          @space_tab[@space_nr] = val
          @space_nr += 1
          @space_nr - 1
        end

        def space_pop
          return 0 if @space_nr <= 0

          @space_nr -= 1
          ret = @space_tab[@space_nr]
          @space_tab[@space_nr] = -1
          ret
        end

        def space_nr
          @space_nr
        end

        # ---- namespace database (xmlParserNs*) ------------------------------------------------------

        def ns_nr
          @ns_tab.length
        end

        def ns_reset
          @ns_hash = {}
          @ns_element_id = 0
          @ns_default_index = INT_MAX
        end

        # xmlParserNsStartElement
        def ns_start_element
          @ns_element_id += 1
          0
        end

        # xmlParserNsLookup
        def ns_lookup(prefix)
          return @ns_default_index if prefix.nil?

          @ns_hash.fetch(prefix, INT_MAX)
        end

        # xmlParserNsLookupUri
        def ns_lookup_uri(prefix)
          return Pure::XML_XML_NAMESPACE if prefix == "xml"

          idx = ns_lookup(prefix)
          return nil if idx == INT_MAX || idx < @min_ns_index

          ret = @ns_tab[idx][1]
          ret.empty? ? nil : ret
        end

        # xmlParserNsLookupSax
        def ns_lookup_sax(prefix)
          return nil if prefix == "xml"

          idx = ns_lookup(prefix)
          return nil if idx == INT_MAX || idx < @min_ns_index

          @ns_extra[idx][0]
        end

        # xmlParserNsUpdateSax
        def ns_update_sax(prefix, sax_data)
          return -1 if prefix == "xml"

          idx = ns_lookup(prefix)
          return -1 if idx == INT_MAX || idx < @min_ns_index

          @ns_extra[idx][0] = sax_data
          0
        end

        # xmlParserNsPush
        def ns_push(prefix, uri, sax_data, def_attr)
          return 0 if prefix == "xml"

          if prefix.nil?
            old_index = @ns_default_index
            if old_index != INT_MAX
              extra = @ns_extra[old_index]
              if extra[1] == @ns_element_id
                err_attribute_dup(nil, "xmlns") if def_attr == 0
                return 0
              end
              return 0 if option?(PARSE_NSCLEAN) && uri == @ns_tab[old_index][1]
            end
            @ns_default_index = @ns_tab.length
          else
            old_index = @ns_hash.fetch(prefix, INT_MAX)
            if old_index != INT_MAX
              extra = @ns_extra[old_index]
              if extra[1] == @ns_element_id
                err_attribute_dup("xmlns", prefix) if def_attr == 0
                return 0
              end
              return 0 if option?(PARSE_NSCLEAN) && uri == @ns_tab[old_index][1]
            end
            @ns_hash[prefix] = @ns_tab.length
          end
          @ns_tab << [prefix, uri]
          @ns_extra << [sax_data, @ns_element_id, old_index]
          1
        end

        # xmlParserNsPop
        def ns_pop(nr)
          i = @ns_tab.length - 1
          stop = @ns_tab.length - nr
          while i >= stop
            prefix = @ns_tab[i][0]
            old = @ns_extra[i][2]
            if prefix.nil?
              @ns_default_index = old
            elsif old == INT_MAX
              @ns_hash.delete(prefix)
            else
              @ns_hash[prefix] = old
            end
            i -= 1
          end
          @ns_tab.pop(nr)
          @ns_extra.pop(nr)
          nr
        end
      end
    end
  end
end
