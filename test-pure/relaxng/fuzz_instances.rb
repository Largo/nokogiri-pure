# frozen_string_literal: true

# Mutates the instances of the corpus (cases/cases.json) and validates them against their
# original schema: ruby fuzz_instances.rb SEED PER_CASE && CASES=cases/fuzzinst.json ruby compare.rb
# Uses the native gem only to read/serialize the instances.
gem "nokogiri", "1.19.4"
require "nokogiri"
require "json"
require "fileutils"

seed = (ARGV[0] || 1).to_i
per = (ARGV[1] || 3).to_i
srand(seed)
HERE = File.expand_path(__dir__)
OUT = File.join(HERE, "cases", "fuzzinst")
FileUtils.rm_rf(OUT)
FileUtils.mkdir_p(OUT)

def mutate(doc)
  elems = doc.xpath("//*").to_a
  return if elems.empty?

  n = 1 + rand(3)
  n.times do
    e = elems.sample
    next if e.nil? || e.parent.nil?

    case rand(12)
    when 0 then e.unlink unless e == doc.root
    when 1 then e.add_next_sibling(e.dup) unless e == doc.root
    when 2 then e.name = %w[zz item name card x].sample
    when 3 then (a = e.attribute_nodes.sample) && a.unlink
    when 4 then e[%w[extra id x name].sample] = %w[1 abc a b].sample
    when 5 then e.add_child(Nokogiri::XML::Text.new(["txt", " ", "12", "\n"].sample, doc))
    when 6 then e.children.each { |c| c.content = %w[1 x true 2020-01-01 -3].sample if c.text? }
    when 7
      sib = e.next_element
      e.add_next_sibling(sib) if sib # swap
    when 8 then e.add_child(Nokogiri::XML::Comment.new(doc, "c"))
    when 9 then e.children.to_a.reverse.each { |c| e.add_child(c) }
    when 10 then (a = e.attribute_nodes.sample) && (a.value = %w[zz 0 true a:b].sample)
    else e.add_child(doc.create_element(elems.sample.name))
    end
  end
end

cases = JSON.parse(File.read(File.join(HERE, "cases", "cases.json")))
out = []
cases.each do |c|
  next if c["instances"].empty?

  insts = []
  c["instances"].each_with_index do |inst, i|
    src = File.read(File.join(HERE, inst)) rescue next
    per.times do |k|
      doc = Nokogiri::XML(src)
      next if doc.root.nil?

      mutate(doc)
      p = File.join(OUT, c["id"].tr("/", "_") + "_#{i}_#{k}.xml")
      File.write(p, doc.to_xml)
      insts << p.sub("#{HERE}/", "")
    end
  end
  out << { id: "fuzzinst/#{c["id"]}", schema: c["schema"], instances: insts }
end
File.write(File.join(HERE, "cases", "fuzzinst.json"), JSON.pretty_generate(out))
puts "#{out.size} cases, #{out.sum { |c| c[:instances].size }} instances"
