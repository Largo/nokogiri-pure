# frozen_string_literal: true

# Enumerates schema/instance cases for the differential harness.
# A case: { "id" => String, "xsd" => path, "instances" => [paths], "files" => bool (also validate_file) }
# or inline: { "id", "xsd_string", "xsd_url", "instances_inline" => [[name, xml]] }
module SchemaCases
  LIBXML2 = "/root/workspace/nokogiri-pure-ref/libxml2-2.13.9"
  UPSTREAM = "/root/workspace/nokogiri-upstream/test/files"
  HERE = File.expand_path("..", __dir__)

  module_function

  def libxml2_cases
    dir = File.join(LIBXML2, "test/schemas")
    Dir[File.join(dir, "*_*.xsd")].sort.map do |xsd|
      base = File.basename(xsd, ".xsd")
      prefix = base.sub(/_\d\z/, "").sub(/_\d\z/, "")
      insts = Dir[File.join(dir, "#{prefix}_*.xml")].sort
      { "id" => "libxml2/#{base}", "xsd" => xsd, "instances" => insts, "files" => true }
    end
  end

  def upstream_cases
    [
      { "id" => "upstream/po", "xsd" => File.join(UPSTREAM, "po.xsd"), "instances" => [File.join(UPSTREAM, "po.xml")], "files" => true },
      { "id" => "upstream/foo", "xsd" => File.join(UPSTREAM, "foo/foo.xsd"), "instances" => [File.join(UPSTREAM, "valid_bar.xml")], "files" => true },
      { "id" => "upstream/bar", "xsd" => File.join(UPSTREAM, "bar/bar.xsd"), "instances" => [File.join(UPSTREAM, "valid_bar.xml")], "files" => true },
    ] + Dir[File.join(UPSTREAM, "saml/*.xsd")].sort.map do |x|
      { "id" => "upstream/saml/#{File.basename(x)}", "xsd" => x, "instances" => [], "files" => false }
    end
  end

  # hand-written cases: test-pure/schema/cases/*.rb each define CASES << {...}
  def custom_cases
    list = []
    Dir[File.join(HERE, "cases/*.rb")].sort.each do |f|
      mod = Module.new
      mod.const_set(:CASES, [])
      mod.module_eval(File.read(f), f)
      mod::CASES.each_with_index do |c, i|
        c = c.transform_keys(&:to_s)
        c["id"] ||= "#{File.basename(f, ".rb")}/#{i}"
        c["id"] = "custom/#{c["id"]}"
        list << c
      end
    end
    list
  end

  def xsts_cases
    f = File.join(HERE, "xsts/cases.json")
    return [] unless File.exist?(f)

    require "json"
    JSON.parse(File.read(f))
  end

  def fuzz_cases
    f = File.join(HERE, "fuzz/cases.json")
    return [] unless File.exist?(f)

    require "json"
    JSON.parse(File.read(f))
  end

  def all(filter = nil)
    cs = libxml2_cases + upstream_cases + custom_cases + xsts_cases
    cs += fuzz_cases if ENV["FUZZ"]
    cs = cs.select { |c| c["id"].include?(filter) } if filter
    cs
  end
end
