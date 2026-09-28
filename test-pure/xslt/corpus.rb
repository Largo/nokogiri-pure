# frozen_string_literal: true

# Builds the XSLT differential corpus as JSON cases (see runner.rb).
#   ruby test-pure/xslt/corpus.rb [filter-regex] > /tmp/cases.json
require "json"
# (binary-safe: cases and results are exchanged with Marshal)

REF = "/root/workspace/nokogiri-pure-ref/libxslt-1.1.43/tests"
UPSTREAM = "/root/workspace/nokogiri-upstream/test/files"
LOCAL = File.join(__dir__, "cases")

def read(path)
  File.binread(path)
end

cases = []
dirs = %w[REC REC2 general documents numbers keys namespaces extensions reports encoding
          exslt/common exslt/date exslt/dynamic exslt/functions exslt/math exslt/saxon exslt/sets exslt/strings]
dirs.each do |d|
  Dir[File.join(REF, d, "*.xsl")].sort.each do |xsl|
    xml = xsl.sub(/\.xsl\z/, ".xml")
    next unless File.exist?(xml)

    cases << { "name" => "#{d}/#{File.basename(xsl)}", "xsl" => read(xsl), "xml" => read(xml),
               "xsl_url" => xsl, "xml_url" => xml, "params" => ["test", "'passed_value'", "test2", "'passed_value2'"] }
  end
end
Dir[File.join(REF, "XSLTMark", "*.xsl")].sort.each do |xsl|
  base = File.basename(xsl, ".xsl")
  xml = File.join(REF, "XSLTMark", "#{base}.xml")
  xml = File.join(REF, "XSLTMark", "db100.xml") unless File.exist?(xml)
  next unless File.exist?(xml)

  cases << { "name" => "XSLTMark/#{base}", "xsl" => read(xsl), "xml" => read(xml), "xsl_url" => xsl, "xml_url" => xml }
end
# nokogiri's own fixtures
{
  "staff.xslt" => "staff.xml", "exslt.xslt" => "exslt.xml", "xslt_included.xsl" => "staff.xml",
}.each do |xsl, xml|
  x = File.join(UPSTREAM, xsl)
  y = File.join(UPSTREAM, xml)
  next unless File.exist?(x) && File.exist?(y)

  cases << { "name" => "nokogiri/#{xsl}", "xsl" => read(x), "xml" => read(y), "xsl_url" => x, "xml_url" => y }
end
# hand-written cases: test-pure/xslt/cases/*.xsl (+ same-named .xml, or default input)
default_xml = File.exist?(File.join(LOCAL, "default.xml")) ? read(File.join(LOCAL, "default.xml")) : "<doc/>"
Dir[File.join(LOCAL, "*.xsl")].sort.each do |xsl|
  xml = xsl.sub(/\.xsl\z/, ".xml")
  cases << { "name" => "cases/#{File.basename(xsl)}", "xsl" => read(xsl),
             "xml" => File.exist?(xml) ? read(xml) : default_xml, "xsl_url" => xsl, "xml_url" => xml }
end

filter = ARGV[0] ? Regexp.new(ARGV[0]) : nil
cases.select! { |c| filter.match?(c["name"]) } if filter
$stdout.binmode
$stdout.write(Marshal.dump(cases))
