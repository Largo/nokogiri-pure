# frozen_string_literal: true

# Shared setup for worker C's unit tests (build.rb / constraints*.rb / fixup*.rb).
$LOAD_PATH.unshift(File.expand_path("../../../lib", __dir__))
require "minitest/autorun"
require "nokogiri"
require "nokogiri/pure/xmlregexp"
%w[components errors build constraints constraints_types fixup_facets fixup fixup_components].each do |f|
  require "nokogiri/pure/schemas/#{f}"
end

module UnitC
  P = Nokogiri::Pure
  S = Nokogiri::Pure::Schemas
  R = Nokogiri::Pure::XmlRegexp
  SEQ = S::XML_SCHEMA_TYPE_SEQUENCE
  CHO = S::XML_SCHEMA_TYPE_CHOICE
  ALL = S::XML_SCHEMA_TYPE_ALL
  UNB = S::UNBOUNDED

  def el(name, ns = nil, flags: 0)
    S::SchemaElement.new(name: name, target_namespace: ns, flags: flags)
  end

  def pt(term, min = 1, max = 1)
    S::SchemaParticle.new(children: term, min_occurs: min, max_occurs: max)
  end

  def mg(type, *parts)
    parts.each_cons(2) { |a, b| a.next = b }
    S::SchemaModelGroup.new(type: type, children: parts.first)
  end

  def ctype(particle)
    S::SchemaType.new(type: S::XML_SCHEMA_TYPE_COMPLEX, content_type: S::XML_SCHEMA_CONTENT_ELEMENTS,
      subtypes: particle, name: "t")
  end

  # wildcard helpers: ns lists -> linked SchemaWildcardNs
  def ns_list(*values)
    head = nil
    values.reverse_each { |v| head = S::SchemaWildcardNs.new(value: v, next: head) }
    head
  end

  def ns_values(list)
    out = []
    while list
      out << list.value
      list = list.next
    end
    out
  end

  def wild(any: 0, set: nil, neg: :none, pc: S::XML_SCHEMAS_ANY_STRICT)
    w = S::SchemaWildcard.new(any: any, process_contents: pc, type: S::XML_SCHEMA_TYPE_ANY_ATTRIBUTE)
    w.ns_set = ns_list(*set) if set
    w.neg_ns_set = S::SchemaWildcardNs.new(value: neg) unless neg == :none
    w
  end
end
