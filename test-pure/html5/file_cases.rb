# frozen_string_literal: true

# Differential cases from real HTML files: ruby file_cases.rb SEED OUT FILES...
seed = Integer(ARGV.shift)
out = ARGV.shift
rng = Random.new(seed)
cases = []
ARGV.each_with_index do |f, i|
  data = File.binread(f).force_encoding(Encoding::UTF_8)
  cases << { id: "file#{i}:whole:#{File.basename(f)}", data: data, context: nil, script: false,
             opts: { max_errors: -1, parse_noscript_content_as_text: false, max_tree_depth: -1, max_attributes: -1 } }
  3.times do |j|
    a = rng.rand(data.bytesize)
    len = rng.rand(1..4000)
    piece = data.byteslice(a, len).force_encoding(Encoding::UTF_8)
    cases << { id: "file#{i}:slice#{j}", data: piece, context: [nil, "div", "table", "svg", "select"].sample(random: rng),
               script: rng.rand(2) == 1, opts: { max_errors: -1, parse_noscript_content_as_text: rng.rand(2) == 1 } }
  end
end
File.binwrite(out, Marshal.dump(cases))
puts cases.size
