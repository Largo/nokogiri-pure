# frozen_string_literal: true

# Hand-written XSLT cases: [name, stylesheet (full, or top-level content to wrap), optional xml,
# optional params]. The default input is cases/default.xml.
module XSLTInlineCases
  WRAP = <<~XSL
    <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
      xmlns:x="urn:x" xmlns:exsl="http://exslt.org/common" xmlns:str="http://exslt.org/strings"
      xmlns:set="http://exslt.org/sets" xmlns:math="http://exslt.org/math" exclude-result-prefixes="exsl str set math">
    %s
    </xsl:stylesheet>
  XSL

  CASES = [
    # --- basic instructions -----------------------------------------------------------------
    ["identity", <<~X],
      <xsl:template match="@*|node()"><xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy></xsl:template>
    X
    ["value-of-types", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="1 div 3"/>|<xsl:value-of select="1 div 0"/>|<xsl:value-of select="0 div 0"/>|<xsl:value-of select="-0"/>|<xsl:value-of select="1e20"/>|<xsl:value-of select="0.1 + 0.2"/>|<xsl:value-of select="true()"/>|<xsl:value-of select="//item"/>|<xsl:value-of select="count(//item)"/>|<xsl:value-of select="//nothing"/></r></xsl:template>
    X
    ["copy-of-kinds", <<~X],
      <xsl:template match="/"><r><xsl:copy-of select="/doc/title"/><xsl:copy-of select="//comment()"/><xsl:copy-of select="//processing-instruction()"/><xsl:copy-of select="//item/@n"/><xsl:copy-of select="42"/><xsl:copy-of select="//x:ns-el"/></r></xsl:template>
    X
    ["copy-of-attrs-after-children", <<~X],
      <xsl:template match="/"><r><c/><xsl:copy-of select="//item/@n"/></r></xsl:template>
    X
    ["copy-of-ns-nodes", <<~X],
      <xsl:template match="/"><r><xsl:copy-of select="/doc/namespace::*"/><y><xsl:copy-of select="//x:ns-el/namespace::x"/></y></r></xsl:template>
    X
    ["copy-shallow", <<~X],
      <xsl:template match="*"><xsl:copy><xsl:apply-templates/></xsl:copy></xsl:template>
      <xsl:template match="text()"><xsl:copy/></xsl:template>
      <xsl:template match="comment()|processing-instruction()"><xsl:copy/></xsl:template>
    X
    ["element-attribute", <<~X],
      <xsl:template match="/"><xsl:element name="e{1+1}" namespace="urn:e"><xsl:attribute name="a">v</xsl:attribute><xsl:attribute name="p:b" namespace="urn:p">w</xsl:attribute><xsl:attribute name="c" namespace="urn:c">z</xsl:attribute><xsl:attribute name="xml:lang">de</xsl:attribute><xsl:element name="inner"/><xsl:element name="x:q"/></xsl:element></xsl:template>
    X
    ["attribute-errors", <<~X],
      <xsl:template match="/"><r><x/><xsl:attribute name="late">1</xsl:attribute></r></xsl:template>
    X
    ["attribute-bad-name", <<~X],
      <xsl:template match="/"><r><xsl:attribute name="{'1bad'}">1</xsl:attribute></r></xsl:template>
    X
    ["attribute-xmlns", <<~X],
      <xsl:template match="/"><r><xsl:attribute name="{'xmlns'}">1</xsl:attribute></r></xsl:template>
    X
    ["element-bad-name", <<~X],
      <xsl:template match="/"><xsl:element name="{'a b'}">x</xsl:element></xsl:template>
    X
    ["comment-pi", <<~X],
      <xsl:template match="/"><r><xsl:comment>c -- d</xsl:comment><xsl:comment>ok</xsl:comment><xsl:processing-instruction name="tgt">data ?&gt; more</xsl:processing-instruction><xsl:processing-instruction name="p{1}">d</xsl:processing-instruction></r></xsl:template>
    X
    ["text-doe", <<~X],
      <xsl:template match="/"><r><xsl:text disable-output-escaping="yes">&lt;raw/&gt;</xsl:text><xsl:value-of select="'&lt;v/&gt;'" disable-output-escaping="yes"/><xsl:text>&lt;esc&gt;</xsl:text></r></xsl:template>
    X
    ["if-choose", <<~X],
      <xsl:template match="item"><xsl:choose><xsl:when test="@n &gt; 5">big</xsl:when><xsl:when test="@n">small</xsl:when><xsl:otherwise>none</xsl:otherwise></xsl:choose><xsl:if test="position() = last()">!</xsl:if>,</xsl:template>
      <xsl:template match="/"><r><xsl:apply-templates select="//item"/></r></xsl:template>
    X
    ["for-each-sort", <<~X],
      <xsl:template match="/"><r><xsl:for-each select="//item"><xsl:sort select="."/><xsl:value-of select="."/>,</xsl:for-each>|<xsl:for-each select="//item"><xsl:sort select="@n" data-type="number" order="descending"/><xsl:value-of select="@n"/>,</xsl:for-each>|<xsl:for-each select="//item"><xsl:sort select="." case-order="upper-first"/><xsl:sort select="@n" data-type="number"/><xsl:value-of select="@id"/>,</xsl:for-each></r></xsl:template>
    X
    ["sort-avt", <<~X],
      <xsl:template match="/"><r><xsl:for-each select="//item"><xsl:sort select="@n" data-type="{'number'}" order="{'descending'}"/><xsl:value-of select="@n"/>,</xsl:for-each><xsl:for-each select="//item"><xsl:sort select="." data-type="{'bogus'}"/>.</xsl:for-each></r></xsl:template>
    X
    ["sort-lang", <<~X],
      <xsl:template match="/"><r><xsl:for-each select="//item"><xsl:sort select="." lang="en"/><xsl:value-of select="."/>,</xsl:for-each></r></xsl:template>
    X
    ["apply-templates-sort-params", <<~X],
      <xsl:template match="/"><r><xsl:apply-templates select="//item"><xsl:with-param name="p" select="'P'"/><xsl:sort select="@id" order="descending"/></xsl:apply-templates></r></xsl:template>
      <xsl:template match="item"><xsl:param name="p" select="'default'"/><xsl:value-of select="concat(@id, $p, position(), '/', last())"/>;</xsl:template>
    X
    ["modes", <<~X],
      <xsl:template match="/"><r><xsl:apply-templates select="//item[1]"/><xsl:apply-templates select="//item[1]" mode="m"/><xsl:apply-templates select="//item[1]" mode="x:m"/></r></xsl:template>
      <xsl:template match="item">default</xsl:template>
      <xsl:template match="item" mode="m">m</xsl:template>
      <xsl:template match="item" mode="x:m">xm</xsl:template>
    X
    ["builtin-templates", <<~X],
      <xsl:template match="/"><r><xsl:apply-templates/><xsl:apply-templates select="//item/@n" mode="q"/></r></xsl:template>
    X
    ["priorities", <<~X],
      <xsl:template match="/"><r><xsl:apply-templates select="//item|//title|//x:ns-el|//text|//empty"/></r></xsl:template>
      <xsl:template match="*">[*]</xsl:template>
      <xsl:template match="item">[item]</xsl:template>
      <xsl:template match="item[@n]">[item-n]</xsl:template>
      <xsl:template match="list/item[2]">[second]</xsl:template>
      <xsl:template match="x:*">[x:*]</xsl:template>
      <xsl:template match="node()" priority="-1">[node]</xsl:template>
      <xsl:template match="doc//text">[text]</xsl:template>
      <xsl:template match="empty" priority="3">[e3]</xsl:template>
      <xsl:template match="empty" priority="3">[e3b]</xsl:template>
    X
    ["patterns", <<~X],
      <xsl:template match="/"><r><xsl:apply-templates select="//node()|//@*" mode="p"/></r></xsl:template>
      <xsl:template match="text()" mode="p"/>
      <xsl:template match="/doc/list/item[@n &gt; 2]" mode="p">A<xsl:value-of select="@id"/></xsl:template>
      <xsl:template match="id('i5')" mode="p">ID</xsl:template>
      <xsl:template match="@x:*" mode="p">XA</xsl:template>
      <xsl:template match="@*" mode="p">@</xsl:template>
      <xsl:template match="processing-instruction('pi-target')" mode="p">PI</xsl:template>
      <xsl:template match="comment()" mode="p">C</xsl:template>
      <xsl:template match="doc//b" mode="p">B</xsl:template>
      <xsl:template match="nums/v[position() mod 2 = 0][. != 'NaN']" mode="p">V<xsl:value-of select="."/></xsl:template>
      <xsl:template match="child::empty | attribute::lang" mode="p">E</xsl:template>
      <xsl:template match="*" mode="p">.</xsl:template>
    X
    ["pattern-errors", <<~X],
      <xsl:template match="foo(" >x</xsl:template>
    X
    ["pattern-error2", <<~X],
      <xsl:template match="a//">x</xsl:template>
    X
    ["pattern-error3", <<~X],
      <xsl:template match="p:a">x</xsl:template>
    X
    ["variables", <<~X],
      <xsl:variable name="g" select="count(//item)"/>
      <xsl:variable name="rtf"><a>1</a><b>2</b></xsl:variable>
      <xsl:param name="gp">default</xsl:param>
      <xsl:template match="/"><xsl:variable name="l" select="'local'"/><r><xsl:value-of select="concat($g, $l, $gp, $rtf)"/><xsl:copy-of select="$rtf"/><xsl:value-of select="count(exsl:node-set($rtf)/*)"/><xsl:for-each select="//item"><xsl:variable name="i" select="position()"/><xsl:value-of select="$i"/></xsl:for-each></r></xsl:template>
    X
    ["variable-redefinition", <<~X],
      <xsl:template match="/"><xsl:variable name="a" select="1"/><xsl:variable name="a" select="2"/><r><xsl:value-of select="$a"/></r></xsl:template>
    X
    ["global-var-redefinition", <<~X],
      <xsl:variable name="a" select="1"/><xsl:variable name="a" select="2"/>
      <xsl:template match="/"><r><xsl:value-of select="$a"/></r></xsl:template>
    X
    ["undefined-variable", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="$nope"/></r></xsl:template>
    X
    ["recursive-global", <<~X],
      <xsl:variable name="a" select="$b"/><xsl:variable name="b" select="$a"/>
      <xsl:template match="/"><r><xsl:value-of select="$a"/></r></xsl:template>
    X
    ["params-passed", <<~X, nil, ["p1", "'one'", "p2", "1+2", "x:p3", "'ns'", "{urn:x}p4", "'clark'"]],
      <xsl:param name="p1"/><xsl:param name="p2"/><xsl:param name="x:p3"/><xsl:param name="x:p4"/><xsl:variable name="v" select="'var'"/>
      <xsl:template match="/"><r><xsl:value-of select="concat($p1, $p2, $x:p3, $x:p4)"/></r></xsl:template>
    X
    ["params-bad", <<~X, nil, ["p1", "1 +"]],
      <xsl:param name="p1"/>
      <xsl:template match="/"><r><xsl:value-of select="$p1"/></r></xsl:template>
    X
    ["call-template", <<~X],
      <xsl:template match="/"><r><xsl:call-template name="t"><xsl:with-param name="a" select="1"/><xsl:with-param name="b">two</xsl:with-param></xsl:call-template><xsl:call-template name="x:t"/></r></xsl:template>
      <xsl:template name="t"><xsl:param name="a"/><xsl:param name="b"/><xsl:param name="c" select="'C'"/><xsl:value-of select="concat($a, $b, $c)"/></xsl:template>
      <xsl:template name="x:t">ns-named</xsl:template>
    X
    ["call-template-missing", <<~X],
      <xsl:template match="/"><r><xsl:call-template name="nope"/></r></xsl:template>
    X
    ["recursion-factorial", <<~X],
      <xsl:template match="/"><r><xsl:call-template name="f"><xsl:with-param name="n" select="20"/></xsl:call-template></r></xsl:template>
      <xsl:template name="f"><xsl:param name="n"/><xsl:choose><xsl:when test="$n &lt;= 1">1</xsl:when><xsl:otherwise><xsl:variable name="r"><xsl:call-template name="f"><xsl:with-param name="n" select="$n - 1"/></xsl:call-template></xsl:variable><xsl:value-of select="$n * $r"/></xsl:otherwise></xsl:choose></xsl:template>
    X
    ["infinite-recursion", <<~X],
      <xsl:template match="/"><xsl:call-template name="loop"/></xsl:template>
      <xsl:template name="loop"><xsl:call-template name="loop"/></xsl:template>
    X
    ["message", <<~X],
      <xsl:template match="/"><xsl:message>hello <xsl:value-of select="count(//item)"/></xsl:message><r/></xsl:template>
    X
    ["message-terminate", <<~X],
      <xsl:template match="/"><r>before<xsl:message terminate="yes">stop</xsl:message>after</r></xsl:template>
    X
    ["message-bad-terminate", <<~X],
      <xsl:template match="/"><r><xsl:message terminate="maybe">m</xsl:message></r></xsl:template>
    X
    ["keys", <<~X],
      <xsl:key name="byn" match="item" use="@n"/>
      <xsl:key name="bytext" match="item" use="."/>
      <xsl:key name="x:k" match="v" use="."/>
      <xsl:template match="/"><r><xsl:value-of select="key('byn', '10')/@id"/>|<xsl:value-of select="count(key('bytext', 'apple'))"/>|<xsl:value-of select="count(key('bytext', //item))"/>|<xsl:value-of select="key('x:k', '2')"/>|<xsl:apply-templates select="key('bytext','apple')" mode="k"/></r></xsl:template>
      <xsl:template match="key('byn', '3')" mode="k">KEYMATCH</xsl:template>
      <xsl:template match="item" mode="k"><xsl:value-of select="@id"/></xsl:template>
    X
    ["key-undefined", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="count(key('nope', 'x'))"/></r></xsl:template>
    X
    ["generate-id", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="generate-id()"/>|<xsl:value-of select="generate-id(//item[2])"/>|<xsl:value-of select="generate-id(//item)"/>|<xsl:value-of select="generate-id(//item[2]) = generate-id(//item[2])"/>|<xsl:value-of select="generate-id(//nothing)"/>|<xsl:value-of select="generate-id(//x:ns-el/namespace::x)"/>|<xsl:value-of select="generate-id(//item/@n)"/></r></xsl:template>
    X
    ["system-property", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="system-property('xsl:version')"/>|<xsl:value-of select="system-property('xsl:vendor')"/>|<xsl:value-of select="system-property('xsl:vendor-url')"/>|<xsl:value-of select="system-property('nope')"/>|<xsl:value-of select="system-property('q:x')"/></r></xsl:template>
    X
    ["availability", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="element-available('xsl:value-of')"/><xsl:value-of select="element-available('xsl:nope')"/><xsl:value-of select="element-available('exsl:document')"/><xsl:value-of select="function-available('concat')"/><xsl:value-of select="function-available('exsl:node-set')"/><xsl:value-of select="function-available('str:tokenize')"/><xsl:value-of select="function-available('nope')"/><xsl:value-of select="function-available('key')"/></r></xsl:template>
    X
    ["unparsed-entity-uri", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="unparsed-entity-uri('pic')"/>|<xsl:value-of select="unparsed-entity-uri('nope')"/></r></xsl:template>
    X
    ["current", <<~X],
      <xsl:template match="/"><r><xsl:for-each select="//item"><xsl:value-of select="count(//item[. = current()])"/></xsl:for-each></r></xsl:template>
    X
    ["format-number", <<~X],
      <xsl:decimal-format name="eu" decimal-separator="," grouping-separator="." NaN="nan" infinity="inf" minus-sign="~"/>
      <xsl:decimal-format name="x:f" percent="p"/>
      <xsl:template match="/"><r><xsl:value-of select="format-number(1234567.891, '#,##0.00')"/>|<xsl:value-of select="format-number(1234567.891, '#.##0,00', 'eu')"/>|<xsl:value-of select="format-number(-0.5, '0.0;(0.0)')"/>|<xsl:value-of select="format-number(0 div 0, '0', 'eu')"/>|<xsl:value-of select="format-number(-1 div 0, '0', 'eu')"/>|<xsl:value-of select="format-number(0.25, '0%')"/>|<xsl:value-of select="format-number(0.25, '0p', 'x:f')"/>|<xsl:value-of select="format-number(1, '0', 'nope')"/></r></xsl:template>
    X
    ["number", <<~X],
      <xsl:template match="/"><r><xsl:for-each select="//item"><xsl:number/>.<xsl:number format="a"/>.<xsl:number format="I" value="position() * 7"/>.<xsl:number level="any" count="item|v"/>;</xsl:for-each><xsl:for-each select="//v"><xsl:number level="multiple" count="*" format="1.1 "/></xsl:for-each><xsl:number value="1234567" grouping-separator="," grouping-size="3"/></r></xsl:template>
    X
    ["attribute-sets", <<~X],
      <xsl:attribute-set name="s1" use-attribute-sets="s2"><xsl:attribute name="a">1</xsl:attribute><xsl:attribute name="b">1</xsl:attribute></xsl:attribute-set>
      <xsl:attribute-set name="s2"><xsl:attribute name="b">2</xsl:attribute><xsl:attribute name="c"><xsl:value-of select="count(//item)"/></xsl:attribute></xsl:attribute-set>
      <xsl:attribute-set name="x:s3"><xsl:attribute name="d">3</xsl:attribute></xsl:attribute-set>
      <xsl:template match="/"><r xsl:use-attribute-sets="s1 x:s3" e="lre"><xsl:element name="el" use-attribute-sets="s2"/><xsl:copy use-attribute-sets="s1"/></r></xsl:template>
    X
    ["attribute-set-recursion", <<~X],
      <xsl:attribute-set name="a" use-attribute-sets="a"><xsl:attribute name="x">1</xsl:attribute></xsl:attribute-set>
      <xsl:template match="/"><r xsl:use-attribute-sets="a"/></xsl:template>
    X
    ["namespace-alias", <<~X],
      <xsl:namespace-alias stylesheet-prefix="x" result-prefix="#default"/>
      <xsl:template match="/"><x:out xmlns:keep="urn:keep"><x:in keep:a="1"/></x:out></xsl:template>
    X
    ["namespace-alias2", <<~X],
      <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:axsl="urn:alias" xmlns:out="http://www.w3.org/1999/XSL/Transform">
        <xsl:namespace-alias stylesheet-prefix="axsl" result-prefix="xsl"/>
        <xsl:template match="/"><axsl:stylesheet version="1.0"><axsl:template match="{name(/*)}"><axsl:value-of select="."/></axsl:template></axsl:stylesheet></xsl:template>
      </xsl:stylesheet>
    X
    ["exclude-result-prefixes", <<~X],
      <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:a="urn:a" xmlns:b="urn:b" xmlns="urn:default" exclude-result-prefixes="a #default">
        <xsl:template match="/"><r xmlns:c="urn:c" xsl:exclude-result-prefixes="c"><a:x/><b:y/><inner/></r></xsl:template>
      </xsl:stylesheet>
    X
    ["namespaces-in-result", <<~X],
      <xsl:template match="/"><r xmlns="urn:d"><xsl:copy-of select="//item[1]"/><xsl:element name="no-ns" namespace=""/><plain/><xsl:element name="x:y"><xsl:attribute name="x:z">1</xsl:attribute></xsl:element><q xmlns=""><xsl:copy-of select="//x:ns-el"/></q></r></xsl:template>
    X
    ["ns-prefix-conflict", <<~X],
      <xsl:template match="/"><r xmlns:p="urn:one"><xsl:attribute name="p:a" namespace="urn:two">1</xsl:attribute><xsl:element name="p:e" namespace="urn:three"><xsl:attribute name="p:b" namespace="urn:four">2</xsl:attribute></xsl:element></r></xsl:template>
    X
    ["avt", <<~X],
      <xsl:template match="/"><r a="{count(//item)}" b="{{literal}}" c="x{'}'}y" d="{concat('a', &quot;}&quot;)}" e="{}" f="pre{1}{2}post" g="}}"/></xsl:template>
    X
    ["avt-errors", <<~X],
      <xsl:template match="/"><r a="{1 +}"/></xsl:template>
    X
    ["avt-unmatched", <<~X],
      <xsl:template match="/"><r a="x}y"/></xsl:template>
    X
    ["strip-space", <<~X],
      <xsl:strip-space elements="*"/><xsl:preserve-space elements="text title"/>
      <xsl:template match="/"><r><xsl:value-of select="count(//text())"/><xsl:copy-of select="/doc/list"/></r></xsl:template>
    X
    ["output-text", <<~X],
      <xsl:output method="text"/>
      <xsl:template match="/">line1 &amp; &lt;<xsl:value-of select="//title"/><r>ignored tag</r></xsl:template>
    X
    ["output-html", <<~X],
      <xsl:output method="html" indent="yes"/>
      <xsl:template match="/"><html><head><title>t</title></head><body><p>a<br/>b</p><script>if (a &lt; b) x();</script><input checked="checked"/><a href="http://x/ y?a=1&amp;b=é">l</a></body></html></xsl:template>
    X
    ["output-html-auto", <<~X],
      <xsl:template match="/"><html><body><p>auto html<br/></p></body></html></xsl:template>
    X
    ["output-html-doctype", <<~X],
      <xsl:output method="html" doctype-public="-//W3C//DTD HTML 4.01//EN" doctype-system="http://www.w3.org/TR/html4/strict.dtd" encoding="ISO-8859-1"/>
      <xsl:template match="/"><html><body>é</body></html></xsl:template>
    X
    ["output-xml-options", <<~X],
      <xsl:output method="xml" indent="yes" encoding="ISO-8859-1" standalone="yes" doctype-system="foo.dtd" doctype-public="-//FOO//EN" cdata-section-elements="c x:c2"/>
      <xsl:template match="/"><!-- lead --><r><c>cdata &lt;text&gt; é</c><x:c2>ns cdata</x:c2><d>é ü</d><e a="é"/></r></xsl:template>
    X
    ["output-omit-decl", <<~X],
      <xsl:output omit-xml-declaration="yes" indent="no"/>
      <xsl:template match="/"><r>x</r><xsl:comment>trailing</xsl:comment></xsl:template>
    X
    ["output-xhtml", <<~X],
      <xsl:output method="xhtml"/>
      <xsl:template match="/"><html><body/></html></xsl:template>
    X
    ["output-bad-method", <<~X],
      <xsl:output method="bogus"/>
      <xsl:template match="/"><r/></xsl:template>
    X
    ["output-qname-method", <<~X],
      <xsl:output method="x:custom"/>
      <xsl:template match="/"><r/></xsl:template>
    X
    ["output-bad-values", <<~X],
      <xsl:output indent="maybe" standalone="perhaps" omit-xml-declaration="dunno"/>
      <xsl:template match="/"><r/></xsl:template>
    X
    ["multiple-roots", <<~X],
      <xsl:template match="/"><a/><b/>text<c/></xsl:template>
    X
    ["empty-result", <<~X],
      <xsl:template match="/"/>
    X
    ["text-only-result", <<~X],
      <xsl:template match="/">just text</xsl:template>
    X
    ["unknown-xsl-element", <<~X],
      <xsl:template match="/"><r><xsl:bogus/></r></xsl:template>
    X
    ["unknown-xsl-element-fallback", <<~X],
      <xsl:template match="/"><r><xsl:bogus><xsl:fallback>fell back</xsl:fallback></xsl:bogus></r></xsl:template>
    X
    ["forwards-compatible", <<~X],
      <xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:future-top/><xsl:template match="/"><r><xsl:future><xsl:fallback>fb</xsl:fallback></xsl:future></r></xsl:template></xsl:stylesheet>
    X
    ["extension-element-unknown", <<~X],
      <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:e="urn:ext" extension-element-prefixes="e"><xsl:template match="/"><r><e:thing/><e:other><xsl:fallback>fb</xsl:fallback></e:other></r></xsl:template></xsl:stylesheet>
    X
    ["literal-result-stylesheet", <<~X],
      <html xsl:version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><body><xsl:value-of select="count(//item)"/></body></html>
    X
    ["not-a-stylesheet", <<~X],
      <html><body/></html>
    X
    ["missing-version", <<~X],
      <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:template match="/"><r/></xsl:template></xsl:stylesheet>
    X
    ["compile-errors", <<~X],
      <xsl:template match="/"><r><xsl:value-of/><xsl:if/><xsl:for-each/><xsl:copy-of/><xsl:call-template/><xsl:sort select="."/></r></xsl:template>
      <xsl:template>no match</xsl:template>
      <xsl:template name="1bad"/>
      <xsl:key name="k"/>
      <xsl:bogus-top/>
      <foo/>
      text at top
    X
    ["compile-xpath-error", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="1 +"/></r></xsl:template>
    X
    ["misplaced-param", <<~X],
      <xsl:template match="/"><r/><xsl:param name="late"/></xsl:template>
    X
    ["variable-with-content-and-select", <<~X],
      <xsl:template match="/"><xsl:variable name="v" select="1">content</xsl:variable><r><xsl:value-of select="$v"/></r></xsl:template>
    X
    ["apply-imports-none", <<~X],
      <xsl:template match="/"><r><xsl:apply-imports/></r></xsl:template>
    X
    ["for-each-non-nodeset", <<~X],
      <xsl:template match="/"><r><xsl:for-each select="'str'">x</xsl:for-each></r></xsl:template>
    X
    ["apply-templates-non-nodeset", <<~X],
      <xsl:template match="/"><r><xsl:apply-templates select="1"/></r></xsl:template>
    X
    ["xpath-runtime-errors", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="nofunc()"/></r></xsl:template>
    X
    ["xpath-ns-unbound", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="count(//q:item)"/></r></xsl:template>
    X
    ["document-self", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="count(document('')//xsl:template)"/></r></xsl:template>
    X
    ["document-missing", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="count(document('does-not-exist.xml'))"/></r></xsl:template>
    X
    ["document-uris", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="count(document('a b.xml'))"/>|<xsl:value-of select="count(document('default.xml#i2'))"/>|<xsl:value-of select="document('default.xml#xpointer(//item[3])')"/>|<xsl:value-of select="count(document('default.xml', /))"/>|<xsl:value-of select="count(document(//nothing))"/>|<xsl:value-of select="count(document('%64efault.xml'))"/></r></xsl:template>
    X
    ["document-nodeset-arg", <<~X],
      <xsl:template match="/"><xsl:variable name="names"><n>default.xml</n><n>default.xml</n></xsl:variable><r><xsl:value-of select="count(document(exsl:node-set($names)/n)//item)"/></r></xsl:template>
    X
    ["exsl-node-set", <<~X],
      <xsl:template match="/"><xsl:variable name="t"><i>3</i><i>1</i><i>2</i></xsl:variable><r><xsl:for-each select="exsl:node-set($t)/i"><xsl:sort select="."/><xsl:value-of select="."/></xsl:for-each><xsl:value-of select="exsl:object-type($t)"/><xsl:value-of select="exsl:object-type(1)"/></r></xsl:template>
    X
    ["rtf-as-nodeset-error", <<~X],
      <xsl:template match="/"><xsl:variable name="t"><i>3</i></xsl:variable><r><xsl:value-of select="count($t/i)"/></r></xsl:template>
    X
    ["whitespace-text-in-templates", <<~X],
      <xsl:template match="/">
        <r>
          <a>  x  </a>
          <xsl:text>  keep  </xsl:text>
          <b xml:space="preserve">  <c/>  </b>
        </r>
      </xsl:template>
    X
    ["deep-apply", <<~X],
      <xsl:template match="*"><e name="{name()}" depth="{count(ancestor::*)}"><xsl:apply-templates select="*"/></e></xsl:template>
    X
    ["lang-function", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="count(//item[lang('en')])"/><xsl:value-of select="lang('de')"/></r></xsl:template>
    X
    ["id-function", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="id('i2 i4')"/>|<xsl:value-of select="count(id('i1 i2 i9'))"/></r></xsl:template>
    X
    ["str-functions", <<~X],
      <xsl:template match="/"><r><xsl:for-each select="str:tokenize('a,b;c', ',;')"><xsl:value-of select="."/>.</xsl:for-each><xsl:value-of select="str:padding(3, 'ab')"/><xsl:value-of select="str:concat(//item)"/></r></xsl:template>
    X
    ["set-math", <<~X],
      <xsl:template match="/"><r><xsl:value-of select="count(set:distinct(//item))"/><xsl:value-of select="math:max(//item/@n)"/><xsl:value-of select="math:min(//v)"/><xsl:value-of select="count(set:intersection(//item, //item[@n]))"/></r></xsl:template>
    X
    ["copy-xml-lang-attr", <<~X],
      <xsl:template match="/"><r xml:lang="fr"><xsl:copy-of select="/doc/@lang"/><xsl:attribute name="xml:space">preserve</xsl:attribute></r></xsl:template>
    X
    ["value-of-rtf-nested", <<~X],
      <xsl:template match="/"><xsl:variable name="a"><x><xsl:value-of select="//title"/></x></xsl:variable><xsl:variable name="b"><y><xsl:copy-of select="$a"/></y></xsl:variable><r><xsl:copy-of select="$b"/><xsl:value-of select="string-length($b)"/></r></xsl:template>
    X
    ["entity-ref-text", <<~X, "<!DOCTYPE d [<!ENTITY e 'ENT'>]><d>a&e;b<x>&e;</x></d>"],
      <xsl:template match="/"><r><xsl:value-of select="d"/>|<xsl:copy-of select="d/node()"/></r></xsl:template>
    X
    ["cdata-input", <<~X, "<d><![CDATA[<cdata> & stuff]]><x>1</x></d>"],
      <xsl:template match="/"><r><xsl:value-of select="d"/><xsl:copy-of select="d/node()"/></r></xsl:template>
    X
    ["unicode", <<~X, "<d>日本語 é 𝄞</d>"],
      <xsl:template match="/"><r a="{d}"><xsl:value-of select="substring(d, 1, 2)"/>|<xsl:value-of select="string-length(d)"/>|<xsl:value-of select="translate(d, '日', 'X')"/></r></xsl:template>
    X
    ["sort-lang-words", <<~X, "<w>" + %w[apple Apple APPLE apples app-le app_le a-b ab aB Ab AB a.b ábc abc Ábc 10 9 100 1a a1 _x x_ -x .x x. éclair Eclair École ecole côte cote coté côté straße strasse ß ss ü u ue Ü foo2 foo10 foo-bar foobar ñ n ö o oe œ æ ae Æ ø ¡hola hola ~tilde @at $d % ! 한국 中文 ω Ω].map { |w| "<i>#{w.encode(xml: :text)}</i>" }.join + "<i>a b</i><i> ab</i><i>abc\u0301</i></w>"],
      <xsl:output method="text"/>
      <xsl:template match="/"><xsl:for-each select="//i"><xsl:sort select="." lang="en-US"/><xsl:value-of select="."/>|</xsl:for-each>
      <xsl:for-each select="//i"><xsl:sort select="." lang="en" order="descending"/><xsl:value-of select="."/>|</xsl:for-each>
      <xsl:for-each select="//i"><xsl:sort select="." lang="fr"/><xsl:value-of select="."/>|</xsl:for-each></xsl:template>
    X
  ].freeze

  HTML_INPUT = <<~H
    <!DOCTYPE html>
    <html><head><title>T</title><meta charset="utf-8"></head>
    <body><div id="main" class="a b"><p>One <b>bold</b> &amp; <i>it</i></p><p>Two&nbsp;&eacute;</p>
    <ul><li>x</li><li>y</li></ul><img src="a.png"><br>tail</div><!-- c --><script>if (a < b) {}</script></body></html>
  H

  HTML_CASES = [
    ["html-identity", <<~X],
      <xsl:template match="@*|node()"><xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy></xsl:template>
    X
    ["html-extract", <<~X],
      <xsl:output method="xml" indent="yes"/>
      <xsl:template match="/"><r><xsl:for-each select="//p"><para n="{position()}"><xsl:value-of select="normalize-space(.)"/></para></xsl:for-each><xsl:copy-of select="//ul"/><title><xsl:value-of select="/html/head/title"/></title></r></xsl:template>
    X
    ["html-to-html", <<~X],
      <xsl:output method="html"/>
      <xsl:template match="/"><html><body><xsl:apply-templates select="//li"/><xsl:copy-of select="//img"/></body></html></xsl:template>
      <xsl:template match="li"><p class="{.}"><xsl:value-of select="."/></p></xsl:template>
    X
  ].freeze

  module_function

  def cases
    out = CASES.map do |name, xsl, xml, params|
      xsl = format(WRAP, xsl) unless xsl.lstrip.start_with?("<xsl:stylesheet", "<html", "<?xml")
      { "name" => "inline/#{name}", "xsl" => xsl, "xml" => xml, "params" => params }
    end
    HTML_CASES.each do |name, xsl|
      out << { "name" => "inline/#{name}", "xsl" => format(WRAP, xsl), "xml" => HTML_INPUT, "html" => true }
    end
    out
  end
end
