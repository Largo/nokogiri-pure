# frozen_string_literal: true

# Mutation fuzzer: takes valid schema/instance pairs from the corpus and writes mutated instances
# (element deletion/duplication/swap, text and attribute value changes, unknown attributes/elements)
# to fuzz/cases.json, which the harness picks up.   ruby gen.rb [seed] [max_cases]
gem "nokogiri", "1.19.4"
require "nokogiri"
require "json"
require_relative "../harness/cases"

seed = Integer(ARGV[0] || 1)
max = Integer(ARGV[1] || 1500)
rng = Random.new(seed)
VALUES = ["x", "", " ", "-1", "0", "1.5", "99999999999999999999", "2001-02-29", "true", "a b", "P1Y", "é", "INF", "NaN", "xs:foo", "#{"z" * 40}"].freeze

def mutate(doc, rng)
  elems = doc.xpath("//*").to_a
  return nil if elems.empty?

  e = elems[rng.rand(elems.size)]
  case rng.rand(9)
  when 0 then return nil if e == doc.root; e.unlink
  when 1 then e.add_next_sibling(e.dup)
  when 2
    sib = e.next_element or return nil
    sib.add_next_sibling(e)
  when 3 then e.children.each { |c| c.unlink if c.text? }; e.add_child(Nokogiri::XML::Text.new(VALUES[rng.rand(VALUES.size)], doc))
  when 4
    a = e.attribute_nodes.first or return nil
    a.value = VALUES[rng.rand(VALUES.size)]
  when 5 then e["zzUnknown"] = "1"
  when 6 then e.add_child(Nokogiri::XML::Node.new("zzElem", doc))
  when 7
    a = e.attribute_nodes.first or return nil
    a.unlink
  when 8 then e.children.each(&:unlink)
  end
  doc
end

out = []
cases = SchemaCases.all.select { |c| c["xsd"] && !c["instances"].to_a.empty? }
cases.shuffle(random: rng).each do |c|
  break if out.size >= max

  begin
    schema = Dir.chdir(File.dirname(c["xsd"])) { Nokogiri::XML::Schema.from_document(Nokogiri::XML(File.read(c["xsd"]), c["xsd"])) }
  rescue StandardError
    next
  end
  inst = c["instances"].find do |i|
    d = Nokogiri::XML(File.read(i), i)
    d.errors.empty? && d.root && schema.validate(d).empty?
  rescue StandardError
    false
  end
  next unless inst

  muts = []
  4.times do |k|
    d = Nokogiri::XML(File.read(inst), inst)
    (1 + rng.rand(2)).times { d = (mutate(d, rng) rescue nil) || d }
    muts << ["m#{k}", d.to_xml]
  end
  out << { "id" => "fuzz/#{c["id"]}", "xsd" => c["xsd"], "instances_inline" => muts, "files" => false }
end
File.write(File.join(__dir__, "cases.json"), JSON.pretty_generate(out))
puts out.size
