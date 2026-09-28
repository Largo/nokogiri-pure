# frozen_string_literal: true
load File.join(__dir__, "cases.rb")
here = __dir__
inputs = HTML4Cases::SNIPPETS.map(&:b).reject(&:empty?) + HTML4Cases.fuzz(300, 99).map(&:b)
Dir[File.join(HTML4Cases::FILES, "*.html")].sort.each { |f| inputs << File.binread(f) }
cases = []
inputs.each do |s|
  cases << [:mem, s, nil, 0]
  cases << [:mem, s, "UTF-8", 0]
  cases << [:memrec, s, nil, 0]
  cases << [:io, s, nil, 0]
  cases << [:push, s, "UTF-8", 5]
  cases << [:pushrec, s, nil, 64]
end
File.binwrite("/tmp/claude-0/hsax_cases.marshal", Marshal.dump(cases))
lib = File.expand_path("../../lib", here)
system("ruby -e 'gem \"nokogiri\", \"1.19.4\"; load \"#{here}/sax_dump.rb\"' /tmp/claude-0/hsax_cases.marshal /tmp/claude-0/hsax_o.marshal") or abort
system("ruby -W0 -I#{lib} #{here}/sax_dump.rb /tmp/claude-0/hsax_cases.marshal /tmp/claude-0/hsax_p.marshal") or abort
o = Marshal.load(File.binread("/tmp/claude-0/hsax_o.marshal"))
pr = Marshal.load(File.binread("/tmp/claude-0/hsax_p.marshal"))
fails = 0
cases.each_with_index do |c, i|
  next if o[i] == pr[i]

  fails += 1
  next if fails > 6

  k = (0...[o[i].size, pr[i].size].max).find { |j| o[i][j] != pr[i][j] }
  puts "=== #{c[0]} #{c[1][0, 100].inspect} enc=#{c[2].inspect} chunk=#{c[3]} ev #{k}"
  puts "  oracle: #{o[i][k].inspect[0, 300]}"
  puts "  pure:   #{pr[i][k].inspect[0, 300]}"
end
puts "#{cases.size - fails}/#{cases.size} identical"
