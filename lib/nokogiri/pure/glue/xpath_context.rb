# frozen_string_literal: true

# Port of ext/nokogiri/xml_xpath_context.c

module Nokogiri
  module Pure
    module XPath
      NOKOGIRI_PREFIX = "nokogiri"
      NOKOGIRI_URI = "http://www.nokogiri.org/default_ns/ruby/extensions_functions"
      NOKOGIRI_BUILTIN_PREFIX = "nokogiri-builtin"
      NOKOGIRI_BUILTIN_URI = "https://www.nokogiri.org/default_ns/ruby/builtins"

      module_function

      # _noko_xml_xpath_context__css_class: find a CSS class in a `class` attribute value
      CSS_CLASS_RE = {}
      BLANK_BYTES_RE = /[ \t\n\r]/n

      def css_class_match?(str, val)
        return false if str.nil? || val.nil?

        vb = val.b
        if !vb.empty? && !BLANK_BYTES_RE.match?(vb)
          # a blank-free class name matches iff it equals one of the blank-separated words
          re = CSS_CLASS_RE[vb] ||= begin
            CSS_CLASS_RE.clear if CSS_CLASS_RE.size > 1000
            /(?:\A|[ \t\n\r])#{Regexp.escape(vb)}(?:[ \t\n\r]|\z)/n
          end
          return re.match?(str.b)
        end

        val_len = vb.bytesize
        return true if val_len == 0

        sb = str.b
        len = sb.bytesize
        i = 0
        while i < len
          if sb.getbyte(i) == vb.getbyte(0) && sb.byteslice(i, val_len) == vb
            nb = sb.getbyte(i + val_len)
            return true if nb.nil? || nb == 0x20 || nb == 0x09 || nb == 0x0A || nb == 0x0D
          end
          # advance to whitespace
          while i < len && !((c = sb.getbyte(i)) == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D)
            i += 1
          end
          # advance to start of next word
          while i < len && ((c = sb.getbyte(i)) == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D)
            i += 1
          end
        end
        false
      end

      # noko_xml_xpath_context_xpath_func_css_class
      CSS_CLASS_FUNC = lambda do |ctxt, nargs|
        ctxt.check_arity(nargs, 2)
        ctxt.cast_top_to_string
        needle = ctxt.value_pop
        ctxt.xp_error(INVALID_TYPE) if needle.nil? || !needle.is_a?(String)
        ctxt.cast_top_to_string
        hay = ctxt.value_pop
        ctxt.xp_error(INVALID_TYPE) if hay.nil? || !hay.is_a?(String)
        ctxt.value_push(XPath.css_class_match?(hay, needle))
      end

      # noko_xml_xpath_context_xpath_func_local_name_is
      LOCAL_NAME_IS_FUNC = lambda do |ctxt, nargs|
        ctxt.check_arity(nargs, 1)
        ctxt.cast_top_to_string
        ctxt.check_type_string
        element_name = ctxt.value_pop
        node = ctxt.context.node
        # (an xmlNs read through an xmlNode pointer yields its href as "name")
        name = node.is_a?(XmlNs) ? node.href : node.name
        ctxt.value_push(!name.nil? && name == element_name)
      end

      PURE_FUNCS[CSS_CLASS_FUNC] = true
      PURE_FUNCS[LOCAL_NAME_IS_FUNC] = true

      # _noko_xml_xpath_context__xpath2ruby: returns the Ruby object, or :undef
      def xpath2ruby(obj, context)
        case obj
        when ValueTree
          :undef
        when String
          obj.dup.force_encoding(::Encoding::UTF_8)
        when Array
          Pure.wrap_node_set(obj, context.doc._ruby_doc)
        when Float
          obj
        when true, false
          obj
        else
          :undef
        end
      end

      # Nokogiri_marshal_xpath_funcall_and_return_values
      def marshal_funcall(ctxt, argc, handler, method_name)
        argv = Array.new(argc)
        (argc - 1).downto(0) do |j|
          obj = ctxt.value_pop
          argv[j] = xpath2ruby(obj, ctxt.context)
          argv[j] = XPath.cast_to_string(obj).dup.force_encoding(::Encoding::UTF_8) if argv[j] == :undef
        end

        rb_retval = handler.__send__(method_name, *argv)

        case rb_retval
        when Float, Integer
          ctxt.value_push(rb_retval.to_f)
        when String
          ctxt.value_push(Pure::XPath.string_value_cstr(rb_retval).dup.force_encoding(::Encoding::UTF_8))
        when true
          ctxt.value_push(true)
        when false
          ctxt.value_push(false)
        when nil
          # nothing pushed
        when Array
          rb_node_set = Nokogiri::XML::NodeSet.new(ctxt.context.doc._ruby_doc, rb_retval)
          ctxt.value_push(XPath.node_set_merge(nil, Pure.node_set_nodes(rb_node_set)))
        when Nokogiri::XML::NodeSet
          ctxt.value_push(XPath.node_set_merge(nil, Pure.node_set_nodes(rb_retval)))
        else
          raise RuntimeError, "Invalid return type"
        end
      end

      # _noko_xml_xpath_context__handler_invoker
      def handler_invoker(handler)
        lambda do |ctxt, nargs|
          XPath.marshal_funcall(ctxt, nargs, handler, ctxt.context.function)
        end
      end

      DEPRECATED_UNNAMESPACED_MSG = "A custom XPath or CSS handler function named '%s' is being invoked " \
        "without a namespace. Please update your query to reference this function as 'nokogiri:%s'. " \
        "Invoking custom handler functions without a namespace is deprecated and will become an error " \
        "in Nokogiri v1.17.0."

      # rb_category_warning(RB_WARN_CATEGORY_DEPRECATED, ...): only when $VERBOSE is true
      def warn_deprecation(msg)
        return unless $VERBOSE
        return unless Warning[:deprecated]

        loc = caller_locations.find { |l| !l.path.to_s.include?("/nokogiri/pure/") }
        prefix = loc ? "#{loc.path}:#{loc.lineno}: " : ""
        Warning.warn("#{prefix}warning: #{msg}\n", category: :deprecated)
      end

      # _noko_xml_xpath_context_handler_lookup
      def handler_lookup(handler)
        invoker = nil
        lambda do |_data, name, ns_uri|
          if handler.respond_to?(name)
            if ns_uri.nil?
              XPath.warn_deprecation(format(DEPRECATED_UNNAMESPACED_MSG, name, name))
            end
            invoker ||= XPath.handler_invoker(handler)
          end
        end
      end

      # StringValueCStr
      def string_value_cstr(value)
        str = value.is_a?(String) ? value : ::String.try_convert(value)
        raise TypeError, "no implicit conversion of #{value.nil? ? "nil" : value.class} into String" if str.nil?
        raise ArgumentError, "string contains null byte" if str.include?("\0")

        str
      end
    end
  end

  module XML
    class XPathContext
      class << self
        # noko_xml_xpath_context_new
        def new(rb_node)
          c_node = Pure.unwrap(rb_node)
          c_context = Pure::XPath::Context.new(c_node.doc)
          c_context.node = c_node
          c_context.register_ns(Pure::XPath::NOKOGIRI_PREFIX, Pure::XPath::NOKOGIRI_URI)
          c_context.register_ns(Pure::XPath::NOKOGIRI_BUILTIN_PREFIX, Pure::XPath::NOKOGIRI_BUILTIN_URI)
          c_context.register_func_ns("css-class", Pure::XPath::NOKOGIRI_BUILTIN_URI, Pure::XPath::CSS_CLASS_FUNC)
          c_context.register_func_ns("local-name-is", Pure::XPath::NOKOGIRI_BUILTIN_URI,
            Pure::XPath::LOCAL_NAME_IS_FUNC)
          rb_context = allocate
          rb_context.instance_variable_set(:@__native, c_context)
          rb_context
        end

        private :allocate
      end

      # noko_xml_xpath_context_register_ns
      def register_ns(prefix, uri)
        c_context = __context
        ns_uri = uri.nil? ? nil : Pure::XPath.string_value_cstr(uri)
        c_context.register_ns(Pure::XPath.string_value_cstr(prefix), ns_uri)
        self
      end

      # noko_xml_xpath_context_register_variable
      def register_variable(name, value)
        c_context = __context
        xml_value = value.nil? ? nil : Pure::XPath.string_value_cstr(value).dup.force_encoding(::Encoding::UTF_8).freeze
        c_context.register_variable(Pure::XPath.string_value_cstr(name).dup.freeze, xml_value)
        self
      end

      # noko_xml_xpath_context_evaluate
      def evaluate(*args)
        unless args.length == 1 || args.length == 2
          raise ArgumentError, "wrong number of arguments (given #{args.length}, expected 1..2)"
        end

        rb_expression, rb_function_lookup_handler = args
        c_context = __context
        c_expression_str = Pure::XPath.string_value_cstr(rb_expression)

        unless rb_function_lookup_handler.nil?
          c_context.user_data = rb_function_lookup_handler
          c_context.register_func_lookup(Pure::XPath.handler_lookup(rb_function_lookup_handler),
            rb_function_lookup_handler)
        end

        rb_errors = []
        Pure::Errors.handler = ->(err) { rb_errors << Pure.wrap_error(err) }
        begin
          c_xpath_object = Pure::XPath.eval_expression(c_expression_str, c_context)
        ensure
          Pure::Errors.handler = nil
          c_context.register_func_lookup(nil, nil)
        end

        if c_xpath_object.nil?
          raise rb_errors[0] if rb_errors[0]

          raise TypeError, "exception class/object expected"
        end

        rb_xpath_object = Pure::XPath.xpath2ruby(c_xpath_object, c_context)
        rb_xpath_object = Pure.wrap_node_set(nil, c_context.doc._ruby_doc) if rb_xpath_object == :undef
        rb_xpath_object
      end

      # noko_xml_xpath_context_set_node
      def node=(rb_node)
        c_context = __context
        c_node = Pure.unwrap(rb_node)
        c_context.doc = c_node.doc
        c_context.node = c_node
        rb_node
      end

      private

      def __context
        @__native or raise TypeError, "wrong argument type #{self.class} (expected xmlXPathContext)"
      end
    end
  end
end
