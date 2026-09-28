# frozen_string_literal: true

# Shared dumper for the differential harness: loaded by both the native oracle process and the
# pure process. Produces plain data (Marshal-able) describing parse results.

module ParserDump
  module_function

  def plain(x)
    case x
    when Array then x.map { |y| plain(y) }
    when Struct then plain(x.to_a)
    when String, Integer, Symbol, nil, true, false then x
    else x.inspect
    end
  end

  def err(e)
    [e.message, e.line, e.column, e.level, e.code, e.domain, e.str1, e.str2, e.str3, e.int1, e.file]
  end

  def node(n, depth = 0)
    return [:deep] if depth > 60

    case n
    when Nokogiri::XML::Document
      [:doc, n.encoding, n.version, n.children.map { |c| node(c, depth + 1) }]
    when Nokogiri::XML::DTD
      [:dtd, n.name, n.external_id, n.system_id, n.children.map { |c| node(c, depth + 1) }]
    when Nokogiri::XML::Element
      [:el, n.name, n.namespace&.prefix, n.namespace&.href, n.line,
        n.namespace_definitions.map { |ns| [ns.prefix, ns.href] },
        n.attribute_nodes.map { |a| [a.name, a.namespace&.prefix, a.namespace&.href, a.value, a.children.map { |c| node(c, depth + 1) }] },
        n.children.map { |c| node(c, depth + 1) }]
    when Nokogiri::XML::CDATA
      [:cdata, n.content]
    when Nokogiri::XML::Text
      [:text, n.content, n.line]
    when Nokogiri::XML::Comment
      [:comment, n.content]
    when Nokogiri::XML::ProcessingInstruction
      [:pi, n.name, n.content]
    when Nokogiri::XML::EntityReference
      [:eref, n.name]
    when Nokogiri::XML::EntityDecl
      [:entdecl, n.name, n.entity_type, n.external_id, n.system_id, n.content]
    when Nokogiri::XML::ElementDecl
      [:eldecl, n.name, n.element_type, n.prefix]
    when Nokogiri::XML::AttributeDecl
      [:attrdecl, n.name, n.attribute_type, n.default, n.enumeration]
    else
      [n.class.name, n.name]
    end
  rescue => e
    [:dump_error, e.class.name, e.message]
  end

  class Recorder < Nokogiri::XML::SAX::Document
    attr_reader :log

    def initialize
      super
      @log = []
    end

    %i[xmldecl start_document end_document start_element end_element start_element_namespace
      end_element_namespace characters comment warning error cdata_block processing_instruction reference].each do |m|
      define_method(m) do |*args|
        @log << [m, *ParserDump.plain(args)]
      end
    end
  end

  def run_sax(input, opts, encoding)
    rec = Recorder.new
    parser = Nokogiri::XML::SAX::Parser.new(rec, encoding)
    res = {}
    begin
      parser.parse(input) do |ctx|
        ctx.recovery = true if opts & 1 != 0
        ctx.replace_entities = true if opts & 2 != 0
        res[:ctx] = ctx
      end
      res[:pos] = [res[:ctx].line, res[:ctx].column]
    rescue => e
      res[:exception] = e.class.name
      res[:message] = e.message
    end
    res.delete(:ctx)
    res[:log] = rec.log
    res
  end

  def run_push(input, opts, chunk, encoding = nil)
    rec = Recorder.new
    parser = Nokogiri::XML::SAX::PushParser.new(rec, nil, encoding || "UTF-8")
    parser.options = opts
    res = { raised: [] }
    input.b.bytes.each_slice(chunk).with_index do |sl, i|
      parser.write(sl.pack("C*"), false)
    rescue => e
      res[:raised] << [i, e.class.name, e.message]
    end
    begin
      parser.finish
    rescue => e
      res[:raised] << [:finish, e.class.name, e.message]
    end
    res[:log] = rec.log
    res
  end

  def run_fragment(input, opts, context)
    doc = Nokogiri::XML(context)
    ctx = doc.at("//*[@ctx]") || doc.root || doc
    set = ctx.parse(input, opts)
    { nodes: set.map { |n| node(n) }, errors: doc.errors.map { |e| err(e) }, doc: doc.to_xml }
  rescue => e
    { exception: e.class.name, message: e.message }
  end

  def run_validate(input, opts)
    d = Nokogiri::XML::Document.read_memory(input, nil, nil, opts)
    errs = d.validate
    { verrors: errs&.map { |e| err(e) }&.sort, errors: d.errors.map { |e| err(e) }, ids: (d.xpath("//*[@id]").map { |n| n["id"] } rescue nil) }
  rescue => e
    { exception: e.class.name, message: e.message }
  end

  def run_io(input, opts, encoding)
    d = Nokogiri::XML::Document.read_io(StringIO.new(input), nil, encoding, opts)
    { xml: d.to_xml.gsub(/(?:^<!NOTATION .*? >\n)+/m) { |m| m.scan(/<!NOTATION .*? >\n/m).sort.join }, tree: node(d), errors: d.errors.map { |e| err(e) } }
  rescue => e
    { exception: e.class.name, message: e.message }
  end

  def dispatch(input, opts, encoding, url, mode)
    case mode
    when nil, :doc then run(input, opts, encoding, url)
    when :sax then run_sax(input, opts, encoding)
    when :sax_io then run_sax(StringIO.new(input), opts, encoding)
    when :io then run_io(input, opts, encoding)
    when :validate then run_validate(input, opts)
    when Array
      case mode[0]
      when :push then run_push(input, opts, mode[1], encoding)
      when :fragment then run_fragment(input, opts, mode[1])
      end
    end
  end

  def run(input, opts, encoding = nil, url = nil)
    d = Nokogiri::XML::Document.read_memory(input, url, encoding, opts)
    xml = begin
      # notation tables are hash-ordered (randomized) in libxml2
      d.to_xml.gsub(/(?:^<!NOTATION .*? >\n)+/m) { |m| m.scan(/<!NOTATION .*? >\n/m).sort.join }
    rescue => e
      "to_xml raised #{e.class}"
    end
    { xml: xml, tree: node(d), errors: d.errors.map { |e| err(e) }, url: d.url }
  rescue Nokogiri::XML::SyntaxError => e
    { exception: e.class.name, message: e.message, errors: (e.respond_to?(:errors) ? e.errors.map { |x| err(x) } : [err(e)]) }
  rescue => e
    { exception: e.class.name, message: e.message }
  end
end
