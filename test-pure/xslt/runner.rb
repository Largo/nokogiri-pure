# frozen_string_literal: true

# Runs XSLT cases (JSON on stdin: [{"name", "xsl", "xml", "params", "xsl_url", "xml_url"}]) and prints
# JSON results. Usage:
#   ruby test-pure/xslt/runner.rb native < cases.json     (installed nokogiri gem)
#   ruby test-pure/xslt/runner.rb pure   < cases.json     (nokogiri-pure)
require "json"
require "timeout"

mode = ARGV[0]
if mode == "native"
  gem "nokogiri", "1.19.4"
  require "nokogiri"
else
  $LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
  require "nokogiri"
  require_relative "scratch" unless defined?(Nokogiri::Pure::Parser)
end

def parse_xml(str, url, xslt)
  if mode_pure_scratch?
    XSLTScratch.xml(str)
  else
    opts = xslt ? Nokogiri::XML::ParseOptions::DEFAULT_XSLT : Nokogiri::XML::ParseOptions::DEFAULT_XML
    Nokogiri::XML::Document.parse(str, url, nil, opts)
  end
end

def mode_pure_scratch?
  defined?(XSLTScratch) && !defined?(Nokogiri::Pure::Parser)
end

cases = JSON.parse($stdin.read)
results = {}
old_stderr = $stderr.dup
cases.each do |c|
  res = {}
  begin
    $stderr.reopen(File::NULL)
    Timeout.timeout(c["timeout"] || 20) do
      xsl_doc = parse_xml(c["xsl"], c["xsl_url"], true)
      ss = Nokogiri::XSLT::Stylesheet.parse_stylesheet_doc(xsl_doc)
      doc = parse_xml(c["xml"], c["xml_url"], false)
      out = ss.transform(doc, c["params"] || [])
      res["serialize"] = ss.serialize(out)
      res["to_s"] = out.to_s rescue "ERR #{$!.class}"
    end
  rescue Exception => e # rubocop:disable Lint/RescueException
    res["error"] = "#{e.class}: #{e.message}"
  ensure
    $stderr.reopen(old_stderr)
  end
  results[c["name"]] = res
end
puts JSON.generate(results)
