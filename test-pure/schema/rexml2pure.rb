# frozen_string_literal: true

# Scratch converter REXML -> Nokogiri::Pure tree (used only until the pure XML parser lands).
# Tracks line numbers like libxml2 (line of the end of the start tag).
require "rexml/parsers/baseparser"
require "rexml/text"

module Rexml2Pure
  module_function

  T = Nokogiri::Pure::Tree

  def parse(src, url = nil)
    src = src.dup.force_encoding("UTF-8")
    doc = T.new_doc("1.0")
    doc.url = url
    parser = REXML::Parsers::BaseParser.new(src)
    stack = [doc]
    last_pos = 0
    line = 1
    while parser.has_next?
      ev = parser.pull
      pos = parser.position
      line += src.byteslice(last_pos, pos - last_pos).to_s.count("\n") if pos > last_pos
      last_pos = pos if pos > last_pos
      case ev[0]
      when :start_element
        name = ev[1]
        attrs = ev[2]
        parent = stack.last
        node = T.new_doc_node(doc, nil, name.include?(":") ? name.split(":", 2)[1] : name)
        node.line = line
        if parent.equal?(doc)
          T.add_child(doc, node)
        else
          T.add_child(parent, node)
        end
        attrs.each do |k, v|
          if k == "xmlns"
            T.new_ns(node, v, nil)
          elsif k.start_with?("xmlns:")
            T.new_ns(node, v, k[6..])
          end
        end
        prefix = name.include?(":") ? name.split(":", 2)[0] : nil
        ns = T.search_ns(doc, node, prefix)
        T.set_ns(node, ns) if ns
        attrs.each do |k, v|
          next if k == "xmlns" || k.start_with?("xmlns:")

          val = REXML::Text.unnormalize(v)
          if k.include?(":")
            pfx, local = k.split(":", 2)
            ans = T.search_ns(doc, node, pfx)
            T.new_ns_prop(node, ans, local, val)
          else
            T.new_prop(node, k, val)
          end
        end
        stack.push(node)
      when :end_element
        stack.pop
      when :text
        next if stack.last.equal?(doc)

        t = T.new_doc_text(doc, REXML::Text.unnormalize(ev[1]))
        t.line = line
        T.add_child(stack.last, t)
      when :cdata
        c = T.new_cdata_block(doc, ev[1])
        T.add_child(stack.last, c)
      when :comment
        c = T.new_doc_comment(doc, ev[1])
        T.add_child(stack.last, c)
      end
    end
    doc
  end
end
