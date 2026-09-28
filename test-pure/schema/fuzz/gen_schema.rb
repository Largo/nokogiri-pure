# frozen_string_literal: true

# Schema mutation fuzzer: mutates schema documents of the corpus (attribute values, removed/duplicated
# children, renamed refs) and writes fuzz/cases.json (instances are kept).  ruby gen_schema.rb [seed] [max]
gem "nokogiri", "1.19.4"
require "nokogiri"
require "json"
require_relative "../harness/cases"

seed = Integer(ARGV[0] || 1)
max = Integer(ARGV[1] || 2000)
rng = Random.new(seed)
VALS = %w[0 1 unbounded -1 x xs:string xs:int xs:nope qualified unqualified true false #all extension restriction ##any ##other ##local strict lax skip optional required prohibited 2 abc].freeze
out = []
SchemaCases.all.select { |c| c["xsd"] }.shuffle(random: rng).each do |c|
  break if out.size >= max

  src = File.read(c["xsd"]) rescue next
  doc = Nokogiri::XML(src) rescue next
  next unless doc.errors.empty? && doc.root

  elems = doc.xpath("//*[namespace-uri()='http://www.w3.org/2001/XMLSchema']").to_a
  next if elems.size < 2

  (1 + rng.rand(3)).times do
    e = elems[rng.rand(elems.size)]
    next if e == doc.root || e.parent.nil?

    case rng.rand(6)
    when 0 then e.unlink
    when 1 then e.add_next_sibling(e.dup)
    when 2
      a = e.attribute_nodes.sample(random: rng) or next
      a.value = VALS[rng.rand(VALS.size)]
    when 3
      a = e.attribute_nodes.sample(random: rng) or next
      a.unlink
    when 4 then e[%w[minOccurs maxOccurs default fixed nillable abstract final block mixed use form][rng.rand(11)]] = VALS[rng.rand(VALS.size)]
    when 5
      sib = e.next_element or next
      sib.add_next_sibling(e)
    end
  end
  insts = (c["instances"] || []).first(3).map { |i| [File.basename(i), File.read(i)] } rescue []
  out << { "id" => "fuzzs/#{c["id"]}", "xsd_string" => doc.to_xml, "xsd_url" => c["xsd"], "cwd" => File.dirname(c["xsd"]),
           "instances_inline" => insts, "files" => false }
end
File.write(File.join(__dir__, "cases.json"), JSON.pretty_generate(out))
puts out.size
