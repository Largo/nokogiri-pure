# frozen_string_literal: true

module Nokogiri
  module Pure
    # xmlErrorDomain
    module Domain
      NONE = 0
      PARSER = 1
      TREE = 2
      NAMESPACE = 3
      DTD = 4
      HTML = 5
      MEMORY = 6
      OUTPUT = 7
      IO = 8
      FTP = 9
      HTTP = 10
      XINCLUDE = 11
      XPATH = 12
      XPOINTER = 13
      REGEXP = 14
      DATATYPE = 15
      SCHEMASP = 16
      SCHEMASV = 17
      RELAXNGP = 18
      RELAXNGV = 19
      CATALOG = 20
      C14N = 21
      XSLT = 22
      VALID = 23
      CHECK = 24
      WRITER = 25
      MODULE = 26
      I18N = 27
      SCHEMATRONV = 28
      BUFFER = 29
      URI = 30
    end

    # xmlErrorLevel
    module Level
      NONE = 0
      WARNING = 1
      ERROR = 2
      FATAL = 3
    end

    # xmlError
    class XmlError
      attr_accessor :domain, :code, :message, :level, :file, :line, :str1, :str2, :str3, :int1, :int2, :node, :ctxt

      def initialize(domain: 0, code: 0, message: nil, level: Level::ERROR, file: nil, line: 0,
        str1: nil, str2: nil, str3: nil, int1: 0, int2: 0, node: nil)
        @domain = domain
        @code = code
        @message = message
        @level = level
        @file = file
        @line = line
        @str1 = str1
        @str2 = str2
        @str3 = str3
        @int1 = int1
        @int2 = int2
        @node = node
      end

      def inspect
        "#<Pure::XmlError #{@domain}/#{@code} L#{@level} #{@line}:#{@int2} #{@message.inspect}>"
      end
    end

    # Emulates libxml2's global structured error handler (xmlSetStructuredErrorFunc), per thread.
    module Errors
      module_function

      def handler
        Thread.current[:__nokogiri_pure_error_handler]
      end

      def handler=(h)
        Thread.current[:__nokogiri_pure_error_handler] = h
      end

      # Run the block with +h+ (a callable taking an XmlError) installed as the structured handler.
      def with_handler(h)
        saved = handler
        self.handler = h
        begin
          yield
        ensure
          self.handler = saved
        end
      end

      # Run the block collecting Nokogiri::XML::SyntaxError objects into +list+ (noko__error_array_pusher)
      def collecting(list, &block)
        with_handler(->(err) { list << Pure.wrap_error(err) }, &block)
      end

      # xmlVUpdateError: derive file/line from the error's node (walking up to an element)
      def fill_location(err)
        node = err.node
        return err if node.nil? || !node.respond_to?(:parent)

        10.times do
          break if node.type == ELEMENT_NODE || node.parent.nil?

          node = node.parent
        end
        err.node = node
        err.file ||= node.doc.url if node.doc.respond_to?(:url)
        if err.line.nil? || err.line == 0
          line = node.type == ELEMENT_NODE ? node.line : 0
          line = Tree.get_line_no(node) if line == 0 || line == 65535
          err.line = line
        end
        err
      end

      def report(err)
        fill_location(err)
        h = handler
        h&.call(err)
        err
      end
    end

    module_function

    # noko_xml_syntax_error__wrap
    def wrap_error(error)
      klass = if error && error.domain == Domain::XPATH
        Nokogiri::XML::XPath::SyntaxError
      else
        Nokogiri::XML::SyntaxError
      end
      msg = error&.message
      e = klass.new(msg)
      if error
        path = error.node ? Tree.get_node_path(error.node) : nil
        e.instance_variable_set(:@domain, error.domain)
        e.instance_variable_set(:@code, error.code)
        e.instance_variable_set(:@level, error.level)
        e.instance_variable_set(:@file, error.file)
        e.instance_variable_set(:@line, error.line)
        e.instance_variable_set(:@path, path)
        e.instance_variable_set(:@str1, error.str1)
        e.instance_variable_set(:@str2, error.str2)
        e.instance_variable_set(:@str3, error.str3)
        e.instance_variable_set(:@int1, error.int1)
        e.instance_variable_set(:@column, error.int2)
      end
      e
    end
  end
end
