# frozen_string_literal: true

# Generates cases.json for the differential harness from the W3C XSTS 2006-11-06 test sets.
# Fetch first: curl -sSLf -o xsts.tar.gz https://www.w3.org/XML/2004/xml-schema-test-suite/xmlschema2006-11-06/xsts-2007-06-20.tar.gz && tar xzf xsts.tar.gz
gem "nokogiri", "1.19.4"
require "nokogiri"
require "json"
root = File.join(__dir__, "xmlschema2006-11-06")
cases = []
Dir[File.join(root, "*Meta/*.testSet")].sort.each do |ts|
  doc = Nokogiri::XML(File.read(ts))
  doc.remove_namespaces!
  base = File.dirname(ts)
  set = File.basename(ts, ".testSet")
  doc.xpath("//testGroup").each do |g|
    schema_docs = g.xpath("schemaTest/schemaDocument").map { |d| File.expand_path(d["href"], base) }
    next if schema_docs.empty?

    xsd = schema_docs.first
    next unless File.exist?(xsd)

    insts = g.xpath("instanceTest/instanceDocument").map { |d| File.expand_path(d["href"], base) }.select { |f| File.exist?(f) }
    cases << { "id" => "xsts/#{File.basename(File.dirname(ts))}/#{set}/#{g["name"]}", "xsd" => xsd, "instances" => insts, "files" => true }
  end
end
File.write(File.join(__dir__, "cases.json"), JSON.pretty_generate(cases))
puts cases.size
