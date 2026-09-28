# frozen_string_literal: true

# Differential test of the xmlschemastypes.c port against the native nokogiri gem, going through
# real schema validation: lexical verdicts (element content), canonical values (xs:unique
# duplicate messages, enumeration sets) and facet verdicts. The xmlschemas.c logic around the
# Types calls (whitespace normalization, which value is needed) is emulated here.
#
# Native results are cached in fixtures/native.json.gz; pass --regen to recompute them.
#   ruby -Ilib test-pure/schema/types/native_diff.rb [--regen] [-v]
require "json"
require "zlib"
require "open3"
require_relative "c_requests"

module TypesNativeDiff
  module_function

  T = Nokogiri::Pure::Schemas::Types
  S = Nokogiri::Pure::Schemas
  XSD = "http://www.w3.org/2001/XMLSchema"
  FIXTURE = File.join(__dir__, "fixtures", "native.json.gz")

  LEX_SKIP = %w[anyType QName NOTATION ENTITY ENTITIES IDREFS NMTOKENS].freeze

  def xml_ok?(v)
    v.valid_encoding? && v.each_char.all? do |c|
      o = c.ord
      o == 9 || o == 10 || o == 13 || (o >= 0x20 && o <= 0xD7FF) || (o >= 0xE000 && o <= 0xFFFD) || o >= 0x10000
    end
  end

  def ty(name) = T.get_predefined_type(name, XSD)

  # ws of a built-in type (xmlSchemaGetWhiteSpaceFacetValue)
  def ws_of(t)
    case t
    when "string", "anySimpleType" then S::XML_SCHEMA_WHITESPACE_PRESERVE
    when "normalizedString" then S::XML_SCHEMA_WHITESPACE_REPLACE
    else S::XML_SCHEMA_WHITESPACE_COLLAPSE
    end
  end

  def normalize(t, v)
    case ws_of(t)
    when S::XML_SCHEMA_WHITESPACE_COLLAPSE then T.collapse_string(v) || v
    when S::XML_SCHEMA_WHITESPACE_REPLACE then T.white_space_replace(v) || v
    else v
    end
  end

  # xmlSchemaGetCanonValueWhtspExt_1 (for_hash = 0) of a single value
  def canon_ext(val, ws)
    case T.get_val_type(val)
    when S::XML_SCHEMAS_STRING, S::XML_SCHEMAS_NORMSTRING, S::XML_SCHEMAS_ANYSIMPLETYPE
      value = T.value_get_as_string(val)
      unless value.nil?
        v2 = if ws == S::XML_SCHEMA_WHITESPACE_COLLAPSE
          T.collapse_string(value)
        elsif ws == S::XML_SCHEMA_WHITESPACE_REPLACE
          T.white_space_replace(value)
        end
        value = v2 unless v2.nil?
      end
      value || ""
    else
      r, c = T.get_canon_value(val)
      r == -1 ? :error : c
    end
  end

  def primitive_stringish?(t)
    tt = ty(t)
    tt = tt.base_type while tt.base_type && !tt.base_type.equal?(tt) &&
      (tt.flags & S::XML_SCHEMAS_TYPE_BUILTIN_PRIMITIVE) == 0 && tt.built_in_type != S::XML_SCHEMAS_ANYSIMPLETYPE
    [S::XML_SCHEMAS_STRING, S::XML_SCHEMAS_ANYSIMPLETYPE].include?(tt.built_in_type)
  end

  def jobs
    out = []
    TypesCorpus::ALL_TYPES.each do |t|
      next if LEX_SKIP.include?(t)

      vals = TypesCorpus.parse_values(t).select { |v| xml_ok?(v) }
      out << { "kind" => "lex", "type" => t, "values" => vals }
      valid = vals.select { |v| T.val_predef_type_node_no_norm(ty(t), normalize(t, v), false, nil)[0] == 0 }
      out << { "kind" => "uniq", "type" => t, "values" => valid } unless %w[anySimpleType].include?(t)
    end
    # facets (one facet per schema)
    TypesCorpus.facet_cases.group_by { |f, _fvt, fv, b, _v, _a| [f, fv, b] }.each do |(f, fv, b), cases|
      next if %w[whiteSpace pattern enumeration].include?(f) || !xml_ok?(fv)
      next if b == "QName" || b == "NOTATION"

      vals = cases.map { |c| c[4] }.select { |v| xml_ok?(v) && v == v.strip }.uniq
      out << { "kind" => "facet", "base" => b, "facets" => [[f, fv]], "values" => vals }
    end
    # enumeration sets (canonical values in the error message)
    TypesCorpus.facet_cases.select { |c| c[0] == "enumeration" }.group_by { |c| c[3] }.each do |b, cases|
      next if %w[QName NOTATION anySimpleType].include?(b)

      fvs = cases.map { |c| c[2] }.uniq.select { |v| xml_ok?(v) }
      fvs = fvs.select { |fv| T.val_predef_type_node_no_norm(ty(b), normalize(b, fv), false, nil)[0] == 0 }
      next if fvs.empty?

      out << { "kind" => "facet", "base" => b, "facets" => fvs.map { |fv| ["enumeration", fv] },
               "values" => TypesCorpus.parse_values(b).select { |v| xml_ok?(v) }.first(40) }
    end
    # every valid date/duration/float value as a single enumeration (canonical forms)
    %w[dateTime date time gYear gYearMonth gMonth gMonthDay gDay duration float double decimal
       integer hexBinary base64Binary boolean anyURI].each do |b|
      valid = TypesCorpus.parse_values(b).select { |v| xml_ok?(v) && v != "" && T.val_predef_type_node_no_norm(ty(b), normalize(b, v), false, nil)[0] == 0 }
      valid.each_slice(25) do |slice|
        others = (valid - slice).first(3)
        out << { "kind" => "facet", "base" => b, "facets" => slice.map { |fv| ["enumeration", fv] }, "values" => others }
      end
    end
    out
  end

  def native_results(jobs, regen)
    if !regen && File.exist?(FIXTURE)
      data = JSON.parse(Zlib::GzipReader.open(FIXTURE, &:read))
      return data["results"] if data["jobs"] == jobs

      warn "native fixture is stale; regenerating"
    end
    env = ENV.to_h.reject { |k, _| k.start_with?("RUBY") || k == "BUNDLE_GEMFILE" }
    out, err, st = Open3.capture3(env, "ruby", File.join(__dir__, "native_oracle.rb"), stdin_data: JSON.generate(jobs),
      unsetenv_others: false)
    abort("native oracle failed: #{err}") unless st.success?
    results = JSON.parse(out)
    Zlib::GzipWriter.open(FIXTURE) { |gz| gz.write(JSON.generate({ "jobs" => jobs, "results" => results })) }
    results
  end

  # pure expectations -------------------------------------------------------------------------

  def expect_lex(t, v)
    T.val_predef_type_node_no_norm(ty(t), v, false, nil)[0] == 0
  end

  def expect_uniq(t, v)
    r, val = T.val_predef_type_node_no_norm(ty(t), normalize(t, v), true, nil)
    return :invalid if r != 0
    return :noval if val.nil?
    # the duplicate is only detected if the value equals itself (xmlSchemaAreValuesEqual)
    return nil if T.compare_values(val, T.copy_value(val) || val) != 0

    canon_ext(val, ws_of(t))
  end

  def facet_value_type(f, b) = TypesCorpus.facet_value_type(f, b)

  def build_facet(f, fv, b)
    facet = S::SchemaFacet.new(type: TypesCorpus::FACET[f], value: fv)
    r, facet.val = if %w[minInclusive minExclusive maxInclusive maxExclusive enumeration].include?(f)
      T.val_predef_type_node_no_norm(ty(b), normalize(b, fv), true, nil)
    else
      T.val_predef_type_node(ty(facet_value_type(f, b)), fv, true, nil)
    end
    [r, facet]
  end

  def expect_facet(b, facets, v)
    stringish = primitive_stringish?(b)
    need_val = !stringish || facets.any? { |f, _| f == "enumeration" }
    v = normalize(b, v) if facets.any? { |f, _| f == "enumeration" }
    r, val = T.val_predef_type_node_no_norm(ty(b), v, need_val, nil)
    return false if r != 0

    ws = stringish ? ws_of(b) : S::XML_SCHEMA_WHITESPACE_COLLAPSE
    vt = val ? T.get_val_type(val) : ty(b).built_in_type
    facets.each do |f, fv|
      next if f == "enumeration"

      _, facet = build_facet(f, fv, b)
      ret = if %w[length minLength maxLength].include?(f)
        T.validate_length_facet_whtsp(facet, vt, v, val, ws)[0]
      else
        T.validate_facet_whtsp(facet, ws, vt, v, val, ws)
      end
      return false if ret != 0
    end
    true
  end

  def run(regen: false, verbose: false)
    js = jobs
    results = native_results(js, regen)
    stats = Hash.new { |h, k| h[k] = [0, 0] }
    fails = []
    js.zip(results).each do |job, res|
      kind = job["kind"]
      if res["schema_error"]
        # a facet value the schema parser rejects
        errs = job["facets"].map { |f, fv| build_facet(f, fv, job["base"])[0] }
        prim = ty(job["base"])
        prim = prim.base_type while (prim.flags & S::XML_SCHEMAS_TYPE_BUILTIN_PRIMITIVE) == 0 && prim.base_type
        allowed = job["facets"].map { |f, _| T.is_built_in_type_facet(prim, TypesCorpus::FACET[f]) }
        stats["facet-schema"][0] += 1
        if errs.any? { |e| e != 0 } || allowed.any? { |a| a == 0 }
          stats["facet-schema"][1] += 1
        else
          fails << [job.merge("values" => nil), "schema error", res["schema_error"], errs]
        end
        next
      end
      job["values"].zip(res["results"]).each do |v, msgs|
        case kind
        when "lex"
          want = msgs.empty?
          got = expect_lex(job["type"], v)
          stats["lex"][0] += 1
          want == got ? stats["lex"][1] += 1 : fails << [job["type"], v, [want, msgs, got]]
        when "uniq"
          m = msgs.map { |x| x[/Duplicate key-sequence \['(.*)'\] in unique/m, 1] }.compact.first
          got = expect_uniq(job["type"], v)
          next if got == :noval && m.nil?

          stats["uniq"][0] += 1
          m == got ? stats["uniq"][1] += 1 : fails << [job["type"], v, [m, msgs, got]]
        when "facet"
          if job["facets"].all? { |f, _| f == "enumeration" }
            set = msgs.map { |x| x[/is not an element of the set \{(.*)\}\.\s*\z/m, 1] }.compact.first
            next if set.nil?

            want_set = job["facets"].map do |_, fv|
              _, facet = build_facet("enumeration", fv, job["base"])
              "'#{canon_ext(facet.val, ws_of(job["base"]))}'"
            end.join(", ")
            stats["enum-canon"][0] += 1
            set == want_set ? stats["enum-canon"][1] += 1 : fails << [job["base"], job["facets"], [set, want_set]]
          else
            want = msgs.empty?
            got = expect_facet(job["base"], job["facets"], v)
            stats["facet"][0] += 1
            want == got ? stats["facet"][1] += 1 : fails << [[job["base"], job["facets"]], v, [want, msgs, got]]
          end
        end
      end
    end
    stats.each { |k, (n, ok)| puts format("%-13s %d/%d", k, ok, n) }
    fails.first(verbose ? 300 : 30).each { |f| p f }
    fails.empty?
  end
end

if $PROGRAM_NAME == __FILE__
  ok = TypesNativeDiff.run(regen: ARGV.include?("--regen"), verbose: ARGV.include?("-v"))
  exit(ok ? 0 : 1)
end
