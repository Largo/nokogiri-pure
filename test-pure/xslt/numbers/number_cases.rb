# frozen_string_literal: true

# Case tables for the xsl:number formatting tests (value= and level="multiple").

module XslNumberCases
  # [xpath expression for value=, the double number() yields]
  VALUES = [
    ["0", 0.0], ["1", 1.0], ["2", 2.0], ["3", 3.0], ["4", 4.0], ["5", 5.0], ["9", 9.0],
    ["10", 10.0], ["14", 14.0], ["19", 19.0], ["25", 25.0], ["26", 26.0], ["27", 27.0],
    ["40", 40.0], ["49", 49.0], ["52", 52.0], ["53", 53.0], ["90", 90.0], ["99", 99.0],
    ["400", 400.0], ["444", 444.0], ["494", 494.0], ["702", 702.0], ["703", 703.0],
    ["900", 900.0], ["999", 999.0], ["1000", 1000.0], ["1234", 1234.0], ["1994", 1994.0],
    ["3999", 3999.0], ["4999", 4999.0], ["5000", 5000.0], ["5001", 5001.0], ["18278", 18_278.0],
    ["18279", 18_279.0], ["1234567", 1_234_567.0], ["1000000000", 1e9],
    ["0.4", 0.4], ["0.5", 0.5], ["1.5", 1.5], ["2.5", 2.5], ["2.4999", 2.4999], ["-0.4", -0.4],
    ["-0.5", -0.5], ["1 div 0", Float::INFINITY], ["0 div 0", Float::NAN], ["'abc'", Float::NAN],
    ["4503599627370496 * 4503599627370496", 4_503_599_627_370_496.0 * 4_503_599_627_370_496.0],
    ["4503599627370496 * 4503599627370496 * 4503599627370496 * 4503599627370496",
     4_503_599_627_370_496.0**4],
    ["4503599627370496 * 4503599627370496 * 4503599627370496 * 4503599627370496 * " \
     "4503599627370496 * 4503599627370496 * 4503599627370496 * 4503599627370496 * " \
     "4503599627370496 * 4503599627370496 * 4503599627370496 * 4503599627370496 * " \
     "4503599627370496 * 4503599627370496 * 4503599627370496 * 4503599627370496 * " \
     "4503599627370496 * 4503599627370496 * 4503599627370496", 4_503_599_627_370_496.0**19]
  ].freeze

  FORMATS = [
    nil, "", "1", "01", "001", "0001", "0", "00", "a", "A", "i", "I", "aa", "Ab", "iv",
    "1.", "(1)", "[a]", "#1", "--1--", "1.1", "1.a.i", "1-A-i-a", "A.1.a)", "x", "b", "α",
    "١", "٠١", "०१", "๑", "༡", "༠༠༡",
    "1, ", "a.b.c.d", ". ", "§1", "1§", "#", "①", "Ⅰ", "〇", "一",
    "A1", "1a", "i.I.a.A.1.01", "--", "..1..", "1 2 3", "١١", "0a", "12", "9"
  ].freeze

  # [grouping-separator, grouping-size] attribute pairs (nil = attribute absent)
  GROUPINGS = [
    [nil, nil], [",", "3"], [".", "2"], [" ", "1"], [" ", "3"], ["٬", "3"],
    [",", nil], [nil, "3"], [",", "0"], [",", "-2"], [",", " 4x"], [",", "x"], ["ab", "3"],
    ["\u{1F600}", "2"], [",", "400"]
  ].freeze

  # counts for level="multiple" (outermost first)
  MULTI_COUNTS = [[1], [3], [1, 1], [3, 2, 5], [2, 26, 27, 4], [1, 2, 3, 4, 5, 6], [12, 1]].freeze

  MULTI_FORMATS = [
    "1", "1.1", "1.a", "1.A.i", "(1-a)", "1.1.1.1.1.1.1", "i", "1) ", "01.1", "a b", "[A/i]",
    "١.١", "#", "1§a", "x.y", ""
  ].freeze

  # sscanf("%d") as used by xsltNumberComp for grouping-size
  def self.scan_int(str)
    m = str.match(/\A[ \t\n\v\f\r]*([+-]?\d+)/)
    m ? m[1].to_i : 0
  end

  # ---- level/count/from on a document -------------------------------------------------------
  # element: [:e, qname, {attr => value (xmlns decls included)}, [children]]
  # text: [:t, str]  comment: [:c, str]  processing instruction: [:pi, target, data]
  DOC = [:e, "r", {}, [
    [:e, "a", {}, []], [:e, "b", {}, []],
    [:e, "a", {}, [[:e, "a", {}, []], [:e, "b", {}, []], [:e, "a", { "id" => "1", "x" => "2" }, []]]],
    [:e, "sec", {}, [
      [:e, "a", {}, []], [:t, "text1"], [:c, "c1"], [:pi, "pi", "data"],
      [:e, "b", {}, [[:e, "a", {}, []],
                     [:e, "sec", {}, [[:e, "a", {}, []], [:e, "a", {}, [[:t, "deep"], [:e, "b", {}, []]]]]]]]
    ]],
    [:e, "p:x", { "xmlns:p" => "urn:p" }, [
      [:e, "p:x", {}, []], [:e, "q:x", { "xmlns:q" => "urn:p" }, []], [:e, "x", {}, []],
      [:c, "c2"], [:e, "p:x", {}, [[:e, "p:x", {}, [[:t, "t9"]]]]]
    ]],
    [:e, "a", {}, [[:t, "t2"], [:e, "a", {}, [[:t, "t3"]]], [:c, "c3"]]]
  ]].freeze

  NODES_XPATH = "/ | //node() | //@* | //namespace::*"

  # pattern text => [kind, arg] interpreted by the test's stub matcher
  COUNT_PATTERNS = [nil, "a", "a|b", "*", "text()", "p:x", "comment()"].freeze
  FROM_PATTERNS = [nil, "sec", "a"].freeze
  LEVELS = %w[single multiple any].freeze
  LEVEL_FORMATS = ["1", "1.a.i"].freeze
  LEVEL_VALUES = ["count(preceding::node())", "string-length(name()) * 3", "count(ancestor::*) div 2",
                  "-1", "1 div 0"].freeze

  def self.esc_text(s) = s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

  def self.to_xml(spec)
    case spec[0]
    when :e
      _, name, attrs, kids = spec
      a = attrs.map { |k, v| %( #{k}="#{esc_text(v).gsub('"', "&quot;")}") }.join
      "<#{name}#{a}>#{kids.map { |k| to_xml(k) }.join}</#{name}>"
    when :t then esc_text(spec[1])
    when :c then "<!--#{spec[1]}-->"
    when :pi then "<?#{spec[1]} #{spec[2]}?>"
    end
  end
end
