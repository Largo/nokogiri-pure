# frozen_string_literal: true

require_relative "corpus"
require "nokogiri"
require "nokogiri/pure/schemas/types"

# Requests for the direct C oracle (types_oracle.c) and the pure-Ruby responder that must
# produce byte-identical answers.
module TypesCRequests
  module_function

  def hx(s)
    return "-" if s.nil?
    return "=" if s.empty?

    s.b.unpack1("H*")
  end

  def unhx(s)
    return nil if s == "-"
    return +"" if s == "="

    [s].pack("H*").force_encoding(Encoding::UTF_8)
  end

  # Array of request lines (without newline)
  def all
    reqs = []
    TypesCorpus::ALL_TYPES.each do |t|
      TypesCorpus.parse_values(t).each do |v|
        next if v.include?("\0")

        reqs << ["P", t, "N", hx(v)].join("\t")
        reqs << ["P", t, "R", hx(v)].join("\t")
      end
    end
    TypesCorpus.compare_groups.each do |t1, v1, t2, v2|
      reqs << ["C", t1, "R", hx(v1), t2, "R", hx(v2)].join("\t")
      reqs << ["C", t1, "N", hx(v1), t2, "N", hx(v2)].join("\t") if v1.match?(/\s/) || v2.match?(/\s/)
    end
    TypesCorpus.facet_cases.each do |f, fvt, fv, b, v, actual|
      reqs << ["F", TypesCorpus::FACET[f].to_s, fvt, hx(fv), b, b, "R", hx(v), actual.to_s].join("\t")
    end
    names = (TypesCorpus::NAMES + TypesCorpus::GENERIC + TypesCorpus::LANGS).uniq
    names += TypesCorpus.random_values("Name", 400, 99)
    names.uniq.each { |v| reqs << ["N", hx(v)].join("\t") }
    TypesCorpus.node_docs.each do |xml, attr, pairs|
      reqs << (["D", hx(xml), hx(attr)] + pairs.flat_map { |t, v| [t, hx(v)] }).join("\t")
    end
    reqs.uniq
  end
end

# Computes the oracle's answer with the pure-Ruby port.
class TypesPureResponder
  T = Nokogiri::Pure::Schemas::Types
  S = Nokogiri::Pure::Schemas
  XSD = "http://www.w3.org/2001/XMLSchema"

  def hx(s) = TypesCRequests.hx(s)

  def ty(name) = T.get_predefined_type(name, XSD)

  def parse(t, mode, v, want, node = nil)
    if mode == "N"
      T.val_predef_type_node(t, v, want, node)
    else
      T.val_predef_type_node_no_norm(t, v, want, node)
    end
  end

  def respond(line)
    f = line.split("\t", -1)
    case f[0]
    when "P" then resp_p(f)
    when "C" then resp_c(f)
    when "F" then resp_f(f)
    when "N" then resp_n(f)
    when "D" then resp_d(f)
    end
  end

  def unhx(s) = TypesCRequests.unhx(s)

  def canon(val)
    out = +""
    r, c = T.get_canon_value(val)
    out << "\t#{r}\t#{hx(c)}"
    (0..3).each do |ws|
      r, c = T.get_canon_value_whtsp(val, ws)
      out << "\t#{r}\t#{hx(c)}"
    end
    out
  end

  def resp_p(f)
    t = ty(f[1])
    v = unhx(f[3])
    r0, = parse(t, f[2], v, false)
    r1, val = parse(t, f[2], v, true)
    out = +"#{r0}\t#{r1}\t#{val ? T.get_val_type(val) : -1}"
    if val
      out << canon(val)
      cp = T.copy_value(val)
      out << "\t#{cp ? T.compare_values(val, cp) : -99}"
      out << "\t#{hx(T.value_get_as_string(val))}"
      out << "\t#{T.value_get_as_boolean(val)}"
    end
    out
  end

  def resp_c(f)
    r1, a = parse(ty(f[1]), f[2], unhx(f[3]), true)
    r2, b = parse(ty(f[4]), f[5], unhx(f[6]), true)
    out = +"#{r1}\t#{r2}\t#{T.compare_values(a, b)}"
    (0..3).each { |x| (0..3).each { |y| out << "\t#{T.compare_values_whtsp(a, x, b, y)}" } }
    out
  end

  def resp_f(f)
    ftype = f[1].to_i
    fv = unhx(f[3])
    base = ty(f[4])
    v = unhx(f[7])
    facet = S::SchemaFacet.new(type: ftype, value: fv)
    rf, facet.val = if f[2].start_with?("R:")
      T.val_predef_type_node_no_norm(ty(f[2][2..]), fv, true, nil)
    else
      T.val_predef_type_node(ty(f[2]), fv, true, nil)
    end
    rv, val = parse(ty(f[5]), f[6], v, true)
    actual = f[8].to_i
    fvt = facet.val ? T.get_val_type(facet.val) : -1
    isdec = fvt == S::XML_SCHEMAS_DECIMAL || (fvt >= S::XML_SCHEMAS_INTEGER && fvt <= S::XML_SCHEMAS_UBYTE)
    out = +"#{rf}\t#{rv}\t#{isdec ? T.get_facet_value_as_u_long(facet) : 0}"
    out << "\t#{T.validate_facet(base, facet, v, val)}"
    out << "\t#{T.validate_facet(nil, facet, v, nil)}"
    out << "\t#{T.validate_facet(base, facet, v, nil)}"
    vt = val ? T.get_val_type(val) : base.built_in_type
    (0..3).each do |x|
      (0..3).each do |y|
        out << if facet.val.nil? && ftype == S::XML_SCHEMA_FACET_ENUMERATION && y != 0
          "\tX"
        else
          "\t#{T.validate_facet_whtsp(facet, x, vt, v, val, y)}"
        end
      end
    end
    if [S::XML_SCHEMA_FACET_LENGTH, S::XML_SCHEMA_FACET_MINLENGTH, S::XML_SCHEMA_FACET_MAXLENGTH].include?(ftype)
      r, len = T.validate_length_facet(base, facet, v, val)
      out << "\t#{r}\t#{len || 12_345}"
      (0..3).each do |y|
        r, len = T.validate_length_facet_whtsp(facet, vt, v, val, y)
        out << "\t#{r}\t#{len || 12_345}"
      end
      r, exp = T.validate_list_simple_type_facet(facet, v, actual)
      out << "\t#{r}\t#{exp || 12_345}"
    end
    out
  end

  def resp_n(f)
    v = unhx(f[1])
    ints = [T.validate_nc_name(v, 0), T.validate_nc_name(v, 1), T.validate_q_name(v, 0),
      T.validate_q_name(v, 1), T.validate_name(v, 0), T.validate_name(v, 1),
      T.validate_nm_token(v, 0), T.validate_nm_token(v, 1)]
    "#{ints.join("\t")}\t#{hx(T.collapse_string(v))}\t#{hx(T.white_space_replace(v))}"
  end

  def resp_d(f)
    xml = unhx(f[1])
    aname = unhx(f[2])
    rdoc = Nokogiri::XML(xml) { |c| c.nonet }
    doc = rdoc.instance_variable_get(:@__native)
    root = Nokogiri::Pure::Tree.doc_get_root_element(doc)
    node = aname ? Nokogiri::Pure::Tree.get_prop_node_internal(root, aname, nil, false) : root
    outs = []
    i = 3
    while i + 1 < f.size
      r, val = T.val_predef_type_node(ty(f[i]), unhx(f[i + 1]), true, node)
      c = val ? T.get_canon_value(val)[1] : nil
      atype = node && node.type == Nokogiri::Pure::ATTRIBUTE_NODE ? node.atype : -1
      outs << "#{r}\t#{hx(c)}\t#{atype}"
      i += 2
    end
    ids = doc.ids ? doc.ids.size : 0
    refs = doc.refs ? doc.refs.size : 0
    "#{outs.join("\t")}\t#{ids}\t#{refs}"
  end
end
