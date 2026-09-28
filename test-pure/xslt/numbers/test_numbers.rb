# frozen_string_literal: true

# Differential tests of the numbers.c port (lib/nokogiri/pure/xslt/numbers.rb) against expected
# outputs recorded from the native gem by gen_fixtures.rb.
#
#   ruby test-pure/xslt/numbers/test_numbers.rb
#   FULL=1 ruby -Ilib test-pure/xslt/numbers/test_numbers.rb   # load the whole pure library

require "minitest/autorun"
require "json"
require "zlib"

LIB = File.expand_path("../../../lib", __dir__)
if ENV["FULL"]
  $LOAD_PATH.unshift(LIB)
  require "nokogiri"
end
%w[util tree errors xpath xslt/internals xslt/utils xslt/numbers].each do |f|
  require File.join(LIB, "nokogiri/pure", f)
end
require_relative "number_cases"

class TestXsltNumbers < Minitest::Test
  X = Nokogiri::Pure::XSLT
  N = X::Numbers
  FIXTURES = File.join(__dir__, "fixtures")

  def self.fixture(name)
    Zlib::GzipReader.open(File.join(FIXTURES, name)) { |gz| JSON.parse(gz.read) }
  end

  def self.float(hex) = [hex].pack("H*").unpack1("G")

  def capture_errors(&blk)
    errs = +""
    res = X.with_generic_error_func(->(m) { errs << m }, &blk)
    [res, errs]
  end

  def decimal_format(fields)
    d = X::DecimalFormat.new(nil, nil)
    %i[digit pattern_separator minus_sign infinity no_number decimal_point grouping percent
       permille zero_digit].each { |k| d.__send__(:"#{k}=", nil) }
    fields.each { |k, v| d.__send__(:"#{k}=", v) }
    d
  end

  # the numdata xsltNumberComp builds from the attributes
  def number_data(format, gsep, gsize)
    d = X::NumberData.new
    d.has_format = !format.nil?
    d.format = format || ""
    if gsep
      cp, len = N.get_utf8_char(gsep.b)
      d.grouping_character = cp < 0 ? 0 : cp
      d.grouping_character_len = len
    end
    if gsize
      d.digits_per_group = XslNumberCases.scan_int(gsize)
    else
      d.grouping_character = 0
    end
    d
  end

  def test_format_number_conversion_table
    fx = self.class.fixture("format_number.json.gz")
    dfs = fx["decimal_formats"].transform_values { |h| decimal_format(h) }
    numbers = fx["numbers"].map { |h| self.class.float(h) }
    failures = []
    fx["cases"].each do |dname, pi, ni, status, res, err|
      pat = fx["patterns"][pi]
      (got_status, got), errs = capture_errors { X.format_number_conversion(dfs[dname], pat, numbers[ni]) }
      next if [got_status, got, errs] == [status, res, err]

      failures << "#{dname} #{pat.inspect} #{numbers[ni].inspect}: expected #{[status, res, err].inspect}, " \
                  "got #{[got_status, got, errs].inspect}"
    end
    assert_empty(failures.first(20), "#{failures.size}/#{fx["cases"].size} format-number cases differ")
  end

  def test_format_number_through_stylesheet
    df = decimal_format(digit: "#", pattern_separator: ";", decimal_point: ".", grouping: ",",
                        percent: "%", permille: "‰", zero_digit: "0", minus_sign: "-",
                        infinity: "Infinity", no_number: "NaN")
    self.class.fixture("format_number_sheet.json.gz").each do |hex, pat, out|
      (_, got), = capture_errors { X.format_number_conversion(df, pat, self.class.float(hex)) }
      assert_equal(out, got, "format-number(#{self.class.float(hex)}, #{pat.inspect})")
    end
  end

  def test_xsl_number_value_table
    failures = []
    cases = self.class.fixture("xsl_number_value.json.gz")
    cases.each do |format, gsep, gsize, expr, hex, out, err|
      data = number_data(format, gsep, gsize)
      got, errs = capture_errors { N.format_numbers(data, [self.class.float(hex)], data.format) }
      ok = err ? errs == err : (got == out && errs.empty?)
      next if ok

      failures << "format=#{format.inspect} sep=#{gsep.inspect} size=#{gsize.inspect} value=#{expr[0, 40]}: " \
                  "expected #{(err || out).inspect}, got #{got.inspect} #{errs.inspect}"
    end
    assert_empty(failures.first(20), "#{failures.size}/#{cases.size} xsl:number value cases differ")
  end

  def test_xsl_number_multiple_table
    failures = []
    cases = self.class.fixture("xsl_number_multiple.json.gz")
    cases.each do |counts, format, gsep, gsize, out|
      data = number_data(format, gsep, gsize)
      got, = capture_errors { N.format_numbers(data, counts.map(&:to_f), data.format) }
      failures << "#{counts.inspect} #{format.inspect}: expected #{out.inspect}, got #{got.inspect}" if got != out
    end
    assert_empty(failures.first(20), "#{failures.size}/#{cases.size} xsl:number multiple cases differ")
  end

  def test_tokenize
    t = N.tokenize("((01.a-i))")
    assert_equal("((", t.start)
    assert_equal("))", t.end)
    assert_equal([[nil, 0x30, 2], [".", 0x61, 0], ["-", 0x69, 0]], t.tokens.map(&:to_a))

    t = N.tokenize("")
    assert_nil(t.start)
    assert_nil(t.end)
    assert_empty(t.tokens)

    t = N.tokenize("٠٠١ x")
    assert_equal([[nil, 0x660, 3], [" ", 0x30, 1]], t.tokens.map(&:to_a))
  end

  def test_negative_value_error
    data = number_data("1", nil, nil)
    got, errs = capture_errors { N.format_numbers(data, [-3.0], "1") }
    assert_equal("0", got)
    assert_equal("error\nxsl-number : negative value\n", errs)
  end

  def test_alpha_and_roman
    data = number_data(nil, nil, nil)
    assert_equal("zz", N.format_numbers(data, [702.0], "a"))
    assert_equal("AAA", N.format_numbers(data, [703.0], "A"))
    assert_equal("MCMXCIV", N.format_numbers(data, [1994.0], "I"))
    assert_equal("mmmmm", N.format_numbers(data, [5000.0], "i"))
    assert_equal("5001", N.format_numbers(data, [5001.0], "i"))
    assert_equal("0", N.format_numbers(data, [0.0], "a"))
  end

  # ---- xsltNumberFormat on a pure tree (level/count/from, value=) ------------------------------

  FakeCtxt = Struct.new(:xpath_ctxt, :insert, :out, :state, :error, :inst)

  PATTERN_STUBS = {
    "a" => ->(n) { n.type == Nokogiri::Pure::ELEMENT_NODE && n.name == "a" && n.ns.nil? },
    "a|b" => ->(n) { n.type == Nokogiri::Pure::ELEMENT_NODE && %w[a b].include?(n.name) && n.ns.nil? },
    "*" => ->(n) { n.type == Nokogiri::Pure::ELEMENT_NODE },
    "text()" => ->(n) { [Nokogiri::Pure::TEXT_NODE, Nokogiri::Pure::CDATA_SECTION_NODE].include?(n.type) },
    "p:x" => ->(n) { n.type == Nokogiri::Pure::ELEMENT_NODE && n.name == "x" && n.ns&.href == "urn:p" },
    "comment()" => ->(n) { n.type == Nokogiri::Pure::COMMENT_NODE },
    "sec" => ->(n) { n.type == Nokogiri::Pure::ELEMENT_NODE && n.name == "sec" && n.ns.nil? }
  }.freeze

  # stand-ins for the transform.c/pattern.c functions numbers.c calls, active only for FakeCtxt
  module Stubs
    def test_comp_match_list(ctxt, node, comp)
      return(comp.call(node) ? 1 : 0) if comp.is_a?(Proc)

      super
    end

    def copy_text_string(ctxt, target, string, noescape)
      return ctxt.out << string if ctxt.is_a?(FakeCtxt)

      super
    end
  end
  X.singleton_class.prepend(Stubs)

  def build_pure(spec, doc, parent, nsmap)
    t = Nokogiri::Pure::Tree
    case spec[0]
    when :e
      _, qname, attrs, kids = spec
      nsmap = nsmap.dup
      node = t.new_doc_node(doc, nil, qname.split(":").last)
      attrs.each do |k, v|
        next unless k.start_with?("xmlns")

        nsmap[k.split(":")[1]] = t.new_ns(node, v, k.split(":")[1])
      end
      node.ns = nsmap[qname.include?(":") ? qname.split(":").first : nil]
      attrs.each { |k, v| t.new_prop(node, k, v) unless k.start_with?("xmlns") }
      t.add_child(parent, node)
      kids.each { |k| build_pure(k, doc, node, nsmap) }
    when :t then t.add_child(parent, t.new_doc_text(doc, spec[1]))
    when :c then t.add_child(parent, t.new_doc_comment(doc, spec[1]))
    when :pi then t.add_child(parent, t.new_doc_pi(doc, spec[1], spec[2]))
    end
  end

  def test_xsl_number_levels
    doc = Nokogiri::Pure::Tree.new_doc
    build_pure(XslNumberCases::DOC, doc, doc, {})
    xctxt = Nokogiri::Pure::XPath::Context.new(doc)
    xctxt.node = doc
    nodes = Nokogiri::Pure::XPath.eval(XslNumberCases::NODES_XPATH, xctxt)
    failures = []
    cases = self.class.fixture("xsl_number_levels.json.gz")
    cases.each do |level, count, from, format, out, err|
      data = X::NumberData.new
      data.format = format
      data.has_format = true
      if level == "value"
        data.value = count
      else
        data.level = level
        data.count_pat = count && PATTERN_STUBS.fetch(count)
        data.from_pat = from && PATTERN_STUBS.fetch(from)
      end
      ctxt = FakeCtxt.new(xctxt, nil, +"")
      _, errs = capture_errors do
        nodes.each do |n|
          X.number_format(ctxt, data, n)
          ctxt.out << "\n"
        end
      end
      ok = err ? errs == err : (ctxt.out == out && errs.empty?)
      failures << "#{level} count=#{count.inspect} from=#{from.inspect} format=#{format}:\n" \
                  "  expected #{(out || err).inspect}\n  got      #{ctxt.out.inspect} #{errs.inspect}" unless ok
    end
    assert_empty(failures.first(10), "#{failures.size}/#{cases.size} xsl:number level sheets differ")
  end
end
