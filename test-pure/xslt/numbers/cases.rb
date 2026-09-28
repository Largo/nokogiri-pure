# frozen_string_literal: true

# Shared case tables for the format-number() differential tests.

module NumberCases
  DEFAULT_DF = {
    digit: "#", pattern_separator: ";", decimal_point: ".", grouping: ",", percent: "%",
    permille: "‰", zero_digit: "0", minus_sign: "-", infinity: "Infinity", no_number: "NaN"
  }.freeze

  DECIMAL_FORMATS = {
    "default" => DEFAULT_DF,
    "european" => DEFAULT_DF.merge(decimal_point: ",", grouping: "."),
    "arabic" => DEFAULT_DF.merge(zero_digit: "٠", decimal_point: "٫", grouping: "٬",
                                 minus_sign: "−"),
    "symbols" => DEFAULT_DF.merge(digit: "x", zero_digit: "o", pattern_separator: "|",
                                  percent: "p", permille: "m", minus_sign: "~",
                                  infinity: "INF", no_number: "not-a-number"),
    "multichar" => DEFAULT_DF.merge(grouping: "''", minus_sign: "--", infinity: "∞∞",
                                    decimal_point: "·"),
    "spacegroup" => DEFAULT_DF.merge(grouping: " ", decimal_point: ","),
    "emptygroup" => DEFAULT_DF.merge(grouping: ""),
    "cjkzero" => DEFAULT_DF.merge(zero_digit: "〇", grouping: "、"),
    "astral" => DEFAULT_DF.merge(zero_digit: "\u{1D7CE}", percent: "\u{1F4AF}", minus_sign: "\u{2796}")
  }.freeze

  NUMBERS = [
    0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 1.5, 2.5, -2.5, 0.25, 0.125, 0.05, 0.005, 0.0005,
    1.005, 1.015, 1.025, 2.675, 0.045, 1.45, 9.995, 99.995, 0.1, 0.2, 0.3, 0.7, 0.9999,
    0.99999999, 123.456, -123.456, 1234.5678, -1234.5678, 1_234_567.891, 12_345_678.9,
    1e15, 1e16, 1e17, 1.2345678901234567e20, 9_007_199_254_740_993.0, 1e21, 1e22, 1e100, -1e100,
    1.7976931348623157e308, 1e-5, 1e-10, 1e-300, 5e-324, 3.141592653589793, 2.718281828459045,
    -3.141592653589793, 1.0 / 3, 2.0 / 3, -2.0 / 3, 100.0, 1000.0, 999_999.5, 0.0049, 0.015,
    42.0, 7.0, 0.999, 1e5, 123_456_789.0, -0.001, 12.345e3,
    Float::INFINITY, -Float::INFINITY, Float::NAN
  ].freeze

  PATTERNS = [
    "0", "#", "0.00", "#.##", "#,##0.00", "#,##0.###", "0.0", "0.#", ".0", ".#", ".##", "#.",
    "0.", "00.000", "000", "#,###", "#,##,###", "#,#", "#,##0", "0,0", "0.00%", "#%", "%#",
    "0%", "0.0%", "‰0", "0‰", "#,##0.00‰", "$#,##0.00", "#,##0.00 EUR",
    "'#'0", "0'%'", "''0", "0''", "'a;b'0", "a'", "0 'x' y", "#,##0.00;(#,##0.00)",
    "#,##0.00;-#,##0.00", "0;0", "0;-0", "0;(0)", "0;neg0", "0;-#", "0.0;[0.0]", "0;%0",
    "0;0%", "0;0%%", "0;0‰", "#;#;#", "0;", ";0", ";", "0.00;", "prefix0suffix",
    "pre#,##0.0#suf;npre0nsuf", "0#", "#0#", "0.0#0", "0.#0", "#.#.#", "0,", ",0", "0.,0",
    "0,.0", "00,00.00,0", "%%0", "0%%", "%0%", "‰%0", "0.00%;0.00%", "-0", "0-",
    "¤0.00", "0.000000000000000000000000000000", "0.##########################",
    "#" * 40 + "0", "0" * 30, "#,##0.0000000000", "a", "abc", "'", "0'", "'0", "''",
    "0.0e0", "0;'", "#,##0;(#,##0", "0;0;0", "x", "٠", "٠.٠٠",
    "#,##,##,##0.0", "0." + "#" * 320, "0." + "0" * 320, "#" + ".0" * 3, "0.0.0",
    "0x0", "x#x", "#x#", "0 0", "0,000,000.000,000", "(0)", "0;0.0",
    "oo", "o.oo", "x,xxo.oox", "xo", "o|~o", "o|(o)", "po", "om", "o.oop", "o''o",
    "٠.٠٠", "٠٫٠٠", "#٬##٠٫٠",
    "#.##0,00", "0,00", "#.###,##", "〇.〇", "#、##〇", "\u{1D7CE}.\u{1D7CE}",
    "\u{1D7CE}\u{1F4AF}", "\u{1F4AF}\u{1D7CE}", "#''##0", "#''##0.0", "0·00",
    "# ##0,00", "#,##0.00 ;(#,##0.00 )", "#,##0.00 ;(#,##0.00)"
  ].freeze
end
