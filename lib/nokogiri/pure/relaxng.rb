# frozen_string_literal: true

# Pure-Ruby port of libxml2 2.13.9 relaxng.c: RELAX NG grammar parsing and simplification
# (includes / externalRef, define merging and combine, the rules of sections 4 and 7 of the
# specification), the built-in and W3C XML Schema datatype libraries, compilation of content
# models to xmlRegexp automata where libxml2 does it, and the interpreted validation engine.
#
# The port is function-by-function: xmlRelaxNGFooBar() -> RelaxNG.foo_bar(), structures keep
# their C field names (snake_cased), and error reporting (codes, messages, domains, nodes) is
# the same as libxml2's. See relaxng/*.rb.
#
# Public entry points (used by glue/xml_relax_ng.rb):
#   RelaxNG.new_doc_parser_ctxt(doc)        xmlRelaxNGNewDocParserCtxt (copies the document)
#   RelaxNG.new_parser_ctxt(url)            xmlRelaxNGNewParserCtxt
#   RelaxNG.new_mem_parser_ctxt(buffer)     xmlRelaxNGNewMemParserCtxt
#   ctxt.serror = callable                  xmlRelaxNGSetParserStructuredErrors
#   RelaxNG.parse(ctxt)                     xmlRelaxNGParse -> Schema or nil
#   RelaxNG.new_valid_ctxt(schema)          xmlRelaxNGNewValidCtxt
#   vctxt.serror = callable                 xmlRelaxNGSetValidStructuredErrors
#   RelaxNG.validate_doc(vctxt, doc)        xmlRelaxNGValidateDoc -> 0 / 1 / -1

require_relative "errors"
require_relative "parser/codes"
require_relative "xmlregexp"

module Nokogiri
  module Pure
    module RelaxNG
    end
  end
end

require_relative "relaxng/structs"
require_relative "relaxng/errors"
require_relative "relaxng/types"
require_relative "relaxng/compile"
require_relative "relaxng/parse"
require_relative "relaxng/simplify"
require_relative "relaxng/validate"
