# frozen_string_literal: true

# Scratch helpers for XSLT tests: parse XML with the pure parser if available, else REXML.
require_relative "../xpath/tree_builder"

module XSLTScratch
  module_function

  def xml(str)
    XPathScratch.parse(str)
  end

  def xslt(str)
    Nokogiri::XSLT::Stylesheet.parse_stylesheet_doc(xml(str))
  end
end
