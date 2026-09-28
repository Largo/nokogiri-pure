# frozen_string_literal: true

# Runs with the NATIVE nokogiri gem (separate process): validates instance documents built from
# the jobs read as JSON on stdin and prints the verdicts / messages as JSON.
#   ruby test-pure/schema/types/native_oracle.rb < jobs.json > results.json
gem "nokogiri", "1.19.4"
require "nokogiri"
require "json"

XS = 'xmlns:xs="http://www.w3.org/2001/XMLSchema"'

def esc(v)
  v.gsub(/[&<>\r\n\t]/) { |c| { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\r" => "&#13;", "\n" => "&#10;", "\t" => "&#9;" }[c] }
end

def attr_esc(v)
  esc(v).gsub('"', "&quot;")
end

# one <v> (or <g><v/><v/></g>) per line, mapped back through the error line; with
# separate: true every item is validated in its own document (an internal error aborts the
# validation of the rest of a document)
def run(schema_src, items, separate: false)
  if separate
    res = []
    items.each do |item|
      r = run(schema_src, [item])
      return r if r["schema_error"]

      res << r["results"][0]
    end
    return { "results" => res }
  end
  schema = begin
    Nokogiri::XML::Schema(schema_src)
  rescue Nokogiri::XML::SyntaxError => e
    return { "schema_error" => e.message }
  end
  lines = +"<r>\n"
  line_of = {}
  items.each_with_index do |item, i|
    line_of[lines.count("\n") + 1] = i
    lines << item << "\n"
  end
  lines << "</r>\n"
  doc = Nokogiri::XML(lines)
  res = Array.new(items.size) { [] }
  schema.validate(doc).each do |e|
    idx = line_of[e.line]
    if idx
      res[idx] << e.message
    else
      (res[-1] ||= []) << "UNMAPPED #{e.line}: #{e.message}"
    end
  end
  { "results" => res }
end

jobs = JSON.parse($stdin.read)
out = jobs.map do |job|
  case job["kind"]
  when "lex"
    src = %(<xs:schema #{XS}><xs:element name="r"><xs:complexType><xs:sequence>
      <xs:element name="v" type="xs:#{job["type"]}" minOccurs="0" maxOccurs="unbounded"/>
      </xs:sequence></xs:complexType></xs:element></xs:schema>)
    run(src, job["values"].map { |v| "<v>#{esc(v)}</v>" })
  when "uniq"
    src = %(<xs:schema #{XS}><xs:element name="r"><xs:complexType><xs:sequence>
      <xs:element name="g" minOccurs="0" maxOccurs="unbounded"><xs:complexType><xs:sequence>
      <xs:element name="v" type="xs:#{job["type"]}" maxOccurs="unbounded"/></xs:sequence></xs:complexType>
      <xs:unique name="u"><xs:selector xpath="v"/><xs:field xpath="."/></xs:unique></xs:element>
      </xs:sequence></xs:complexType></xs:element></xs:schema>)
    run(src, job["values"].map { |v| "<g><v>#{esc(v)}</v><v>#{esc(v)}</v></g>" }, separate: true)
  when "facet"
    src = %(<xs:schema #{XS}><xs:element name="r"><xs:complexType><xs:sequence>
      <xs:element name="v" minOccurs="0" maxOccurs="unbounded"><xs:simpleType>
      <xs:restriction base="xs:#{job["base"]}">#{job["facets"].map { |f, fv| %(<xs:#{f} value="#{attr_esc(fv)}"/>) }.join}</xs:restriction>
      </xs:simpleType></xs:element></xs:sequence></xs:complexType></xs:element></xs:schema>)
    run(src, job["values"].map { |v| "<v>#{esc(v)}</v>" })
  end
end
puts JSON.generate(out)
