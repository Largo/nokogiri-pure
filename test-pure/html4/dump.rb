# frozen_string_literal: true
# Usage: ruby dump.rb cases.marshal out.marshal   (loads whichever nokogiri is on the load path)
require "nokogiri"

def dump_node(n, out, depth = 0)
  rec = [depth, n.type, n.name, (n.respond_to?(:line) ? n.line : nil)]
  case n.type
  when Nokogiri::XML::Node::TEXT_NODE, Nokogiri::XML::Node::CDATA_SECTION_NODE, Nokogiri::XML::Node::COMMENT_NODE,
       Nokogiri::XML::Node::PI_NODE
    rec << n.content.b
  when Nokogiri::XML::Node::DTD_NODE
    rec << n.external_id << n.system_id
  when Nokogiri::XML::Node::ELEMENT_NODE
    rec << n.attribute_nodes.map { |a| [a.name, a.value&.b, a.children.size] }
  end
  out << rec
  if n.type != Nokogiri::XML::Node::DTD_NODE
    n.children.each { |c| dump_node(c, out, depth + 1) }
  end
end

def run_case(c)
  kind, input, url, enc, opts = c
  doc = case kind
  when :mem then Nokogiri::HTML4::Document.read_memory(input, url, enc, opts)
  when :io then Nokogiri::HTML4::Document.read_io(StringIO.new(input), url, enc, opts)
  when :parse then Nokogiri::HTML4(input, url, enc, opts)
  when :parseio then Nokogiri::HTML4(StringIO.new(input), url, enc, opts)
  when :parsefrag then (f = Nokogiri::HTML4.fragment(input); return [[:frag, f.to_html.b, f.errors.map(&:to_s)]])
  end
  out = []
  out << [:encoding, doc.encoding, doc.url]
  out << [:errors, doc.errors.map { |e| [e.message.b, e.line, e.column, e.level, e.code, e.domain, e.str1&.b, e.str2&.b, e.int1, (e.respond_to?(:path) ? e.path : nil)] }]
  doc.children.each { |ch| dump_node(ch, out) }
  out
rescue Exception => e
  [[:exception, e.class.name, e.message.b]]
end

cases = Marshal.load(File.binread(ARGV[0]))
results = cases.map { |c| run_case(c) }
File.binwrite(ARGV[1], Marshal.dump(results))
