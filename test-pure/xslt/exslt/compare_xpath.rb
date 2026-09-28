# frozen_string_literal: true

# Differential test of the EXSLT functions at the XPath level (does not need the XSLT core):
#   ruby test-pure/xslt/exslt/compare_xpath.rb [filter-regexp]
#
# native: each case runs in its own libxslt transform:
#           <t>exsl:object-type(EXPR)</t><v><xsl:copy-of select="EXPR"/></v>
# pure:   EXPR is evaluated with Pure::XPath on a context where the EXSLT functions are
#         registered and whose +extra+ is a minimal transform context (for RVTs); the result is
#         serialized like xsl:copy-of would.
require "json"
require "open3"
require_relative "xpath_cases"

FILTER = ARGV[0] ? Regexp.new(ARGV[0]) : nil

def cases
  EXSLTCases::ALL.select { |c| FILTER.nil? || FILTER.match?(c) }
end

def shape(str) = str.gsub(/\d/, "9")

if ENV["MODE"].nil?
  root = File.expand_path("../../..", __dir__)
  outs = {}
  { "native" => ["ruby", __FILE__, *ARGV],
    "pure" => ["ruby", "-W0", "-I#{root}/lib", __FILE__, *ARGV] }.each do |mode, cmd|
    out, err, st = Open3.capture3({ "MODE" => mode }, *cmd)
    warn "#{mode} failed:\n#{err}" unless st.success?
    outs[mode] = JSON.parse(out.empty? ? "[]" : out)
  end
  n = outs["native"]
  pu = outs["pure"]
  fails = 0
  cases.each_with_index do |c, i|
    a = n[i]
    b = pu[i]
    if c.start_with?("~")
      a = shape(a.to_s)
      b = shape(b.to_s)
    end
    next if a == b

    fails += 1
    puts "CASE:   #{c}"
    puts "NATIVE: #{a.inspect}"
    puts "PURE:   #{b.inspect}"
    puts
  end
  puts "#{cases.length} cases, #{fails} differences"
  exit(fails == 0 ? 0 : 1)
end

NS_DECLS = EXSLTCases::NAMESPACES.map { |p, u| %(xmlns:#{p}="#{u}") }.join(" ")

def attr_escape(s) = s.encode(xml: :attr)[1..-2]

if ENV["MODE"] == "native"
  gem "nokogiri", "1.19.4"
  require "nokogiri"
  doc = Nokogiri::XML(EXSLTCases::INPUT)
  results = cases.map do |c|
    expr = attr_escape(c.delete_prefix("~"))
    xsl = <<~XSL
      <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" #{NS_DECLS}>
      <xsl:template match="/"><r><t><xsl:value-of select="exsl:object-type(#{expr})"/></t><v><xsl:copy-of select="#{expr}"/></v></r></xsl:template>
      </xsl:stylesheet>
    XSL
    begin
      res = Nokogiri::XSLT(xsl).transform(doc)
      t = res.at("/r/t").text
      v = res.at("/r/v").children.map { |x| x.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML) }.join
      "#{t}|#{v}"
    rescue StandardError
      "ERROR"
    end
  end
  puts JSON.generate(results)
  exit
end

# ---- pure ----------------------------------------------------------------------------------
require "nokogiri"
require_relative "../../xpath/tree_builder"
Dir[File.expand_path("../../../lib/nokogiri/pure/xslt/*.rb", __dir__)].sort.each { |f| require f }
require "nokogiri/pure/xslt/exslt"

P = Nokogiri::Pure
X = P::XSLT
E = X::EXSLT
XP = P::XPath

rdoc = XPathScratch.parse(EXSLTCases::INPUT)
doc = rdoc.instance_variable_get(:@__native)

def make_context(doc)
  ctx = XP::Context.new(doc)
  EXSLTCases::NAMESPACES.each { |p, u| ctx.register_ns(p, u) }
  fns = {
    E::MATH_NAMESPACE => E::MATH_FUNCTIONS, E::SETS_NAMESPACE => E::SETS_FUNCTIONS,
    E::STRINGS_NAMESPACE => E::STR_FUNCTIONS, E::DATE_NAMESPACE => E::DATE_FUNCTIONS,
    E::COMMON_NAMESPACE => [["node-set", :node_set_function], ["object-type", :object_type_function]],
    E::DYNAMIC_NAMESPACE => [["evaluate", :dyn_evaluate_function], ["map", :dyn_map_function]],
    E::SAXON_NAMESPACE => [["expression", :saxon_expression_function], ["eval", :saxon_eval_function],
                           ["evaluate", :saxon_evaluate_function], ["systemId", :saxon_system_id_function],
                           ["line-number", :saxon_line_number_function]],
  }
  fns.each { |uri, list| list.each { |name, m| ctx.register_func_ns(name, uri, E.method(m)) } }
  tctxt = X::TransformContext.new
  tctxt.xpath_ctxt = ctx
  tctxt.state = X::STATE_OK
  tctxt.depth = 0
  tctxt.max_template_depth = 3000
  ext = { E::SAXON_NAMESPACE => {} }
  tctxt.define_singleton_method(:__ext_data) { ext }
  ctx.extra = tctxt
  ctx
end

# the saxon module data (xsltGetExtData) without the extension-module machinery
X.singleton_class.prepend(Module.new do
  def get_ext_data(ctxt, uri)
    return ctxt.__ext_data[uri] if ctxt.respond_to?(:__ext_data)

    super
  end
end)

AS_XML = Nokogiri::XML::Node::SaveOptions::AS_XML

def ser_node(n)
  if n.type == P::DOCUMENT_NODE
    n.child_list.map { |c| ser_node(c) }.join
  else
    d = n.doc
    P.wrap_document(Nokogiri::XML::Document, d) if d && d._ruby_doc.nil?
    # (natively the copied exsl: namespace is declared on the <r> result element)
    P.wrap_node(n).to_xml(save_with: AS_XML).sub(%( xmlns:exsl="http://exslt.org/common"), "")
  end
end

def ser(res)
  case res
  when XP::ValueTree then res.empty? ? "" : res[0].child_list.map { |c| ser_node(c) }.join
  when Array then res.map { |n| ser_node(n) }.join
  else
    s = XP.cast_to_string(res)
    s = s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub("\r", "&#13;")
    s.gsub(/[^\x00-\x7F]/) { |ch| format("&#x%X;", ch.ord) }
  end
end

def type_name(res)
  case res
  when String then "string"
  when Float then "number"
  when true, false then "boolean"
  when XP::ValueTree then "RTF"
  when Array then "node-set"
  when XP::UserObject then "external"
  end
end

results = cases.map do |c|
  expr = c.delete_prefix("~")
  begin
    ctx = make_context(doc)
    ctx.node = doc
    res = nil
    X.with_generic_error_func(->(_msg) {}) do
      P::Errors.collecting([]) { res = XP.eval(expr, ctx) }
    end
    res.nil? ? "ERROR" : "#{type_name(res)}|#{ser(res)}"
  rescue StandardError => e
    "EXCEPTION #{e.class}: #{e.message} #{e.backtrace.first(3).join(' ')}"
  end
end
puts JSON.generate(results)
