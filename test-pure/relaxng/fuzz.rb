# frozen_string_literal: true

# Random RELAX NG schemas + instances (valid-ish instances generated from the schema, then
# mutated), and random mutations of the corpus schemas, written under cases/fuzz*/ with a
# cases file for run_cases.rb:
#   ruby fuzz.rb SEED COUNT && CASES=cases/fuzz.json ruby compare.rb
require "fileutils"
require "json"

seed = (ARGV[0] || 1).to_i
count = (ARGV[1] || 200).to_i
srand(seed)
HERE = File.expand_path(__dir__)
OUT = File.join(HERE, "cases", "fuzz")
FileUtils.rm_rf(OUT)
FileUtils.mkdir_p(OUT)

RNG = "http://relaxng.org/ns/structure/1.0"
XSD = "http://www.w3.org/2001/XMLSchema-datatypes"
NAMES = %w[a b c d e f item x y].freeze
NSS = [nil, nil, nil, "urn:n1", "urn:n2"].freeze
XSD_TYPES = {
  "integer" => %w[0 1 -5 42 abc 1.5 +3],
  "int" => %w[7 2147483648 x -1],
  "string" => ["", "hello", "a b", " x "],
  "token" => ["t", " a  b ", ""],
  "NCName" => %w[ok 1bad a:b _x],
  "boolean" => %w[true false 1 0 yes],
  "decimal" => %w[1.5 -0.25 1e3 12],
  "date" => %w[2020-01-31 2020-02-30 20-1-1],
  "ID" => %w[i1 i2 i1 1x],
  "IDREF" => %w[i1 i2 zz],
  "NMTOKENS" => ["a b", "", "x,y"],
  "double" => %w[1.0 INF NaN x],
  "anyURI" => ["http://x", "a b", "%zz"],
  "language" => %w[en en-US 123],
}.freeze
FACETS = {
  "integer" => [["minInclusive", "0"], ["maxExclusive", "10"], ["totalDigits", "2"]],
  "string" => [["minLength", "1"], ["maxLength", "3"], ["pattern", "[a-z]*"], ["length", "5"]],
  "decimal" => [["fractionDigits", "1"], ["minExclusive", "0"]],
  "token" => [["enumeration", "t"], ["whiteSpace", "collapse"]],
}.freeze

def esc(s) = s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub('"', "&quot;")

class Gen
  attr_reader :defines

  def initialize
    @defines = {}
    @ndef = 0
  end

  def name_class(depth)
    case rand(10)
    when 0..6 then [:name, NAMES.sample, NSS.sample]
    when 7 then [:anyName, rand(2).zero? ? nil : [[:name, NAMES.sample, nil]]]
    when 8 then [:nsName, NSS.compact.sample, rand(3).zero? ? [[:name, NAMES.sample, nil]] : nil]
    else
      depth > 2 ? [:name, "z", nil] : [:choice, Array.new(1 + rand(2)) { name_class(depth + 1) }]
    end
  end

  def value_pattern(depth)
    case rand(8)
    when 0 then [:text]
    when 1 then [:value, nil, nil, %w[v1 v2 v3].sample]
    when 2
      t = XSD_TYPES.keys.sample
      [:value, XSD, t, XSD_TYPES[t].sample]
    when 3, 4
      t = XSD_TYPES.keys.sample
      params = rand(2).zero? && FACETS[t] ? [FACETS[t].sample] : []
      ex = rand(5).zero? ? [:value, nil, nil, XSD_TYPES[t].sample] : nil
      [:data, XSD, t, params, ex]
    when 5 then [:data, nil, %w[string token].sample, [], nil]
    when 6
      depth > 2 ? [:text] : [:list, [:oneOrMore, value_pattern(depth + 2)]]
    else
      depth > 2 ? [:text] : [:choice, Array.new(2) { value_pattern(depth + 1) }]
    end
  end

  def pattern(depth)
    r = rand(depth > 3 ? 6 : 21)
    case r
    when 0 then [:empty]
    when 1 then [:text]
    when 2, 3, 4 then element(depth + 1)
    when 5 then [:attribute, name_class(depth), value_pattern(depth)]
    when 6, 7 then [:group, Array.new(1 + rand(3)) { pattern(depth + 1) }]
    when 8, 9 then [:choice, Array.new(1 + rand(3)) { pattern(depth + 1) }]
    when 10 then [:interleave, Array.new(1 + rand(3)) { pattern(depth + 1) }]
    when 11 then [:optional, pattern(depth + 1)]
    when 12 then [:zeroOrMore, pattern(depth + 1)]
    when 13 then [:oneOrMore, pattern(depth + 1)]
    when 14 then [:mixed, pattern(depth + 1)]
    when 15 then value_pattern(depth)
    when 16
      if @defines.size < 5
        n = "d#{@ndef += 1}"
        @defines[n] = :pending
        @defines[n] = pattern(depth + 1)
        [:ref, n]
      elsif @defines.any?
        [:ref, @defines.keys.sample]
      else
        [:empty]
      end
    when 17 then rand(4).zero? ? [:notAllowed] : [:empty]
    when 18
      # wide choices / sequences exercise the automata code paths for states with many
      # transitions
      kind = %i[choice zeroOrMore oneOrMore group].sample
      elems = Array.new(8 + rand(14)) do
        [:element, [:name, (NAMES + %w[g h i j k l m n o q r s t u v w]).sample, NSS.sample], [[%i[empty text].sample]]]
      end
      case kind
      when :choice, :group then [kind, elems]
      else [kind, [:choice, elems]]
      end
    else element(depth + 1)
    end
  end

  def element(depth)
    [:element, name_class(depth), Array.new(rand(3)) { pattern(depth + 1) }.then { |a| a.empty? ? [[:empty]] : a }]
  end

  def top = element(0)
end

def nc_xml(nc)
  case nc[0]
  when :name then %(<name#{nc[2] ? %( ns="#{nc[2]}") : ""}>#{nc[1]}</name>)
  when :anyName then "<anyName>#{nc[1] ? "<except>#{nc[1].map { |x| nc_xml(x) }.join}</except>" : ""}</anyName>"
  when :nsName then %(<nsName ns="#{nc[1]}">#{nc[2] ? "<except>#{nc[2].map { |x| nc_xml(x) }.join}</except>" : ""}</nsName>)
  when :choice then "<choice>#{nc[1].map { |x| nc_xml(x) }.join}</choice>"
  end
end

def xml(p)
  case p[0]
  when :empty, :text, :notAllowed then "<#{p[0]}/>"
  when :element then "<element>#{nc_xml(p[1])}#{p[2].map { |x| xml(x) }.join}</element>"
  when :attribute then "<attribute>#{nc_xml(p[1])}#{xml(p[2])}</attribute>"
  when :group, :choice, :interleave then "<#{p[0]}>#{p[1].map { |x| xml(x) }.join}</#{p[0]}>"
  when :optional, :zeroOrMore, :oneOrMore, :mixed, :list then "<#{p[0]}>#{xml(p[1])}</#{p[0]}>"
  when :value
    lib = p[1] ? %( datatypeLibrary="#{p[1]}") : ""
    type = p[2] ? %( type="#{p[2]}") : ""
    "<value#{lib}#{type}>#{esc(p[3])}</value>"
  when :data
    lib = p[1] ? %( datatypeLibrary="#{p[1]}") : ""
    params = p[3].map { |n, v| %(<param name="#{n}">#{esc(v)}</param>) }.join
    ex = p[4] ? "<except>#{xml(p[4])}</except>" : ""
    %(<data#{lib} type="#{p[2]}">#{params}#{ex}</data>)
  when :ref then %(<ref name="#{p[1]}"/>)
  end
end

# ---- instance generation ------------------------------------------------------------------
class Inst
  def initialize(defines)
    @defines = defines
    @depth = 0
  end

  def pick_name(nc)
    case nc[0]
    when :name then [nc[1], nc[2]]
    when :anyName then [NAMES.sample, NSS.sample]
    when :nsName then [NAMES.sample, nc[1]]
    when :choice then pick_name(nc[1].sample)
    end
  end

  def value(p)
    case p[0]
    when :text then %w[t hello x].sample
    when :value then rand(6).zero? ? "zz" : p[3]
    when :data then (XSD_TYPES[p[2]] || ["s"]).sample
    when :list then Array.new(rand(3)) { value(p[1][1]) }.join(" ")
    when :choice then value(p[1].sample)
    else "v"
    end
  end

  # returns [attrs, items]; items are strings (text) or [name, ns, attrs, items]
  def gen(p)
    @depth += 1
    return [[], []] if @depth > 12

    case p[0]
    when :empty, :notAllowed then [[], []]
    when :text then [[], rand(2).zero? ? [value(p)] : []]
    when :value, :data, :list then [[], [value(p)]]
    when :element
      a, i = p[2].map { |x| gen(x) }.transpose.map(&:flatten1)
      [[], [[*pick_name(p[1]), a, i]]]
    when :attribute then [[[*pick_name(p[1]), value(p[2])]], []]
    when :group, :interleave
      parts = p[1].map { |x| gen(x) }
      parts.shuffle! if p[0] == :interleave && rand(2).zero?
      a, i = parts.transpose.map(&:flatten1)
      [a || [], i || []]
    when :choice then gen(p[1].sample)
    when :optional then rand(2).zero? ? gen(p[1]) : [[], []]
    when :zeroOrMore, :oneOrMore
      n = p[0] == :oneOrMore ? 1 + rand(2) : rand(3)
      parts = Array.new(n) { gen(p[1]) }
      parts.empty? ? [[], []] : parts.transpose.map(&:flatten1)
    when :mixed
      a, i = gen(p[1])
      [a, i.flat_map { |x| rand(2).zero? ? ["mix", x] : [x] }]
    when :ref
      d = @defines[p[1]]
      d.is_a?(Array) ? gen(d) : [[], []]
    else [[], []]
    end
  ensure
    @depth -= 1
  end

  def mutate(items)
    items = items.dup
    case rand(8)
    when 0 then items.delete_at(rand(items.size)) unless items.empty?
    when 1 then items.insert(rand(items.size + 1), items.sample) unless items.empty?
    when 2 then items.shuffle!
    when 3 then items.insert(rand(items.size + 1), ["zz", nil, [], []])
    when 4 then items.insert(rand(items.size + 1), "stray text")
    end
    items.map do |it|
      next it unless it.is_a?(Array) && rand(3).zero?

      n, ns, a, c = it
      a = a.dup
      case rand(4)
      when 0 then a.delete_at(rand(a.size)) unless a.empty?
      when 1 then a << ["extra", nil, "1"]
      when 2 then a = a.map { |an, ans, v| [an, ans, rand(2).zero? ? "zz" : v] }
      end
      [n, ns, a, mutate(c)]
    end
  end

  def ser(items, inscope = {})
    items.map do |it|
      next esc(it) if it.is_a?(String)

      n, ns, attrs, children = it
      decls = +""
      scope = inscope.dup
      pfx = nil
      if ns
        pfx = scope[ns] || "p#{scope.size}"
        unless scope[ns]
          decls << %( xmlns:#{pfx}="#{ns}")
          scope[ns] = pfx
        end
      end
      seen = {}
      as = attrs.map do |an, ans, v|
        if ans
          ap = scope[ans] || "p#{scope.size}"
          unless scope[ans]
            decls << %( xmlns:#{ap}="#{ans}")
            scope[ans] = ap
          end
          key = "#{ap}:#{an}"
        else
          key = an
        end
        next nil if seen[key]

        seen[key] = true
        %( #{key}="#{esc(v)}")
      end.compact.join
      qn = pfx ? "#{pfx}:#{n}" : n
      children.empty? ? "<#{qn}#{decls}#{as}/>" : "<#{qn}#{decls}#{as}>#{ser(children, scope)}</#{qn}>"
    end.join
  end
end

class Array
  def flatten1 = flatten(1)
end

cases = []
count.times do |k|
  g = Gen.new
  top = g.top
  defs = g.defines.select { |_, v| v.is_a?(Array) }
  schema = if defs.empty? && rand(2).zero?
    top_xml = xml(top)
    top_xml.sub("<element>", %(<element xmlns="#{RNG}">))
  else
    %(<grammar xmlns="#{RNG}"><start>#{xml(top)}</start>) +
      defs.map { |n, d| %(<define name="#{n}">#{xml(d)}</define>) }.join + "</grammar>"
  end
  dir = File.join(OUT, format("%04d", k))
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "schema.rng"), schema + "\n")
  gen = Inst.new(g.defines)
  insts = []
  6.times do |j|
    _, items = gen.gen(top)
    items = gen.mutate(items) if j >= 2
    items = [items.find { |x| x.is_a?(Array) } || ["root", nil, [], []]] if items.count { |x| x.is_a?(Array) } != 1
    p = File.join(dir, "i#{j}.xml")
    File.write(p, gen.ser(items.select { |x| x.is_a?(Array) }) + "\n")
    insts << p.sub("#{HERE}/", "")
  end
  cases << { id: "fuzz/#{format("%04d", k)}", schema: File.join(dir, "schema.rng").sub("#{HERE}/", ""), instances: insts }
end

# ---- mutations of corpus schemas --------------------------------------------------------------
corpus = JSON.parse(File.read(File.join(HERE, "cases", "cases.json")))
MUT = File.join(HERE, "cases", "fuzzmut")
FileUtils.rm_rf(MUT)
FileUtils.mkdir_p(MUT)
count.times do |k|
  c = corpus.sample
  src = File.read(File.join(HERE, c["schema"])) rescue next
  s = src.dup
  3.times do
    tags = s.scan(%r{<(/?)([A-Za-z]+)}).map { |_, t| t }.uniq
    case rand(6)
    when 0 # drop an element start/end pair content
      if (m = s.match(%r{<(empty|text|zeroOrMore|optional|choice|group|interleave|element|attribute|ref|define|start|data|value|list)\b[^>]*/>}))
        s = s.sub(m[0], "")
      end
    when 1 # rename a tag
      t = tags.sample
      s = s.gsub(/<(\/?)#{t}\b/) { "<#{$1}#{%w[choice group interleave optional oneOrMore zeroOrMore mixed list].sample}" } if t && t != "grammar"
    when 2 then s = s.sub(/name="([^"]*)"/) { %(name="#{rand(2).zero? ? "#{$1}x" : $1.upcase}") }
    when 3 then s = s.sub("<empty/>", "<notAllowed/>")
    when 4 then s = s.sub(%r{</element>}, "<text/></element>")
    else s = s.sub(/type="[^"]*"/, %(type="#{XSD_TYPES.keys.sample}"))
    end
  end
  dir = File.join(MUT, format("%04d", k))
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "schema.rng"), s)
  # resources next to the original schema stay reachable through a relative xml:base
  insts = c["instances"].map { |i| i }
  cases << { id: "fuzzmut/#{format("%04d", k)}", schema: File.join(dir, "schema.rng").sub("#{HERE}/", ""), instances: insts }
end

File.write(File.join(HERE, "cases", "fuzz.json"), JSON.pretty_generate(cases))
puts "#{cases.size} fuzz cases"
