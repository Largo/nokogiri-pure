# frozen_string_literal: true

# Dumps parse results using the public Nokogiri API (used with the native gem as the oracle).
module DumpNative
  module_function

  def node_lines(node, depth, out)
    ind = "  " * depth
    case node.type
    when Nokogiri::XML::Node::ELEMENT_NODE
      ns = node.namespace
      nsdefs = node.namespace_definitions.map { |d| "#{d.prefix}=#{d.href}" }.join(",")
      out << "#{ind}E #{ns&.prefix}|#{ns&.href}|#{node.name} L#{node.line} [#{nsdefs}]"
      node.attribute_nodes.each do |a|
        ans = a.namespace
        out << "#{ind}  A #{ans&.prefix}|#{ans&.href}|#{a.name}=#{a.value.inspect}"
      end
      node.children.each { |c| node_lines(c, depth + 1, out) }
    when Nokogiri::XML::Node::TEXT_NODE
      out << "#{ind}T #{node.content.inspect} L#{node.line}"
    when Nokogiri::XML::Node::CDATA_SECTION_NODE
      out << "#{ind}C #{node.content.inspect} L#{node.line}"
    when Nokogiri::XML::Node::COMMENT_NODE
      out << "#{ind}M #{node.content.inspect} L#{node.line}"
    when Nokogiri::XML::Node::DTD_NODE
      out << "#{ind}D #{node.name.inspect} #{node.external_id.inspect} #{node.system_id.inspect}"
    else
      out << "#{ind}? #{node.type}"
    end
  end

  def run(c)
    opts = { max_errors: -1, parse_noscript_content_as_text: c[:script] }
    out = []
    begin
      if c[:context]
        doc = Nokogiri::HTML5::Document.new
        frag = Nokogiri::HTML5::DocumentFragment.new(doc, c[:data], c[:context], **opts)
        target = frag
      else
        doc = Nokogiri::HTML5.parse(c[:data], **opts)
        target = doc
      end
      target.children.each { |n| node_lines(n, 0, out) }
      out << "Q #{target.quirks_mode.inspect}"
      target.errors.each do |e|
        out << "ERR #{e.line}:#{e.column} #{e.str1} #{Exception.instance_method(:to_s).bind_call(e).inspect} file=#{e.file.inspect} lvl=#{e.level} dom=#{e.domain} code=#{e.code}"
      end
    rescue => e
      out << "EXC #{e.class}: #{e.message}"
    end
    out
  end
end
