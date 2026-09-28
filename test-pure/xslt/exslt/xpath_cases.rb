# frozen_string_literal: true

# XPath expressions exercising the EXSLT functions. Each is evaluated against INPUT with the
# root node as context node; the harness compares the object type and the copy-of
# serialization of the result between native libexslt and nokogiri-pure.
#
# Cases starting with "~" are nondeterministic (current date, random): only their "shape"
# (digits replaced by 9) is compared.

module EXSLTCases
  INPUT = "<doc><n>3</n><n>1</n><n>4</n><n>1</n><n>5</n>" \
          "<s>apple</s><s>banana</s><s>apple</s><s>cherry</s>" \
          "<d>P1Y2M</d><d>P3D</d><d>PT4H</d><d2>P1D</d2><d2>-P2D</d2><d3>P1M</d3><d3>-P1D</d3>" \
          "<d4>PT0.5S</d4><d4>PT86399.75S</d4><d5>P1D</d5><d5>junk</d5>" \
          "<e/><x>NaN</x><m>-2</m><m>x</m><f>1e3</f><f>-0</f>" \
          "<from>a</from><from>b</from><from>ab</from><to>1</to><to>2</to>" \
          "<from2>b</from2><from2/><to2>X</to2><to2>-</to2>" \
          "<t>2001-10-26T21:32:52</t><t>1999-01-01</t></doc>"

  NUMS = ["0", "-0", "1", "-1", "0.5", "-0.5", "2", "10", "3.14159", "100", "-100", "0.1",
          "0.00001", "10000000000", "1 div 0", "-1 div 0", "number('x')", "'7'", "true()",
          "1.5707963267948966", "0.7853981633974483", "710", "-745.2", "1e2", "123456789.123"].freeze

  MATH = [
    "math:min(//n)", "math:max(//n)", "math:min(//s)", "math:max(//s)", "math:min(/doc/e)",
    "math:max(//zz)", "math:min(//m)", "math:max(//f)", "math:min(//f)", "math:highest(//n)",
    "math:lowest(//n)", "count(math:highest(//n))", "count(math:lowest(//n))",
    "math:highest(//s)", "math:lowest(//m)", "math:highest(//zz)", "math:lowest(/doc/e)",
    "math:min('a')", "math:max()", "math:min()", "math:highest(1)", "math:lowest(1, 2)",
    "math:min(exsl:node-set('5'))",
    "math:random(1)", "math:abs()", "math:power(2)", "math:atan2(1)", "math:constant('PI')",
  ]
  %w[PI E SQRRT2 LN2 LN10 LOG2E SQRT1_2 FOO pi].each do |c|
    ["0", "0.5", "1", "1.9", "2", "3", "5", "10", "16", "17", "18", "20", "25", "50", "60",
     "number('x')", "1 div 0"].each { |pr| MATH << "math:constant('#{c}', #{pr})" }
  end
  %w[abs sqrt log sin cos tan asin acos atan exp].each do |f|
    NUMS.each { |x| MATH << "math:#{f}(#{x})" }
  end
  [["2", "10"], ["2", "0.5"], ["-8", "1 div 3"], ["-2", "3"], ["-2", "-3"], ["0", "-1"],
   ["-0", "-1"], ["-0", "-3"], ["1 div 0", "0.5"], ["-1 div 0", "0.5"], ["-1 div 0", "-0.5"],
   ["-1 div 0", "3"], ["-1 div 0", "-3"], ["10", "400"], ["2", "-1074"], ["0.5", "1 div 0"],
   ["-1", "1 div 0"], ["1", "number('x')"], ["number('x')", "0"], ["-2", "0.5"], ["10", "-2"],
   ["1.0000001", "10000000"], ["3", "3"], ["7", "0.3333"], ["-0.5", "-1 div 0"],
   ["'2'", "'3'"]].each do |b, e|
    MATH << "math:power(#{b}, #{e})"
  end
  [["1", "1"], ["1", "-1"], ["-1", "-1"], ["0", "0"], ["0", "-0"], ["-0", "-0"], ["-0", "0"],
   ["1 div 0", "1 div 0"], ["-1 div 0", "1 div 0"], ["1", "0"], ["number('x')", "1"],
   ["3", "-4"], ["0.5", "2"]].each do |y, x|
    MATH << "math:atan2(#{y}, #{x})"
  end

  SETS = [
    "set:difference(//n, //n[1])", "set:difference(//n, //zz)", "set:difference(//zz, //n)",
    "set:difference(//n, //n)", "set:intersection(//n, //n[position() > 2])",
    "set:intersection(//n, //zz)", "set:intersection(//n, //s)", "set:distinct(//n)",
    "set:distinct(//s)", "set:distinct(//zz)", "count(set:distinct(//n | //s))",
    "set:has-same-node(//n, //n[2])", "set:has-same-node(//n, //s)",
    "set:has-same-node(//zz, //n)", "set:leading(//n, //n[3])", "set:leading(//n, //s)",
    "set:leading(//n, //zz)", "set:leading(//n, //n[1])", "set:leading(//n, //n[3] | //n[4])",
    "set:trailing(//n, //n[3])", "set:trailing(//n, //s)", "set:trailing(//n, //zz)",
    "set:trailing(//n, //n[5])", "set:trailing(//n, //n[2] | //n[4])",
    "set:distinct('x')", "set:difference(//n)", "set:leading('a', //n)", "set:trailing(//n, 'a')",
    "set:has-same-node(1, 2)", "exsl:object-type(set:difference(//n, //zz))",
    "exsl:object-type(set:leading(exsl:node-set('a'), //zz))",
  ].freeze

  STR = [
    "str:tokenize('2001-06-03T11:40:23', '-T:')", "str:tokenize('date math str')",
    "str:tokenize('a,b,,c', ',')", "str:tokenize('abc', '')", "str:tokenize('', ',')",
    "str:tokenize('ééxé', 'x')", "str:tokenize('aébéc', 'é')", "str:tokenize(' a  b ', ' ')",
    "count(str:tokenize('a,b,,c,', ','))", "str:tokenize('a,b;c', ',;')", "str:tokenize('éà', '')",
    "str:tokenize('a\tb\nc d')", "str:tokenize(//s)", "str:tokenize(12.5, '.')",
    "str:tokenize()", "str:tokenize('a', 'b', 'c')", "exsl:object-type(str:tokenize('a b'))",
    "str:split('a, simple, list', ', ')", "str:split('date math str')", "str:split('abc', '')",
    "str:split('aXbxc', 'x')", "str:split('aXbxc', 'X')", "str:split('a  b', ' ')",
    "str:split(' a ', ' ')", "str:split('', ' ')", "str:split('abc', 'abc')",
    "str:split('abcab', 'ab')", "str:split('ABCab', 'ab')", "count(str:split('a--b--', '--'))",
    "str:split()", "str:split('a', 'b', 'c')", "str:split('ab', 'abc')",
    "str:encode-uri('http://www.example.com/a b?c=d&e', true())",
    "str:encode-uri('http://www.example.com/a b?c=d&e', false())",
    "str:encode-uri('abc', true(), 'UTF-8')", "str:encode-uri('abc', true(), 'utf-8')",
    "str:encode-uri('é~@#[]', true())", "str:encode-uri('é~@#[]', false())",
    "str:encode-uri('', true())", "str:encode-uri('%41', true())", "str:encode-uri('a')",
    "str:encode-uri(1 div 0, 0)", "str:encode-uri('a/b', 'x')",
    "str:decode-uri('a%20b%C3%A9')", "str:decode-uri('%ZZ')", "str:decode-uri('%C3')",
    "str:decode-uri('abc%')", "str:decode-uri('abc%4')", "str:decode-uri('x', 'UTF-8')",
    "str:decode-uri('x', 'latin1')", "str:decode-uri('%00a')", "str:decode-uri('a%00')",
    "str:decode-uri('%e2%82%ac')", "str:decode-uri('')", "str:decode-uri()",
    "str:decode-uri('%41%2', 'UTF-8')",
    "str:padding(5)", "str:padding(5, 'ab')", "str:padding(5, 'é')", "str:padding(0)",
    "str:padding(-1)", "str:padding(3.7, 'xyz')", "str:padding(7, '')", "str:padding(number('x'))",
    "string-length(str:padding(200000, 'a'))", "string-length(str:padding(99999.9, 'ab'))",
    "str:padding(4, 'éab')", "str:padding()", "str:padding(1, 2, 3)", "str:padding(2, 1)",
    "str:padding(1 div 0, '')", "string-length(str:padding(1 div 0))",
    "str:align('abc', '-----')", "str:align('abc', '-----', 'right')",
    "str:align('abc', '-----', 'center')", "str:align('abc', '------', 'center')",
    "str:align('abcdef', '---')", "str:align('abc', '---')", "str:align('é', 'éèàü', 'center')",
    "str:align('é', 'éèàü', 'right')", "str:align('', 'xy', 'left')", "str:align('ab', '')",
    "str:align('a', 'bcd', 'Right')", "str:align('a')", "str:align('a', 'b', 'c', 'd')",
    "str:concat(//s)", "str:concat(//zz)", "str:concat('x')", "str:concat(//n | //s)",
    "str:concat()", "str:concat(exsl:node-set('q'))",
    "str:replace('abcabc', 'b', 'X')", "str:replace('abc', '', 'X')",
    "str:replace('abc', 'c', '')", "str:replace('aaaa', 'aa', 'b')",
    "str:replace('aabbcc', //from, //to)", "str:replace('abba', //from, 'Z')",
    "str:replace('abcab', //from2, //to2)", "str:replace('abc', //zz, 'Z')",
    "str:replace('abc', //from, //zz)", "str:replace('', 'a', 'b')",
    "str:replace('ébé', 'b', 'é')", "str:replace('abc', 'abc', 'abcabc')",
    "str:replace(12345, 3, 9)", "str:replace('x')", "exsl:object-type(str:replace('a', 'a', 'b'))",
    "count(str:replace('a', 'a', ''))", "str:replace('a-b', '-', //zz)",
  ].freeze

  DATES = ["2001-10-26T21:32:52", "2001-10-26T21:32:52+02:00", "2001-10-26T21:32:52Z",
           "2001-10-26T21:32:52.12679", "2001-10-26T21:32:52.5-05:30", "2001-10-26",
           "2001-10-26Z", "2001-10-26+14:00", "2001-10-26-23:59", "2001-10", "2001-10Z", "2001",
           "2001-02", "2001+01:00", "-0044-03-15", "-0001-01-01", "0001-01-01", "0000-01-01",
           "2001-02-29", "2000-02-29", "1900-02-29", "2004-02-29", "21:32:52", "21:32:52Z",
           "21:32:52.123456789", "21:32:59.9999999999", "00:00:00", "23:59:60", "24:00:00",
           "21:32", "21:32:52+05:30", "--10-26", "--10--", "---26", "--02-30", "---32",
           "20011-10-26", "02001-10-26", "123456-01-01", "2001-10-26T24:00:00",
           "2001-10-26T21:32:52.", "2001-10-26T21:32:52+24:00", "2001-10-26T21:32:52+23:59",
           "2001-10-26T21:32:52+01", "2001-13-01", "2001-00-01", "2001-01-00", "x", "",
           "2001-10-26 ", " 2001-10-26", "+2001-10-26", "2001-1-26", "1999-12-31T23:59:59",
           "2008-12-29", "2010-01-03", "2005-01-01", "2012-12-31", "-0400-02-29", "-0401-02-29",
           "9999-12-31", "10000-01-01", "2001-10-26T21:32:52-00:00", "2001-10-26+00:00",
           "1970-01-01T00:00:00Z", "1582-10-10", "0400-03-01"].freeze

  DATE_FNS = %w[date time year leap-year month-in-year month-name month-abbreviation
                week-in-year week-in-month day-in-year day-in-month day-of-week-in-month
                day-in-week day-name day-abbreviation hour-in-day minute-in-hour
                second-in-minute seconds].freeze

  DATE = []
  DATE_FNS.each do |f|
    DATES.each { |d| DATE << "date:#{f}('#{d}')" }
    DATE << "~date:#{f}()"
    DATE << "date:#{f}(1, 2)"
  end

  DURATIONS = ["P1Y2M3DT4H5M6S", "PT36H", "PT1.5M", "P1.5Y", "PT0.000000001S",
               "PT1.0000000005S", "P0D", "-P0D", "P", "PT", "P1DT", "P1H", "PT1D", "P1Y1Y",
               "P1M1Y", "p1d", " P1D", "P99999999999999999999D", "P768614336404564650Y",
               "P768614336404564651Y", "PT86400S", "PT90061.5S", "-PT1S", "-P1DT1S", "P1M",
               "-P1M", "PT0S", "P0Y0M0DT0H0M0.0S", "P1.S", "P.5D", "PT.5S", "PT1.S", "-P1Y1D",
               "P12M", "P13M", "P25H", "PT61M", "PT3601S", "PT999999999999S", "P1Y2MT",
               "PT1H1H", "P1D1D", "--P1D", "P-1D", "PT1M1.25S", "P106751991167300DT24H"].freeze

  DATE_ARITH = []
  DURATIONS.each do |dur|
    DATE_ARITH << "date:add-duration('#{dur}', 'P0D')"
    DATE_ARITH << "date:seconds('#{dur}')"
    DATE_ARITH << "date:add('2001-10-26T21:32:52', '#{dur}')"
  end
  [["2001-10-26", "P1Y2M3DT4H5M6.7S"], ["2000-01-31", "P1M"], ["2000-02-29", "P1Y"],
   ["2001", "P1M"], ["2001-12", "P1M"], ["2001", "P400D"], ["2001-10-26T21:32:52", "-PT1S"],
   ["2001-10-26", "-P1D"], ["0001-01-01", "-P1D"], ["0001-01-01T00:00:00", "-PT1S"],
   ["2001-10-26", "P"], ["2001-10-26", "P1.5D"], ["21:32:52", "PT1H"], ["--10-26", "P1D"],
   ["2001-10-26+05:00", "PT23H"], ["2001-03-31", "-P1M"], ["2001-01-01", "P146097D"],
   ["2001-01-01", "-P146097D"], ["2001-01-01", "P1000000D"], ["2001-01-01", "-P10000000D"],
   ["2001-12-31T23:59:59.5Z", "PT0.5S"], ["2001-10", "P31D"], ["2001-10", "PT1S"],
   ["2001", "P1Y"], ["2001", "-P2001Y"], ["2001-10-26", "P0D"], ["x", "P1D"],
   ["2001-10-26", "x"], ["1999-12-31T23:00:00-01:00", "PT1H"], ["2001-01-31", "P1M1D"],
   ["2001-01-01T00:00:00", "P1D"], ["-0001-12-31", "P1D"],
   ["2001", "P768614336404564650Y"], ["2001-10-26T21:32:52.999999999", "PT0.0000000011S"],
   ["2001-10-26", "P106751991167300DT24H"]].each do |d, dur|
    DATE_ARITH << "date:add('#{d}', '#{dur}')"
  end
  [["P1Y", "P1M"], ["P1D", "-P1D"], ["P1M", "-P1D"], ["PT23H", "PT1H"], ["-PT1S", "PT2S"],
   ["P9223372036854775807D", "P1D"], ["-P1M", "P1M"], ["-P1D", "-PT1S"], ["P1M", "-P1M"],
   ["PT12H", "PT12H"], ["-PT12H", "-PT12H"], ["P1Y", "-P13M"], ["x", "P1D"],
   ["P768614336404564650Y", "P1M"], ["P1D", "-P1DT1S"], ["-P1D", "P1DT1S"]].each do |a, b|
    DATE_ARITH << "date:add-duration('#{a}', '#{b}')"
  end
  [["2001-01-01", "2002-01-01"], ["2001", "2003"], ["2001-06", "2000-01"],
   ["2001-01-01T00:00:00Z", "2001-01-01T00:00:00+02:00"],
   ["2001-01-01T00:00:00.5", "2001-01-01T00:00:01"], ["2001-10-26", "2001-10-26T21:32:52"],
   ["2001", "2001-10-26T21:32:52"], ["2001-10", "2002"], ["-0001-01-01", "0001-01-01"],
   ["21:00:00", "22:00:00"], ["2001-01-01", "x"], ["2001-10-26T21:32:52", "2001-10-26T21:32:51"],
   ["2004-02-29", "2005-02-28"], ["1970-01-01", "2038-01-19T03:14:08Z"],
   ["2001-10-26T23:00:00-05:00", "2001-10-27T01:00:00Z"],
   ["2001-10-26T21:32:52.25", "2001-10-26T21:32:51.5"], ["--10-26", "2001-10-26"],
   ["123456789012-01-01", "2001-01-01"], ["2001-01", "2001-01-15"]].each do |a, b|
    DATE_ARITH << "date:difference('#{a}', '#{b}')"
  end
  ["0", "1", "-1", "86400", "90061.5", "-90061.5", "'x'", "1 div 0", "-1 div 0", "0.1",
   "123456789.123456", "-0.000001", "0.0000000004", "0.0000000006", "1e15", "-86400.5",
   "31556952", "'  42  '", "true()", "//n", "99999999999999999999999999"].each do |n|
    DATE_ARITH << "date:duration(#{n})"
  end
  DATE_ARITH.push("~date:duration()", "date:duration(1, 2)", "~date:date-time()",
                  "date:date-time(1)", "date:add('2001')", "date:add-duration('P1D')",
                  "date:difference('2001')", "date:sum(//d)", "date:sum(//d2)", "date:sum(//d3)",
                  "date:sum(//d4)", "date:sum(//d5)", "date:sum(//zz)", "date:sum('P1D')",
                  "date:sum()", "date:sum(//n)", "date:seconds(1, 2)", "~date:seconds()",
                  "date:seconds(//t)", "date:year(//t)", "date:add(//t, 'P1D')")

  COMMON = [
    "exsl:object-type('a')", "exsl:object-type(1)", "exsl:object-type(true())",
    "exsl:object-type(//n)", "exsl:object-type(exsl:node-set('a'))", "exsl:object-type()",
    "exsl:object-type(1, 2)", "exsl:node-set('abc')", "count(exsl:node-set('abc'))",
    "exsl:node-set(//n)", "exsl:node-set(3)", "exsl:node-set(//zz)", "exsl:node-set()",
    "exsl:node-set(1, 2)", "exsl:object-type(saxon:expression('1'))",
    "name(exsl:node-set('abc')/..)", "count(exsl:node-set('abc')/..)",
  ].freeze

  DYN = [
    "dyn:evaluate('1+1')", "dyn:evaluate('//n[2]')", "dyn:evaluate('')",
    "dyn:evaluate(concat('co', 'unt(//n)'))", "dyn:evaluate('string(//s[3])')",
    "dyn:evaluate('math:max(//n)')", "dyn:evaluate(//zz)", "dyn:evaluate(1)",
    "dyn:map(//n, '. * 2')", "dyn:map(//n, 'string(.)')", "dyn:map(//n, '. > 2')",
    "dyn:map(//n, '.')", "dyn:map(//s, 'string-length(.)')", "dyn:map(//zz, '1')",
    "dyn:map(//n, '')", "dyn:map(//n, 'position()')", "dyn:map(//n, 'last()')",
    "dyn:map(//n | //s, '../n[1]')", "count(dyn:map(//n, '. > 2'))",
    "dyn:map(//n, '1 div 0')", "dyn:map(//n, 'number(\"x\")')", "dyn:map(//s, 'false()')",
    "dyn:map(//n, 'exsl:node-set(.)')", "dyn:map(//n, '/doc/e')",
    "dyn:map(dyn:map(//n, '. + 1'), '. * 10')", "exsl:object-type(dyn:map(//n, '.'))",
    "dyn:map(//n, '0.1 + 0.2')", "dyn:map(//n, '-0')",
  ].freeze

  SAXON = [
    "saxon:evaluate('1+2')", "saxon:eval(saxon:expression('count(//n)'))",
    "saxon:evaluate('//s[2]')", "saxon:eval(saxon:expression('1'))",
    "saxon:evaluate(concat('//', 'n[3]'))", "saxon:systemId()", "saxon:line-number(//zz)",
    "exsl:object-type(saxon:expression('1'))",
  ].freeze

  ALL = MATH + SETS + STR + DATE + DATE_ARITH + COMMON + DYN + SAXON

  NAMESPACES = {
    "math" => "http://exslt.org/math", "set" => "http://exslt.org/sets",
    "str" => "http://exslt.org/strings", "date" => "http://exslt.org/dates-and-times",
    "exsl" => "http://exslt.org/common", "dyn" => "http://exslt.org/dynamic",
    "saxon" => "http://icl.com/saxon", "func" => "http://exslt.org/functions",
  }.freeze
end
