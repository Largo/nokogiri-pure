# frozen_string_literal: true

# Mutation fuzzer: mutates corpus stylesheets (with the native gem) and writes the cases to
# stdout (Marshal). Usage: ruby test-pure/xslt/fuzz.rb SEED COUNT [filter] > cases.bin
#   CASES=cases.bin ruby test-pure/xslt/compare.rb -v
gem "nokogiri", "1.19.4"
require "nokogiri"
require "open3"

seed = (ARGV[0] || 1).to_i
count = (ARGV[1] || 200).to_i
filter = ARGV[2]
rng = Random.new(seed)
corpus_bin, = Open3.capture2("ruby", File.join(__dir__, "corpus.rb"), *[filter].compact, binmode: true)
corpus = Marshal.load(corpus_bin).reject { |c| c["name"].start_with?("big/") }

XSL = "http://www.w3.org/1999/XSL/Transform"
EXPRS = [".", "..", "*", "@*", "node()", "text()", "//*", "1", "'s'", "true()", "position()", "last()",
         "count(//*)", "name()", "local-name(..)", "string(.)", "1 div 0", "-0", "0 div 0", "/", "id('x')",
         "key('k', .)", "document('')", "current()", "generate-id()", "$v", "concat(., 'x')",
         "sum(//@*)", "*[1]", "*[last()]", "following-sibling::*[1]", "ancestor-or-self::*",
         "namespace::*", "processing-instruction()", "comment()", "//@*[2]", "number(.)",
         "format-number(12345.678, '#,##0.0')", "substring(., 2, 3)", "translate(., 'abc', 'ABC')",
         "not(*)", "boolean(@*)", "string-length()", "normalize-space()", "round(2.5)", "floor(-1.5)",
         "system-property('xsl:vendor')", "element-available('xsl:if')", "unparsed-entity-uri('x')",
         "exsl:node-set($v)", "'<'", "@nope", "foo:bar", "1 +", "(", "count()", "\"q\"",
        ].freeze
NAMES = %w[value-of copy-of apply-templates for-each if choose when otherwise element attribute text
           comment processing-instruction copy number variable param with-param call-template sort
           message fallback apply-imports].freeze

def mutate(doc, rng)
  elems = doc.xpath("//*")
  return false if elems.empty?

  el = elems[rng.rand(elems.size)]
  case rng.rand(9)
  when 0 then el.remove unless el == doc.root
  when 1 then el.add_next_sibling(el.dup) unless el == doc.root
  when 2
    attrs = %w[select test match name mode use value count from format level data-type order]
    a = attrs[rng.rand(attrs.size)]
    el[a] = EXPRS[rng.rand(EXPRS.size)]
  when 3
    return false if el.attributes.empty?

    el.remove_attribute(el.attributes.keys.sample(random: rng))
  when 4
    if el.namespace&.href == XSL
      el.name = NAMES[rng.rand(NAMES.size)]
    end
  when 5
    other = elems[rng.rand(elems.size)]
    el.add_child(other.dup) unless other.ancestors.include?(el) || other == el
  when 6
    el.add_child(Nokogiri::XML::Text.new(["  ", "x", "&", " y "].sample(random: rng), doc))
  when 7
    el["priority"] = ["1", "-1", "0.5", "x", "2"].sample(random: rng) if el.name == "template"
  when 8
    ns = el.namespace_definitions.first
    el.remove_attribute("exclude-result-prefixes") if ns
  end
  true
end

cases = []
count.times do |i|
  base = corpus[rng.rand(corpus.size)]
  doc = Nokogiri::XML(base["xsl"])
  next if doc.root.nil?

  (1 + rng.rand(3)).times { mutate(doc, rng) }
  cases << base.merge("name" => "fuzz#{seed}/#{i}/#{base["name"]}", "xsl" => doc.to_xml, "timeout" => 20)
end
$stdout.binmode
$stdout.write(Marshal.dump(cases))
