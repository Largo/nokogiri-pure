# frozen_string_literal: true

# Regenerates the expected outputs in fixtures/ from the NATIVE gem:
#   ruby test-pure/xslt/numbers/gen_fixtures.rb
# (never with -I pointing at nokogiri-pure/lib)

require_relative "native_oracle"
require_relative "cases"
require_relative "number_cases"
require "json"
require "zlib"

DIR = File.join(__dir__, "fixtures")
Dir.mkdir(DIR) unless Dir.exist?(DIR)

def hexd(x) = [x].pack("G").unpack1("H*")

def write_gz(name, obj)
  Zlib::GzipWriter.open(File.join(DIR, name)) { |gz| gz.write(JSON.generate(obj)) }
end

# ---- format-number(): xsltFormatNumberConversion called directly ------------------------------
numbers = NumberCases::NUMBERS.map { |n| hexd(n) }
fn_cases = []
NumberCases::DECIMAL_FORMATS.each do |dname, df|
  NumberCases::PATTERNS.each_with_index do |pat, pi|
    NumberCases::NUMBERS.each_with_index do |num, ni|
      status, res, err = NativeNumbers.format_number(df, pat, num)
      fn_cases << [dname, pi, ni, status, res, err]
    end
  end
end
write_gz("format_number.json.gz",
         { "decimal_formats" => NumberCases::DECIMAL_FORMATS, "patterns" => NumberCases::PATTERNS,
           "numbers" => numbers, "cases" => fn_cases })
puts "format_number: #{fn_cases.size} cases"

# ---- format-number() through a real stylesheet (checks the Fiddle harness) --------------------
def esc(s) = s.encode(xml: :attr)[1..-2]

sheet_cases = []
[0.5, 0.125, 2.5, -1234.5, 1e21].each do |num|
  expr = num.negative? ? "-#{-num}" : num.to_s
  expr = "1000000000000000000000" if num == 1e21
  ["#,##0.00", "0.0#", "#,##0.00;(#)", "0%", "0‰"].each do |pat|
    xsl = Nokogiri::XSLT(<<~XSL)
      <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
      <xsl:output method="text" encoding="UTF-8"/>
      <xsl:template match="/"><xsl:value-of select="format-number(#{expr}, &quot;#{esc(pat)}&quot;)"/></xsl:template>
      </xsl:stylesheet>
    XSL
    out = xsl.apply_to(Nokogiri::XML("<a/>")) rescue $!.message
    sheet_cases << [hexd(num), pat, out.force_encoding(Encoding::UTF_8)]
  end
end
write_gz("format_number_sheet.json.gz", sheet_cases)

# ---- xsl:number value="..." -------------------------------------------------------------------
def number_attrs(format, gsep, gsize)
  a = +""
  a << %( format="#{esc(format)}") if format
  a << %( grouping-separator="#{esc(gsep)}") if gsep
  a << %( grouping-size="#{esc(gsize)}") if gsize
  a
end

def run_sheet(body, xml = "<a/>")
  xsl = Nokogiri::XSLT(<<~XSL)
    <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
    <xsl:output method="text" encoding="UTF-8"/>
    <xsl:template match="/">#{body}</xsl:template>
    </xsl:stylesheet>
  XSL
  [xsl.apply_to(Nokogiri::XML(xml)).force_encoding(Encoding::UTF_8), nil]
rescue RuntimeError => e
  [nil, e.message.force_encoding(Encoding::UTF_8)]
end

# each case: [format, gsep, gsize, expr, number, output or nil, error message or nil]
value_cases = []
XslNumberCases::FORMATS.each do |format|
  XslNumberCases::GROUPINGS.each do |gsep, gsize|
    one = ->(expr) { %(<xsl:number value="#{esc(expr)}"#{number_attrs(format, gsep, gsize)}/>) }
    out, = run_sheet(XslNumberCases::VALUES.map { |expr, _| "#{one.(expr)}<xsl:text>&#10;</xsl:text>" }.join)
    if out
      lines = out.split("\n", -1)
      lines.pop
      raise "line count mismatch for #{format.inspect}" unless lines.size == XslNumberCases::VALUES.size
    end
    XslNumberCases::VALUES.each_with_index do |(expr, num), i|
      res, err = out ? [lines[i], nil] : run_sheet(one.(expr))
      value_cases << [format, gsep, gsize, expr, hexd(num), res, err]
    end
  end
end
write_gz("xsl_number_value.json.gz", value_cases)
puts "xsl:number value: #{value_cases.size} cases"

# ---- xsl:number level="multiple" --------------------------------------------------------------
def nest(counts)
  return "" if counts.empty?

  c, *rest = counts
  ("<s/>" * (c - 1)) + (rest.empty? ? %(<s id="t"/>) : "<s>#{nest(rest)}</s>")
end

multi_cases = []
XslNumberCases::MULTI_COUNTS.each do |counts|
  xml = "<r>#{nest(counts)}</r>"
  XslNumberCases::MULTI_FORMATS.each do |format|
    [[nil, nil], [",", "1"]].each do |gsep, gsize|
      xsl = Nokogiri::XSLT(<<~XSL)
        <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="text" encoding="UTF-8"/>
        <xsl:template match="/"><xsl:for-each select="//s[@id='t']"><xsl:number level="multiple" count="s"#{number_attrs(format, gsep, gsize)}/></xsl:for-each></xsl:template>
        </xsl:stylesheet>
      XSL
      out = xsl.apply_to(Nokogiri::XML(xml)).force_encoding(Encoding::UTF_8)
      multi_cases << [counts, format, gsep, gsize, out]
    end
  end
end
write_gz("xsl_number_multiple.json.gz", multi_cases)
puts "xsl:number multiple: #{multi_cases.size} cases"

# ---- xsl:number level/count/from and value= on a document --------------------------------------
xml = XslNumberCases.to_xml(XslNumberCases::DOC)
level_cases = []
XslNumberCases::LEVELS.each do |level|
  XslNumberCases::COUNT_PATTERNS.each do |count|
    XslNumberCases::FROM_PATTERNS.each do |from|
      XslNumberCases::LEVEL_FORMATS.each do |format|
        attrs = +%( level="#{level}" format="#{format}")
        attrs << %( count="#{esc(count)}") if count
        attrs << %( from="#{esc(from)}") if from
        body = %(<xsl:for-each select="#{XslNumberCases::NODES_XPATH}" xmlns:p="urn:p">) +
               %(<xsl:number#{attrs} xmlns:p="urn:p"/><xsl:text>&#10;</xsl:text></xsl:for-each>)
        out, err = run_sheet(body, xml)
        level_cases << [level, count, from, format, out, err]
      end
    end
  end
end
XslNumberCases::LEVEL_VALUES.each do |value|
  body = %(<xsl:for-each select="#{XslNumberCases::NODES_XPATH}">) +
         %(<xsl:number value="#{esc(value)}" format="1"/><xsl:text>&#10;</xsl:text></xsl:for-each>)
  out, err = run_sheet(body, xml)
  level_cases << ["value", value, nil, "1", out, err]
end
write_gz("xsl_number_levels.json.gz", level_cases)
puts "xsl:number levels: #{level_cases.size} sheets"
