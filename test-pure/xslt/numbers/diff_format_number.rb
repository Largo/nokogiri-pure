# frozen_string_literal: true

# In-process differential check of Pure::XSLT.format_number_conversion against the native
# gem's xsltFormatNumberConversion (via Fiddle). Loads only the pure files numbers.rb needs,
# next to the native gem (they live in Nokogiri::Pure, which the native gem doesn't define).
#
#   ruby test-pure/xslt/numbers/diff_format_number.rb           # the case tables
#   ruby test-pure/xslt/numbers/diff_format_number.rb fuzz 20000 [seed]

require_relative "native_oracle"
require_relative "cases"

PURE = File.expand_path("../../../lib/nokogiri/pure", __dir__)
%w[util tree errors xpath xslt/internals xslt/utils xslt/numbers].each { |f| require File.join(PURE, f) }

X = Nokogiri::Pure::XSLT

def pure_format_number(df, format, number)
  d = X::DecimalFormat.new(nil, nil)
  NumberCases::DEFAULT_DF.each_key { |k| d.__send__(:"#{k}=", nil) }
  df.each { |k, v| d.__send__(:"#{k}=", v) }
  errs = +""
  status, res = X.with_generic_error_func(->(m) { errs << m }) do
    X.format_number_conversion(d, format, number)
  end
  [status, res, errs]
end

def check(df, format, number, failures)
  exp = NativeNumbers.format_number(df, format, number)
  got = pure_format_number(df, format, number)
  return true if exp == got

  failures << [df, format, number, exp, got]
  false
end

failures = []
total = 0
if ARGV[0] == "fuzz"
  n = (ARGV[1] || 10_000).to_i
  rng = Random.new((ARGV[2] || 1).to_i)
  alphabet = ["0", "#", ".", ",", ";", "%", "‰", "'", "a", " ", "-", "٠", "x", "o", "|"]
  dfs = NumberCases::DECIMAL_FORMATS.values
  n.times do
    fmt = Array.new(rng.rand(0..12)) { alphabet.sample(random: rng) }.join
    num = case rng.rand(4)
    when 0 then rng.rand * 10**rng.rand(-5..20)
    when 1 then -rng.rand * 10**rng.rand(-5..20)
    when 2 then [rng.rand(2**64)].pack("Q").unpack1("D")
    else rng.rand(-100_000..100_000) / [1.0, 10.0, 100.0, 1000.0].sample(random: rng)
    end
    total += 1
    df = dfs.sample(random: rng)
    if rng.rand < 0.3 # scramble the decimal format symbols (incl. empty / multi-char ones)
      df = df.to_h { |k, v| [k, rng.rand < 0.5 ? v : Array.new(rng.rand(0..2)) { alphabet.sample(random: rng) }.join] }
    end
    check(df, fmt, num, failures)
  end
else
  NumberCases::DECIMAL_FORMATS.each_value do |df|
    NumberCases::PATTERNS.each do |pat|
      NumberCases::NUMBERS.each do |num|
        total += 1
        check(df, pat, num, failures)
      end
    end
  end
end

failures.first(30).each do |df, format, number, exp, got|
  puts "FAIL df=#{df.values_at(:zero_digit, :decimal_point, :grouping).inspect} fmt=#{format.inspect} n=#{number.inspect}"
  puts "  native: #{exp.inspect}"
  puts "  pure:   #{got.inspect}"
end
puts "#{total - failures.size}/#{total} passed"
exit(failures.empty? ? 0 : 1)
