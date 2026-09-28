# frozen_string_literal: true

# Scratch helper: build a Nokogiri::Pure tree from XML using REXML (until the pure parser lands).
require "rexml/document"

module XPathScratch
  P = Nokogiri::Pure
  T = Nokogiri::Pure::Tree

  module_function

  def parse(xml)
    begin
      return Nokogiri::XML(xml) if defined?(Nokogiri::Pure::Parser)
    rescue NameError, NotImplementedError
      # fall through
    end
    rdoc = REXML::Document.new(xml)
    doc = T.new_doc("1.0")
    rdoc.children.each { |c| add(doc, doc, c) }
    P.wrap_document(Nokogiri::XML::Document, doc)
  end

  def add(doc, parent, r)
    case r
    when REXML::Element
      node = T.new_doc_node(doc, nil, r.name)
      T.add_child(parent, node)
      r.attributes.each_attribute do |a|
        if a.prefix == "xmlns"
          T.new_ns(node, a.value, a.name)
        elsif a.name == "xmlns" && a.prefix.to_s.empty?
          T.new_ns(node, a.value, nil)
        end
      end
      ns = T.search_ns(doc, node, r.prefix.to_s.empty? ? nil : r.prefix)
      node.ns = ns
      r.attributes.each_attribute do |a|
        next if a.prefix == "xmlns" || (a.name == "xmlns" && a.prefix.to_s.empty?)

        ans = a.prefix.to_s.empty? ? nil : T.search_ns(doc, node, a.prefix)
        T.new_ns_prop(node, ans, a.name, a.value)
      end
      r.children.each { |c| add(doc, node, c) }
    when REXML::CData
      T.add_child(parent, T.new_cdata_block(doc, r.value))
    when REXML::Text
      T.add_child(parent, T.new_doc_text(doc, r.value))
    when REXML::Comment
      T.add_child(parent, T.new_doc_comment(doc, r.string))
    when REXML::Instruction
      T.add_child(parent, T.new_doc_pi(doc, r.target, r.content))
    end
  end
end
