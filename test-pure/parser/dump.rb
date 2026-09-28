# frozen_string_literal: true

# Shared dumper for the differential harness: loaded by both the native oracle process and the
# pure process. Produces plain data (Marshal-able) describing parse results.

module ParserDump
  module_function

  def err(e)
    [e.message, e.line, e.column, e.level, e.code, e.domain, e.str1, e.str2, e.str3, e.int1, e.file]
  end

  def node(n, depth = 0)
    return [:deep] if depth > 60

    case n
    when Nokogiri::XML::Document
      [:doc, n.encoding, n.version, n.children.map { |c| node(c, depth + 1) }]
    when Nokogiri::XML::DTD
      [:dtd, n.name, n.external_id, n.system_id, n.children.map { |c| node(c, depth + 1) }]
    when Nokogiri::XML::Element
      [:el, n.name, n.namespace&.prefix, n.namespace&.href, n.line,
        n.namespace_definitions.map { |ns| [ns.prefix, ns.href] },
        n.attribute_nodes.map { |a| [a.name, a.namespace&.prefix, a.namespace&.href, a.value, a.children.map { |c| node(c, depth + 1) }] },
        n.children.map { |c| node(c, depth + 1) }]
    when Nokogiri::XML::CDATA
      [:cdata, n.content]
    when Nokogiri::XML::Text
      [:text, n.content, n.line]
    when Nokogiri::XML::Comment
      [:comment, n.content]
    when Nokogiri::XML::ProcessingInstruction
      [:pi, n.name, n.content]
    when Nokogiri::XML::EntityReference
      [:eref, n.name]
    when Nokogiri::XML::EntityDecl
      [:entdecl, n.name, n.entity_type, n.external_id, n.system_id, n.content]
    when Nokogiri::XML::ElementDecl
      [:eldecl, n.name, n.element_type, n.prefix]
    when Nokogiri::XML::AttributeDecl
      [:attrdecl, n.name, n.attribute_type, n.default, n.enumeration]
    else
      [n.class.name, n.name]
    end
  rescue => e
    [:dump_error, e.class.name, e.message]
  end

  def run(input, opts, encoding = nil, url = nil)
    d = Nokogiri::XML::Document.read_memory(input, url, encoding, opts)
    xml = begin
      # notation tables are hash-ordered (randomized) in libxml2
      d.to_xml.gsub(/(?:^<!NOTATION[^\n]*\n)+/) { |m| m.lines.sort.join }
    rescue => e
      "to_xml raised #{e.class}"
    end
    { xml: xml, tree: node(d), errors: d.errors.map { |e| err(e) }, url: d.url }
  rescue Nokogiri::XML::SyntaxError => e
    { exception: e.class.name, message: e.message, errors: (e.respond_to?(:errors) ? e.errors.map { |x| err(x) } : [err(e)]) }
  rescue => e
    { exception: e.class.name, message: e.message }
  end
end
