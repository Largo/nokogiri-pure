# frozen_string_literal: true

# Case generators for the XmlRegexp differential harness (see run_diff.rb / harness.rb).
# Everything is deterministic (seeded Random), so fixtures stay valid until this file changes.
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "nokogiri/pure/xmlregexp"

module RegexpCorpus
  SUITES = %w[syntax errors categories blocks fuzz_regexp fuzz_bad models fuzz_models programs].freeze
  X = Nokogiri::Pure::XmlRegexp

  POOL = (%w[a b c d e x y z A B Z 0 1 5 9 _ - . : ; , ! ? * + ( ) [ ] { } | \\ ^ $ # @ / ' " & < > = ~ `] +
          [" ", "\t", "\n", "\r", "é", "ß", "µ", "×", "÷", "ª", "²", "Ω", "λ", "Я", "ж", "中", "文", "ア", "한",
           "٣", "۵", "́", "ः", "⃝", " ", " ", "​", " ", "　", "Ⅰ",
           "½", "€", "¢", "ˆ", "ʰ", "ǅ", "‘", "’", "«", "»",
           "‐", "‿", "∀", "©", "", "�", "\u{10400}", "\u{1D400}", "\u{1D7CE}",
           "\u{1F600}", "\u{20000}", "\u{E0001}", "\u{F0000}", "͸", "\u0001", "￾", "·",
           "ๆ", "٠", "〇", "一", "̀", " ", "­", "؀", "ก",
           "\u{10FFFD}", "퟿", ";", "Ω",]).freeze
  SAFE_POOL = (POOL - ["\u0001", "￾"]).freeze

  CATS = %w[L Lu Ll Lt Lm Lo M Mn Mc Me N Nd Nl No P Pc Pd Ps Pe Pi Pf Po Z Zs Zl Zp S Sm Sc Sk So C Cc Cf Co Cn].freeze
  BLOCKS = X::Unicode::BLOCKS.map(&:first).freeze
  MULTI = %w[\s \S \i \I \c \C \d \D \w \W .].freeze
  SINGLE = %w[\n \r \t \\\\ \| \. \- \^ \? \* \+ \{ \} \( \) \[ \]].freeze
  NONSTD = %w[\! \" \# \$ \% \, \/ \: \; \= \> \@ \` \~].freeze

  module_function

  def suite(name)
    send("suite_#{name}")
  end

  # ---- helpers ----
  def members_of(atom_pattern)
    @members ||= {}
    @members[atom_pattern] ||= begin
      comp = Nokogiri::Pure::Errors.with_handler(->(_) {}) { X.regexp_compile(atom_pattern) }
      comp ? SAFE_POOL.select { |c| X.regexp_exec(comp, c) == 1 } : []
    end
  end

  def mutate(rng, s)
    chars = s.chars
    case rng.rand(3)
    when 0 then chars.delete_at(rng.rand(chars.size)) unless chars.empty?
    when 1 then chars.insert(rng.rand(chars.size + 1), SAFE_POOL.sample(random: rng))
    else chars[rng.rand(chars.size)] = SAFE_POOL.sample(random: rng) unless chars.empty?
    end
    chars.join
  end

  def strings_for(rng, samples, extra = [])
    out = samples.dup
    samples.first(4).each { |s| out << mutate(rng, s) }
    2.times { out << Array.new(rng.rand(1..4)) { SAFE_POOL.sample(random: rng) }.join }
    out << ""
    (out + extra).uniq
  end

  # ---- random regexp AST: node -> [pattern, sampler] ----
  class Gen
    def initialize(rng, bad: false)
      @rng = rng
      @bad = bad
    end

    def r(n) = @rng.rand(n)
    def pick(a) = a[r(a.size)]

    def literal
      c = pick(SAFE_POOL - ["\n", "\r", "\t"])
      if ".\\?*+()|[]{}".include?(c)
        ["\\#{c}", c]
      else
        [c, c]
      end
    end

    def cat_prop
      if r(4) == 0
        "\\#{r(2) == 0 ? "p" : "P"}{Is#{pick(BLOCKS)}}"
      else
        "\\#{r(3) == 0 ? "P" : "p"}{#{pick(CATS)}}"
      end
    end

    def class_item
      case r(9)
      when 0, 1
        a = pick(SAFE_POOL - ["[", "]", "\\", "-", "^"])
        b = pick(SAFE_POOL - ["[", "]", "\\", "-", "^"])
        a, b = b, a if a.ord > b.ord
        "#{a}-#{b}"
      when 2 then pick(MULTI - ["."])
      when 3 then cat_prop
      when 4 then pick(SINGLE)
      when 5 then %w[a-z A-Z 0-9 a-f].sample(random: @rng)
      else
        c = pick(SAFE_POOL)
        "[]\\-^".include?(c) ? "\\#{c}" : c
      end
    end

    def char_class
      items = Array.new(1 + r(3)) { class_item }.join
      s = +"["
      s << "^" if r(4) == 0
      s << items
      if r(4) == 0
        sub = Array.new(1 + r(2)) { class_item }.join
        s << "-[#{r(5) == 0 ? "^" : ""}#{sub}]"
      end
      s << "]"
      s
    end

    def atom(depth)
      case r(depth > 2 ? 8 : 10)
      when 0, 1, 2
        lit, c = literal
        [lit, -> { c }]
      when 3 then single_char_atom(pick(MULTI))
      when 4 then single_char_atom(cat_prop)
      when 5, 6 then single_char_atom(char_class)
      when 7 then single_char_atom(r(2) == 0 ? pick(SINGLE) : pick(NONSTD))
      else
        pat, samp = alternation(depth + 1)
        ["(#{pat})", samp]
      end
    end

    def single_char_atom(pat)
      members = RegexpCorpus.members_of(pat)
      [pat, -> { members.empty? ? pick(SAFE_POOL) : pick(members) }]
    end

    def quantifier
      case r(14)
      when 0, 1 then ["?", 0, 1]
      when 2, 3 then ["*", 0, 3]
      when 4, 5 then ["+", 1, 3]
      when 6 then n = r(4); ["{#{n}}", n, n]
      when 7 then n = r(3); ["{#{n},}", n, n + 3]
      when 8 then n = r(3); m = n + r(4); ["{#{n},#{m}}", n, m]
      when 9 then ["{0,1}", 0, 1]
      when 10 then n = 1 + r(12); ["{#{n}}", n, n]
      else [nil, 1, 1]
      end
    end

    def piece(depth)
      pat, samp = atom(depth)
      q, lo, hi = quantifier
      [q ? "#{pat}#{q}" : pat, -> { Array.new(lo + r(hi - lo + 1)) { samp.call }.join }]
    end

    def branch(depth)
      pieces = Array.new(r(4) + (depth.zero? ? 1 : 0)) { piece(depth) }
      [pieces.map(&:first).join, -> { pieces.map { |_, s| s.call }.join }]
    end

    def alternation(depth)
      n = r(4) == 0 ? 2 + r(2) : 1
      branches = Array.new(n) { branch(depth) }
      [branches.map(&:first).join("|"), -> { branches[r(branches.size)][1].call }]
    end
  end

  def regexp_case(pattern, strings)
    { "kind" => "regexp", "pattern" => pattern, "strings" => strings }
  end

  # ---- suites ----
  def suite_syntax
    rng = Random.new(1)
    pats = [
      "", "a", "abc", "a|b", "a|", "|a", "|", "(a)", "()", "(|)", "a?", "a*", "a+", "a{0}", "a{0,0}", "a{1}",
      "a{2}", "a{2,}", "a{0,}", "a{1,3}", "a{0,3}", "a{3,3}", "(ab){2}", "(ab){0,2}", "(ab){2,}", "(a|b){2,3}",
      "(a|b)*c", "(a*)*", "(a?)+", "(a*b*)*", "(a|ab)(c|bcd)(d*)", "((a|b)c)*", "(a(b(c(d))))", "a*b*c*",
      "[abc]", "[^abc]", "[a-z]", "[^a-z]", "[a-zA-Z0-9]", "[-a]", "[a-]", "[a-c-]", "[^-a]", "[--/]",
      "[a-z-[aeiou]]", "[a-z-[^aeiou]]", "[\\w-[\\d]]", "[^\\w-[a]]", "[a-z-[b-y-[c]]]", "[\\p{L}-[\\p{Lu}]]",
      "[\\^]", "[\\-]", "[\\[\\]]", "[\\n\\r\\t]", "[\\\\]", "[a\\-z]", "[.]", "[*+?]", "[(){}|]", "[a^]",
      "\\n", "\\r", "\\t", "\\\\", "\\|", "\\.", "\\-", "\\^", "\\?", "\\*", "\\+", "\\{", "\\}", "\\(",
      "\\)", "\\[", "\\]", "\\!", "\\\"", "\\#", "\\$", "\\%", "\\,", "\\/", "\\:", "\\;", "\\=", "\\>",
      "\\@", "\\`", "\\~", "\\u0041", "\\u00e9+", "\\uD801\\uDC00", "[\\u0041]", "[\\u]", "\\u004a{2}",
      ".", ".*", ".+", "\\s", "\\S", "\\i", "\\I", "\\c", "\\C", "\\d", "\\D", "\\w", "\\W", "\\i\\c*",
      "[\\s\\d]", "[^\\s]", "[\\S]", "[\\i-[:]]", "\\c+", "\\d{3}-\\d{4}", "[0-9]{5}(-[0-9]{4})?",
      "\\p{L}", "\\p{Lu}", "\\P{Lu}", "\\p{IsBasicLatin}", "\\P{IsBasicLatin}", "[\\p{IsGreek}\\p{Nd}]",
      "\\p{IsGreekandCoptic}", "\\p{IsNoSuchBlock}", "[\\p{IsNoSuchBlock}]", "[^\\p{IsNoSuchBlock}]",
      "\\P{IsNoSuchBlock}", "\\p{Is}", "\\p{IsBasic-Latin}", "\\p{Cn}", "\\P{Cn}", "[\\p{Cn}a]",
      "a{", "a}", "{", "}", "a{}", "^a$", "$", "^", "a^b", "#", "a b", " ", "é+", "中文", "\u{10400}+",
      "[é-ü]", "[\u{10000}-\u{10FFFF}]+", "[^\u{10000}-\u{10FFFF}]", "(a|b|c|d|e|f)+g",
      "(a|a)", "(a|a)*b", "a*a", "(ab|ac)", "a{2,3}a", "(a{2})*", "((a{2}){3}){2}", "(a{1,2}){2,3}",
      "(a|bc){0,5}d", "x(a?){3}y", "(a?){0,2}", "(a*){2}", "([ab]{2}|c)+", "a{1000}", "(ab){1,1000}",
      "[a-c]{3}|[b-d]{2}", "\\d*\\.\\d+", "-?\\d+(\\.\\d*)?", "[+-]?[0-9]+", "[A-Z][a-z]*( [A-Z][a-z]*)*",
      "(\\p{Lu}\\p{Ll}*)+", "[\\p{L}\\p{N}_]+", "\\p{Sc}\\d+", "(.)*", "(.|\\n)*", "[\\s\\S]*",
      "[a-z]+@[a-z]+\\.[a-z]{2,3}", "(0[1-9]|1[0-2])/(0[1-9]|[12][0-9]|3[01])", "\\c{2,5}",
    ]
    extra = ["a", "b", "ab", "abc", "aa", "aaa", "aaaa", "aaaaa", "abab", "c", "d", "", "0", "123", "12345",
             "12345-6789", "A", "Ab", "é", "\u{10400}", "\u0001", "￾", "-", "^", "$", "{", "}", "\n", "\r",
             "\t", " ", "a b", "x", "abcd", "abcdd", "abd", "Hello World", "user@host.com", "12/31", "13/01",
             "1.5", ".5", "-3", "+7", "a" * 1000, "ab" * 50, "xy", "xay", "xaay", "xaaay", "xaaaay"]
    pats.map do |p|
      regexp_case(p, strings_for(rng, [], extra + SAFE_POOL.first(40)) + [{ "hex" => "61ff62" }, { "hex" => "610062" }])
    end
  end

  def suite_errors
    pats = [
      "(a", "a)", ")", "((a)", "(a))", "[a", "[", "]", "a]", "[]", "[^]", "[a-]b", "[a-", "[z-a]", "[a-\\q]",
      "[\\q]", "[a[b]]", "[a-[b]", "[a-[b]c]", "[a-[b]]c]", "[a-[]]", "[-[a]]", "\\q", "\\", "a\\",
      "\\p", "\\pL", "\\p{", "\\p{L", "\\p{Lu", "\\p{Q}", "\\p{Ix}", "\\p{I}", "\\p{Isx", "\\P{Lu",
      "\\p{}", "\\p{IsBasicLatin", "[\\p{Lu]", "[\\p{Q}]", "\\u", "\\u12", "\\u12G4", "\\uD800",
      "\\uD800x", "\\uD800\\u0041", "\\uDC00", "[\\uD800]", "a{x}", "a{,3}", "a{3", "a{3,", "a{3,x}",
      "a{99999999999}", "a{2147483647}", "a{2147483648}", "a{1,99999999999}", "a{3,1}", "a**", "a*+",
      "a?*", "*a", "+", "?", "a|*", "(*)", "(?:a)", "a{1}{2}", "[a-z-[aeiou]", "[a-z-[aeiou]x]",
      "(" * 49 + "a" + ")" * 49, "(" * 50 + "a" + ")" * 50, "(" * 51 + "a" + ")" * 51, "(" * 60,
      "[[a]]", "[a]]", "[\\]", "[\\", "[a\\", "\\P{I", "\\P{Is", "\\p{Is-}", "\\p{IsBasicLatin}}",
      { "hex" => "61ff" }, { "hex" => "5bff5d" }, { "hex" => "5b612dff5d" }, { "hex" => "5bff2d615d" },
      { "hex" => "c0af" }, { "hex" => "eda080" }, "a{0,1}{2}", "(a)(b", "a|(b", "a|b)",
    ]
    pats.map { |p| regexp_case(p, ["a", "", "ab"]) }
  end

  def suite_categories
    rng = Random.new(3)
    cps = [0x9, 0xA, 0xD, 0x20, 0x21, 0x30, 0x41, 0x5F, 0x61, 0x7F, 0x85, 0xA0, 0xAA, 0xAD, 0xB2, 0xB5, 0xB7,
           0xBA, 0xC0, 0xD7, 0xF7, 0x1C5, 0x2B0, 0x2C6, 0x300, 0x345, 0x37E, 0x387, 0x3A9, 0x488, 0x5BE, 0x600,
           0x660, 0x6DD, 0x903, 0x966, 0xE01, 0xE46, 0x16EE, 0x1680, 0x180E, 0x2000, 0x200B, 0x2010, 0x2018,
           0x2019, 0x2028, 0x2029, 0x202F, 0x203F, 0x2044, 0x20AC, 0x20DD, 0x2126, 0x2160, 0x2190, 0x2200,
           0x3000, 0x3005, 0x3007, 0x3021, 0x3041, 0x4E00, 0x9FA5, 0xAC00, 0xD7A3, 0xD7FF, 0xE000, 0xF8FF,
           0xFB1E, 0xFE00, 0xFEFF, 0xFF10, 0xFFFD, 0x10000, 0x10400, 0x1D165, 0x1D173, 0x1D400, 0x1D7CE,
           0x1F600, 0x20000, 0x2A6D6, 0x2F800, 0xE0001, 0xE0100, 0xF0000, 0x100000, 0x10FFFD, 0x10FFFF]
    cps += Array.new(80) { rng.rand(0x3000) } + Array.new(40) { rng.rand(0x10000) } + Array.new(20) { 0x10000 + rng.rand(0x100000) }
    cps = cps.reject { |c| (0xD800..0xDFFF).cover?(c) || c == 0xFFFE || c == 0xFFFF }.uniq
    strs = cps.map { |c| [c].pack("U") }
    out = []
    CATS.each do |c|
      ["\\p{#{c}}", "\\P{#{c}}", "[\\p{#{c}}]", "[^\\p{#{c}}]", "[\\P{#{c}}x]", "[a-z-[\\p{#{c}}]]", "\\p{#{c}}+"].each do |p|
        out << regexp_case(p, strs + ["\u0001", "ab", "", "aA1"])
      end
    end
    MULTI.each do |m|
      ["#{m}", "[#{m}]", "[^#{m}]", "#{m}+"].each { |p| out << regexp_case(p, strs + ["\u0001", ""]) }
    end
    out
  end

  def suite_blocks
    out = []
    BLOCKS.each do |b|
      tbl = X::BLOCK_TABLE[b]
      pts = tbl.flat_map { |v| [v - 1, v, v + 1, v + 17] }.select { |c| c >= 1 && c <= 0x10FFFF }
      pts += [0x41, 0x3B1, 0x4E00, 0x10400]
      pts = pts.reject { |c| (0xD800..0xDFFF).cover?(c) || c == 0xFFFE || c == 0xFFFF }.uniq
      strs = pts.map { |c| [c].pack("U") }
      ["\\p{Is#{b}}", "\\P{Is#{b}}", "[\\p{Is#{b}}]", "[^\\p{Is#{b}}a]"].each { |p| out << regexp_case(p, strs) }
    end
    out
  end

  def suite_fuzz_regexp
    rng = Random.new(5)
    Array.new(2500) do
      g = Gen.new(rng)
      pat, samp = g.alternation(0)
      samples = Array.new(6) { samp.call }.uniq
      regexp_case(pat, strings_for(rng, samples))
    end
  end

  def suite_fuzz_bad
    rng = Random.new(7)
    alphabet = %w[a b ( ) [ ] { } \\ - ^ | ? * + . , 0 1 9 p P { } L u I s n u D 8 x] + ["\\p{", "\\u", "-[", "{2,", "é"]
    Array.new(2000) do
      pat = Array.new(1 + rng.rand(8)) { alphabet.sample(random: rng) }.join
      regexp_case(pat, ["", "a", "ab", "b", "(", "{", "aa", "1", "p"])
    end
  end

  # ---- automata ----
  def model_case(tree, runs)
    { "kind" => "model", "tree" => tree, "runs" => runs }
  end

  def suite_models
    e = ->(n, mi = 1, ma = 1, ns = nil) { ["elem", n, ns, mi, ma] }
    trees = [
      ["seq", 1, 1, [e["a"], e["b"], e["c"]]],
      ["seq", 1, 1, [e["a", 0], e["b", 0, -1], e["c", 1, 3]]],
      ["choice", 1, 1, [e["a"], e["b"], e["c"]]],
      ["choice", 0, -1, [e["a"], e["b"]]],
      ["choice", 2, 4, [e["a"], ["seq", 1, 1, [e["b"], e["c"]]]]],
      ["seq", 2, 3, [e["a"], e["b", 0]]],
      ["seq", 0, -1, [e["a"], e["b"]]],
      ["seq", 3, -1, [e["a"]]],
      ["seq", 1, 1, [e["a", 2, 5], e["b", 0, 2]]],
      ["all", 1, [e["a"], e["b", 0], e["c"]]],
      ["all", 0, [e["a", 0], e["b", 0]]],
      ["all", 1, [e["a", 1, 1, "urn:x"], e["b", 0, 1, "urn:y"]]],
      ["seq", 1, 1, [e["a", 1, 1, "urn:x"], ["any", 0, -1, "any"]]],
      ["seq", 1, 1, [["any", 1, 1, ["ns", ["urn:x", "urn:y"]]], e["b"]]],
      ["seq", 1, 1, [["any", 0, 2, ["not", "urn:x"]], e["b"]]],
      ["seq", 1, 1, [["any", 1, 1, ["not", "urn:x"]]]],
      ["seq", 1, 1, [e["a"], e["a", 0]]],
      ["choice", 1, 1, [e["a"], ["seq", 1, 1, [e["a"], e["b"]]]]],
      ["seq", 1, 1, [e["a", 0, -1], e["a"]]],
      ["seq", 1, 1, [["subst", "h", nil, [["m1", nil], ["m2", "urn:x"]], 1, 1], e["z"]]],
      ["seq", 1, 1, [["subst", "h", nil, [["m1", nil]], 0, 3]]],
      ["all", 1, [["subst", "h", nil, [["m1", nil]], 1, 1], e["b", 0]]],
      ["seq", 1, 1, [["choice", 0, 1, [e["a"], e["b"]]], ["seq", 0, 2, [e["c"], e["d", 0, -1]]]]],
      ["seq", 1, 1, []],
      ["choice", 1, 1, [["seq", 1, 1, []], e["a"]]],
      ["seq", 1, 1, [e["a", 0, 1], e["b", 0, 1], e["c", 0, 1], e["d", 0, 1], e["e", 0, 1], e["f", 0, 1], e["g", 0, 1],
                     e["h", 0, 1], e["i", 0, 1], e["j", 0, 1], e["k", 0, 1], e["l", 0, 1]]],
      ["choice", 1, -1, [e["a", 1, -1], e["b"]]],
      ["seq", 1, 1, [e["x", 0, 100], e["y", 5, 5]]],
    ]
    rng = Random.new(11)
    trees.map { |t| model_case(t, runs_for(rng, t)) }
  end

  def names_of(t, acc = [])
    case t[0]
    when "elem" then acc << [t[1], t[2]]
    when "subst" then acc << [t[1], t[2]]; t[3].each { |m| acc << m }
    when "any"
      acc << ["w", "urn:x"] << ["w", nil] << ["w", "urn:q"]
    when "seq", "choice" then t[3].each { |c| names_of(c, acc) }
    when "all" then t[2].each { |c| names_of(c, acc) }
    end
    acc.uniq
  end

  def runs_for(rng, tree, n = 14)
    alpha = names_of(tree) + [["zz", nil], ["a", "urn:x"]]
    runs = [[]]
    runs << alpha.first(6)
    (n - 2).times do
      runs << Array.new(rng.rand(1..7)) { alpha.sample(random: rng) }
    end
    runs.uniq
  end

  def random_tree(rng, depth = 0)
    names = %w[a b c d e]
    occ = lambda do
      case rng.rand(8)
      when 0 then [0, 1]
      when 1 then [0, -1]
      when 2 then [1, -1]
      when 3 then [rng.rand(3), 2 + rng.rand(3)]
      when 4 then [2, -1]
      else [1, 1]
      end
    end
    if depth >= 3 || rng.rand(3) == 0
      case rng.rand(12)
      when 0
        kinds = ["any", ["ns", ["urn:x"]], ["not", "urn:x"], ["ns", ["urn:x", "urn:y"]]]
        mi, ma = occ.call
        ["any", mi, ma, kinds.sample(random: rng)]
      when 1
        mi, ma = occ.call
        ["subst", "h", nil, [["m", nil], ["b", nil]].first(1 + rng.rand(2)), mi, ma]
      else
        mi, ma = occ.call
        ["elem", names.sample(random: rng), rng.rand(6) == 0 ? "urn:x" : nil, mi, ma]
      end
    else
      case rng.rand(7)
      when 0
        children = names.sample(1 + rng.rand(4), random: rng).map { |n| ["elem", n, nil, rng.rand(2), 1] }
        ["all", rng.rand(2), children]
      when 1, 2, 3
        mi, ma = occ.call
        ["seq", mi, ma, Array.new(rng.rand(4)) { random_tree(rng, depth + 1) }]
      else
        mi, ma = occ.call
        ["choice", mi, ma, Array.new(1 + rng.rand(3)) { random_tree(rng, depth + 1) }]
      end
    end
  end

  def suite_fuzz_models
    rng = Random.new(13)
    Array.new(700) do
      t = random_tree(rng)
      t = ["seq", 1, 1, [t]] unless %w[seq choice all].include?(t[0])
      model_case(t, runs_for(rng, t, 10))
    end
  end

  def suite_programs
    rng = Random.new(17)
    toks = %w[a b c]
    Array.new(700) do
      prog = []
      nstates = 1
      st = -> { rng.rand(6) == 0 ? nil : rng.rand(nstates) }
      (3 + rng.rand(10)).times do
        tok = toks.sample(random: rng)
        ns = [nil, "urn:x", "urn:y"].sample(random: rng)
        d = rng.rand(3) == 0 ? nil : 50 + rng.rand(5)
        case rng.rand(16)
        when 0 then prog << ["state"]
        when 1, 2 then prog << ["trans", rng.rand(nstates), st.call, tok, d]
        when 3, 4 then prog << ["trans2", rng.rand(nstates), st.call, tok, ns, d]
        when 5 then prog << ["neg", rng.rand(nstates), st.call, "*", ns || "urn:x", d]
        when 6 then prog << ["count", rng.rand(nstates), st.call, tok, rng.rand(3), 1 + rng.rand(3), d]
        when 7 then prog << ["count2", rng.rand(nstates), st.call, tok, ns, rng.rand(2), 1 + rng.rand(3), d]
        when 8 then prog << ["once", rng.rand(nstates), st.call, tok, 1, 1 + rng.rand(2), d]
        when 9 then prog << ["once2", rng.rand(nstates), st.call, tok, ns, 1, 1, d]
        when 10, 11 then prog << ["eps", rng.rand(nstates), st.call]
        when 12 then prog << ["all", rng.rand(nstates), st.call, rng.rand(2)]
        when 13
          prog << ["counter", rng.rand(3), 1 + rng.rand(3)]
          next
        when 14 then prog << ["counted", rng.rand(nstates), st.call, 0]
        else prog << ["countertrans", rng.rand(nstates), st.call, 0]
        end
        nstates += 1
      end
      prog.unshift(["counter", 0, 2])
      (1 + rng.rand(2)).times { prog << ["final", rng.rand(nstates)] }
      alpha = toks.product([nil, "urn:x", "urn:y"]) + [["zz", nil], ["*", "urn:x"]]
      runs = [[]] + Array.new(8) { Array.new(rng.rand(1..5)) { alpha.sample(random: rng) } }
      { "kind" => "program", "program" => prog, "runs" => runs.uniq }
    end
  end
end
