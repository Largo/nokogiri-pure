# frozen_string_literal: true

module Nokogiri
  module Pure
    # Character encoding handlers (libxml2 encoding.c). libxml2 uses iconv for anything that's not
    # built in; we use Ruby's transcoders for that.
    module Enc
      # A libxml2 xmlCharEncodingHandler. +kind+ is one of :utf8, :utf16le, :utf16be, :utf16 (LE with
      # BOM on output), :latin1, :ascii, :html (output-only, UTF8ToHtml), :ruby (use +ruby_encoding+).
      Handler = Struct.new(:name, :kind, :ruby_encoding) do
        def utf8?
          kind == :utf8
        end

        # UTF-8 -> target bytes. Unencodable chars become "&#NNN;" (xmlCharEncOutput's fallback).
        def encode_output(str, init: false)
          str = str.dup.force_encoding(Encoding::UTF_8)
          case kind
          when :utf8
            str.b
          when :html
            out = +"".b
            str.each_char do |ch|
              cp = ch.ord
              if cp < 0x80
                out << ch
              else
                ent = HTMLParser.respond_to?(:entity_value_lookup) ? HTMLParser.entity_value_lookup(cp) : nil
                out << (ent ? "&#{ent.name};" : "&##{cp};")
              end
            end
            out
          when :utf16
            bom = init ? "\xFF\xFE".b : "".b
            bom + Enc.transcode_with_charrefs(str, Encoding::UTF_16LE)
          else
            Enc.transcode_with_charrefs(str, ruby_encoding)
          end
        end

        # target bytes -> UTF-8 string (invalid sequences raise ArgumentError)
        def decode_input(bytes)
          bytes = bytes.b
          case kind
          when :utf8 then bytes.force_encoding(Encoding::UTF_8)
          when :utf16 then decode_utf16(bytes)
          when :utf16le then bytes.force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8)
          when :utf16be then bytes.force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8)
          when :html then bytes.force_encoding(Encoding::UTF_8)
          else bytes.force_encoding(ruby_encoding).encode(Encoding::UTF_8)
          end
        end

        private def decode_utf16(bytes)
          if bytes.start_with?("\xFE\xFF".b)
            bytes.byteslice(2..).force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8)
          elsif bytes.start_with?("\xFF\xFE".b)
            bytes.byteslice(2..).force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8)
          else
            bytes.force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8)
          end
        end
      end

      BUILTIN = {
        "UTF-8" => [:utf8, Encoding::UTF_8],
        "UTF8" => [:utf8, Encoding::UTF_8, "UTF-8"],
        "UTF-16" => [:utf16, Encoding::UTF_16LE],
        "UTF16" => [:utf16, Encoding::UTF_16LE, "UTF-16"],
        "UTF-16LE" => [:utf16le, Encoding::UTF_16LE],
        "UTF-16BE" => [:utf16be, Encoding::UTF_16BE],
        "ISO-8859-1" => [:latin1, Encoding::ISO_8859_1],
        "ISO-LATIN-1" => [:latin1, Encoding::ISO_8859_1, "ISO-8859-1"],
        "ISO LATIN 1" => [:latin1, Encoding::ISO_8859_1, "ISO-8859-1"],
        "ASCII" => [:ascii, Encoding::US_ASCII],
        "US-ASCII" => [:ascii, Encoding::US_ASCII],
      }.freeze

      @aliases = {}

      class << self
        attr_reader :aliases

        # xmlAddEncodingAlias
        def add_alias(name, alias_name)
          @aliases[alias_name.upcase] = name
          0
        end

        # xmlDelEncodingAlias: 0 on success, -1 if not found
        def del_alias(alias_name)
          @aliases.delete(alias_name.upcase) ? 0 : -1
        end

        def get_alias(name)
          @aliases[name.upcase]
        end

        def clear_aliases
          @aliases.clear
        end

        # xmlFindCharEncodingHandler / xmlOpenCharEncodingHandler
        def find_handler(name, output: false)
          return nil if name.nil? || name.empty?

          if (target = get_alias(name))
            name = target
          end
          up = name.upcase
          if (b = BUILTIN[up])
            return Handler.new(b[2] || up, b[0], b[1])
          end
          return Handler.new("HTML", :html, Encoding::UTF_8) if output && up == "HTML"

          renc = ruby_encoding_for(name)
          return nil if renc.nil? || renc.dummy? && !renc.name.start_with?("UTF-16", "UTF-32", "ISO-2022")

          Handler.new(name, :ruby, renc)
        end

        def ruby_encoding_for(name)
          case name.upcase
          when "UCS-4", "UCS4", "ISO-10646-UCS-4" then Encoding::UTF_32BE
          when "UCS-2", "UCS2", "ISO-10646-UCS-2" then Encoding::UTF_16BE
          when "UCS-4LE" then Encoding::UTF_32LE
          when "UCS-4BE" then Encoding::UTF_32BE
          when "UTF-32" then Encoding::UTF_32BE
          else
            Encoding.find(name)
          end
        rescue ArgumentError
          nil
        end

        def transcode_with_charrefs(str, enc)
          str.encode(enc, fallback: ->(ch) { "&##{ch.ord};".encode(enc) }).b
        rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError, Encoding::ConverterNotFoundError
          out = +"".b
          str.each_char do |ch|
            out << ch.encode(enc).b
          rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
            out << "&##{ch.ord};".encode(enc).b
          end
          out
        end
      end
    end
  end
end
