# frozen_string_literal: true
# Nokogiri-level HTML4 SAX event dump (runs under either nokogiri). usage: ruby sax_dump.rb in.marshal out.marshal
require "nokogiri"
require "stringio"

class EvDoc < Nokogiri::XML::SAX::Document
  attr_reader :ev

  def initialize
    super
    @ev = []
  end

  %w[start_document end_document start_element end_element characters comment warning error cdata_block
     processing_instruction xmldecl reference start_element_namespace end_element_namespace].each do |m|
    define_method(m) { |*a| @ev << [m.to_sym, *a.map { |x| x.is_a?(String) ? x.b : x }] }
  end
end

def run(kind, input, enc, chunk)
  d = EvDoc.new
  case kind
  when :mem
    Nokogiri::HTML4::SAX::Parser.new(d).parse_memory(input, enc)
  when :memrec
    Nokogiri::HTML4::SAX::Parser.new(d).parse_memory(input, enc) { |c| c.recovery = true; d.ev << [:ctx, c.line, c.column] }
  when :io
    Nokogiri::HTML4::SAX::Parser.new(d).parse_io(StringIO.new(input), enc)
  when :push
    pp = Nokogiri::HTML4::SAX::PushParser.new(d, nil, enc)
    pos = 0
    while pos < input.bytesize
      begin
        pp << input.byteslice(pos, chunk)
      rescue => e
        d.ev << [:raise, e.class.name, e.message.b]
      end
      pos += chunk
    end
    begin
      pp.finish
    rescue => e
      d.ev << [:raise, e.class.name, e.message.b]
    end
  when :pushrec
    pp = Nokogiri::HTML4::SAX::PushParser.new(d, nil, enc)
    pp.options |= 1
    pos = 0
    while pos < input.bytesize
      pp << input.byteslice(pos, chunk)
      pos += chunk
    end
    pp.finish
  end
  d.ev
rescue Exception => e
  d.ev + [[:exception, e.class.name, e.message.b]]
end

cases = Marshal.load(File.binread(ARGV[0]))
File.binwrite(ARGV[1], Marshal.dump(cases.map { |c| run(*c) }))
