# ruby.wasm compiles Ruby on the wasm (= browser JS engine) native stack, where each AST level
# costs a large frame: at V8's default stack, files whose AST is ~45+ levels deep fail to load
# ("Maximum call stack size exceeded"). Keep every lib file well below that.
#   ruby test-pure/wasm_ast_depth.rb [max=30]
require "prism"
max = (ARGV[0] || 30).to_i
bad = []
Dir[File.expand_path("../lib/**/*.rb", __dir__)].sort.each do |f|
  deepest = Hash.new(0)
  walk = lambda do |n, d|
    return unless n
    if d > max
      deepest[n.location.start_line] = [deepest[n.location.start_line], d].max
      return
    end
    n.compact_child_nodes.each { |c| walk.(c, d + 1) }
  end
  walk.(Prism.parse_file(f).value, 0)
  bad << [f.sub(%r{.*/lib/}, "lib/"), deepest.keys.min, deepest.size] unless deepest.empty?
end
bad.each { |f, line, n| puts "#{f}:#{line} (#{n} sites deeper than #{max})" }
puts bad.empty? ? "ok: no file deeper than #{max}" : "#{bad.size} files too deep"
exit(bad.empty? ? 0 : 1)
