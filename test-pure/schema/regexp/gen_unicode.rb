# frozen_string_literal: true

# Generates lib/nokogiri/pure/xmlregexp/unicode.rb from libxml2 2.13.9's xmlunicode.c and
# chvalid.c/chvalid.h (the character tables used by xmlregexp.c). libxml2's tables are
# Unicode 4.0.1; Ruby's own \p{} classes must NOT be used.
#
#   ruby test-pure/schema/regexp/gen_unicode.rb
#
# For every xmlUCSIsCat*/xmlUCSIs<Block>() function the generator extracts the set of ranges it
# accepts. Functions implemented with xmlCharInRange() binary-search a table; the generator
# checks that those tables are sorted and non-overlapping (so the binary search is equivalent to
# plain membership) and aborts otherwise.

REF = ENV["LIBXML2_SRC"] || "/root/workspace/nokogiri-pure-ref/libxml2-2.13.9"
OUT = File.expand_path("../../../lib/nokogiri/pure/xmlregexp/unicode.rb", __dir__)

def parse_range_arrays(src)
  arrays = {}
  src.scan(/static const xmlCh[SL]Range\s+(\w+)\[\]\s*=\s*\{(.*?)\};/m) do |name, body|
    arrays[name] = body.scan(/\{\s*(0x\h+)\s*,\s*(0x\h+)\s*\}/).map { |a, b| [a.hex, b.hex] }
  end
  groups = {}
  src.scan(/const xmlChRangeGroup\s+(\w+)\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*,\s*([\w()]+)\s*,\s*([\w()]+)\s*\}/m) do |name, ns, nl, s, l|
    s = s.sub(/\A\(\w+\)/, "")
    l = l.sub(/\A\(\w+\)/, "")
    sr = s == "NULL" || s == "0" ? [] : arrays.fetch(s)
    lr = l == "NULL" || l == "0" ? [] : arrays.fetch(l)
    raise "#{name}: count mismatch" if sr.size != ns.to_i || lr.size != nl.to_i

    [sr, lr].each do |tab|
      tab.each_cons(2) do |(a1, b1), (a2, b2)|
        raise "#{name}: table not sorted/disjoint (#{a1}-#{b1}, #{a2}-#{b2})" unless b1 < a2
      end
      tab.each { |a, b| raise "#{name}: bad range" unless a <= b }
    end
    sr.each { |a, b| raise "#{name}: short range above 0xffff" if b > 0xffff }
    lr.each { |a, _| raise "#{name}: long range below 0x10000" if a < 0x10000 }
    groups[name] = sr + lr
  end
  groups
end

# Parse `return( <expr> );` made only of ORs of (code >= A) && (code <= B) / (code == A)
def parse_bool_expr(fname, expr)
  ranges = []
  rest = expr.gsub(/\(\s*code\s*>=\s*(0x\h+|\d+)\s*\)\s*&&\s*\(\s*code\s*<=\s*(0x\h+|\d+)\s*\)/) do
    ranges << [Integer($1), Integer($2)]
    " R "
  end
  rest = rest.gsub(/\(\s*code\s*==\s*(0x\h+|\d+)\s*\)/) do
    ranges << [Integer($1), Integer($1)]
    " R "
  end
  leftover = rest.gsub(/[\s()R|]/, "")
  raise "#{fname}: cannot parse expression: #{expr.inspect} (leftover #{leftover.inspect})" unless leftover.empty?

  ranges
end

def normalize(ranges)
  ranges = ranges.sort
  out = []
  ranges.each do |a, b|
    if out.any? && a <= out[-1][1] + 1
      out[-1][1] = b if b > out[-1][1]
    else
      out << [a, b]
    end
  end
  out
end

uni = File.read(File.join(REF, "xmlunicode.c"))
groups = parse_range_arrays(uni)

funcs = {}
uni.scan(/^int\s*\n(xmlUCSIs\w+)\(int code\)\s*\{\s*return\s*(.*?);\s*\}/m) do |fname, body|
  if body =~ /\A\(\s*xmlCharInRange\(\(unsigned int\)code,\s*&(\w+)\)\s*\)\z/
    funcs[fname] = groups.fetch($1)
  else
    funcs[fname] = parse_bool_expr(fname, body)
  end
end

# block table, in the C order (binary-searched with strcmp by xmlUnicodeLookup)
block_tbl = uni[/static const xmlUnicodeRange xmlUnicodeBlocks\[\] = \{(.*?)\};/m, 1]
blocks = block_tbl.scan(/\{"([^"]+)",\s*(\w+)\}/)
raise "block count" unless blocks.size == 128 && uni.include?("xmlUnicodeBlockTbl = {xmlUnicodeBlocks, 128}")

cats = %w[C Cc Cf Co Cs L Ll Lm Lo Lt Lu M Mc Me Mn N Nd Nl No P Pc Pd Pe Pf Pi Po Ps S Sc Sk Sm So Z Zl Zp Zs]

chv = File.read(File.join(REF, "chvalid.c"))
chv_groups = {}
chv.scan(/static const xmlChSRange\s+(\w+)\[\]\s*=\s*\{(.*?)\};/m) do |name, body|
  chv_groups[name] = body.scan(/\{\s*(0x\h+)\s*,\s*(0x\h+)\s*\}/).map { |a, b| [a.hex, b.hex] }
end
chv.scan(/static const xmlChLRange\s+(\w+)\[\]\s*=\s*\{(.*?)\};/m) do |name, body|
  chv_groups[name] = body.scan(/\{\s*(0x\h+)\s*,\s*(0x\h+)\s*\}/).map { |a, b| [a.hex, b.hex] }
end
chgroups = {}
chv.scan(/const xmlChRangeGroup\s+(\w+)\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*,\s*([\w()]+)\s*,\s*([\w()]+)\s*\}/m) do |name, ns, nl, s, l|
  s = s.sub(/\A\(\w+\)/, "")
  l = l.sub(/\A\(\w+\)/, "")
  sr = %w[NULL 0].include?(s) ? [] : chv_groups.fetch(s)
  lr = %w[NULL 0].include?(l) ? [] : chv_groups.fetch(l)
  raise "#{name}: count mismatch" if sr.size != ns.to_i || lr.size != nl.to_i

  [sr, lr].each do |tab|
    tab.each_cons(2) { |(_, b1), (a2, _)| raise "#{name} not sorted" unless b1 < a2 }
  end
  chgroups[name] = sr + lr
end

# chvalid.h macros (< 0x100 parts), transcribed from include/libxml/chvalid.h
base_char = [[0x41, 0x5a], [0x61, 0x7a], [0xc0, 0xd6], [0xd8, 0xf6], [0xf8, 0xff]] + chgroups.fetch("xmlIsBaseCharGroup").reject { |a, _| a < 0x100 }
ideographic = [[0x3007, 0x3007], [0x3021, 0x3029], [0x4e00, 0x9fa5]]
digit = [[0x30, 0x39]] + chgroups.fetch("xmlIsDigitGroup").reject { |a, _| a < 0x100 }
combining = chgroups.fetch("xmlIsCombiningGroup").reject { |a, _| a < 0x100 }
extender = [[0xb7, 0xb7]] + chgroups.fetch("xmlIsExtenderGroup").reject { |a, _| a < 0x100 }

def fmt(name, ranges)
  flat = normalize(ranges).flatten
  lines = flat.each_slice(10).map { |sl| "          " + sl.map { |v| format("0x%x", v) }.join(", ") + "," }
  "        #{name} = [\n#{lines.join("\n")}\n        ].freeze\n"
end

out = +<<~RUBY
  # frozen_string_literal: true

  # GENERATED by test-pure/schema/regexp/gen_unicode.rb from libxml2 2.13.9 xmlunicode.c /
  # chvalid.c (Unicode 4.0.1 data as used by libxml2's regexp engine). Do not edit.
  #
  # Each table is a flat, sorted Array [lo0, hi0, lo1, hi1, ...] of disjoint inclusive ranges.

  module Nokogiri
    module Pure
      module XmlRegexp
        module Unicode
RUBY

cats.each do |c|
  out << fmt("CAT_#{c.upcase}", funcs.fetch("xmlUCSIsCat#{c}"))
end
out << "\n        # XML 1.0 (4th edition) character classes from chvalid.h (IS_BASECHAR, ...)\n"
out << fmt("BASE_CHAR", base_char)
out << fmt("IDEOGRAPHIC", ideographic)
out << fmt("DIGIT", digit)
out << fmt("COMBINING", combining)
out << fmt("EXTENDER", extender)
out << "\n        # xmlUnicodeBlocks: [name, [lo, hi, ...]] in the C table order (xmlUnicodeLookup binary-searches\n"
out << "        # it with strcmp, so the order matters)\n"
out << "        BLOCKS = [\n"
blocks.each do |name, fn|
  r = funcs.fetch(fn)
  flat = normalize(r).flatten.map { |v| format("0x%x", v) }.join(", ")
  out << "          [#{name.inspect}, [#{flat}].freeze],\n"
end
out << "        ].freeze\n"
out << <<~RUBY
        end
      end
    end
  end
RUBY

File.write(OUT, out)
puts "wrote #{OUT} (#{cats.size} categories, #{blocks.size} blocks)"
