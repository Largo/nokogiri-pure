# frozen_string_literal: true

# Port of ext/nokogiri/html4_document.c

require_relative "../html_parser"

module Nokogiri
  module HTML4
    class Document < Nokogiri::XML::Document
      class << self
        # new(uri=nil, external_id=nil) → HTML4::Document
        def new(*args)
          uri = args[0]
          external_id = args[1]
          doc = Nokogiri::Pure::HTMLParser.new_doc(
            uri ? uri.to_str : nil,
            external_id ? external_id.to_str : nil,
          )
          Nokogiri::Pure.wrap_document(self, doc, args)
        end

        # read_io(io, url, encoding, options)
        def read_io(io, url, encoding, options)
          c_url = url.nil? ? nil : url.to_str
          c_encoding = encoding.nil? ? nil : encoding.to_str
          options = Integer(options)
          error_list = []

          c_doc = Nokogiri::Pure::Errors.collecting_then_clear(error_list) do
            Nokogiri::Pure::HTMLParser.read_io(Nokogiri::Pure::HTMLParser.io_reader(io), c_url, c_encoding, options)
          end

          # If EncodingFound has occurred in EncodingReader, propagate the error.
          if io.respond_to?(:encoding_found)
            encoding_found = io.encoding_found
            raise encoding_found unless encoding_found.nil?
          end

          Nokogiri::HTML4::Document.__send__(:html4_check_errors, c_doc, error_list, options)
          rb_doc = Nokogiri::Pure.wrap_document(self, c_doc)
          rb_doc.instance_variable_set(:@errors, error_list)
          rb_doc
        end

        # read_memory(string, url, encoding, options)
        def read_memory(html, url, encoding, options)
          c_buffer = html.to_str
          c_url = url.nil? ? nil : url.to_str
          c_encoding = encoding.nil? ? nil : encoding.to_str
          options = Integer(options)
          error_list = []

          c_doc = Nokogiri::Pure::Errors.collecting_then_clear(error_list) do
            Nokogiri::Pure::HTMLParser.read_memory(c_buffer, c_url, c_encoding, options)
          end

          Nokogiri::HTML4::Document.__send__(:html4_check_errors, c_doc, error_list, options)
          rb_doc = Nokogiri::Pure.wrap_document(self, c_doc)
          rb_doc.instance_variable_set(:@errors, error_list)
          rb_doc
        end

        private

        def html4_check_errors(c_doc, error_list, options)
          if c_doc.nil? || ((options & Nokogiri::Pure::HTMLParser::PARSE_RECOVER) == 0 && !error_list.empty?)
            rb_error = error_list[0]
            if rb_error.nil?
              raise RuntimeError, "Could not parse document"
            else
              raise Nokogiri::XML::SyntaxError,
                "Parser without recover option encountered error or warning: #{rb_error}"
            end
          end
        end
      end

      # The type for this document
      def type
        Nokogiri::Pure.unwrap(self).type
      end
    end
  end
end
