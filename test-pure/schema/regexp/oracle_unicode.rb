# frozen_string_literal: true

# Dumps the native libxml2 (nokogiri 1.19.4 gem) Unicode tables into fixtures/unicode_native.txt.
#   ruby test-pure/schema/regexp/oracle_unicode.rb     (needs gcc)
gem "nokogiri", "1.19.4"
require "nokogiri"
require "fiddle"
require "tmpdir"

dir = __dir__
so = $LOADED_FEATURES.grep(%r{nokogiri/[\d.]+/nokogiri\.so\z}).first || $LOADED_FEATURES.grep(/nokogiri\.so\z/).first
Dir.mktmpdir do |tmp|
  lib = File.join(tmp, "unicode_dump.so")
  system("gcc", "-O2", "-shared", "-fPIC", "-o", lib, File.join(dir, "unicode_dump.c"), "-ldl", exception: true)
  blocks = File.join(tmp, "blocks.txt")
  src = File.read("/root/workspace/nokogiri-pure-ref/libxml2-2.13.9/xmlunicode.c")
  names = src[/xmlUnicodeBlocks\[\] = \{(.*?)\};/m, 1].scan(/\{"([^"]+)"/).flatten
  File.write(blocks, (names + ["NoSuchBlock", "basiclatin", ""]).join("\n") + "\n")
  h = Fiddle::Handle.new(lib)
  f = Fiddle::Function.new(h["unicode_dump"], [Fiddle::TYPE_VOIDP] * 3, Fiddle::TYPE_INT)
  rc = f.call(so, blocks, File.join(dir, "fixtures", "unicode_native.txt"))
  raise "dump failed" unless rc == 0
end
puts "ok"
