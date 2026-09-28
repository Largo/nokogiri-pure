# frozen_string_literal: true
# Ruby twin of htmlsax.c: same output format, driven by Nokogiri::Pure::HTMLParser.
# usage: ruby saxdump.rb MODE CHUNK OPTIONS ENCODING FILE
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "nokogiri/pure/util"
require "nokogiri/pure/tree"
require "nokogiri/pure/errors"
require "nokogiri/pure/encoding"
require "nokogiri/pure/html_parser"

module SaxDump
  P = Nokogiri::Pure
  H = P::HTMLParser

  def self.pstr(s)
    return "nil" if s.nil?

    out = +"\""
    s.b.each_byte do |c|
      if c == 0x22 || c == 0x5C
        out << "\\" << c.chr
      elsif c < 0x20 || c >= 0x7F
        out << format("\\x%02X", c)
      else
        out << c.chr
      end
    end
    out << "\""
  end

  class Logger
    attr_accessor :ctxt

    def loc
      c = @ctxt
      c && c.has_input ? " @#{c.line}:#{c.col}" : ""
    end

    def start_document(_) = puts("startDocument#{loc}")
    def end_document(_) = puts("endDocument#{loc}")

    def start_element(_, n, a)
      s = +"startElement #{SaxDump.pstr(n)}"
      if a
        a.each_slice(2) { |k, v| s << " #{SaxDump.pstr(k)}=#{SaxDump.pstr(v)}" }
      end
      puts "#{s}#{loc}"
    end

    def end_element(_, n) = puts("endElement #{SaxDump.pstr(n)}#{loc}")
    def characters(_, s) = puts("characters #{SaxDump.pstr(s)}#{loc}")
    def cdata_block(_, s) = puts("cdata #{SaxDump.pstr(s)}#{loc}")
    def ignorable_whitespace(_, s) = puts("ignorable #{SaxDump.pstr(s)}#{loc}")
    def comment(_, s) = puts("comment #{SaxDump.pstr(s)}#{loc}")
    def processing_instruction(_, t, d) = puts("pi #{SaxDump.pstr(t)} #{SaxDump.pstr(d)}#{loc}")
    def internal_subset(_, n, e, s) = puts("internalSubset #{SaxDump.pstr(n)} #{SaxDump.pstr(e)} #{SaxDump.pstr(s)}#{loc}")
  end

  def self.serr(e)
    puts "error d=#{e.domain} c=#{e.code} l=#{e.level} #{e.line}:#{e.int2} #{pstr(e.message)} s1=#{pstr(e.str1)} s2=#{pstr(e.str2)} i1=#{e.int1}"
  end

  def self.dump(n, depth)
    while n
      s = +"#{"  " * depth}#{n.type} #{pstr(n.name)}#{n.type == P::DTD_NODE ? "" : " L#{n.line}"}"
      if [P::TEXT_NODE, P::CDATA_SECTION_NODE, P::COMMENT_NODE, P::PI_NODE].include?(n.type)
        s << " #{pstr(n.content)}"
      end
      s << " #{pstr(n.external_id)} #{pstr(n.system_id)}" if n.type == P::DTD_NODE
      if n.type == P::ELEMENT_NODE
        a = n.properties
        while a
          s << " @#{pstr(a.name)}=#{a.children ? pstr(a.children.content) : "nil"}"
          a = a.next
        end
      end
      puts s
      dump(n.children, depth + 1) if n.type != P::DTD_NODE
      n = n.next
    end
  end

  def self.run(mode, chunk, opts, enc, file)
    $stdout.sync = false
    data = File.binread(file)
    dom = mode.include?("dom")
    logger = dom ? nil : Logger.new
    P::Errors.with_handler(->(e) { serr(e) }) do
      if mode.start_with?("push")
        e = enc ? H.parse_char_encoding(enc) : :none
        ctxt = H.create_push_parser_ctxt(logger, nil, nil, nil, e)
        logger&.ctxt = ctxt
        ctxt.use_options(opts)
        chunk = 1 << 24 if chunk <= 0
        pos = 0
        while pos < data.bytesize
          piece = data.byteslice(pos, chunk)
          r = ctxt.parse_chunk(piece, false)
          puts "chunk #{piece.bytesize} r=#{r}"
          pos += piece.bytesize
        end
        r = ctxt.parse_chunk(nil, true)
        puts "final r=#{r} wf=#{ctxt.well_formed}"
        if dom && ctxt.my_doc
          puts "encoding #{pstr(ctxt.my_doc.encoding)}"
          dump(ctxt.my_doc.children, 0)
        end
      else
        ctxt = H::Context.new(logger)
        logger&.ctxt = ctxt
        ctxt.use_options(opts)
        ctxt.push_memory_input(data, nil, enc)
        doc = H.ctxt_parse_document(ctxt)
        if dom && doc
          puts "encoding #{pstr(doc.encoding)}"
          dump(doc.children, 0)
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  SaxDump.run(ARGV[0], ARGV[1].to_i, ARGV[2].to_i, ARGV[3] == "-" ? nil : ARGV[3], ARGV[4])
end
