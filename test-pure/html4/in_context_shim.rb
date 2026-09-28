# frozen_string_literal: true
# Scratch shim (testing only): Parser.node_in_context for HTML documents, per xml_node.c in_context,
# until the XML parser port provides the real one.
require "nokogiri"
module Nokogiri
  module Pure
    module Parser
      def self.node_in_context(rb_node, str, options)
        node = Pure.unwrap(rb_node)
        rb_doc = node.doc._ruby_doc
        err = rb_doc.instance_variable_get(:@errors)
        doc_is_empty = node.doc.children.nil?
        node_children = node.children
        doc_children = node.doc.children
        error, list = Errors.collecting(err) do
          HTMLParser.parse_in_node_context(node, str.b, options)
        end
        if error != 0
          node.doc.children = doc_children
          node.children = node_children
        end
        c = node.doc.children
        while c
          c.parent = node.doc
          c = c.next
        end
        if error != 0 && doc_is_empty && node.doc.children
          top = node
          top = top.parent while top.parent
          node.doc.children = nil if top.type == DOCUMENT_FRAG_NODE
        end
        raise RuntimeError, "error parsing fragment (#{error})" if error == 1 || error == 2

        nodes = []
        while list
          tmp = list.next
          list.next = nil
          nodes << list
          list = tmp
        end
        Pure.wrap_node_set(nodes, rb_doc)
      end
    end
  end
end
