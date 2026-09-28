# frozen_string_literal: true

# Runs Ruby snippets against both the native gem and the pure implementation and diffs results.
# ruby test-pure/html5/snippets.rb
SNIPPETS = <<~'RUBY'.split("\n---\n")
  Nokogiri::HTML5("<p>x").errors
  ---
  Nokogiri::HTML5("<p>x", max_errors: 10).errors.map(&:to_s)
  ---
  Nokogiri::HTML5("﻿<p>x", max_errors: 10).errors.map { [_1.to_s, _1.line, _1.column] }
  ---
  Nokogiri::HTML5("a\tb\t<x \t\u0001>", max_errors: 10).errors.map { [_1.to_s, _1.line, _1.column] }
  ---
  Nokogiri::HTML5("a\r\nb\r<x\r\n\u0001>\r", max_errors: 10).errors.map { [_1.to_s, _1.line, _1.column] }
  ---
  Nokogiri::HTML5("<p>x", max_errors: "1")
  ---
  Nokogiri::HTML5("<p>x", max_errors: 1.9).errors.size
  ---
  Nokogiri::HTML5("<p>x", max_errors: 2**40)
  ---
  Nokogiri::HTML5("<p>x", max_errors: true)
  ---
  Nokogiri::HTML5("<p>x", foo: 1)
  ---
  Nokogiri::Gumbo.parse("x", nil, Nokogiri::HTML5::Document, max_errors: 1, max_tree_depth: 1)
  ---
  Nokogiri::Gumbo.parse("x", nil, Nokogiri::HTML5::Document)
  ---
  Nokogiri::Gumbo.parse(123, nil, Nokogiri::HTML5::Document, max_errors: 1, max_tree_depth: 1, max_attributes: 1)
  ---
  Nokogiri::Gumbo.parse(nil, nil, Nokogiri::HTML5::Document, max_errors: 1, max_tree_depth: 1, max_attributes: 1)
  ---
  d = Nokogiri::Gumbo.parse("<p>x", "http://a/", Nokogiri::HTML5::Document, max_errors: -1, max_tree_depth: -1, max_attributes: -1); [d.url, d.quirks_mode, d.errors.map(&:file), d.encoding, d.class]
  ---
  d = Nokogiri::HTML5("<!DOCTYPE html PUBLIC '' ''><p>x"); [d.internal_subset.name, d.internal_subset.external_id, d.internal_subset.system_id, d.quirks_mode]
  ---
  d = Nokogiri::HTML5("<!DOCTYPE><p>x"); [d.internal_subset.name, d.internal_subset.external_id, d.internal_subset.system_id, d.quirks_mode]
  ---
  d = Nokogiri::HTML5("<!DOCTYPE foo PUBLIC 'a' 'b'><p>x"); [d.internal_subset.name, d.internal_subset.external_id, d.internal_subset.system_id, d.quirks_mode, d.children.map(&:name)]
  ---
  d = Nokogiri::HTML5("<p>x"); [d.internal_subset, d.quirks_mode]
  ---
  f = Nokogiri::HTML5.fragment("<td>x", context: "foo:bar")
  ---
  f = Nokogiri::HTML5.fragment("<td>x", context: "xy:td")
  ---
  f = Nokogiri::HTML5.fragment("<td>x", context: "abcde:td")
  ---
  f = Nokogiri::HTML5.fragment("<td>x", context: "HTML:tr", max_errors: 5); [f.children.map(&:name), f.errors.map(&:to_s), f.quirks_mode]
  ---
  f = Nokogiri::HTML5.fragment("<td>x", context: "SVG", max_errors: 5); [f.children.map(&:name), f.errors.map(&:to_s)]
  ---
  f = Nokogiri::HTML5.fragment("<mi>x", context: "Math", max_errors: 5); [f.children.map(&:name), f.errors.map(&:to_s)]
  ---
  f = Nokogiri::HTML5.fragment("<p>x", context: "a\0b")
  ---
  f = Nokogiri::HTML5.fragment("<input><form>x", context: "FORM", max_errors: 5); [f.to_html, f.errors.map(&:to_s)]
  ---
  d = Nokogiri::HTML5("<!DOCTYPE html><form><div></div></form>"); div = d.root.children[1].children[0].children[0]; f = div.fragment("<form>y</form>"); [f.to_html, f.quirks_mode]
  ---
  d = Nokogiri::HTML5("<p></p>"); f = d.root.children[1].children[0].fragment("<table>y"); [f.to_html, f.quirks_mode]
  ---
  d = Nokogiri::HTML5("<!DOCTYPE html PUBLIC '-//W3C//DTD XHTML 1.0 Frameset//' ''><p></p>"); f = d.root.children[1].children[0].fragment("<p><table>y"); [f.to_html, f.quirks_mode, d.quirks_mode]
  ---
  d = Nokogiri::HTML5("<!DOCTYPE html PUBLIC '-//W3C//DTD HTML 4.01 Transitional//'><p></p>"); f = d.root.children[1].children[0].fragment("<p><table>y"); [f.to_html, f.quirks_mode, d.quirks_mode]
  ---
  d = Nokogiri::XML("<root xmlns='urn:x'><a/></root>"); d2 = Nokogiri::HTML5::Document.new; f = Nokogiri::HTML5::DocumentFragment.new(d2, "<p>", d.root.children[0])
  ---
  d = Nokogiri::HTML5("<math><annotation-xml encoding='TEXT/HTML'></annotation-xml></math>"); ax = d.root.children[1].children[0].children[0]; f = ax.fragment("<p>x</p><svg>"); [f.to_html, f.errors.size]
  ---
  d = Nokogiri::HTML5("<math><annotation-xml encoding='TEXT/HTML'></annotation-xml></math>"); ax = d.root.children[1].children[0].children[0]; f = Nokogiri::HTML5::DocumentFragment.new(d, "<p>x</p>", ax, max_errors: 3); [f.to_html, f.errors.map(&:to_s)]
  ---
  d = Nokogiri::HTML5("<p>" * 10, max_tree_depth: 5)
  ---
  d = Nokogiri::HTML5.fragment("<p>" * 10, max_tree_depth: 5)
  ---
  d = Nokogiri::HTML5.fragment("<p>" * 4, max_tree_depth: 5).to_html
  ---
  d = Nokogiri::HTML5("<p a=1 b=2 c=3>", max_attributes: 2)
  ---
  d = Nokogiri::HTML5("<p a=1 b=2 a=3>", max_attributes: 2, max_errors: 3).errors.map(&:to_s)
  ---
  Nokogiri::HTML5("<p>" + "&amp;" * 3 + "\xff".b + "é".b + "\xe2\x82".b, max_errors: 10).errors.map(&:to_s)
  ---
  Nokogiri::HTML5("<p>" + "\xff\xfe".b, max_errors: 10).errors.map(&:to_s)
  ---
  Nokogiri::HTML5("<p>é".encode("ISO-8859-1"), max_errors: 10).to_html
  ---
  Nokogiri::HTML5("<p>é".encode("UTF-16LE"), max_errors: 10).to_html
  ---
  Nokogiri::HTML5("<p id=a><p id=a>").to_html
  ---
  Nokogiri::HTML5("<svg><clippath/><foreignobject><p/></foreignobject></svg><math><mi xlink:href=x xml:lang=y xmlns=z xmlns:xlink=q definitionurl=1/></math>", max_errors: 20).to_html
  ---
  d = Nokogiri::HTML5("<svg xlink:href=x><a xml:lang=y xmlns=z xmlns:xlink=q></svg><math xlink:href=1>"); d.root.namespace_definitions.map { [_1.prefix, _1.href] } + d.root.children[1].children.flat_map { |c| c.attribute_nodes.map { |a| [a.name, a.namespace&.prefix] } }
  ---
  f = Nokogiri::HTML5.fragment("<svg xlink:href=x></svg><div><math></math></div><svg xml:lang=q>"); f.children.map { |c| c.namespace_definitions.map { [_1.prefix, _1.href] } }
  ---
  Nokogiri::HTML5("<p>" + "x" * 70000 + "<!--c-->\n<b>" + "\n" * 70000 + "<i>y</i>").root.children[1].children.map { [_1.name, _1.line] }
  ---
  Nokogiri::HTML5("<table><tr><td>a</td></tr>x y<tr><td>", max_errors: 10).errors.map(&:to_s)
  ---
  Nokogiri::HTML5("<textarea>\nx</textarea><pre>\n\ny</pre>").to_html
RUBY

require "open3"
here = __dir__
runner = <<~'R'
  require "nokogiri"
  snippets = Marshal.load($stdin.read)
  out = snippets.map do |s|
    begin
      r = eval(s)
      r.inspect.gsub(/0x[0-9a-f]+/, "0x?")
    rescue Exception => e
      "EXC #{e.class}: #{e.message}"
    end
  end
  print Marshal.dump(out)
R
native, = Open3.capture2("ruby", "-e", 'gem "nokogiri", "1.19.4"; ' + runner, stdin_data: Marshal.dump(SNIPPETS), binmode: true)
pure, = Open3.capture2("ruby", "-W0", "-I#{here}/../../lib", "-e", runner, stdin_data: Marshal.dump(SNIPPETS), binmode: true)
native = Marshal.load(native)
pure = Marshal.load(pure)
bad = 0
SNIPPETS.each_with_index do |s, i|
  next if native[i] == pure[i]

  bad += 1
  puts "=== #{s}"
  puts "native: #{native[i][0, 2000]}"
  puts "pure:   #{pure[i][0, 2000]}"
end
puts "#{SNIPPETS.size - bad}/#{SNIPPETS.size} snippets match"
