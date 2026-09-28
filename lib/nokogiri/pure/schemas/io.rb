# frozen_string_literal: true

require_relative "common"

# Loading of schema documents (xmlCtxtReadFile / xmlCtxtReadMemory as used by
# xmlSchemaAddSchemaDoc) on top of the pure XML parser.
module Nokogiri
  module Pure
    module Schemas
      # hook for tests before the parser exists: a callable(content, url, options) -> XmlDoc
      class << self
        attr_accessor :parse_memory_override
      end

      def self.parse_memory(content, url, options)
        if parse_memory_override
          parse_memory_override.call(content, url, options)
        else
          Pure::Parser.read_memory(content, url, nil, options)
        end
      end

      # xmlCtxtReadFile(ctxt, location, NULL, options)
      def self.read_file_hook(location, options, _pctxt)
        if Pure.const_defined?(:Parser) && Pure::Parser.respond_to?(:read_file) && parse_memory_override.nil?
          return Pure::Parser.read_file(location, nil, options | (nonet? ? PARSE_NONET : 0))
        end

        path = location_to_path(location)
        if path.nil?
          io_error(location, network: location.match?(%r{\A[a-z][a-z0-9+.-]*://}i) && nonet?)
          return nil
        end
        content = begin
          File.binread(path)
        rescue SystemCallError
          io_error(location)
          return nil
        end
        parse_memory(content, location, options)
      end

      # xmlCtxtReadMemory(ctxt, buffer, len, NULL, NULL, options)
      def self.read_memory_hook(buffer, options, _pctxt)
        parse_memory(buffer, nil, options)
      end

      def self.location_to_path(location)
        return nil if location.nil?

        if location.start_with?("file://localhost/")
          location.sub("file://localhost", "")
        elsif location.start_with?("file:///")
          location.sub("file://", "")
        elsif location.start_with?("file:/")
          location.sub("file:", "")
        elsif location.match?(%r{\A[a-z][a-z0-9+.-]*:}i) && !location.match?(%r{\A[a-z]:[\\/]}i)
          nil
        else
          location
        end
      end

      # emulate the IO error libxml2 raises for an unloadable resource (xmlLoadResource)
      def self.io_error(location, network: false)
        if network
          err = XmlError.new(domain: Domain::IO, code: ErrCode::IO_NETWORK_ATTEMPT, level: Level::ERROR,
            message: "Attempt to load network entity #{location}\n", str1: location)
        else
          err = XmlError.new(domain: Domain::IO, code: ErrCode::IO_LOAD_ERROR, level: Level::WARNING,
            message: "failed to load \"#{location}\": No such file or directory\n", str1: location)
        end
        Errors.report(err)
      end
    end
  end
end
