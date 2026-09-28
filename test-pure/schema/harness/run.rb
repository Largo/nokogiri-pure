# frozen_string_literal: true

# Differential harness runner.
#   ruby run.rb native [filter] > native.json   (oracle: installed nokogiri 1.19.4)
#   ruby run.rb pure   [filter] > pure.json     (nokogiri-pure)
# Each case -> { "schema" => {...}, "instances" => { name => [errors] }, "files" => { name => [errors] } }
mode = ARGV[0] or abort "usage: run.rb native|pure [filter]"
filter = ARGV[1]
if mode == "native"
  gem "nokogiri", "1.19.4"
  require "nokogiri"
else
  $LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
  require "nokogiri"
  if ENV["REXML"]
    require_relative "../rexml2pure"
    module Nokogiri::XML
      class << Document
        def parse(string_or_io, url = nil, encoding = nil, options = nil)
          s = string_or_io.respond_to?(:read) ? string_or_io.read : string_or_io.to_s
          Nokogiri::Pure.wrap_document(Nokogiri::XML::Document, Rexml2Pure.parse(s, url))
        end
      end
    end
    Nokogiri::Pure::SchemaGlue.load!
    Nokogiri::Pure::Schemas.parse_memory_override = ->(content, url, _o) { Rexml2Pure.parse(content, url) }
  end
end
require "json"
require "timeout"
require_relative "cases"

def err_rec(e)
  return { "string" => e } if e.is_a?(String)

  {
    "message" => e.message, "domain" => e.domain, "code" => e.code, "level" => e.level,
    "line" => e.line, "column" => e.column, "file" => e.file, "path" => e.path,
    "str1" => e.str1, "str2" => e.str2, "str3" => e.str3, "int1" => e.int1,
  }
end

def errs(list) = list.map { |e| err_rec(e) }

def run_case(c)
  out = { "schema" => nil, "instances" => {}, "files" => {} }
  schema = nil
  begin
    if c["xsd"]
      doc = Nokogiri::XML::Document.parse(File.read(c["xsd"]), c["xsd"])
    else
      doc = Nokogiri::XML::Document.parse(c["xsd_string"], c["xsd_url"])
    end
    schema = Nokogiri::XML::Schema.from_document(doc)
    out["schema"] = { "ok" => true, "errors" => errs(schema.errors) }
  rescue Nokogiri::XML::SyntaxError => e
    list = e.respond_to?(:errors) && e.errors ? e.errors : [e]
    out["schema"] = { "ok" => false, "exception" => e.class.name, "message" => e.message, "errors" => errs(list) }
  rescue Exception => e # rubocop:disable Lint/RescueException
    raise if e.is_a?(Interrupt)

    out["schema"] = { "ok" => false, "crash" => "#{e.class}: #{e.message}", "bt" => e.backtrace&.first(8) }
  end
  return out unless schema

  insts = (c["instances"] || []).map { |p| [File.basename(p), File.read(p), p] }
  insts += (c["instances_inline"] || []).map { |n, x| [n, x, nil] }
  insts.each do |name, xml, path|
    begin
      d = Nokogiri::XML::Document.parse(xml, path)
      out["instances"][name] = errs(schema.validate(d))
    rescue Exception => e # rubocop:disable Lint/RescueException
      raise if e.is_a?(Interrupt)

      out["instances"][name] = [{ "crash" => "#{e.class}: #{e.message}", "bt" => e.backtrace&.first(8) }]
    end
    next unless c["files"] && path

    begin
      out["files"][name] = errs(schema.validate(path))
    rescue Exception => e # rubocop:disable Lint/RescueException
      raise if e.is_a?(Interrupt)

      out["files"][name] = [{ "crash" => "#{e.class}: #{e.message}", "bt" => e.backtrace&.first(8) }]
    end
  end
  out
end

results = {}
SchemaCases.all(filter).each do |c|
  Dir.chdir(c["xsd"] ? File.dirname(c["xsd"]) : (c["cwd"] || Dir.pwd)) do
    results[c["id"]] = Timeout.timeout(Integer(ENV.fetch("CASE_TIMEOUT", "60"))) { run_case(c) }
  rescue Timeout::Error
    results[c["id"]] = { "timeout" => true }
  end
end
puts JSON.pretty_generate(results)
