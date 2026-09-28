# frozen_string_literal: true

# Random HTML-ish inputs for differential testing: ruby fuzz_cases.rb SEED COUNT OUTFILE
PIECES = [
  "<", ">", "</", "/>", "<!", "<!--", "-->", "--!>", "<!-", "-", "--", "<?", "?>", "=", "\"", "'", "`", " ", "\t", "\n",
  "\r", "\r\n", "\f", "\0", "\x01", "\x7f", "\u0085", "￾", "﷐", "\u{1F600}", "é", "\xff", "\xc3", "\xe2\x82",
  "\xed\xa0\x80", "\xf4\x90\x80\x80", "&", "&amp", "&amp;", "&notin", "&noti", "&not", "&#", "&#x", "&#X41;", "&#65",
  "&#0;", "&#x110000;", "&#xD800;", "&#128;", "&#x9F;", "&#13;", "&#xFFFE;", "&foo;", "&AElig", "&lt=", "&ltx",
  "&NotEqualTilde;", "&#99999999999;", "<!DOCTYPE html>", "<!doctype html PUBLIC \"-//W3C//DTD HTML 4.01//EN\">",
  "<!DOCTYPE html SYSTEM \"about:legacy-compat\">", "<!DOCTYPE", " PUBLIC ", " SYSTEM ", "<![CDATA[", "]]>", "]",
  "html", "head", "body", "p", "div", "table", "tr", "td", "th", "tbody", "caption", "col", "colgroup", "select",
  "option", "optgroup", "textarea", "title", "script", "style", "xmp", "iframe", "noscript", "noembed", "noframes",
  "plaintext", "template", "svg", "math", "mi", "mtext", "annotation-xml", "foreignObject", "desc", "clipPath",
  "font", "b", "i", "a", "nobr", "form", "frameset", "frame", "li", "ul", "dd", "dt", "h1", "h2", "pre", "listing",
  "br", "img", "image", "input", "hr", "button", "ruby", "rt", "rp", "rb", "rtc", "applet", "object", "marquee",
  "xlink:href", "xml:lang", "xmlns", "xmlns:xlink", "definitionurl", "viewbox", "encoding", "text/html", "color",
  "type", "hidden", "id", "class", "x", "y", "FOO", "Bar", "a b", "<p>", "</p>", "<table>", "<td>", "<tr>", "</td>",
  "<svg>", "</svg>", "<math>", "<b>", "</b>", "<i>", "</i>", "<a href=x>", "</a>", "<script>", "</script>",
  "<!--x-->", "<br/>", "<div/>", "<select>", "<option>", "<template>", "</template>", "<frameset>", "<body>",
  "<html>", "</html>", "</body>", "<head>", "<title>", "</title>", "<textarea>", "<style>", "</style>",
  "<font color=red>", "<annotation-xml encoding=text/html>", "<foreignObject>", "<mi>", "<plaintext>",
]
CONTEXTS = [nil, nil, nil, "div", "body", "table", "tr", "td", "select", "svg", "math", "svg:foreignObject",
  "math:annotation-xml", "title", "textarea", "script", "style", "plaintext", "template", "html", "form", "frameset",
  "noscript", "head", "tbody", "colgroup", "caption", "svg:desc", "math:mi", "xmp", "iframe"]

def gen(rng)
  n = rng.rand(1..40)
  s = String.new(encoding: Encoding::BINARY)
  n.times { s << PIECES[rng.rand(PIECES.size)].b }
  s.force_encoding(Encoding::UTF_8)
end

seed = Integer(ARGV[0])
count = Integer(ARGV[1])
rng = Random.new(seed)
cases = count.times.map do |i|
  opts = { max_errors: [-1, -1, -1, 0, 1, 3].sample(random: rng), parse_noscript_content_as_text: rng.rand(2) == 1 }
  opts[:max_tree_depth] = [400, 400, 400, 2, 5, -1].sample(random: rng)
  opts[:max_attributes] = [400, 400, 400, 0, 1, 2, -1].sample(random: rng)
  { id: "fuzz#{seed}:#{i}", data: gen(rng), context: CONTEXTS.sample(random: rng), script: opts[:parse_noscript_content_as_text], opts: opts }
end
File.binwrite(ARGV[2], Marshal.dump(cases))
