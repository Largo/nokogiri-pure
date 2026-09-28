# frozen_string_literal: true

# Differential test: run XPath expressions against native Nokogiri (the oracle) and nokogiri-pure.
#   ruby test-pure/xpath/compare.rb [cases_file]
# Runs itself twice: once with the native gem (MODE=native), once with -Ilib (MODE=pure), diffs.
require "json"
require "open3"

CASES = ARGV[0] || File.join(__dir__, "cases.rb")

if ENV["MODE"].nil?
  root = File.expand_path("../..", __dir__)
  outs = {}
  { "native" => ["ruby", __FILE__, CASES], "pure" => ["ruby", "-W0", "-I#{root}/lib", __FILE__, CASES] }.each do |mode, cmd|
    out, err, st = Open3.capture3({ "MODE" => mode }, *cmd)
    unless st.success?
      warn "#{mode} failed:\n#{err}"
    end
    outs[mode] = out.lines
  end
  n = outs["native"]
  pu = outs["pure"]
  fails = 0
  n.each_with_index do |line, i|
    next if line == pu[i]

    fails += 1
    puts "NATIVE: #{line}"
    puts "PURE:   #{pu[i]}"
    puts
  end
  puts "#{n.length} results, #{fails} differences"
  exit(fails == 0 ? 0 : 1)
end

if ENV["MODE"] == "native"
  gem "nokogiri", "1.19.4"
  require "nokogiri"
  def parse(xml) = Nokogiri::XML(xml)
else
  require "nokogiri"
  require_relative "tree_builder"
  def parse(xml) = XPathScratch.parse(xml)
end

def sig(obj)
  case obj
  when Nokogiri::XML::NodeSet
    "SET[" + obj.map { |n| sig(n) }.join(", ") + "]"
  when Nokogiri::XML::Namespace
    "NS(#{obj.prefix.inspect}=#{obj.href.inspect})"
  when Nokogiri::XML::Node
    "#{obj.class.name.split("::").last}(#{obj.path})"
  when Float
    obj.nan? ? "NaN" : (obj == 0 && 1.0 / obj < 0 ? "-0.0" : obj.inspect)
  else
    obj.inspect
  end
end

class Handler
  def thing(*a) = a.first
  def num = 42
  def str(s) = "<#{s}>"
  def nodes(ns) = ns
  def arr(ns) = ns.to_a.reverse
  def nilly = nil
  def bad = :sym
  def args(*a) = a.map { |x| x.class.name }.join(",")
  def bool = true
end

load CASES
DOCS.each do |name, xml|
  doc = parse(xml)
  EXPRS.each do |ctx_path, expr, opts|
    opts ||= {}
    begin
      ctx = ctx_path == "/" ? doc : doc.at_xpath(ctx_path)
      if ctx.nil?
        puts "#{name} #{ctx_path} #{expr.inspect} => NOCTX"
        next
      end
      c = Nokogiri::XML::XPathContext.new(ctx)
      (opts[:ns] || {}).each { |k, v| c.register_ns(k, v) }
      (opts[:vars] || {}).each { |k, v| c.register_variable(k, v) }
      res = c.evaluate(expr, opts[:handler] ? Handler.new : nil)
      puts "#{name} #{ctx_path} #{expr.inspect} => #{sig(res)}"
    rescue Exception => e # rubocop:disable Lint/RescueException
      extra = e.respond_to?(:int1) ? " code=#{e.code} dom=#{e.domain} lvl=#{e.level} str1=#{e.str1.inspect} int1=#{e.int1}" : ""
      puts "#{name} #{ctx_path} #{expr.inspect} => ERR #{e.class}: #{e.message}#{extra}"
    end
  end
end
