# frozen_string_literal: true

# Scaling smoke test for the HTML parsers: 4x the input must take about 4x the time (no quadratic
# rescans on single-line documents, long runs, long references ...). ruby html_scaling.rb
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "nokogiri"
def t; c = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID); yield; Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - c; end
gens = {
  "tags1line" => ->(n) { "<p>" + "<b class=x>a</b><!-- c -->" * n },
  "longtext" => ->(n) { "<p>" + "abc def " * (n * 3) + "</p>" },
  "longtext_u" => ->(n) { "<p>" + "abc déf " * (n * 3) + "</p>" },
  "longscript" => ->(n) { "<script>" + "var x = 1; " * (n * 2) + "</script>" },
  "comments" => ->(n) { "<!-- x -->" * n + "a" * (n * 10) },
  "longattr" => ->(n) { "<a href=\"" + "x" * (n * 20) + "\">" },
  "unclosed" => ->(n) { "<a b=\"" + "<i>x</i>" * n },
  "longrefs" => ->(n) { "<p>&#x" + "a" * n + " &#" + "1" * n + " &" + "a" * n + " <a b=\"&#x" + "a" * n + "\" c='&#" + "1" * n + "' d=&" + "b" * n + ">" },
  "manyrefs" => ->(n) { "<p>" + "&#xaaaaaaaaaaaa &#11111111111 &amp &amp; <a b='&#xaaaaaaaaa&#1111111111&amp'>" * (n / 10) },
}
gens.each do |name, g|
  r = [2000, 8000].map do |n|
    s = g.(n)
    [t { Nokogiri::HTML4(s.b) }, t { Nokogiri::HTML5(s) }]
  end
  printf("%-12s h4 x%.1f  h5 x%.1f  (%.3fs %.3fs)\n", name, r[1][0] / r[0][0], r[1][1] / r[0][1], r[1][0], r[1][1])
end
