# frozen_string_literal: true

# ruby run_cases.rb oracle|pure CASES_JSON OUT_JSON [FILTER]
# Parses each schema with Nokogiri::XML::RelaxNG and validates its instances, recording every
# error with all its fields. Run once with the native gem ("oracle") and once with lib/ ("pure").
mode, cases_file, out_file, filter = ARGV
here = File.expand_path(__dir__)
if mode == "oracle"
  gem "nokogiri", "1.19.4"
else
  $LOAD_PATH.unshift(File.expand_path("../../lib", here))
end
require "nokogiri"
require "json"
require "timeout"
require "tmpdir"

cases = JSON.parse(File.read(cases_file))
cases.select! { |c| c["id"].include?(filter) } if filter

# keep the individual errors of aggregated parse failures
module AggregateSpy
  def aggregate(errors)
    $last_aggregate = errors.dup
    super
  end
end
Nokogiri::XML::SyntaxError.singleton_class.prepend(AggregateSpy)

def js(v)
  return v unless v.is_a?(String)

  v.dup.force_encoding(Encoding::UTF_8).valid_encoding? ? v : "BIN:#{v.b.unpack1("H*")}"
end

def ser(e)
  return { "string" => js(e) } if e.is_a?(String)

  { "message" => js(e.message), "domain" => e.domain, "code" => e.code, "level" => e.level, "line" => e.line,
    "file" => js(e.file), "str1" => js(e.str1), "str2" => js(e.str2), "str3" => js(e.str3), "int1" => e.int1,
    "column" => e.column, "path" => js(e.path), }
end

Dir.chdir(here)
results = {}
saved_stderr = STDERR.dup
err_file = File.join(Dir.tmpdir, "rng-stderr-#{mode}-#{Process.pid}.txt")
def run_case(c, r)
  $last_aggregate = nil
  schema = begin
    File.open(c["schema"]) { |f| Nokogiri::XML::RelaxNG(f) }
  rescue Nokogiri::XML::SyntaxError => e
    r["parse"] = { "ok" => false, "class" => e.class.name, "message" => js(e.message),
                   "errors" => ($last_aggregate || [e]).map { |x| ser(x) } }
    nil
  rescue => e
    r["parse"] = { "ok" => false, "class" => e.class.name, "message" => e.message }
    nil
  end
  return unless schema

  r["parse"] = { "ok" => true, "errors" => schema.errors.map { |x| ser(x) } }
  r["instances"] = c["instances"].map do |inst|
    doc = File.open(inst) { |f| Nokogiri::XML(f) }
    errs = schema.validate(doc)
    { "file" => inst, "errors" => errs.map { |x| ser(x) } }
  rescue => e
    { "file" => inst, "exception" => "#{e.class}: #{e.message}", "bt" => e.backtrace&.first(8) }
  end
end

# each case runs in a forked child with a wall-clock limit (libxml2 itself can take
# exponential time on some schema / instance pairs, and Timeout cannot interrupt C code)
LIMIT = (ENV["CASE_TIMEOUT"] || 30).to_i
cases.each do |c|
  r = results[c["id"]] = {}
  STDERR.reopen(err_file, "w")
  STDERR.sync = true
  rd, wr = IO.pipe
  pid = fork do
    rd.close
    res = {}
    begin
      run_case(c, res)
    rescue Exception => e # rubocop:disable Lint/RescueException
      res["crash"] = "#{e.class}: #{e.message}"
      res["bt"] = e.backtrace&.first(12)
    end
    STDERR.flush
    wr.write(JSON.generate(res))
    wr.close
    exit!(0)
  end
  wr.close
  data = +""
  reader = Thread.new { data << rd.read }
  if reader.join(LIMIT)
    Process.wait(pid)
    r.merge!(JSON.parse(data)) unless data.empty?
  else
    Process.kill(:KILL, pid)
    Process.wait(pid)
    reader.kill
    r["timeout"] = true
  end
  rd.close
  STDERR.flush
  err = File.binread(err_file)
  r["stderr"] = js(err) unless err.empty?
end
STDERR.reopen(saved_stderr)
File.delete(err_file) if File.exist?(err_file)
File.write(out_file, JSON.pretty_generate(results))
