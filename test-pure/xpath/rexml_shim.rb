# frozen_string_literal: true

# Scratch shim (tests only): until the pure XML parser lands, parse XML documents via REXML so
# upstream XPath/CSS tests can run. Loaded with -r before the tests.
require "nokogiri"
require_relative "tree_builder"

unless defined?(Nokogiri::Pure::Parser)
  class Nokogiri::XML::Document
    class << self
      def read_memory(string, url, encoding, options)
        doc = XPathScratch.parse(string.to_s)
        Nokogiri::Pure.unwrap(doc).url = url
        doc
      rescue REXML::ParseException => e
        raise Nokogiri::XML::SyntaxError, e.message
      end

      def read_io(io, url, encoding, options)
        read_memory(io.read, url, encoding, options)
      end
    end
  end
end
