# frozen_string_literal: true

# Builds the differential corpus under test-pure/relaxng/cases/ (git-ignored):
#   - libxml2 test/relaxng/*.rng with their *_N.xml instances (copied as is, resources too)
#   - the James Clark OASIS test suite (test/relaxng/OASIS/spectest.xml) and libxml2's own
#     test/relaxng/testsuite.xml, one directory per testCase (schema, instances, resources)
#   - nokogiri's test/files/address_book.rlx
#   - test-pure/relaxng/custom/*.rng with their *_N.xml instances
# and writes cases/cases.json, the input of run_cases.rb.
#
# Uses the native gem to read the suites: ruby test-pure/relaxng/extract_suites.rb
gem "nokogiri", "1.19.4"
require "nokogiri"
require "fileutils"
require "json"

HERE = File.expand_path(__dir__)
OUT = File.join(HERE, "cases")
LIBXML = "/root/workspace/nokogiri-pure-ref/libxml2-2.13.9"
UPSTREAM = "/root/workspace/nokogiri-upstream"

FileUtils.rm_rf(OUT)
FileUtils.mkdir_p(OUT)
cases = []

def rel(path) = path.sub("#{HERE}/", "")

# ---- libxml2 test/relaxng -----------------------------------------------------------------
src = File.join(LIBXML, "test/relaxng")
dst = File.join(OUT, "libxml2")
FileUtils.mkdir_p(dst)
Dir[File.join(src, "*")].each { |f| FileUtils.cp(f, dst) if File.file?(f) }
Dir[File.join(dst, "*.rng")].sort.each do |rng|
  base = File.basename(rng, ".rng")
  insts = Dir[File.join(dst, "#{base}_*.xml")].select { |x| File.basename(x) =~ /\A#{Regexp.escape(base)}_\d+\.xml\z/ }
  cases << { id: "libxml2/#{base}", schema: rel(rng), instances: insts.sort.map { |x| rel(x) } }
end

# ---- spectest-format suites -----------------------------------------------------------------
def write_content(path, node)
  FileUtils.mkdir_p(File.dirname(path))
  elem = node.element_children.first
  if elem
    doc = Nokogiri::XML::Document.new
    doc.root = elem.dup(1)
    File.write(path, doc.root.to_xml + "\n")
  else
    File.write(path, node.text)
  end
end

def write_resources(dir, node)
  node.element_children.each do |c|
    case c.name
    when "resource"
      write_content(File.join(dir, c["name"]), c)
    when "dir"
      d = File.join(dir, c["name"])
      FileUtils.mkdir_p(d)
      write_resources(d, c)
    end
  end
end

{ "oasis" => File.join(LIBXML, "test/relaxng/OASIS/spectest.xml"),
  "libxml2-suite" => File.join(LIBXML, "test/relaxng/testsuite.xml"), }.each do |name, file|
  suite = Nokogiri::XML(File.read(file)) { |c| c.noent }
  suite.xpath("//testCase").each_with_index do |tc, i|
    dir = File.join(OUT, name, format("%03d", i))
    FileUtils.mkdir_p(dir)
    write_resources(dir, tc)
    schema_node = tc.at_xpath("correct|incorrect")
    next unless schema_node

    write_content(File.join(dir, "schema.rng"), schema_node)
    insts = []
    tc.xpath("valid|invalid").each_with_index do |v, j|
      p = File.join(dir, "#{v.name}_#{j}.xml")
      write_content(p, v)
      insts << rel(p)
    end
    cases << { id: "#{name}/#{format("%03d", i)}", schema: rel(File.join(dir, "schema.rng")),
               instances: insts, expect: schema_node.name }
  end
end

# ---- nokogiri test files --------------------------------------------------------------------
dst = File.join(OUT, "nokogiri")
FileUtils.mkdir_p(dst)
FileUtils.cp(File.join(UPSTREAM, "test/files/address_book.rlx"), dst)
FileUtils.cp(File.join(UPSTREAM, "test/files/address_book.xml"), dst)
File.write(File.join(dst, "empty_book.xml"), "<addressBook></addressBook>\n")
cases << { id: "nokogiri/address_book", schema: rel(File.join(dst, "address_book.rlx")),
           instances: [rel(File.join(dst, "address_book.xml")), rel(File.join(dst, "empty_book.xml"))] }

# ---- custom cases ---------------------------------------------------------------------------
src = File.join(HERE, "custom")
dst = File.join(OUT, "custom")
if File.directory?(src)
  FileUtils.cp_r(src, OUT)
  Dir[File.join(dst, "**/*.rng")].sort.each do |rng|
    next if File.basename(rng).start_with?("_") # resources

    base = rng.sub(/\.rng\z/, "")
    insts = Dir["#{base}_*.xml"].sort
    cases << { id: "custom/#{rng.sub("#{dst}/", "").sub(/\.rng\z/, "")}", schema: rel(rng), instances: insts.map { |x| rel(x) } }
  end
end

File.write(File.join(OUT, "cases.json"), JSON.pretty_generate(cases))
puts "#{cases.size} cases, #{cases.sum { |c| c[:instances].size }} instances"
