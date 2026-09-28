# frozen_string_literal: true

# Random XPath expressions for compare.rb:  ruby test-pure/xpath/compare.rb test-pure/xpath/fuzz_cases.rb
# SEED / COUNT env vars control generation (both processes generate the same list).
load File.join(__dir__, "cases.rb")
DOCS.select! { |k, _| %w[d1 d3 html1].include?(k) }

R = Random.new((ENV["SEED"] || 1).to_i)
AXES = %w[child descendant descendant-or-self parent ancestor ancestor-or-self following-sibling preceding-sibling following preceding attribute self namespace]
NAMES = %w[e f r item num x deep sub group div p li td b html body * node() text() comment() processing-instruction() @n @m @id @* a:item]
FUNCS0 = %w[last() position() true() false() string() name() local-name() namespace-uri() normalize-space() number() string-length()]

def pick(a) = a[R.rand(a.length)]

def step(depth)
  s = case R.rand(6)
  when 0 then "#{pick(AXES)}::#{pick(%w[* node() text() e f item x li comment()])}"
  when 1 then pick(NAMES)
  when 2 then ".."
  when 3 then "."
  else pick(NAMES)
  end
  s += "[#{expr(depth + 1)}]" if R.rand(3) == 0 && depth < 3 && s != "." && s != ".."
  s
end

def path(depth)
  steps = (1..R.rand(1..3)).map { step(depth) }
  pre = pick(["", "/", "//", "./", ".//"])
  pre + steps.join(pick(["/", "//", "/"]))
end

def expr(depth = 0)
  return pick(["1", "2", "0", "-1", "'e'", "'10'", "last()", "position()", "1.5", "'t3'"]) if depth > 3

  case R.rand(14)
  when 0, 1, 2, 3 then path(depth)
  when 4 then "#{expr(depth + 1)} #{pick(%w[= != < > <= >=])} #{expr(depth + 1)}"
  when 5 then "#{expr(depth + 1)} #{pick(%w[+ - * div mod])} #{expr(depth + 1)}"
  when 6 then "#{expr(depth + 1)} #{pick(%w[and or])} #{expr(depth + 1)}"
  when 7 then "#{pick(%w[count sum string boolean not number string-length normalize-space name local-name namespace-uri])}(#{path(depth + 1)})"
  when 8 then "#{pick(%w[contains starts-with substring-before substring-after concat])}(#{expr(depth + 1)}, #{expr(depth + 1)})"
  when 9 then "(#{path(depth + 1)} | #{path(depth + 1)})"
  when 10 then "(#{path(depth + 1)})[#{expr(depth + 1)}]"
  when 11 then pick(FUNCS0)
  when 12 then "substring(#{expr(depth + 1)}, #{expr(depth + 1)}#{R.rand(2) == 0 ? ", " + expr(depth + 1) : ""})"
  else pick(["1", "'x'", "3 div 2", "-0", "floor(2.5)", "round(-1.5)", "ceiling(1.1)", "translate('abc', 'b', 'B')", "id('a1')", "lang('en')"])
  end
end

EXPRS = (1..(ENV["COUNT"] || 400).to_i).map { ["/", expr] } + (1..100).map { [pick(["//e[3]", "//f[2]", "//*[2]", "//li[2]", "//div", "//@*[1]", "//text()[2]"]), expr] }
