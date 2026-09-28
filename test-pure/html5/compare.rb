# frozen_string_literal: true

# ruby -Ilib test-pure/html5/compare.rb ORACLE [filter-regex] [--api]
# Compares the pure HTML5 parser against the oracle dump produced by gen_oracle.rb.
require "nokogiri"
require_relative "cases"
require_relative "dump_native"

module DumpPure
  P = Nokogiri::Pure
  module_function

  def text_of(attr)
    s = +""
    c = attr.children
    while c
      s << c.content.to_s
      c = c.next
    end
    s
  end

  def node_lines(node, depth, out)
    ind = "  " * depth
    case node.type
    when P::ELEMENT_NODE
      ns = node.ns
      nsdefs = []
      d = node.ns_def
      while d
        nsdefs << "#{d.prefix}=#{d.href}"
        d = d.next
      end
      out << "#{ind}E #{ns&.prefix}|#{ns&.href}|#{node.name} L#{node.line} [#{nsdefs.join(",")}]"
      a = node.properties
      while a
        ans = a.ns
        out << "#{ind}  A #{ans&.prefix}|#{ans&.href}|#{a.name}=#{text_of(a).inspect}"
        a = a.next
      end
      c = node.children
      while c
        node_lines(c, depth + 1, out)
        c = c.next
      end
    when P::TEXT_NODE
      out << "#{ind}T #{node.content.inspect} L#{node.line}"
    when P::CDATA_SECTION_NODE
      out << "#{ind}C #{node.content.inspect} L#{node.line}"
    when P::COMMENT_NODE
      out << "#{ind}M #{node.content.inspect} L#{node.line}"
    when P::DTD_NODE
      out << "#{ind}D #{node.name.inspect} #{node.external_id.inspect} #{node.system_id.inspect}"
    else
      out << "#{ind}? #{node.type}"
    end
  end

  def run(c)
    opts = { max_errors: -1, parse_noscript_content_as_text: c[:script] }
    out = []
    begin
      if c[:context]
        doc = Nokogiri::HTML5::Document.new
        frag = Nokogiri::HTML5::DocumentFragment.new(doc, c[:data], c[:context], **opts)
        target = frag
      else
        doc = Nokogiri::HTML5.parse(c[:data], **opts)
        target = doc
      end
      n = P.unwrap(target).children
      while n
        node_lines(n, 0, out)
        n = n.next
      end
      out << "Q #{target.quirks_mode.inspect}"
      (target.errors || []).each do |e|
        out << "ERR #{e.line}:#{e.column} #{e.str1} #{Exception.instance_method(:to_s).bind_call(e).inspect} file=#{e.file.inspect} lvl=#{e.level} dom=#{e.domain} code=#{e.code}"
      end
    rescue => e
      out << "EXC #{e.class}: #{e.message}"
      out << e.backtrace.first(8).join("\n") if ENV["BT"]
    end
    out
  end
end

oracle = Marshal.load(File.binread(ARGV[0]))
filter = ARGV[1] && Regexp.new(ARGV[1])
use_api = ARGV.include?("--api")
cases = Html5Cases.all
cases = cases.select { |c| c[:id] =~ filter } if filter
fails = []
t0 = Time.now
cases.each do |c|
  got = use_api ? DumpNative.run(c) : DumpPure.run(c)
  exp = oracle[c[:id]]
  fails << [c, exp, got] unless got == exp
end
puts "#{cases.size - fails.size}/#{cases.size} match (#{(Time.now - t0).round(2)}s)"
fails.first(Integer(ENV.fetch("SHOW", "3"))).each do |c, exp, got|
  puts "=== #{c[:id]} ctx=#{c[:context].inspect}: #{c[:data].inspect}"
  (0...[exp.size, got.size].max).each do |i|
    mark = exp[i] == got[i] ? " " : "!"
    puts "#{mark} exp: #{exp[i]}"
    puts "#{mark} got: #{got[i]}" unless exp[i] == got[i]
  end
end
File.write(ENV["FAILS"], fails.map { |c, *| c[:id] }.join("\n")) if ENV["FAILS"]
