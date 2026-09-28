# frozen_string_literal: true

# Calls the native gem's (nokogiri 1.19.4, libxslt 1.1.43 statically linked and exported)
# xsltFormatNumberConversion directly through Fiddle, capturing xsltGenericError output.
# Must run in a process that loaded the *native* gem (never with -I nokogiri-pure/lib).

gem "nokogiri", "1.19.4"
require "nokogiri"
require "fiddle"

module NativeNumbers
  SO = Dir[File.join(Gem.loaded_specs["nokogiri"].full_gem_path, "lib/nokogiri/#{RUBY_VERSION[/\A\d+\.\d+/]}/nokogiri.so")].first
  LIB = Fiddle.dlopen(SO)

  FORMAT_NUMBER_CONVERSION = Fiddle::Function.new(
    LIB["xsltFormatNumberConversion"],
    [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_VOIDP],
    Fiddle::TYPE_INT
  )
  SET_GENERIC_ERROR_FUNC = Fiddle::Function.new(
    LIB["xsltSetGenericErrorFunc"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID
  )

  @errors = +""
  class << self
    attr_reader :errors
  end

  # (void *ctx, const char *msg, ...): on x86-64 SysV the first variadic arguments arrive in
  # the same registers as fixed ones, so declaring them as pointers lets us read them.
  class Handler < Fiddle::Closure
    def call(_ctx, msg, a1, _a2)
      m = msg.to_s
      out = case m
      when "%s" then a1.to_s
      when "%s\n" then "#{a1}\n"
      else m
      end
      NativeNumbers.errors << out
      nil
    end
  end
  HANDLER = Handler.new(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP] * 4)
  SET_GENERIC_ERROR_FUNC.call(nil, HANDLER)

  FIELDS = %i[next name digit pattern_separator minus_sign infinity no_number decimal_point
              grouping percent permille zero_digit ns_uri].freeze

  def self.cstring(str)
    return Fiddle::Pointer.new(0) if str.nil?

    b = str.b
    ptr = Fiddle::Pointer.malloc(b.bytesize + 1, Fiddle::RUBY_FREE)
    ptr[0, b.bytesize] = b unless b.empty?
    ptr[b.bytesize] = 0
    ptr
  end

  # +df+: Hash of DecimalFormat field => String
  # returns [status, result String (UTF-8) or nil, error text]
  def self.format_number(df, format, number)
    keep = []
    struct = Fiddle::Pointer.malloc(FIELDS.length * Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
    FIELDS.each_with_index do |f, i|
      p = df.key?(f) ? cstring(df[f]) : Fiddle::Pointer.new(0)
      keep << p
      struct[i * Fiddle::SIZEOF_VOIDP, Fiddle::SIZEOF_VOIDP] = [p.to_i].pack("J")
    end
    fmt = cstring(format)
    out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
    out[0, Fiddle::SIZEOF_VOIDP] = [0].pack("J")
    @errors = +""
    status = FORMAT_NUMBER_CONVERSION.call(struct, fmt, number, out)
    rp = out[0, Fiddle::SIZEOF_VOIDP].unpack1("J")
    res = rp.zero? ? nil : Fiddle::Pointer.new(rp).to_s.force_encoding(Encoding::UTF_8)
    keep.clear
    [status, res, @errors.dup.force_encoding(Encoding::UTF_8)]
  end
end
