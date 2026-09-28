# frozen_string_literal: true

# Pure-Ruby port of libxml2's XML parser (parser.c, parserInternals.c, SAX2.c and the input side of
# encoding.c/xmlIO.c), module Nokogiri::Pure::Parser.

require_relative "parser/codes"
require_relative "parser/errstrings"
require_relative "parser/chars"
require_relative "parser/ebcdic"
require_relative "parser/encoding"
require_relative "parser/input"
require_relative "parser/ctxt"
require_relative "parser/lowlevel"
require_relative "parser/core_text"
require_relative "parser/core_values"
require_relative "parser/core_decl"
require_relative "parser/core_content"
require_relative "parser/lean"
require_relative "parser/sax2"
require_relative "parser/push"
require_relative "parser/loader"
require_relative "parser/api"
require_relative "valid"
