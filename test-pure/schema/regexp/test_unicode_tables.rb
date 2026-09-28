# frozen_string_literal: true

# Compares the generated Unicode tables (lib/nokogiri/pure/xmlregexp/unicode.rb) and the
# membership helpers of XmlRegexp against the native libxml2 dump in fixtures/unicode_native.txt
# (regenerate with oracle_unicode.rb, which scans every codepoint with the native functions).
# Tables are compared range by range; the lookup helpers are checked on every range boundary
# (+-1) and on a random sample of codepoints.
require "minitest/autorun"
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "nokogiri/pure/xmlregexp"

class TestXmlRegexpUnicodeTables < Minitest::Test
  X = Nokogiri::Pure::XmlRegexp
  NATIVE = File.readlines(File.join(__dir__, "fixtures", "unicode_native.txt"), chomp: true).to_h do |l|
    kind, name, *ranges = l.split(" ")
    [[kind, name], ranges]
  end

  def fmt(flat) = flat.each_slice(2).map { |a, b| format("%x-%x", a, b) }

  def parse(ranges) = ranges.flat_map { |r| r.split("-").map(&:hex) }

  def member?(flat, c) = flat.each_slice(2).any? { |a, b| c >= a && c <= b }

  def probes(flat)
    rng = Random.new(42)
    pts = flat.flat_map { |v| [v - 1, v, v + 1] } + Array.new(300) { rng.rand(0x110000) } + [0, 0x10ffff]
    pts.select { |c| c >= 0 && c <= 0x10ffff }.uniq
  end

  def check_fn(native_flat, &blk)
    probes(native_flat).each do |c|
      assert_equal member?(native_flat, c), blk.call(c), format("U+%04X", c)
    end
  end

  %w[C Cc Cf Co Cs L Ll Lm Lo Lt Lu M Mc Me Mn N Nd Nl No P Pc Pd Pe Pf Pi Po Ps S Sc Sk Sm So Z Zl Zp Zs].each do |cat|
    define_method("test_cat_#{cat}") do
      tbl = X::Unicode.const_get("CAT_#{cat.upcase}")
      assert_equal NATIVE.fetch(["cat", cat]), fmt(tbl)
      check_fn(parse(NATIVE.fetch(["cat", cat]))) { |c| X.in_table(tbl, c) == 1 }
    end
  end

  def test_blocks
    X::Unicode::BLOCKS.each do |name, _|
      assert_equal NATIVE.fetch(["block", name]), fmt(X::BLOCK_TABLE[name]), name
      check_fn(parse(NATIVE.fetch(["block", name]))) { |c| X.ucs_is_block(c, name) == 1 }
    end
    assert_equal(-1, X.ucs_is_block(0x41, "NoSuchBlock"))
    assert_equal(-1, X.ucs_is_block(0x41, "basiclatin"))
    assert_equal ["ERR"], NATIVE.fetch(%w[block NoSuchBlock])
    assert_equal ["ERR"], NATIVE.fetch(%w[block basiclatin])
  end

  def test_chvalid
    check_fn(parse(NATIVE.fetch(%w[ch xmlIsChar]))) { |c| X.is_char(c) }
    check_fn(parse(NATIVE.fetch(%w[ch xmlIsDigit]))) { |c| X.is_digit(c) }
    check_fn(parse(NATIVE.fetch(%w[ch xmlIsCombining]))) { |c| X.is_combining(c) }
    check_fn(parse(NATIVE.fetch(%w[ch xmlIsExtender]))) { |c| X.is_extender(c) }
    base = parse(NATIVE.fetch(%w[ch xmlIsBaseChar]))
    ideo = parse(NATIVE.fetch(%w[ch xmlIsIdeographic]))
    (probes(base) + probes(ideo)).each do |c|
      assert_equal member?(base, c) || member?(ideo, c), X.is_letter(c), format("U+%04X", c)
    end
  end
end
