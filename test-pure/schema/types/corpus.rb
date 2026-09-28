# frozen_string_literal: true

# Test corpus for the xmlschemastypes.c port (deterministic; random parts use a fixed seed).
module TypesCorpus
  module_function

  XSD = "http://www.w3.org/2001/XMLSchema"

  ALL_TYPES = %w[
    anyType anySimpleType string normalizedString token language Name NCName ID IDREF IDREFS
    ENTITY ENTITIES NMTOKEN NMTOKENS QName NOTATION anyURI boolean decimal integer
    nonPositiveInteger negativeInteger long int short byte nonNegativeInteger unsignedLong
    unsignedInt unsignedShort unsignedByte positiveInteger float double duration dateTime date
    time gYear gYearMonth gMonth gMonthDay gDay hexBinary base64Binary
  ].freeze

  INTEGER_TYPES = %w[
    integer nonPositiveInteger negativeInteger long int short byte nonNegativeInteger
    unsignedLong unsignedInt unsignedShort unsignedByte positiveInteger
  ].freeze
  DECIMAL_TYPES = (["decimal"] + INTEGER_TYPES).freeze
  DATE_TYPES = %w[dateTime date time gYear gYearMonth gMonth gMonthDay gDay].freeze
  STRING_TYPES = %w[string normalizedString token language Name NCName ID IDREF ENTITY NMTOKEN anyURI].freeze

  GENERIC = [
    "", " ", "  ", "\t", "\n", " \t\r\n ", "0", "-0", "+0", "1", "-1", "+1", "01", "00", "000",
    "0.0", ".5", "5.", ".", "-", "+", "+-1", "--1", "1-", "1 2", "1e5", "1E-5", "1e", "1e+", "e5",
    "NaN", "INF", "-INF", "+INF", "nan", "inf", "Infinity", "true", "false", "TRUE", "1 ", " 1",
    " 1 ", "\t1\n", "abc", "a b", "a  b", " a b ", "a\tb", "a\nb", "a\rb", " a ", "a ", "é",
    "日本語", "a:b", ":a", "a:", "a:b:c", "_x", "-x", "x-", "x.y", "1x", "x1", "P1Y", "2002-10-10",
    "12:00:00", "--10", "---10", "AAAA", "0A", "http://example.com/", "en-US", "#frag", "a%20b",
    "a&b", "<", "x\u00b7y", "\u0300x", "x\u0300", "\u3007", "\u00c0\u00ff", "\u0100", "\u0e46x",
    "a\u200db", "\u{10000}", "a\u{1F600}"
  ].freeze

  YEARS = %w[0000 0001 1999 2000 2004 1900 2100 1600 -0001 -0004 -0005 -0100 10000 010000
    99999 -10000 0400 2147483648 9223372036854775807 9223372036854775808 922337203685477580
    -922337203685477580 999 99 1 +2000].freeze
  MONTHS = %w[01 02 04 12 13 00 1 001].freeze
  DAYS = %w[01 28 29 30 31 32 00 1].freeze
  TIMES = %w[00:00:00 23:59:59 23:59:59.999 24:00:00 24:00:00.0 24:00:01 24:01:00 12:60:00
    12:00:60 12:00:59.9999999999 12:00:00. 12:00:00.5 1:00:00 12:0:00 12:00:0 12:00 12:00:00.000001
    07:30:15.123456789 13:20:00.10].freeze
  TZS = ["", "Z", "+00:00", "-00:00", "-14:00", "+14:00", "+14:01", "-14:01", "+15:00", "+05:30",
    "+5:30", "+05:60", "+24:00", "-05:00", "+01:00", "z", "+0100", "+01", "Z "].freeze

  def dates
    out = []
    YEARS.each do |y|
      out << y
      out << "#{y}Z"
      out << "#{y}-05:00"
      MONTHS.each do |m|
        out << "#{y}-#{m}"
        DAYS.each { |d| out << "#{y}-#{m}-#{d}" }
      end
    end
    %w[2000-02-29 2001-02-29 1900-02-29 1600-02-29 -0001-02-29 -0004-02-29 -0005-02-29 2004-04-31
       2004-12-31 0001-01-01 -0001-12-31].each do |d|
      TZS.each { |tz| out << "#{d}#{tz}" }
      TIMES.each { |t| out << "#{d}T#{t}" }
      %w[00:00:00 23:59:59 24:00:00 12:00:00.5].each { |t| TZS.each { |tz| out << "#{d}T#{t}#{tz}" } }
    end
    TIMES.each do |t|
      TZS.each { |tz| out << "#{t}#{tz}" }
    end
    %w[--01 --12 --13 --00 --1 --10-- --02-29 --02-30 --04-31 --04-30 --12-31 --01-01 ---01 ---31
       ---32 ---00 ---1 --01-1 -01-01 --02-29Z --02-29-05:00 --02-14:00 --02-14 --02-15:00 --10Z
       --10-05:00 ---05Z ---05+14:00 --02-29T00:00:00].each do |g|
      out << g
      TZS.first(8).each { |tz| out << "#{g}#{tz}" }
    end
    # whitespace variants
    ["2002-10-10", "2002-10-10T12:00:00", "2002-10-10T12:00:00Z", "12:00:00", "12:00:00Z", "--10",
     "---05", "--10-05", "2002", "2002-10"].each do |d|
      out.push(" #{d}", "#{d} ", " #{d} ", "\t#{d}\n", "#{d}Z ", " #{d}Z")
    end
    out.uniq
  end

  DURATIONS = %w[
    P1Y P1Y2M P1Y2M3D P1Y2M3DT4H5M6S P1Y2M3DT4H5M6.7S -P1Y P PT P1DT PT1H PT1M PT1S PT1.5S
    PT.5S P.5S PT1.S P1.5Y P1.5D PT1.5M P0Y PT0S P0D -P0D -PT0S P1M PT36H PT1440M PT86400S
    PT86401S P1DT24H PT24H P13M P12M P365D P366D P367D P31D P30D P28D P29D P60D P59D P61D
    P1Y1D P1M1D P2M -P1M P1YT P1Y1M1DT1H1M1S P1D1Y PT1S1M P1H PT1D P1YT1Y 1Y PX P-1Y
    P9223372036854775807D P9223372036854775808D P768614336404564650Y P768614336404564651Y
    P9223372036854775807M PT9223372036854775807S PT9223372036854775807H P1Y9223372036854775807M
    PT0.000001S PT59.999999S PT0.1S PT0.2S PT0.30S P0Y0M0DT0H0M0.0S PT1000000H P1DT1H P1DT23H
    P1DT25H PT3600S PT3599S
  ].freeze

  def durations
    out = DURATIONS.dup
    DURATIONS.first(12).each { |d| out.push(" #{d}", "#{d} ", " #{d} ", "-#{d}") }
    out.uniq
  end

  def decimals
    base = %w[0 00 -0 +0 0.0 -0.0 .0 0. 00.00 1 -1 +1 01 001.100 1.0 1.00 1.5 -1.5 10 100 1000
      0.1 0.01 0.001 .001 123.456 -123.456 12345678901234567890 123456789012345678901234567890.123456789
      127 128 -128 -129 255 256 32767 32768 -32768 -32769 65535 65536 2147483647 2147483648
      -2147483648 -2147483649 4294967295 4294967296 9223372036854775807 9223372036854775808
      -9223372036854775808 -9223372036854775809 18446744073709551615 18446744073709551616
      340282366920938463463374607431768211456 -0001 +0001 0000000000000000000000001
      00000000000000000000000000.0000000000000000001 1. 1.a 1..2 1.2.3 1e5 1E5 --1 ++1 +-1 -+1
      0x10 1,5 1_000 ١ 5.00000 -5.0000 100.0010 0.10 010.010 1.50 99999999999999999999.99999999999999999999]
    out = base.dup
    base.first(20).each { |d| out.push(" #{d}", "#{d} ", " #{d} ", "\t#{d}\n") }
    out.uniq
  end

  def floats
    base = %w[0 -0 +0 0.0 -0.0 1 -1 1.5 -1.5 .5 5. 1e5 1E5 1e-5 1E+5 1e 1e+ 1E- 1.5e 1.5E-3 .e1 1.e1
      e1 -e1 12.5e-3 3.4028235e38 3.4028236e38 3.4028234663852886e38 3.40282356779733661637539395458142568447e38
      3.40282356779733661637539395458142568448e38 1e38 1e39 1e308 1e309 2e308 1.7976931348623157e308
      1.7976931348623158e308 1.7976931348623159e308 1e-38 1e-45 1e-46 1.4e-45 7e-46 8e-46 1e-300
      1e-320 1e-323 2e-324 3e-324 1e-400 4.9e-324 0.1 0.2 0.3 1.1 3.14159265358979323846
      0.000000000000000000000000000000000000000000001401298464324817070923729583289916131280e0
      16777216 16777217 16777218 16777219 9007199254740993 9007199254740992 123456789012345678901234567890
      1.00000005960464477539062 1.00000005960464477539063 1.00000017881393432617187499
      2.0000001192092895507812 2.00000011920928955078125 2.00000011920928955078125001
      NaN -NaN +NaN INF -INF +INF Inf inf NAN nan .NaN NaN\  INFx 1.5.5 1..5 1e5.5 1e5e5 0x1p3
      1f 1d - + . -. +. 1,5 ١ 00001.5000]
    out = base.dup
    %w[1.5 -1.5 1e5 NaN INF -INF 1e 0].each { |d| out.push(" #{d}", "#{d} ", " #{d} ", "\n#{d}\t") }
    out.uniq
  end

  BOOLEANS = ["true", "false", "1", "0", " true ", " false", "0 ", "TRUE", "True", "tru", "truex",
    "t rue", "fals", "falsee", "2", "-1", "01", "yes", "", " ", "1 1", "\ttrue\n", "\n0\n", "t",
    "f", "true\u00a0"].freeze

  HEX = ["", "0", "00", "0A", "0a", "0g", "g0", " 0A ", "0 A", "0A0B0C", "ABCDEF", "abcdef",
    "abcdefg", "0A\n0B", "\t0a0b\n", "FFFF", "0000", "000", "a", "é", "0A 0B", "0x00"].freeze

  BASE64 = ["", "AAAA", "AAA=", "AA==", "A===", "====", "AAA", "AB==", "AC==", "AQ==", "AAB=",
    "AAE=", "AAC=", "AA=A", "A A A A", "AAAA\nAAAA", " AAAA ", "\tAA==\n", "QUJD", "QUJDRA==",
    "QUJDREU=", "QUJDREVG", "QUJDREVG=", "QUJDREVG==", "QUJD REVG", "Q", "QU", "QUJ", "QUJDR",
    "!!!!", "AA==AA==", "AA== ", "AA= =", "A=AA", "=AAA", "AAAA=", "AAAA==", "ab+/", "ab-_",
    "AAAA!", "Zm9vYmFy", "Zm9vYmE=", "Zm9vYg==", "Zm9vYh==", "Zm9vYmF=", "Zm 9v Ym Fy",
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="].freeze

  URIS = ["", "http://a", "http://a/", "http://a:", "http://a:80", "http://a:080/x",
    "http://a:99999999999", "http://[::1]", "http://[::1]:80/", "http://[::1", "http://]", "a b",
    "#frag", "?q", "%", "%2", "%zz", "%41", "%4", "a:b", ":a", "//", "///", "////a", "http://a@b",
    "http://a:b@c:1/d", "mailto:x@y", "urn:isbn:1", "é", "a\\b", "http://a/b?c#d#e", "#a#b", "[",
    "]", "a[b]", "http://a/[b]", "file:///c:/x", "c:/x", "c:\\x", "1a:b", "a1+.-:b", "+a:b",
    "http://a b", " http://a ", "\thttp://a\n", "http://a/%20b", "http://a/<b>", "http://a/{b}",
    "http://a/|", "http://a/^", "http://a/`", "http://a/'", "http://a/\"", "http://é.com",
    "http://a/?#", "http://a/?q=1&r=2", "x:", "x:/", "x://", "x://@", "x://@:", "x://:1",
    "http://1.2.3.4/", "http://256.1.1.1/", "http://1.2.3/", "http://a.b.c.d.e/", "http://a;b",
    "../a", "./a", "a/../b", "a#b?c", "a?b#c", "http://a/b%", "http://a/b%2f", "http://a/%e9",
    "http:a", "http:/a", "http:?a", "http:#a", "a:b:c", "//a:b:c", "//a@b@c", "//[a]b", "//a]b",
    "//a[b", "a]b", "tel:+1-555", "data:text/plain,a b", "http://a/\u00a0", "http://a/\u2028",
    "x\u007f", "a  b", " ", "\n"].freeze

  LANGS = ["en", "en-US", "e", "abcdefgh", "abcdefghi", "en-", "-en", "en--us", "1en", "en-1",
    "en-12345678", "en-123456789", "i-klingon", "x-a", "en_US", " en ", "en US", "EN-us",
    "en-US-x-abcdefgh", "a-b-c-d-e", "", "de-DE-1996", "\ten\n", "é", "en-é", "zh-Hant-TW",
    "sgn-BE-FR", "qaa-Qaaa-QM-x-southern"].freeze

  NAMES = ["a", "_a", ":a", "a:b", "a:b:c", "1a", "-a", ".a", "a.", "a-", "a_", "a1", "é", "ÿ",
    "\u00d7", "\u00f7", "Ā", "\u02b0", "\u02d0", "a\u02d0", "\u00b7a", "a\u00b7", "a\u0300",
    "\u0300a", "\u0660", "a\u0660", "\u4e00", "\u3007", "\u3021", "\u3029", "\u302a", "a\u302a",
    "\u01c5", "\u0e46", "a\u0e46", "\u1100", "\u0587", "\u{10000}", "a\u{10000}", "\u{1F600}",
    "a\u{1F600}", "\u2028", "a b", " a ", "a ", " a", "\ta\n", "a\u00a0", ":", "::", "a::b",
    ":a:b", "a:1", "a:_b", "_:_", "a:-", "a:", "é:é", "\u0660:a", "a\u200c", "\u037e", "\u037f",
    "\u2070", "\u218f", "\u2c00", "\u3001", "\uf900", "\ufdf0", "\ufffd", "abc-def.ghi_jkl",
    "xml", "xmlns", "xmlns:a", "A1-_.", "", " "].freeze

  def type_specific(type)
    case type
    when *DATE_TYPES then dates
    when "duration" then durations
    when *DECIMAL_TYPES then decimals
    when "float", "double" then floats
    when "boolean" then BOOLEANS
    when "hexBinary" then HEX
    when "base64Binary" then BASE64
    when "anyURI" then URIS
    when "language" then LANGS
    when "Name", "NCName", "QName", "NMTOKEN", "NMTOKENS", "ID", "IDREF", "IDREFS", "ENTITY",
      "ENTITIES", "NOTATION"
      NAMES + NAMES.first(30).each_slice(3).map { |a| a.join(" ") } + ["a b c", " a  b ", "a\tb\nc"]
    when "string", "normalizedString", "token"
      NAMES + ["a  b", " a", "a ", "a\t", "\ta", "a\r\nb", "a \n b", "  ", "a b c", "a  b  c "]
    else
      []
    end
  end

  # seeded random strings over a per-type alphabet
  def random_values(type, n, seed)
    rng = Random.new(seed)
    alphabet = case type
    when *DATE_TYPES then "0123456789-:TZ+. "
    when "duration" then "PYMDTHS0123456789.- "
    when *DECIMAL_TYPES, "float", "double" then "0123456789.-+eE "
    when "hexBinary" then "0123456789abcdefABCDEFg \n"
    when "base64Binary" then "ABab01+/= \n!"
    when "anyURI" then "ab:/?#[]@%20!$&'()*+,;= .-_~"
    when "language" then "aZ-1 "
    when "boolean" then "truefals01 "
    else "ab:_-.1\u00e9\u0300 "
    end.chars
    Array.new(n) do
      len = rng.rand(1..14)
      Array.new(len) { alphabet[rng.rand(alphabet.size)] }.join
    end
  end

  # structured random dates / durations / numbers that are mostly valid
  def random_structured(type, n, seed)
    rng = Random.new(seed)
    two = ->(max) { format("%02d", rng.rand(0..max)) }
    tz = -> { ["", "Z", format("%s%02d:%02d", rng.rand(2).zero? ? "+" : "-", rng.rand(0..15), [0, 30, 45, 59].sample(random: rng))].sample(random: rng) }
    year = -> { [format("%04d", rng.rand(1..2500)), format("-%04d", rng.rand(1..3000)), rng.rand(10_000..99_999).to_s].sample(random: rng) }
    frac = -> { rng.rand(3).zero? ? ".#{rng.rand(0..999_999)}" : "" }
    Array.new(n) do
      case type
      when "dateTime" then "#{year.()}-#{two.(12)}-#{two.(31)}T#{two.(24)}:#{two.(59)}:#{two.(60)}#{frac.()}#{tz.()}"
      when "date" then "#{year.()}-#{two.(12)}-#{two.(31)}#{tz.()}"
      when "time" then "#{two.(24)}:#{two.(59)}:#{two.(60)}#{frac.()}#{tz.()}"
      when "gYear" then "#{year.()}#{tz.()}"
      when "gYearMonth" then "#{year.()}-#{two.(12)}#{tz.()}"
      when "gMonth" then "--#{two.(12)}#{tz.()}"
      when "gMonthDay" then "--#{two.(12)}-#{two.(31)}#{tz.()}"
      when "gDay" then "---#{two.(31)}#{tz.()}"
      when "duration"
        parts = +"#{rng.rand(4).zero? ? "-" : ""}P"
        %w[Y M D].each { |d| parts << "#{rng.rand(0..500)}#{d}" if rng.rand(2).zero? }
        if rng.rand(2).zero?
          parts << "T"
          %w[H M].each { |d| parts << "#{rng.rand(0..100_000)}#{d}" if rng.rand(2).zero? }
          parts << "#{rng.rand(0..100_000)}#{frac.()}S" if rng.rand(2).zero?
        end
        parts
      when "float", "double"
        m = "#{rng.rand(0..99_999_999)}.#{rng.rand(0..99_999_999)}"
        "#{["", "-", "+"].sample(random: rng)}#{m}#{rng.rand(2).zero? ? "e#{rng.rand(-330..330)}" : ""}"
      else
        "#{["", "-", "+"].sample(random: rng)}#{"0" * rng.rand(0..2)}#{rng.rand(0..10**rng.rand(1..30))}#{rng.rand(2).zero? ? ".#{rng.rand(0..10**rng.rand(1..20))}" : ""}"
      end
    end
  end

  def parse_values(type)
    base = GENERIC + type_specific(type)
    base += random_values(type, 60, type.sum)
    base += random_structured(type, 150, type.sum + 1) if DATE_TYPES.include?(type) || %w[duration float double].include?(type) || DECIMAL_TYPES.include?(type)
    base.uniq
  end

  # ---- comparison pairs ---------------------------------------------------------------------

  def compare_groups
    rng = Random.new(42)
    groups = []
    dec_vals = %w[0 -0 0.0 1 -1 1.0 1.5 -1.5 01.50 10 9 99 100 0.1 0.10 0.01 -0.01 123456789012345678901234567890
      -123456789012345678901234567890 1.23 1.3 1.29 12 2 -2 -10 -9 .5 0.5]
    groups << [DECIMAL_TYPES, dec_vals]
    flt_vals = %w[0 -0 1 -1 1.5 1e10 -1e10 INF -INF NaN 0.1 3.4028235e38 1e39 1e-45 1e-46 16777217 0.30000001]
    groups << [%w[float double], flt_vals]
    date_vals = %w[2002-10-10 2002-10-10Z 2002-10-10+05:00 2002-10-10-05:00 2002-10-09 2002-10-11
      2002-10-10T00:00:00 2002-10-10T00:00:00Z 2002-10-10T12:00:00-05:00 2002-10-10T17:00:00Z
      2002-10-10T12:00:00 2002-10-10T12:00:00+14:00 2002-10-10T12:00:00-14:00 2002-10-10T24:00:00
      2002-10-11T00:00:00 2002-10-11T00:00:00Z 2002-10-10T23:59:59.999 -0001-01-01 0001-01-01 2002
      2002Z 2003 2002-10 2002-11 --10 --11 --10-10 --10-11 ---10 ---11 12:00:00 12:00:00Z 13:00:00+01:00
      11:00:00-01:00 23:59:59Z 00:00:00+14:00 00:00:00-14:00 24:00:00 12:00:00.5 2000-02-29T23:00:00-01:00
      2000-03-01T00:00:00Z 1999-12-31T23:59:59-00:01 2000-01-01T00:00:00+14:00 --02-29 --03-01 ---31
      2002-10-10T12:00:00+13:59 2002-10-10T12:00:00-13:59 --10-14:00 --10Z --12-31+14:00 ---01-14:00
      -0004-02-29 -0001-12-31T23:59:59Z 0001-01-01T00:00:00+01:00]
    groups << [DATE_TYPES, date_vals]
    dur_vals = %w[P1Y P12M P365D P366D P367D P364D P1M P28D P29D P30D P31D P32D P27D P2M P59D P60D P61D P62D
      PT1H PT60M PT3600S P1D PT24H PT86400S -P1Y -P12M P0D PT0S -P0D P1Y1D P13M P396D P400D P1Y2M3DT4H5M6S
      P5Y P1826D P1827D P1825D -PT1S PT1S P1DT1S PT0.5S P1YT1S P1Y-1D]
    groups << [["duration"], dur_vals]
    str_vals = ["a", "a ", " a", "a  b", "a b", "a\tb", "a\nb", "b", "A", "", " ", "ab", "a b ", " a b", "a\t b",
      "a \tb", "a\u00e9", "a\t", "\ta", "  a  b  ", "a b c", "a\r\nb", "a\u0019b", "a!b", "a\"b", "a\u0010"]
    groups << [STRING_TYPES + ["anySimpleType"], str_vals]
    groups << [["boolean"], %w[true false 1 0]]
    groups << [["hexBinary"], %w[00 0A 0a 0B FF 0000 00FF 01 ABCD abcd]]
    groups << [["base64Binary"], ["AAAA", "AAA=", "AA==", "QUJD", "QUJE", "Q U J D", "QUJDRA==", "QUJDRQ==", "AAAAAAAA"]]
    groups << [%w[QName NOTATION], %w[a b a:b x:b]]
    pairs = []
    groups.each do |types, vals|
      vals.each do |v1|
        vals.each do |v2|
          t1 = types.sample(random: rng)
          t2 = types.sample(random: rng)
          pairs << [t1, v1, t2, v2]
        end
      end
    end
    # random structured pairs
    rng2 = Random.new(4242)
    { DATE_TYPES => 1500, ["duration"] => 800, DECIMAL_TYPES => 600, %w[float double] => 400 }.each do |types, n|
      pool = types.flat_map { |t| random_structured(t, 60, t.sum + 7).map { |v| [t, v] } }
      n.times do
        a = pool.sample(random: rng2)
        b = pool.sample(random: rng2)
        pairs << [a[0], a[1], b[0], b[1]]
      end
    end
    # cross-family pairs
    fams = [["decimal", "1"], ["float", "1"], ["date", "2002-10-10"], ["duration", "P1D"], ["string", "a"],
      ["boolean", "true"], ["hexBinary", "0A"], ["base64Binary", "AAAA"], ["QName", "a"], ["anyURI", "a"],
      ["anySimpleType", "a"], ["NMTOKENS", "a b"], ["integer", "1"], ["gYear", "2002"], ["time", "12:00:00"]]
    fams.each { |a| fams.each { |b| pairs << [a[0], a[1], b[0], b[1]] } }
    pairs
  end

  # ---- facet requests ----------------------------------------------------------------------

  FACET = {
    "minInclusive" => 1000, "minExclusive" => 1001, "maxInclusive" => 1002, "maxExclusive" => 1003,
    "totalDigits" => 1004, "fractionDigits" => 1005, "pattern" => 1006, "enumeration" => 1007,
    "whiteSpace" => 1008, "length" => 1009, "maxLength" => 1010, "minLength" => 1011
  }.freeze

  def facet_value_type(facet, base)
    case facet
    when "length", "minLength", "maxLength", "fractionDigits" then "nonNegativeInteger"
    when "totalDigits" then "positiveInteger"
    else base
    end
  end

  def facet_cases
    rng = Random.new(7)
    out = []
    range_sets = {
      "decimal" => [%w[0 1 -1 1.5 100 0.001], %w[0 1 -1 1.5 1.50 100 0.001 -0 99.999 1.4999 1.5001 -100]],
      "integer" => [%w[0 1 -1 100], %w[0 1 -1 100 99 101 -0]],
      "byte" => [%w[0 -128 127], %w[0 -128 127 1 -1]],
      "unsignedLong" => [%w[0 18446744073709551615 10], %w[0 18446744073709551615 9 10 11]],
      "float" => [%w[0 1.5 -INF INF NaN 1e10], %w[0 1.5 1.4 1.6 -INF INF NaN -1e10 1e10 -0]],
      "double" => [%w[0 1.5 INF NaN 1e300], %w[0 1.5 1.49999999 INF NaN 1e300 1e301]],
      "dateTime" => [%w[2002-10-10T12:00:00 2002-10-10T12:00:00Z 2002-10-10T12:00:00+05:00],
        %w[2002-10-10T12:00:00 2002-10-10T12:00:00Z 2002-10-10T07:00:00Z 2002-10-10T11:59:59Z
          2002-10-10T12:00:01-05:00 2002-10-11T02:00:00 2002-10-09T22:00:00 2002-10-10T12:00:00-14:00]],
      "date" => [%w[2002-10-10 2002-10-10Z 2002-10-10-05:00], %w[2002-10-10 2002-10-10Z 2002-10-11 2002-10-09Z 2002-10-10+14:00]],
      "time" => [%w[12:00:00 12:00:00Z 00:00:00+01:00], %w[12:00:00 12:00:00Z 11:00:00-01:00 23:00:00Z 24:00:00]],
      "gYear" => [%w[2002 2002Z -0001], %w[2002 2003 2001 2002Z 2002+14:00 -0002 0001]],
      "gYearMonth" => [%w[2002-10 2002-10Z], %w[2002-10 2002-09 2002-11 2002-10-05:00]],
      "gMonth" => [%w[--10 --10Z], %w[--10 --09 --11 --10-14:00 --10+14:00]],
      "gMonthDay" => [%w[--10-10 --02-29], %w[--10-10 --10-11 --10-09 --02-28 --03-01Z]],
      "gDay" => [%w[---10 ---10Z], %w[---10 ---09 ---11 ---10-05:00 ---31]],
      "duration" => [%w[P1Y P1M P30D PT1H -P1D], %w[P1Y P12M P365D P366D P1M P30D P31D P28D PT1H PT60M PT59M -P1D P0D -PT1S]]
    }
    range_sets.each do |base, (fvals, vals)|
      %w[minInclusive minExclusive maxInclusive maxExclusive enumeration].each do |fname|
        fvals.each do |fv|
          vals.each { |v| out << [fname, base, fv, base, v] }
        end
      end
    end
    digits = %w[0 1 -1 1.5 1.50 12.345 -12.345 0.001 0.0100 100 100.0 12345678901234567890 1234.5678 0.5 00.5 -0.000 99999]
    %w[totalDigits fractionDigits].each do |fname|
      %w[1 2 3 4 5 20 0 18446744073709551616].each do |fv|
        %w[decimal integer long].each do |base|
          digits.each { |v| out << [fname, base, fv, base, v] }
        end
      end
    end
    len_vals = {
      "string" => ["", "a", "ab", "abc", " a ", "a  b", "é", "日本", "a\u{1F600}", "   ", "a\tb\n"],
      "normalizedString" => ["", "a", "ab", " a ", "a  b", "a\tb"],
      "token" => ["a", "ab", "a b", " a "],
      "Name" => ["a", "ab", "abc"], "NCName" => ["a", "abcd"], "NMTOKEN" => ["a", "ab"],
      "language" => ["en", "en-US"], "anyURI" => ["", "a", "http://a/b", " a "],
      "ID" => ["a", "abc"], "IDREF" => ["a", "abc"],
      "hexBinary" => ["", "00", "0A0B", "0A0B0C", "0a0b0c0d"],
      "base64Binary" => ["", "AAAA", "AAA=", "AA==", "AAAAAAAA", "AAAA AAA="],
      "QName" => ["a", "abc"], "NOTATION" => ["a"], "boolean" => ["true"], "decimal" => ["123"]
    }
    %w[length minLength maxLength].each do |fname|
      %w[0 1 2 3 4 18446744073709551615 18446744073709551616 99999999999999999999].each do |fv|
        len_vals.each do |base, vals|
          vals.each { |v| out << [fname, base, fv, base, v] }
        end
      end
    end
    # enumeration over strings with whitespace (compare_values_whtsp_ext paths)
    enum_strs = ["a", "a b", " a b ", "a  b", "a\tb", "", " ", "b", "a\u00e9"]
    %w[string normalizedString token anySimpleType].each do |base|
      enum_strs.each { |fv| enum_strs.each { |v| out << ["enumeration", base, fv, base, v] } }
    end
    %w[boolean hexBinary base64Binary QName anyURI language].each do |base|
      vals = { "boolean" => %w[true false 1 0], "hexBinary" => %w[0A 0a 0B], "base64Binary" => ["AAAA", "AA AA", "AAA="],
               "QName" => %w[a b], "anyURI" => ["a", "a b", "http://a"], "language" => %w[en en-US] }[base]
      vals.each { |fv| vals.each { |v| out << ["enumeration", base, fv, base, v] } }
    end
    # whitespace facet: always 0; mismatched types (-1 paths)
    out << ["whiteSpace", "string", "collapse", "string", "a"]
    out << ["maxInclusive", "decimal", "10", "float", "5"]
    out << ["maxInclusive", "date", "2002-10-10", "decimal", "5"]
    out << ["totalDigits", "decimal", "3", "float", "1.5"]
    out << ["length", "string", "1.5", "string", "a"] # decimal facet value that is not an integer
    out.map do |f, fb, fv, b, v|
      fvt = facet_value_type(f, fb)
      fvt = "R:#{fvt}" if f == "enumeration" && rng.rand(3) != 0
      [f, fvt, fv, b, v, rng.rand(0..5)]
    end
  end

  # ---- node-dependent requests ---------------------------------------------------------------

  def node_docs
    dtd = <<~DTD
      <!DOCTYPE r [
      <!NOTATION gif SYSTEM "image/gif">
      <!ENTITY img SYSTEM "img.gif" NDATA gif>
      <!ENTITY img2 SYSTEM "img2.gif" NDATA gif>
      <!ENTITY parsed "text">
      <!ENTITY ext SYSTEM "ext.xml">
      <!ATTLIST r did ID #IMPLIED>
      ]>
    DTD
    root = '<r xmlns="urn:default" xmlns:p="urn:p" xmlns:q="urn:q" a="x" did="dtdid" b="y"/>'
    plain = '<r xmlns:p="urn:p" a="x" b="y"/>'
    [
      [dtd + root, "a", [%w[ID i1], %w[ID i2], %w[ID i1], ["ID", " i3 "], ["ID", "i3"], %w[ID 1bad], %w[ID a:b]]],
      [dtd + root, "did", [%w[ID i1], %w[ID dtdid]]],
      [dtd + root, "a", [%w[IDREF r1], ["IDREF", " r2 "], %w[IDREF r1], %w[IDREF 1x], ["IDREFS", "a b  c"], ["IDREFS", ""], ["IDREFS", "a 1"]]],
      [dtd + root, "a", [%w[ENTITY img], ["ENTITY", " img "], %w[ENTITY parsed], %w[ENTITY ext], %w[ENTITY none], %w[ENTITY amp], %w[ENTITY 1x]]],
      [dtd + root, "a", [["ENTITIES", "img img2"], ["ENTITIES", "img parsed"], ["ENTITIES", ""], ["ENTITIES", " img "]]],
      [dtd + root, "a", [%w[NOTATION gif], %w[NOTATION p:gif], %w[NOTATION z:gif], %w[NOTATION none], ["NOTATION", " gif "], %w[NOTATION 1x]]],
      [plain, "a", [%w[NOTATION gif], %w[ENTITY img], ["ENTITIES", "img"]]],
      [dtd + root, "a", [%w[QName a], %w[QName p:a], %w[QName q:b], %w[QName z:a], %w[QName xml:lang], ["QName", " p:a "], %w[QName 1a], %w[QName :a]]],
      [dtd + root, nil, [%w[QName a], %w[QName p:a], %w[QName z:a], %w[ID e1], %w[IDREF e2], %w[ENTITY img], %w[NOTATION gif]]],
      [plain, "a", [%w[QName a], %w[QName p:a], %w[ID x1], %w[ID x1]]]
    ]
  end
end
