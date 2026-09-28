# frozen_string_literal: true

# Differential checks of the XPath engine's specialised internals:
#   - FastCollect traversals (single context node, whole node-sets, [n] ranges, sibling counts)
#     against the generic xmlXPathNodeCollectAndTest loop of the same engine (plan-less ops);
#   - document-order comparison / sorting, node-set merges and string->number conversion against
#     the straightforward port at BASE (a git revision; default: the commit before the
#     evaluation speed-ups).
#   ruby test-pure/xpath/internals_diff.rb [BASE]
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "nokogiri"

BASE = ARGV[0] || "9529fa7"
P = Nokogiri::Pure
X = P::XPath
FC = X::FastCollect
ROOT = File.expand_path("../..", __dir__)

def base_source(path)
  src = IO.popen(["git", "-C", ROOT, "show", "#{BASE}:#{path}"], &:read)
  abort "can't read #{path} at #{BASE}" unless $?.success?
  src
end

def extract(src, name, indent)
  i = src.index("#{indent}def #{name}(") or abort "no #{name} at #{BASE}"
  j = src.index("\n#{indent}end\n", i)
  src[i..j + indent.length + 4]
end

xpath_rb = base_source("lib/nokogiri/pure/xpath.rb")
old = %w[doc_order cmp_nodes_ext cmp_turtle wrap_cmp node_set_sort binary_insertion_find
         binary_insertion_sort_start compute_minrun reverse_elements count_run check_invariant
         tim_sort_merge tim_sort_collapse tim_push_next tim_sort node_set_merge membership_tables
         node_set_dup_ns string_eval_number].map { |n| extract(xpath_rb, n, "      ") }.join("\n")
eval("module Nokogiri; module Pure; module XPath; module Base; module_function\n#{old}\nend; end; end; end") # rubocop:disable Security/Eval
merge = extract(base_source("lib/nokogiri/pure/xpath/evaluator.rb"), "merge_and_clear", "        ")
         .sub("def merge_and_clear(", "def base_merge_and_clear(")
eval("module Nokogiri; module Pure; module XPath; class ParserContext\n#{merge}\nend; end; end; end") # rubocop:disable Security/Eval
B = X::Base

$diffs = 0
def diff(what)
  $diffs += 1
  puts "DIFF #{what}" if $diffs <= 30
end

def ids(set) = set.map { |n| n.is_a?(P::XmlNs) ? [n.next.__id__, n.prefix] : n.__id__ }

# ---- documents -------------------------------------------------------------------------------

def all_nodes(n, acc = [], seen = {}.compare_by_identity)
  return acc if n.nil? || seen[n]

  seen[n] = true
  acc << n
  all_nodes(n.properties, acc, seen) if n.type == P::ELEMENT_NODE
  c = n.children
  while c && !c.is_a?(P::XmlNs)
    all_nodes(c, acc, seen)
    c = c.next
  end
  all_nodes(n.int_subset, acc, seen) if n.is_a?(P::XmlDoc)
  acc
end

docs = []
docs << Nokogiri::XML(<<~XML, nil, nil, Nokogiri::XML::ParseOptions::DEFAULT_XML | Nokogiri::XML::ParseOptions::DTDLOAD)
  <?xml version="1.0"?>
  <?lead x?>
  <!DOCTYPE r [<!ENTITY e "ent<b>x</b><a/>"><!ENTITY f "plain"><!ELEMENT r ANY><!ATTLIST a k CDATA "d">]>
  <!--c0-->
  <r xmlns:p="urn:p" xmlns="urn:d"><a p:k="1" k="2">t<p:a/><b>x<a/></b><!--c1--><?pi y?></a>&e;&f;<![CDATA[cd]]><b/><a><a><a><b/></a></a></a></r>
XML
docs << Nokogiri::HTML4("<!DOCTYPE html><div class='x'><p>a<b>b</b>c</p><ul><li>1</li><li>2<i>x</i></li></ul></div><span>s</span>")
docs << Nokogiri::HTML5("<table><tr><td>1<td>2</table><p>x<br>y<!--z-->")
docs << Nokogiri::XML("<c>" + (1..40).map { |i| "<b i='#{i}'><t>x</t><a>y</a> <!--k--></b>" }.join + "</c>")
docs << Nokogiri::XML("<r>" + ("<a>t" * 120) + ("</a>" * 120) + "<a/></r>")
# document-order stamps (xmlXPathOrderDocElems), then changes: stale and missing stamps
st = Nokogiri::XML("<r><a><b/><c/></a><d><e/>txt<f/></d><g/></r>")
X.order_doc_elems(P.unwrap(st))
st.at("g").add_previous_sibling("<h><i/></h>")
st.at("b").add_next_sibling(st.at("e"))
st.root.add_child(st.at("a"))
docs << st
# inconsistent trees: nodes whose parent pointer doesn't match their list
bad = Nokogiri::XML("<r><a><b/><c/></a><d><e/></d><f/></r>")
P.unwrap(bad.at("c")).parent = P.unwrap(bad.at("d"))
docs << bad
bad2 = Nokogiri::XML("<r><a><b/><c/></a><d/></r>")
P.unwrap(bad2.at("c")).parent = nil
docs << bad2
dangling = Nokogiri::XML("<r><a><b/>t</a><c/></r>").at("a").tap(&:unlink)

ctxs = []
docs.each { |d| all_nodes(P.unwrap(d)).each { |n| ctxs << [n, P.unwrap(d)] } }
all_nodes(P.unwrap(dangling)).each { |n| ctxs << [n, P.unwrap(dangling.document)] }
nodes = ctxs.map(&:first)

# ---- traversals vs the generic collector ------------------------------------------------------

TESTS = [
  [X::NODE_TEST_NAME, X::NODE_TYPE_NODE, nil, "a"], [X::NODE_TEST_NAME, X::NODE_TYPE_NODE, "p", "a"],
  [X::NODE_TEST_NAME, X::NODE_TYPE_NODE, "d", "a"], [X::NODE_TEST_NAME, X::NODE_TYPE_NODE, "*", "a"],
  [X::NODE_TEST_NAME, X::NODE_TYPE_NODE, nil, "k"], [X::NODE_TEST_NAME, X::NODE_TYPE_NODE, "p", "k"],
  [X::NODE_TEST_ALL, X::NODE_TYPE_NODE, nil, nil], [X::NODE_TEST_ALL, X::NODE_TYPE_NODE, "d", nil],
  [X::NODE_TEST_TYPE, X::NODE_TYPE_NODE, nil, nil], [X::NODE_TEST_TYPE, X::NODE_TYPE_TEXT, nil, nil],
  [X::NODE_TEST_TYPE, X::NODE_TYPE_COMMENT, nil, nil], [X::NODE_TEST_PI, X::NODE_TYPE_PI, nil, nil],
  [X::NODE_TEST_PI, X::NODE_TYPE_PI, nil, "pi"],
].freeze
AXES = [X::AXIS_CHILD, X::AXIS_DESCENDANT, X::AXIS_DESCENDANT_OR_SELF, X::AXIS_ATTRIBUTE, X::AXIS_SELF,
        X::AXIS_FOLLOWING_SIBLING, X::AXIS_PRECEDING_SIBLING, X::AXIS_PARENT, X::AXIS_ANCESTOR,
        X::AXIS_ANCESTOR_OR_SELF].freeze

# the generic loop: a COLLECT op without a plan
def generic(doc, axis, test, type, prefix, name, ctx_set, max_pos = nil)
  context = X::Context.new(doc)
  context.register_ns("p", "urn:p")
  context.register_ns("d", "urn:d")
  pc = X::ParserContext.new(context)
  op = X::Op.new(X::OP_COLLECT, -1, -1, axis, test, type, prefix, name)
  if max_pos
    op.c2 = X::Op.new(X::OP_PREDICATE, -1, -1, 0, 0, 0, nil, nil)
    op.positional = true
    op.max_pos = max_pos
  end
  pc.value_tab.push(ctx_set.dup)
  pc.node_collect_and_test(op, nil, nil, false)
  pc.value_tab.pop
rescue X::Abort
  :abort
end

URIS = { nil => nil, "*" => nil, "p" => "urn:p", "d" => "urn:d" }.freeze
runs = 0
AXES.each do |axis|
  TESTS.each do |test, type, prefix, name|
    plan = FC.plan_for(axis, test, type, prefix, name) or next
    uri = URIS[prefix]
    ctxs.each do |ctx, doc|
      next if ctx.is_a?(P::XmlNs)

      runs += 1
      want = generic(doc, axis, test, type, prefix, name, [ctx])
      got = []
      FC.run(plan[0], ctx, doc, name, uri, got, plan[1])
      diff("#{plan[0]} from #{ctx.inspect}: #{want.size} vs #{got.size}") if want == :abort || ids(want) != ids(got)
      exists = FC.exists?(plan[0], ctx, doc, name, uri, plan[1])
      diff("exists #{plan[0]} from #{ctx.inspect}") if exists != !got.empty?
      if axis == X::AXIS_PRECEDING_SIBLING || axis == X::AXIS_FOLLOWING_SIBLING
        memo = {}.compare_by_identity
        2.times do
          n = FC.count_run(:"count_#{plan[0]}", ctx, doc, name, uri, memo)
          diff("count_#{plan[0]} from #{ctx.inspect}: #{n} vs #{got.size}") if n != got.size
        end
      end
    end
    next unless axis == X::AXIS_CHILD || axis == X::AXIS_ATTRIBUTE

    # whole node-sets, and [n]
    docs.each do |d|
      dn = P.unwrap(d)
      set = all_nodes(dn).reject { |n| n.is_a?(P::XmlNs) }
      runs += 1
      out = []
      FC.multi_run(:"multi_#{plan[0]}", set, dn, name, uri, out)
      want = generic(dn, axis, test, type, prefix, name, set)
      diff("multi_#{plan[0]}") if ids(want) != ids(out)
      [0, 1, 2, 3].each do |pos|
        out = []
        FC.multi_range_run(:"multi_range_#{plan[0]}", set, dn, name, uri, out, pos)
        want = generic(dn, axis, test, type, prefix, name, set, pos)
        diff("multi_range_#{plan[0]} [#{pos}]") if ids(want) != ids(out)
      end
    end
  end
end
puts "traversals: #{runs} runs"

# ---- document order ---------------------------------------------------------------------------

r = Random.new(1)
pairs = 0
nodes.each do |a|
  Array.new(60) { nodes[r.rand(nodes.length)] }.each do |b|
    pairs += 1
    o = begin; B.cmp_nodes_ext(a, b); rescue => e; e.class; end
    n = begin; X.cmp_nodes_ext(a, b); rescue => e; e.class; end
    diff("cmp #{a.inspect} #{b.inspect}: #{o} vs #{n}") if o != n
  end
end
sorts = 0
groups = docs.map { |d| all_nodes(P.unwrap(d)) } + [nodes]
groups.each do |g|
  200.times do |k|
    set = Array.new(r.rand(1..150)) { g[r.rand(g.length)] }.uniq
    set = set.select { |n| n.type == P::ELEMENT_NODE } if k % 3 == 0
    sorted = set.dup
    (B.node_set_sort(sorted) rescue next)
    variants = [set, sorted, sorted.reverse]
    if sorted.length > 2
      v = sorted.dup
      j = r.rand(sorted.length - 1)
      v[j], v[j + 1] = v[j + 1], v[j]
      variants << v
    end
    variants.each do |inp|
      sorts += 1
      a = inp.dup
      b = inp.dup
      ea = begin; B.node_set_sort(a); nil; rescue => e; e.class; end
      eb = begin; X.node_set_sort(b); nil; rescue => e; e.class; end
      diff("sort #{k}") if ea != eb || ids(a) != ids(b)
    end
  end
end
puts "document order: #{pairs} comparisons, #{sorts} sorts"

# ---- node-set merges --------------------------------------------------------------------------

ns_doc = Nokogiri::XML("<r xmlns:a='urn:a' xmlns:b='urn:b'><x xmlns:c='urn:c'><y/></x><z/>t</r>")
dn = P.unwrap(ns_doc)
pool = all_nodes(dn).reject { |n| n.is_a?(P::XmlDoc) }
els = pool.select { |n| n.type == P::ELEMENT_NODE }
nss = els.flat_map { |e| (P::Tree.get_ns_list(dn, e) || []).map { |ns| X.node_set_dup_ns(e, ns) } }
pool += nss + nss.map { |ns| X.node_set_dup_ns(ns.next, ns) }
pc = X::ParserContext.new(X::Context.new(dn))
merges = 0
3000.times do
  s1a = []
  s1b = []
  sta = []
  stb = []
  r.rand(1..40).times do
    s2 = Array.new(r.rand(0..12)) { pool[r.rand(pool.size)] }
    pc.base_merge_and_clear(s1a, s2.dup, sta)
    pc.merge_and_clear(s1b, s2.dup, stb)
  end
  merges += 1
  diff("merge_and_clear") if ids(s1a) != ids(s1b)
  a = Array.new(r.rand(0..15)) { pool[r.rand(pool.size)] }
  b = Array.new(r.rand(0..15)) { pool[r.rand(pool.size)] }
  diff("node_set_merge") if ids(B.node_set_merge(a.dup, b.dup)) != ids(X.node_set_merge(a.dup, b.dup))
  s = a.dup
  t = a.dup
  diff("node_set_merge self") if ids(B.node_set_merge(s, s)) != ids(X.node_set_merge(t, t))
end
puts "merges: #{merges * 2}"

# ---- string -> number -------------------------------------------------------------------------

alpha = %w[0 1 2 3 4 5 6 7 8 9 9 9 . - + e E x] + [" ", "\t"]
strs = ["", " ", "1", "-1", "1.5", ".5", "5.", "-.5", "1e3", "1E-3", " 12 ", "1.2.3", "-0", "0.1",
        "99999999999999999999999", "0.0000000000000000000000001", "1e400", "1e-400",
        "123456789012345678901234567890.123456789012345678901234567890"]
50_000.times { strs << Array.new(r.rand(0..14)) { alpha[r.rand(alpha.size)] }.join }
strs.each do |s|
  a = B.string_eval_number(s)
  b = X.string_eval_number(s)
  diff("number #{s.inspect}: #{a} vs #{b}") unless (a.nan? && b.nan?) || (a == b && (a != 0 || 1.0 / a == 1.0 / b))
end
puts "numbers: #{strs.size}"

puts $diffs.zero? ? "ok: 0 differences" : "#{$diffs} differences"
exit($diffs.zero? ? 0 : 1)
