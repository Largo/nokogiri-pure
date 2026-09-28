# frozen_string_literal: true

# Pure-Ruby replacement for Nokogiri's C extension.
#
# The C extension is a thin layer ("glue") over libxml2, libxslt and gumbo. This file and the files
# under nokogiri/pure/ replace both: `nokogiri/pure/*.rb` is a Ruby port of the parts of those
# libraries that Nokogiri uses, and `nokogiri/pure/glue/*.rb` ports the glue itself, defining the
# same classes and methods that ext/nokogiri/*.c defines.

require "stringio"

module Nokogiri
  module Pure
    LIBXML_VERSION = "2.13.9"
    LIBXSLT_VERSION = "1.1.43"
  end

  LIBXML_COMPILED_VERSION = Pure::LIBXML_VERSION
  LIBXML_LOADED_VERSION = "21309"
  LIBXSLT_COMPILED_VERSION = Pure::LIBXSLT_VERSION
  LIBXSLT_LOADED_VERSION = "10143"
  PACKAGED_LIBRARIES = true
  PRECOMPILED_LIBRARIES = true
  LIBXML2_PATCHES = [].freeze
  LIBXSLT_PATCHES = [].freeze
  LIBXML_ICONV_ENABLED = true
  LIBXML_ZLIB_ENABLED = false
  LIBXML_HTTP_ENABLED = false
  LIBXSLT_DATETIME_ENABLED = true
  LIBXML_MEMORY_MANAGEMENT = "ruby"

  # module/class skeleton, mirroring Init_nokogiri()
  module Gumbo; end
  module HTML4; module SAX; end; end
  module HTML5; end

  module XML
    module SAX; end
    module XPath; end
  end
  module XSLT; end

  class SyntaxError < ::StandardError; end

  module XML
    class SyntaxError < ::Nokogiri::SyntaxError; end
    module XPath
      class SyntaxError < XML::SyntaxError; end
    end

    class ElementContent; end
    class Namespace; end
    class NodeSet; end
    class Reader; end
    class Node; end
    class Attr < Node; end
    class AttributeDecl < Node; end
    class DTD < Node; end
    class ElementDecl < Node; end
    class EntityDecl < Node; end
    class EntityReference < Node; end
    class ProcessingInstruction < Node; end
    class Element < Node; end
    class CharacterData < Node; end
    class Comment < CharacterData; end
    class Text < CharacterData; end
    class CDATA < Text; end
    class DocumentFragment < Node; end
    class Document < Node; end
    class XPathContext; end
    class Schema; end
    class RelaxNG < Schema; end

    module SAX
      class Parser; end
      class ParserContext; end
      class PushParser; end
    end
  end

  class EncodingHandler; end

  module XSLT
    class Stylesheet; end
  end

  module HTML4
    class Document < XML::Document; end
    class ElementDescription; end
    class EntityLookup; end
    module SAX
      class Parser < XML::SAX::Parser; end
      class ParserContext < XML::SAX::ParserContext; end
      class PushParser < XML::SAX::PushParser; end
    end
  end

  module HTML5
    class Document < HTML4::Document; end
  end

  module Test; end
end

require_relative "pure/util"
require_relative "pure/tree"
require_relative "pure/errors"
require_relative "pure/wrap"
require_relative "pure/encoding"
require_relative "pure/save"
require_relative "pure/c14n"
require_relative "pure/parser" if File.exist?(File.join(__dir__, "pure", "parser.rb"))

Dir[File.join(__dir__, "pure", "glue", "*.rb")].sort.each { |f| require f }
Nokogiri::Pure.init_class_table
