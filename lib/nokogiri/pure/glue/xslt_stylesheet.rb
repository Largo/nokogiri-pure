# frozen_string_literal: true

# Port of ext/nokogiri/xslt_stylesheet.c: Nokogiri::XSLT.register and Nokogiri::XSLT::Stylesheet.

module Nokogiri
  module Pure
    module XSLTGlue
      module_function

      DOMAIN_NAMES = {
        Domain::PARSER => "parser ", Domain::TREE => "tree ", Domain::NAMESPACE => "namespace ",
        Domain::DTD => "validity ", Domain::HTML => "HTML parser ", Domain::MEMORY => "memory ",
        Domain::OUTPUT => "output ", Domain::IO => "I/O ", Domain::XINCLUDE => "XInclude ",
        Domain::XPATH => "XPath ", Domain::XPOINTER => "parser ", Domain::REGEXP => "regexp ",
        Domain::MODULE => "module ", Domain::SCHEMASV => "Schemas validity ",
        Domain::SCHEMASP => "Schemas parser ", Domain::RELAXNGP => "Relax-NG parser ",
        Domain::RELAXNGV => "Relax-NG validity ", Domain::CATALOG => "Catalog ", Domain::C14N => "C14N ",
        Domain::XSLT => "XSLT ", Domain::I18N => "encoding ", Domain::SCHEMATRONV => "schematron ",
        Domain::BUFFER => "internal buffer ", Domain::URI => "URI ",
      }.freeze

      # libxml2's xmlReportError-style formatting (used for errors raised through a parser
      # context, whose channel is xmlParserError/xmlParserWarning)
      def report_error_text(err)
        out = +""
        if err.file
          out << "#{err.file}:#{err.line}: "
        elsif err.line != 0 && err.domain == Domain::PARSER
          out << "Entity: line #{err.line}: "
        end
        out << (DOMAIN_NAMES[err.domain] || "")
        out << case err.level
        when Level::WARNING then "warning : "
        when Level::ERROR, Level::FATAL
          err.domain == Domain::DTD || err.domain == Domain::VALID ? "validity error : " : "error : "
        else ""
        end
        out << err.message.to_s
        out
      end

      # how an XmlError reaches xmlGenericError when no structured handler is installed
      def generic_text(err)
        return report_error_text(err) if err.ctxt

        err.message.to_s
      end

      def wrap_stylesheet(klass, ss)
        obj = Class.instance_method(:allocate).bind_call(klass)
        obj.instance_variable_set(:@__native, ss)
        obj.instance_variable_set(:@func_instances, [])
        ss._private = obj
        obj
      end

      # initFunc
      def init_func(ctxt, uri)
        modules = Nokogiri::XSLT.instance_variable_get(:@modules)
        obj = modules[uri]
        methods = obj.instance_methods(false)
        methods.each do |method_name|
          XSLT.register_ext_function(ctxt, method_name.to_s, uri,
            ->(pctxt, nargs) { method_caller(pctxt, nargs) })
        end
        wrapper = ctxt.style._private
        inst = obj.new
        wrapper.instance_variable_get(:@func_instances) << inst
        inst
      end

      # shutdownFunc
      def shutdown_func(ctxt, _uri, _data)
        wrapper = ctxt.style._private
        wrapper.instance_variable_get(:@func_instances).clear
      end

      # method_caller
      def method_caller(pctxt, nargs)
        transform = XSLT.xpath_get_transform_context(pctxt)
        function_uri = pctxt.context.function_uri
        handler = XSLT.get_ext_data(transform, function_uri)
        function_name = pctxt.context.function
        XPath.marshal_funcall(pctxt, nargs, handler, function_name)
      end

      # noko_xml_document_has_wrapped_blank_nodes_p
      def has_wrapped_blank_nodes?(c_document)
        rb_doc = c_document._ruby_doc
        return false if rb_doc.nil?

        cache = rb_doc.instance_variable_get(:@node_cache)
        return false if cache.nil?

        cache.any? do |rb_node|
          node = rb_node.instance_variable_get(:@__native)
          node && Tree.is_blank_node(node)
        end
      end

      INIT_FUNC = ->(ctxt, uri) { XSLTGlue.init_func(ctxt, uri) }
      SHUTDOWN_FUNC = ->(ctxt, uri, data) { XSLTGlue.shutdown_func(ctxt, uri, data) }

      # errors libxml2 would print on stderr (no handler installed while compiling a stylesheet)
      STDERR_HANDLER = lambda do |err|
        next if err.nil?

        $stderr.write("#{DOMAIN_NAMES[err.domain]}#{err.level == Level::WARNING ? "warning" : "error"} : #{err.message}")
      end
    end
  end

  module XSLT
    @modules = {}

    class << self
      # rb_xslt_s_register
      def register(uri, obj)
        modules = instance_variable_get(:@modules)
        raise RuntimeError, "internal error: @modules not set" if modules.nil?

        modules[uri] = obj
        Pure::XSLT.register_ext_module(
          Pure::XPath.string_value_cstr(uri).dup,
          Pure::XSLTGlue::INIT_FUNC,
          Pure::XSLTGlue::SHUTDOWN_FUNC,
        )
        self
      end
    end

    class Stylesheet
      class << self
        undef_method :allocate rescue nil

        # parse_stylesheet_doc
        def parse_stylesheet_doc(xmldocobj)
          xml = Pure.unwrap_document(xmldocobj)
          errstr = +""
          ss = nil
          Pure::XSLT.with_generic_error_func(->(msg) { errstr << msg }) do
            Pure::Errors.with_handler(Pure::XSLTGlue::STDERR_HANDLER) do
              xml_cpy = Pure::Tree.copy_doc(xml, 1)
              ss = Pure::XSLT.parse_stylesheet_doc(xml_cpy)
            end
          end
          raise RuntimeError, errstr if ss.nil?

          Pure::XSLTGlue.wrap_stylesheet(self, ss)
        end
      end

      # rb_xslt_stylesheet_serialize
      def serialize(xmlobj)
        xml = Pure.unwrap_document(xmlobj)
        ss = Pure.unwrap(self)
        bytes = Pure::XSLT.save_result_to_string(xml, ss)
        bytes.force_encoding(::Encoding::UTF_8)
      end

      # rb_xslt_stylesheet_transform
      def transform(*args)
        raise ArgumentError, "wrong number of arguments (given #{args.length}, expected 1..2)" unless (1..2).cover?(args.length)

        rb_document, rb_param = args
        rb_param = [] if rb_param.nil?
        unless rb_document.is_a?(Nokogiri::XML::Document)
          raise ArgumentError, "argument must be a Nokogiri::XML::Document"
        end

        rb_param = rb_param.to_a.flatten if rb_param.is_a?(Hash)
        unless rb_param.is_a?(Array)
          raise TypeError, "wrong argument type #{rb_param.class} (expected Array)"
        end

        c_document = Pure.unwrap_document(rb_document)
        ss = Pure.unwrap(self)
        params = rb_param.map { |entry| Pure::XPath.string_value_cstr(entry).dup }

        need_space = false
        st = ss
        while st
          if st.strip_spaces
            need_space = true
            break
          end
          st = Pure::XSLT.next_import(st)
        end
        if need_space && Pure::XSLTGlue.has_wrapped_blank_nodes?(c_document)
          c_document = Pure::Tree.copy_doc(c_document, 1)
        end

        rb_error_str = +""
        append = ->(msg) { rb_error_str << msg }
        c_result_document = nil
        saved_generic = Thread.current[:__nokogiri_pure_xml_generic_error]
        Thread.current[:__nokogiri_pure_xml_generic_error] = append
        begin
          Pure::XSLT.with_generic_error_func(append) do
            Pure::Errors.with_handler(->(err) { rb_error_str << Pure::XSLTGlue.generic_text(err) if err }) do
              c_result_document = Pure::XSLT.apply_stylesheet(ss, c_document, params)
            end
          end
        ensure
          Thread.current[:__nokogiri_pure_xml_generic_error] = saved_generic
        end

        raise RuntimeError, rb_error_str unless rb_error_str.empty?

        Pure.wrap_document(Nokogiri::XML::Document, c_result_document)
      end
    end
  end
end
