# frozen_string_literal: true

# Mutation fuzzing from html5lib inputs: ruby mutate_cases.rb SEED COUNT OUT
require_relative "cases"
eval(File.read(File.expand_path("fuzz_cases.rb", __dir__))[/PIECES = .*?\n\]\n/m])
seed = Integer(ARGV[0])
count = Integer(ARGV[1])
rng = Random.new(seed)
base = Html5Cases.tree_construction.map { |c| c[:data].b }
pieces = PIECES.map(&:b)
cases = count.times.map do |i|
  s = base.sample(random: rng).dup
  rng.rand(1..6).times do
    case rng.rand(4)
    when 0 then s.insert(rng.rand(s.bytesize + 1), pieces.sample(random: rng))
    when 1
      a = rng.rand(s.bytesize + 1)
      s = s.byteslice(0, a) + s.byteslice(a + rng.rand(1..8), s.bytesize).to_s
    when 2
      a = rng.rand(s.bytesize + 1)
      s.insert(a, s.byteslice(a, rng.rand(1..20)).to_s * rng.rand(1..3))
    when 3 then s = s + base.sample(random: rng)
    end
  end
  opts = { max_errors: [-1, -1, 2].sample(random: rng), parse_noscript_content_as_text: rng.rand(2) == 1 }
  { id: "mut#{seed}:#{i}", data: s.force_encoding(Encoding::UTF_8), context: [nil, nil, "div", "table", "svg", "math", "select", "template", "tr"].sample(random: rng),
    script: opts[:parse_noscript_content_as_text], opts: opts }
end
File.binwrite(ARGV[2], Marshal.dump(cases))
