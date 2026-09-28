# frozen_string_literal: true

# Differential test of EXSLT through whole XSLT transforms (native gem vs nokogiri-pure), using
# the XSLT core's runner (test-pure/xslt/runner.rb). Complements compare_xpath.rb with what
# needs a real stylesheet: func:function/func:result, result tree fragments, variables,
# compile/runtime error messages, saxon:line-number/systemId.
#   ruby test-pure/xslt/exslt/compare_xslt.rb [filter-regexp] [-v] [-d]
require "open3"

RUNNER = File.expand_path("../runner.rb", __dir__)
filter = ARGV.find { |a| !a.start_with?("-") }
verbose = ARGV.include?("-v")
dump = ARGV.include?("-d") # print every native result

NS = 'xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:func="http://exslt.org/functions" ' \
     'xmlns:exsl="http://exslt.org/common" xmlns:my="urn:my" xmlns:str="http://exslt.org/strings" ' \
     'xmlns:math="http://exslt.org/math" xmlns:set="http://exslt.org/sets" ' \
     'xmlns:dyn="http://exslt.org/dynamic" xmlns:saxon="http://icl.com/saxon" ' \
     'xmlns:date="http://exslt.org/dates-and-times" xmlns:crypto="http://exslt.org/crypto"'

XML = <<~XML
  <doc>
    <n>3</n>
    <n>1</n>
    <n>4</n>
    <s>apple</s><s>banana</s><s>apple</s>
    <d>P1D</d><d>PT12H</d>
  </doc>
XML

def ss(body, excl: "func exsl my str math set dyn saxon date crypto")
  %(<xsl:stylesheet version="1.0" #{NS} extension-element-prefixes="func exsl" exclude-result-prefixes="#{excl}">\n#{body}\n</xsl:stylesheet>)
end

def tmpl(body) = %(<xsl:template match="/">#{body}</xsl:template>)

CASES = {
  # ---- func:function / func:result ----------------------------------------------------------
  "func-basic" => ss(<<~X),
    <func:function name="my:double"><xsl:param name="x"/><func:result select="$x * 2"/></func:function>
    #{tmpl('<out><xsl:value-of select="my:double(21)"/>|<xsl:value-of select="my:double(//n[1])"/></out>')}
  X
  "func-default-param" => ss(<<~X),
    <func:function name="my:f"><xsl:param name="a" select="'A'"/><xsl:param name="b">B</xsl:param>
      <func:result select="concat($a, '-', $b)"/></func:function>
    #{tmpl('<out><xsl:value-of select="my:f()"/>|<xsl:value-of select="my:f(1)"/>|<xsl:value-of select="my:f(1, 2)"/></out>')}
  X
  "func-too-many-args" => ss(<<~X),
    <func:function name="my:f"><xsl:param name="a"/><func:result select="$a"/></func:function>
    #{tmpl('<out><xsl:value-of select="my:f(1, 2)"/></out>')}
  X
  "func-no-result" => ss(<<~X),
    <func:function name="my:f"><xsl:variable name="v" select="1"/></func:function>
    #{tmpl('<out>[<xsl:value-of select="my:f()"/>]<xsl:value-of select="exsl:object-type(my:f())"/></out>')}
  X
  "func-empty-result" => ss(<<~X),
    <func:function name="my:f"><func:result/></func:function>
    #{tmpl('<out>[<xsl:value-of select="my:f()"/>]<xsl:value-of select="exsl:object-type(my:f())"/></out>')}
  X
  "func-rtf-result" => ss(<<~X),
    <func:function name="my:f"><xsl:param name="x"/><func:result><a><xsl:value-of select="$x"/></a><b/></func:result></func:function>
    #{tmpl('<out><xsl:copy-of select="my:f(5)"/>|<xsl:value-of select="exsl:object-type(my:f(1))"/>|<xsl:value-of select="count(exsl:node-set(my:f(1))/*)"/></out>')}
  X
  "func-nodeset-result" => ss(<<~X),
    <func:function name="my:big"><xsl:param name="ns"/><func:result select="$ns[. &gt; 2]"/></func:function>
    #{tmpl('<out><xsl:for-each select="my:big(//n)"><xsl:value-of select="."/>,</xsl:for-each></out>')}
  X
  "func-recursive" => ss(<<~X),
    <func:function name="my:fact"><xsl:param name="n"/>
      <xsl:choose><xsl:when test="$n &lt;= 1"><func:result select="1"/></xsl:when>
      <xsl:otherwise><func:result select="$n * my:fact($n - 1)"/></xsl:otherwise></xsl:choose></func:function>
    #{tmpl('<out><xsl:value-of select="my:fact(10)"/></out>')}
  X
  "func-infinite-recursion" => ss(<<~X),
    <func:function name="my:loop"><xsl:param name="n"/><func:result select="my:loop($n + 1)"/></func:function>
    #{tmpl('<out><xsl:value-of select="my:loop(1)"/></out>')}
  X
  "func-context-node" => ss(<<~X),
    <func:function name="my:name"><func:result select="name(.)"/></func:function>
    #{tmpl('<out><xsl:for-each select="//s"><xsl:value-of select="my:name()"/>;</xsl:for-each></out>')}
  X
  "func-write-result-tree" => ss(<<~X),
    <func:function name="my:f"><junk/><func:result select="1"/></func:function>
    #{tmpl('<out><xsl:value-of select="my:f()"/></out>')}
  X
  "func-two-results" => ss(<<~X),
    <func:function name="my:f"><xsl:if test="true()"><func:result select="1"/></xsl:if><xsl:if test="true()"><func:result select="2"/></xsl:if></func:function>
    #{tmpl('<out><xsl:value-of select="my:f()"/></out>')}
  X
  "func-result-select-and-content" => ss(<<~X),
    <func:function name="my:f"><func:result select="1">x</func:result></func:function>
    #{tmpl('<out><xsl:value-of select="my:f()"/></out>')}
  X
  "func-result-followed-by-element" => ss(<<~X),
    <func:function name="my:f"><func:result select="1"/><xsl:variable name="v"/></func:function>
    #{tmpl('<out><xsl:value-of select="my:f()"/></out>')}
  X
  "func-result-followed-by-fallback" => ss(<<~X),
    <func:function name="my:f"><func:result select="1"/><xsl:fallback/></func:function>
    #{tmpl('<out><xsl:value-of select="my:f()"/></out>')}
  X
  "func-result-outside-function" => ss(tmpl('<out><func:result select="1"/></out>')),
  "func-result-in-variable" => ss(<<~X),
    <func:function name="my:f"><xsl:variable name="v"><func:result select="1"/></xsl:variable><func:result select="2"/></func:function>
    #{tmpl('<out><xsl:value-of select="my:f()"/></out>')}
  X
  "func-result-in-result" => ss(<<~X),
    <func:function name="my:f"><func:result><func:result select="1"/></func:result></func:function>
    #{tmpl('<out><xsl:value-of select="my:f()"/></out>')}
  X
  "func-duplicate" => ss(<<~X),
    <func:function name="my:f"><func:result select="1"/></func:function>
    <func:function name="my:f"><func:result select="2"/></func:function>
    #{tmpl('<out><xsl:value-of select="my:f()"/></out>')}
  X
  "func-not-qname" => ss(<<~X),
    <func:function name="f"><func:result select="1"/></func:function>
    #{tmpl('<out>x</out>')}
  X
  "func-undeclared-prefix" => ss(<<~X),
    <func:function name="nope:f"><func:result select="1"/></func:function>
    #{tmpl('<out>x</out>')}
  X
  "func-only-params" => ss(<<~X),
    <func:function name="my:f"><xsl:param name="a"/></func:function>
    #{tmpl('<out>[<xsl:value-of select="my:f(7)"/>]</out>')}
  X
  "func-rtf-arg" => ss(<<~X),
    <xsl:variable name="rtf"><a>1</a><a>2</a></xsl:variable>
    <func:function name="my:cnt"><xsl:param name="t"/><func:result select="count(exsl:node-set($t)/a)"/></func:function>
    #{tmpl('<out><xsl:value-of select="my:cnt($rtf)"/></out>')}
  X
  "func-local-vars-scope" => ss(<<~X),
    <func:function name="my:f"><xsl:param name="a"/><xsl:variable name="b" select="$a + 1"/><func:result select="$b * 10"/></func:function>
    #{tmpl('<xsl:variable name="b" select="100"/><out><xsl:value-of select="my:f(1)"/>|<xsl:value-of select="$b"/></out>')}
  X
  "func-available" => ss(<<~X),
    <func:function name="my:f"><func:result select="1"/></func:function>
    #{tmpl('<out><xsl:value-of select="function-available(\'my:f\')"/>|<xsl:value-of select="function-available(\'my:g\')"/>|<xsl:value-of select="element-available(\'func:result\')"/>|<xsl:value-of select="function-available(\'str:tokenize\')"/>|<xsl:value-of select="function-available(\'date:date-time\')"/></out>')}
  X
  "func-nested-calls" => ss(<<~X),
    <func:function name="my:inc"><xsl:param name="x"/><func:result select="$x + 1"/></func:function>
    <func:function name="my:twice"><xsl:param name="x"/><func:result select="my:inc(my:inc($x))"/></func:function>
    #{tmpl('<out><xsl:value-of select="my:twice(my:twice(0))"/></out>')}
  X
  "func-result-variable-rtf" => ss(<<~X),
    <func:function name="my:f"><xsl:variable name="v"><x>9</x></xsl:variable><func:result select="$v"/></func:function>
    #{tmpl('<out><xsl:copy-of select="my:f()"/>|<xsl:value-of select="exsl:object-type(my:f())"/></out>')}
  X
  # ---- common ---------------------------------------------------------------------------------
  "common-object-type" => ss(<<~X),
    <xsl:variable name="rtf"><a/></xsl:variable>
    #{tmpl('<out><xsl:value-of select="exsl:object-type($rtf)"/>|<xsl:value-of select="exsl:object-type(exsl:node-set($rtf))"/>|<xsl:value-of select="exsl:object-type(saxon:expression(\'1\'))"/></out>')}
  X
  "common-node-set-rtf" => ss(<<~X),
    <xsl:variable name="rtf"><a x="1">t</a><b/>text</xsl:variable>
    #{tmpl('<out><xsl:for-each select="exsl:node-set($rtf)/node()"><xsl:value-of select="name()"/>;</xsl:for-each>|<xsl:value-of select="exsl:node-set($rtf)/a/@x"/></out>')}
  X
  "common-node-set-string" => ss(tmpl('<out><xsl:copy-of select="exsl:node-set(\'str\')"/>|<xsl:value-of select="count(exsl:node-set(\'s\')/..)"/></out>')),
  "common-node-set-arity" => ss(tmpl('<out><xsl:value-of select="exsl:node-set()"/></out>')),
  "common-object-type-arity" => ss(tmpl('<out><xsl:value-of select="exsl:object-type()"/></out>')),
  # ---- math/sets/strings with RTF arguments -------------------------------------------------
  "math-rtf" => ss(<<~X),
    <xsl:variable name="rtf"><v>5</v><v>2</v></xsl:variable>
    #{tmpl('<out><xsl:value-of select="math:max($rtf)"/>|<xsl:value-of select="math:min(exsl:node-set($rtf)/v)"/>|<xsl:value-of select="count(math:highest(exsl:node-set($rtf)/v))"/></out>')}
  X
  "math-min-arity" => ss(tmpl('<out><xsl:value-of select="math:min(1, 2)"/></out>')),
  "math-max-type" => ss(tmpl('<out><xsl:value-of select="math:max(\'x\')"/></out>')),
  "sets-rtf" => ss(<<~X),
    <xsl:variable name="rtf"><v>5</v><v>5</v></xsl:variable>
    #{tmpl('<out><xsl:value-of select="count(set:distinct(exsl:node-set($rtf)/v))"/>|<xsl:value-of select="exsl:object-type(set:distinct($rtf))"/>|<xsl:value-of select="count(set:leading($rtf, /doc))"/></out>')}
  X
  "strings-rtf" => ss(<<~X),
    <xsl:variable name="rtf"><v>a</v><v>b</v></xsl:variable>
    <xsl:variable name="to"><v>1</v><v>2</v></xsl:variable>
    #{tmpl('<out><xsl:value-of select="str:concat($rtf)"/>|<xsl:value-of select="str:replace(\'aabb\', exsl:node-set($rtf)/v, exsl:node-set($to)/v)"/>|<xsl:value-of select="str:replace(\'ab\', $rtf, \'x\')"/></out>')}
  X
  "strings-tokens-copy" => ss(tmpl('<out><xsl:copy-of select="str:tokenize(\'a b c\')"/><xsl:copy-of select="str:split(\'x-y\', \'-\')"/><xsl:for-each select="str:tokenize(\'q,w\', \',\')"><i><xsl:value-of select="position()"/><xsl:value-of select="name()"/></i></xsl:for-each></out>')),
  "strings-concat-type" => ss(tmpl('<out><xsl:value-of select="str:concat(\'x\')"/></out>')),
  "strings-bad-arity" => ss(tmpl('<out><xsl:value-of select="str:tokenize()"/></out>')),
  # ---- dyn ------------------------------------------------------------------------------------
  "dyn-variables" => ss(<<~X),
    <xsl:variable name="g" select="7"/>
    #{tmpl('<xsl:variable name="l" select="3"/><out><xsl:value-of select="dyn:evaluate(\'$g * $l\')"/>|<xsl:value-of select="dyn:evaluate(\'$nope\')"/>|<xsl:value-of select="count(dyn:evaluate(\'//n\'))"/></out>')}
  X
  "dyn-evaluate-arity" => ss(tmpl('<out><xsl:value-of select="dyn:evaluate(1, 2)"/></out>')),
  "dyn-evaluate-syntax" => ss(tmpl('<out>[<xsl:value-of select="dyn:evaluate(\'1 +\')"/>]</out>')),
  "dyn-map-copy" => ss(tmpl('<out><xsl:copy-of select="dyn:map(//n, \'. * 2\')"/><xsl:copy-of select="dyn:map(//s, \'string-length(.) &gt; 5\')"/><xsl:copy-of select="dyn:map(//n, \'concat(., &quot;x&quot;)\')"/></out>'), excl: "func my str math set dyn saxon date crypto"),
  "dyn-map-rtf-var" => ss(<<~X),
    <xsl:variable name="rtf"><v>1</v></xsl:variable>
    #{tmpl('<out><xsl:value-of select="count(dyn:map(//n, \'$rtf\'))"/>|<xsl:value-of select="count(dyn:map(//n, \'exsl:node-set($rtf)/v\'))"/></out>')}
  X
  "dyn-map-type-error" => ss(tmpl('<out><xsl:value-of select="dyn:map(\'foo\', \'bar\')"/></out>')),
  "dyn-map-compile-error" => ss(tmpl('<out>[<xsl:value-of select="dyn:map(//n, \'1 +\')"/>]</out>')),
  "dyn-map-namespaces" => ss(tmpl('<out><xsl:value-of select="dyn:map(//n, \'math:max(//n)\')"/></out>')),
  # ---- saxon ----------------------------------------------------------------------------------
  "saxon-line-number" => ss(tmpl('<out><xsl:value-of select="saxon:line-number()"/>|<xsl:value-of select="saxon:line-number(//n[2])"/>|<xsl:value-of select="saxon:line-number(//n)"/>|<xsl:for-each select="//s"><xsl:value-of select="saxon:line-number()"/>,</xsl:for-each>|<xsl:value-of select="saxon:line-number(//zz)"/></out>')),
  "saxon-line-number-rtf" => ss(<<~X),
    <xsl:variable name="rtf"><a/></xsl:variable>
    #{tmpl('<out><xsl:value-of select="saxon:line-number($rtf)"/></out>')}
  X
  "saxon-line-number-arity" => ss(tmpl('<out><xsl:value-of select="saxon:line-number(1, 2)"/></out>')),
  "saxon-system-id" => ss(tmpl('<out>[<xsl:value-of select="saxon:systemId()"/>]</out>')),
  "saxon-expression" => ss(<<~X),
    <xsl:variable name="e" select="saxon:expression('count(//n) + $x')"/>
    <xsl:variable name="x" select="10"/>
    #{tmpl('<out><xsl:value-of select="saxon:eval($e)"/>|<xsl:value-of select="saxon:evaluate(\'string(//s[2])\')"/>|<xsl:for-each select="//n"><xsl:value-of select="saxon:eval(saxon:expression(\'. + 1\'))"/>,</xsl:for-each></out>')}
  X
  "saxon-eval-type" => ss(tmpl('<out><xsl:value-of select="saxon:eval(1)"/></out>')),
  "saxon-expression-syntax" => ss(tmpl('<out><xsl:value-of select="saxon:evaluate(\'1 +\')"/></out>')),
  # ---- date -------------------------------------------------------------------------------------
  "date-sum-rtf" => ss(<<~X),
    <xsl:variable name="rtf"><v>P1D</v><v>PT1H</v></xsl:variable>
    #{tmpl('<out><xsl:value-of select="date:sum(//d)"/>|<xsl:value-of select="date:sum(exsl:node-set($rtf)/v)"/>|<xsl:value-of select="date:sum($rtf)"/></out>')}
  X
  "date-arity" => ss(tmpl('<out><xsl:value-of select="date:add(1)"/></out>')),
  # ---- exsl:document ------------------------------------------------------------------------
  "exsl-document-no-href" => ss(tmpl('<out><exsl:document><x/></exsl:document></out>')),
  "exsl-element-available" => ss(tmpl('<out><xsl:value-of select="element-available(\'exsl:document\')"/>|<xsl:value-of select="element-available(\'func:function\')"/>|<xsl:value-of select="function-available(\'exsl:node-set\')"/>|<xsl:value-of select="function-available(\'crypto:md5\')"/></out>')),
}.freeze

cases = CASES.map { |name, xsl| { "name" => name, "xsl" => xsl, "xml" => XML, "xsl_url" => "exslt-#{name}.xsl", "xml_url" => "exslt-input.xml" } }
cases.select! { |c| Regexp.new(filter).match?(c["name"]) } if filter
data = Marshal.dump(cases)

results = {}
%w[native pure].each do |mode|
  out, err, = Open3.capture3("ruby", "-W0", RUNNER, mode, stdin_data: data, binmode: true)
  begin
    results[mode] = Marshal.load(out)
  rescue StandardError
    warn "#{mode} runner failed:\n#{err[-3000..] || err}"
    exit 1
  end
end

if dump
  results["native"].each { |k, v| puts "#{k}: #{(v["error"] || v["serialize"]).to_s.tr("\n", " ")}" }
end

fails = []
cases.each do |c|
  n = results["native"][c["name"]]
  pu = results["pure"][c["name"]]
  next if n == pu

  fails << c["name"]
  next unless verbose

  puts "=== #{c["name"]}"
  %w[error serialize to_s].each do |k|
    next if n[k] == pu[k]

    puts "--- #{k} native:\n#{n[k]}\n--- #{k} pure:\n#{pu[k]}"
  end
end
puts "PASS #{cases.length - fails.length}/#{cases.length}"
puts "FAIL: #{fails.join(" ")}" unless fails.empty?
exit(fails.empty? ? 0 : 1)
