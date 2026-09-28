# frozen_string_literal: true

# Runs every reader case (Marshal file ARGV[0]) with whatever nokogiri is loaded and writes the
# traces to ARGV[1]. Loaded both by the native-gem process and by the pure process.
require "stringio"

module ReaderRun
  MAX_STEPS = 20_000

  class SmallIO
    def initialize(data, n)
      @data = data
      @pos = 0
      @n = n
    end

    def read(len)
      return nil if @pos >= @data.bytesize

      k = [len, @n].min
      s = @data.byteslice(@pos, k)
      @pos += k
      s
    end
  end

  class TooMuchIO
    def initialize(data)
      @data = data
      @pos = 0
    end

    def read(len)
      return nil if @pos >= @data.bytesize

      s = @data.byteslice(@pos, len * 2)
      @pos += len
      s
    end
  end

  class RaisingIO
    def initialize(data, after)
      @io = StringIO.new(data)
      @calls = 0
      @after = after
    end

    def read(len)
      @calls += 1
      raise IOError, "boom" if @calls > @after

      @io.read(len)
    end
  end

  class NonStringIO
    def read(_len)
      :invalid_object
    end
  end

  module_function

  def err(e)
    return [e.class.name, e.message] unless e.is_a?(Nokogiri::XML::SyntaxError)

    [e.class.name, e.message, e.line, e.column, e.level, e.code, e.domain, e.str1, e.str2, e.str3, e.int1, e.file]
  end

  # xmlValidateDocumentFinal reports unknown IDREFs in hash-scan order, which libxml2 randomises
  # per process: sort those (DTD_UNKNOWN_ID, code 536) among themselves.
  def errs(list)
    out = list.map { |x| err(x) }
    idx = out.each_index.select { |i| out[i][5] == 536 }
    sorted = idx.map { |i| out[i] }.sort_by(&:inspect)
    idx.each_with_index { |i, k| out[i] = sorted[k] }
    out
  end

  def safe
    yield
  rescue StandardError => e
    [:raise, e.class.name, e.message]
  end

  def make_reader(input, source, url, enc, opts)
    case source
    when :memory then Nokogiri::XML::Reader.from_memory(input, url, enc, opts)
    when :io then Nokogiri::XML::Reader.from_io(StringIO.new(input), url, enc, opts)
    when :io_toomuch then Nokogiri::XML::Reader.from_io(TooMuchIO.new(input), url, enc, opts)
    when :io_nonstring then Nokogiri::XML::Reader.from_io(NonStringIO.new, url, enc, opts)
    else
      case source[0]
      when :io_small then Nokogiri::XML::Reader.from_io(SmallIO.new(input, source[1]), url, enc, opts)
      when :io_raise then Nokogiri::XML::Reader.from_io(RaisingIO.new(input, source[1]), url, enc, opts)
      end
    end
  end

  def cheap(r)
    n = safe { r.attribute_count }
    [
      safe { r.name }, safe { r.local_name }, safe { r.prefix }, safe { r.namespace_uri }, safe { r.node_type },
      safe { r.depth }, safe { r.value }, safe { r.value? }, safe { r.attributes? }, n,
      safe { r.empty_element? }, safe { r.default? }, safe { r.base_uri }, safe { r.lang }, safe { r.xml_version },
      safe { r.encoding }, safe { r.state },
      safe { (0..(n.is_a?(Integer) ? n : 0)).map { |i| r.attribute_at(i) } },
      safe { [r.attribute("xmlns"), r.attribute("a"), r.attribute("b"), r.attribute("p:c"), r.attribute("xmlns:p"), r.attribute("id")] },
      safe { r.attribute_at(-1) },
    ]
  end

  def step(r, mode)
    case mode
    when :light then cheap(r)
    when :full
      cheap(r) + [safe { r.attribute_hash }, safe { r.namespaces }, safe { r.inner_xml }, safe { r.outer_xml },
        safe { r.attributes }, safe { r.node_type }, safe { r.depth }, safe { r.value }]
    when :outer then [safe { r.name }, safe { r.node_type }, safe { r.depth }, safe { r.outer_xml }, safe { r.inner_xml }]
    when :attrs then [safe { r.name }, safe { r.node_type }, safe { r.attribute_hash }, safe { r.namespaces }]
    when :next_only then [safe { r.name }, safe { r.node_type }]
    end
  end

  def run(c)
    _kind, input, source, url, enc, opts, mode = c
    input = input.dup
    r = begin
      make_reader(input, source, url, enc, opts)
    rescue StandardError => e
      return [:create_error, err(e)]
    end
    trace = [[:initial, safe { r.state }, safe { r.encoding }, safe { r.node_type }, safe { r.name }, safe { r.depth }]]
    steps = 0
    loop do
      steps += 1
      if steps > MAX_STEPS
        trace << :too_many_steps
        break
      end
      res = begin
        r.read
      rescue StandardError => e
        trace << [:read_error, err(e), errs(r.errors), safe { r.state }]
        # a second read after an error
        trace << [:read_again, safe { r.read.nil? }, r.errors.length]
        break
      end
      if res.nil?
        trace << [:eof, errs(r.errors), safe { r.state }, safe { r.node_type }, safe { r.name },
          safe { r.depth }, safe { r.encoding }]
        trace << [:read_again, safe { r.read.nil? }]
        break
      end
      trace << [step(r, mode), r.errors.length]
    end
    trace
  end
end

cases = Marshal.load(File.binread(ARGV[0]))
results = cases.map do |c|
  ReaderRun.run(c)
rescue Exception => e # rubocop:disable Lint/RescueException
  [:crash, e.class.name, e.message, e.backtrace.first(3)]
end
File.binwrite(ARGV[1], Marshal.dump(results))
