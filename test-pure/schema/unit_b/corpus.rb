# frozen_string_literal: true

# Parse-phase differential run of worker B's code over a corpus of schema documents
# (XSTS + libxml2 test/schemas + nokogiri test files).
#
#   ruby test-pure/schema/unit_b/corpus.rb native OUT.json      # with the native gem
#   ruby -Ilib test-pure/schema/unit_b/corpus.rb pure OUT.json [-v]
#
# For every schema: if the pure parse phase reported an error (ctxt.nberrors != 0),
# libxml2's xmlSchemaParse stops there, so the full native error list must be equal;
# otherwise the pure list (warnings only) must be a prefix of the native list.
require "json"

def corpus_files
  here = File.expand_path("..", __dir__)
  list = []
  cj = File.join(here, "xsts/cases.json")
  JSON.parse(File.read(cj)).each { |c| list << c["xsd"] if c["xsd"] } if File.exist?(cj)
  list.concat(Dir["/root/workspace/nokogiri-pure-ref/libxml2-2.13.9/test/schemas/*.xsd"].sort)
  list.concat(Dir["/root/workspace/nokogiri-upstream/test/files/**/*.xsd"].sort)
  list.uniq.select { |f| File.exist?(f) }
end

mode, out = ARGV
case mode
when "native"
  gem "nokogiri", "1.19.4"
  require "nokogiri"
  $captured = nil
  class << Nokogiri::XML::SyntaxError
    alias_method :__orig_aggregate, :aggregate
    def aggregate(errors)
      $captured = errors
      __orig_aggregate(errors)
    end
  end
  res = {}
  corpus_files.each do |f|
    $captured = nil
    doc = Nokogiri::XML(File.binread(f), f)
    begin
      errs = Nokogiri::XML::Schema.from_document(doc).errors
    rescue Nokogiri::XML::SyntaxError
      errs = $captured || []
    rescue StandardError => e
      res[f] = { "exception" => e.class.name }
      next
    end
    res[f] = { "errors" => errs.map { |e| [e.code, e.level, e.line, e.message.sub(/\A(\d+:\d+: )?(WARNING|ERROR|FATAL): /, "")] } }
  end
  File.write(out, JSON.generate(res))
  puts "#{res.size} schemas"
when "pure"
  $LOAD_PATH.unshift(File.expand_path("../../../lib", __dir__))
  require "nokogiri"
  tc = File.expand_path("../../../lib/nokogiri/pure/schemas/types_compare.rb", __dir__)
  $LOADED_FEATURES << tc unless File.exist?(tc)
  require "nokogiri/pure/schemas/types"
  require "nokogiri/pure/schemas/components"
  require "nokogiri/pure/schemas/errors"
  require "nokogiri/pure/schemas/parse_docs"
  require "nokogiri/pure/schemas/io"
  require_relative "../rexml2pure"
  S = Nokogiri::Pure::Schemas
  parse_xml = lambda do |src, url|
    if Nokogiri::Pure.const_defined?(:Parser) && Nokogiri::Pure::Parser.respond_to?(:read_memory)
      Nokogiri::Pure::Parser.read_memory(src, url, nil, S::PARSE_NOENT)
    else
      Rexml2Pure.parse(src, url)
    end
  end
  S.parse_memory_override = ->(content, url, _o) { parse_xml.(content, url) }
  native = JSON.parse(File.read(out))
  verbose = ARGV.include?("-v")
  stats = Hash.new(0)
  native.each do |f, n|
    next stats[:native_exception] += 1 if n["exception"]

    doc = begin
      parse_xml.(File.binread(f), f)
    rescue StandardError, REXML::ParseException
      nil
    end
    next stats[:unparsable] += 1 if doc.nil?

    errors = []
    begin
      ctxt = S.new_doc_parser_ctxt(doc)
      ctxt.serror = ->(e) { errors << e }
      main = S.new_schema(ctxt)
      ctxt.constructor = S.construction_ctxt_create(nil)
      ctxt.constructor.main_schema = main
      r, bucket = S.add_schema_doc(ctxt, S::XML_SCHEMA_SCHEMA_MAIN, nil, doc, nil, 0, nil, nil, nil)
      S.parse_new_doc_with_context(ctxt, main, bucket) if r == 0 && bucket
    rescue StandardError => e
      stats[:exception] += 1
      puts "EXC #{f}: #{e.class}: #{e.message}\n  #{e.backtrace.first(4).join("\n  ")}" if verbose
      next
    end
    got = errors.map { |e| [e.code, e.level, e.line, e.message.chomp] }
    want = n["errors"]
    ok = if ctxt.nberrors != 0
      got.map { |g| g[0, 2] + [g[3]] } == want.map { |w| w[0, 2] + [w[3]] }
    else
      got.map { |g| g[0, 2] + [g[3]] } == want.first(got.size).map { |w| w[0, 2] + [w[3]] }
    end
    lines_ok = ok && got.map { |g| g[2] } == want.first(got.size).map { |w| w[2] }
    stats[ctxt.nberrors != 0 ? :compared_full : :compared_prefix] += 1
    if ok
      stats[:pass] += 1
      unless lines_ok
        stats[:line_mismatch] += 1
        puts "LINES #{f}: want #{want.first(got.size).map { |w| w[2] }.inspect} got #{got.map { |g| g[2] }.inspect}" if verbose
      end
    else
      stats[:fail] += 1
      if verbose
        puts "FAIL #{f}"
        puts "  want: #{want.first([want.size, got.size + 2].max).map(&:inspect).join("\n        ")}"
        puts "  got:  #{got.map(&:inspect).join("\n        ")}"
      end
    end
  end
  p stats
end
