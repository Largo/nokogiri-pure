# frozen_string_literal: true

require_relative "../parser/codes"

module Nokogiri
  module Pure
    module Schemas
      extend self

      # printf-style formatting of libxml2 messages: supports %s (nil -> "(null)"), %d/%i/%u,
      # %c and %%. Any other conversion is copied verbatim. Used where the C code passes a
      # message as a *format* (so that e.g. "%%" in a built message collapses to "%").
      def c_format(fmt, *args)
        return fmt if !fmt.include?("%")

        out = +""
        i = 0
        ai = 0
        n = fmt.bytesize
        bytes = fmt.b
        while i < n
          c = bytes.getbyte(i)
          if c != 37 # '%'
            j = bytes.index("%", i) || n
            out << bytes.byteslice(i, j - i)
            i = j
            next
          end
          # parse %[flags][width][.prec][l]conv
          j = i + 1
          j += 1 while j < n && "-+ #0123456789.l".include?(bytes.getbyte(j).chr)
          conv = j < n ? bytes.getbyte(j).chr : ""
          case conv
          when "%"
            out << "%"
          when "s"
            a = args[ai]
            ai += 1
            out << (a.nil? ? "(null)" : a.to_s.b)
          when "d", "i", "u", "l"
            a = args[ai]
            ai += 1
            spec = bytes.byteslice(i, j - i + 1).delete("l")
            out << format(spec.tr("iu", "dd"), a.to_i)
          when "c"
            a = args[ai]
            ai += 1
            out << (a.is_a?(Integer) ? a.chr : a.to_s)
          else
            out << bytes.byteslice(i, j - i + 1)
          end
          i = j + 1
        end
        out.force_encoding(Encoding::UTF_8)
      end

      # xmlEscapeFormatString: double every '%'
      def escape_format_string(str)
        return nil if str.nil?

        str.include?("%") ? str.gsub("%", "%%") : str
      end

      # xmlVRaiseError + xmlVUpdateError. +schannel+ is a callable (the context's structured
      # error handler) or nil, in which case the global Pure::Errors handler is used.
      # +msg+ is the *already formatted* message.
      def raise_error(schannel, node, domain, code, level, file, line, str1, str2, str3, int1, col, msg)
        return 0 if code == 0

        if node
          10.times do
            break if node.type == ELEMENT_NODE || node.parent.nil?

            node = node.parent
          end
          if node.is_a?(XmlNode)
            file = node.doc.url if file.nil? && node.doc
            if line.nil? || line == 0
              line = node.line if node.type == ELEMENT_NODE
              line = Tree.get_line_no(node) if line.nil? || line == 0 || line == 65535
            end
          end
        end
        err = XmlError.new(domain: domain, code: code, message: msg, level: level, file: file,
          line: line || 0, str1: str1, str2: str2, str3: str3, int1: int1 || 0, node: node)
        err.int2 = col || 0
        if schannel
          schannel.call(err)
        else
          Errors.report(err)
        end
        0
      end

      # Hook used by xmlSchemaAddSchemaDoc: emulates
      #   parserCtxt = xmlNewParserCtxt(); xmlCtxtSetErrorHandler(parserCtxt, pctxt->serror)
      #   doc = xmlCtxtReadFile(parserCtxt, location, NULL, XML_PARSE_NOENT)   (location given)
      #   doc = xmlCtxtReadMemory(parserCtxt, buffer, ..., XML_PARSE_NOENT)   (buffer given)
      # Returns [doc_or_nil, last_error] where last_error is the Pure::XmlError that
      # xmlGetLastError() would return afterwards (or nil).
      def read_schema_doc(pctxt, location, buffer)
        errors = []
        handler = ->(err) do
          errors << err
          pctxt&.serror ? pctxt.serror.call(err) : Errors.report(err)
        end
        doc = nil
        Errors.with_handler(handler) do
          doc = if location
            Schemas.read_file_hook(location, PARSE_NOENT, pctxt)
          else
            Schemas.read_memory_hook(buffer, PARSE_NOENT, pctxt)
          end
        end
        [doc, errors.last]
      end

      PARSE_NOENT = 1 << 1
      PARSE_NONET = 1 << 11

      # Nonet state (xmlNoNetExternalEntityLoader), set by the glue around xmlSchemaParse
      def nonet? = Thread.current[:__nokogiri_pure_schemas_nonet] ? true : false

      def with_nonet(flag)
        saved = Thread.current[:__nokogiri_pure_schemas_nonet]
        Thread.current[:__nokogiri_pure_schemas_nonet] = flag
        yield
      ensure
        Thread.current[:__nokogiri_pure_schemas_nonet] = saved
      end
    end
  end
end
