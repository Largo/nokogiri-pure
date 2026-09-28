# frozen_string_literal: true

# Records the native (libxml2 2.13.9) schema-parse error lists for cases.rb into
# expected.json. Run with the *native* gem, from the repository root:
#   ruby test-pure/schema/unit_b/gen_expected.rb
gem "nokogiri", "1.19.4"
require "nokogiri"
require "json"
require_relative "cases"

$captured = nil
class << Nokogiri::XML::SyntaxError
  alias_method :__orig_aggregate, :aggregate
  def aggregate(errors)
    $captured = errors
    __orig_aggregate(errors)
  end
end

def run_case
  $captured = nil
  begin
    schema = yield
    errs = schema.errors
    status = "ok"
  rescue Nokogiri::XML::SyntaxError
    errs = $captured || []
    status = "failed"
  end
  { "status" => status,
    "errors" => errs.map { |e| { "message" => e.message, "code" => e.code, "level" => e.level, "line" => e.line, "domain" => e.domain } } }
end

out = {}
UnitBCases::CASES.each do |name, xsd|
  out[name] = run_case { Nokogiri::XML::Schema(xsd) }
end
UnitBCases::FILE_CASES.each do |name, file|
  path = File.join(UnitBCases::FILES_DIR, file)
  out[name] = run_case { Nokogiri::XML::Schema.from_document(Nokogiri::XML(File.read(path), path)) }
end
File.write(File.expand_path("expected.json", __dir__), JSON.pretty_generate(out) + "\n")
puts "wrote #{out.size} cases"
