# frozen_string_literal: true

# Unit tests for worker C's constraint helpers: wildcard union/intersection/subset
# (xmlSchemaUnionWildcards, xmlSchemaIntersectWildcards, xmlSchemaCheckCOSNSSubset,
# xmlSchemaCheckCVCWildcardNamespace), particle emptiability, value constraints, facet
# derivation messages and attribute group expansion. Expected results follow the C control
# flow of libxml2 2.13.9 (xmlschemas.c); message strings were checked against the native gem.
# Run: ruby -Ilib test-pure/schema/unit_c/test_constraints.rb

require_relative "helper"

class TestWildcards < Minitest::Test
  include UnitC

  def setup
    @errs = []
    @pctxt = S::SchemaParserCtxt.new(serror: ->(e) { @errs << e })
  end

  def test_union_same_value
    a = wild(set: %w[a b])
    assert_equal 0, S.union_wildcards(@pctxt, a, wild(set: %w[b a]))
    assert_equal %w[a b], ns_values(a.ns_set)
  end

  def test_union_sets_prepends_new_members
    a = wild(set: %w[a b])
    assert_equal 0, S.union_wildcards(@pctxt, a, wild(set: %w[b c d]))
    assert_equal %w[d c a b], ns_values(a.ns_set)
  end

  def test_union_with_any
    a = wild(set: %w[a])
    S.union_wildcards(@pctxt, a, wild(any: 1))
    assert_equal 1, a.any
    assert_nil a.ns_set
    assert_nil a.neg_ns_set
    # complete is any: stays any
    b = wild(any: 1)
    S.union_wildcards(@pctxt, b, wild(set: %w[x]))
    assert_equal 1, b.any
  end

  def test_union_two_negations
    a = wild(neg: "a")
    S.union_wildcards(@pctxt, a, wild(neg: "b"))
    assert_nil a.neg_ns_set.value
    refute_nil a.neg_ns_set
  end

  def test_union_5_1_any
    a = wild(neg: "x")
    S.union_wildcards(@pctxt, a, wild(set: ["x", nil]))
    assert_equal 1, a.any
    assert_nil a.neg_ns_set
  end

  def test_union_5_2_not_absent
    a = wild(set: %w[x y])
    S.union_wildcards(@pctxt, a, wild(neg: "x"))
    assert_nil a.ns_set
    refute_nil a.neg_ns_set
    assert_nil a.neg_ns_set.value
  end

  def test_union_5_3_not_expressible
    a = wild(neg: "x")
    ret = S.union_wildcards(@pctxt, a, wild(set: [nil, "y"]))
    assert_equal P::ErrCode::SCHEMAP_UNION_NOT_EXPRESSIBLE, ret
    assert_equal 1, @errs.size
    assert_equal "The union of the wildcard is not expressible.\n", @errs[0].message
    assert_equal P::ErrCode::SCHEMAP_UNION_NOT_EXPRESSIBLE, @errs[0].code
  end

  def test_union_5_4
    a = wild(set: %w[y])
    S.union_wildcards(@pctxt, a, wild(neg: "x"))
    assert_nil a.ns_set
    assert_equal "x", a.neg_ns_set.value
    b = wild(neg: "x")
    S.union_wildcards(@pctxt, b, wild(set: %w[y]))
    assert_equal "x", b.neg_ns_set.value
  end

  def test_union_6
    a = wild(neg: nil)
    S.union_wildcards(@pctxt, a, wild(set: ["a", nil]))
    assert_equal 1, a.any
    b = wild(set: %w[a])
    S.union_wildcards(@pctxt, b, wild(neg: nil))
    assert_nil b.ns_set
    assert_nil b.neg_ns_set.value
  end

  def test_intersect_sets
    a = wild(set: %w[a b c])
    assert_equal 0, S.intersect_wildcards(@pctxt, a, wild(set: %w[c a]))
    assert_equal %w[a c], ns_values(a.ns_set)
  end

  def test_intersect_any_takes_other
    a = wild(any: 1)
    S.intersect_wildcards(@pctxt, a, wild(set: %w[x y]))
    assert_equal 0, a.any
    assert_equal %w[x y], ns_values(a.ns_set)
  end

  def test_intersect_neg_and_set
    a = wild(neg: "a")
    S.intersect_wildcards(@pctxt, a, wild(set: ["a", "b", nil]))
    assert_equal %w[b], ns_values(a.ns_set)
    assert_nil a.neg_ns_set
    b = wild(set: ["a", nil, "b"])
    S.intersect_wildcards(@pctxt, b, wild(neg: "b"))
    assert_equal %w[a], ns_values(b.ns_set)
  end

  def test_intersect_not_expressible
    a = wild(neg: "a")
    ret = S.intersect_wildcards(@pctxt, a, wild(neg: "b"))
    assert_equal P::ErrCode::SCHEMAP_INTERSECTION_NOT_EXPRESSIBLE, ret
    assert_equal "The intersection of the wildcard is not expressible.\n", @errs[0].message
  end

  def test_intersect_neg_absent
    a = wild(neg: nil)
    S.intersect_wildcards(@pctxt, a, wild(neg: "a"))
    assert_equal "a", a.neg_ns_set.value
    b = wild(neg: "a")
    S.intersect_wildcards(@pctxt, b, wild(neg: nil))
    assert_equal "a", b.neg_ns_set.value
  end

  def test_cos_ns_subset
    assert_equal 0, S.check_cosns_subset(wild(set: %w[a]), wild(any: 1))
    assert_equal 0, S.check_cosns_subset(wild(neg: "a"), wild(neg: "a"))
    assert_equal 1, S.check_cosns_subset(wild(neg: "a"), wild(neg: "b"))
    assert_equal 0, S.check_cosns_subset(wild(set: %w[a b]), wild(set: %w[b c a]))
    assert_equal 1, S.check_cosns_subset(wild(set: %w[a d]), wild(set: %w[b c a]))
    assert_equal 0, S.check_cosns_subset(wild(set: %w[a b]), wild(neg: "c"))
    assert_equal 1, S.check_cosns_subset(wild(set: %w[a c]), wild(neg: "c"))
    assert_equal 1, S.check_cosns_subset(wild(any: 1), wild(set: %w[a]))
  end

  def test_cvc_wildcard_namespace
    assert_equal(-1, S.check_cvc_wildcard_namespace(nil, "a"))
    assert_equal 0, S.check_cvc_wildcard_namespace(wild(any: 1), nil)
    assert_equal 0, S.check_cvc_wildcard_namespace(wild(set: ["a", nil]), nil)
    assert_equal 1, S.check_cvc_wildcard_namespace(wild(set: %w[a]), "b")
    assert_equal 0, S.check_cvc_wildcard_namespace(wild(neg: "a"), "b")
    assert_equal 1, S.check_cvc_wildcard_namespace(wild(neg: "a"), nil)
    assert_equal 1, S.check_cvc_wildcard_namespace(wild(neg: nil), nil)
  end

  def test_clone
    d = wild(neg: "old")
    S.clone_wildcard_ns_constraints(@pctxt, d, wild(any: 0, set: %w[p q]))
    assert_equal %w[p q], ns_values(d.ns_set)
    assert_nil d.neg_ns_set
  end
end

class TestParticles < Minitest::Test
  include UnitC

  def test_emptiable
    assert_equal 1, S.is_particle_emptiable(nil)
    assert_equal 1, S.is_particle_emptiable(pt(el("a"), 0, 1))
    assert_equal 0, S.is_particle_emptiable(pt(el("a")))
    assert_equal 1, S.is_particle_emptiable(pt(mg(SEQ, pt(el("a"), 0, 1), pt(el("b"), 0, 5))))
    assert_equal 0, S.is_particle_emptiable(pt(mg(SEQ, pt(el("a"), 0, 1), pt(el("b")))))
    assert_equal 1, S.is_particle_emptiable(pt(mg(CHO, pt(el("a")), pt(el("b"), 0, 1))))
    assert_equal 0, S.is_particle_emptiable(pt(mg(CHO, pt(el("a")), pt(el("b")))))
    assert_equal 1, S.is_particle_emptiable(pt(mg(SEQ)))
    nested = pt(mg(SEQ, pt(mg(CHO, pt(el("a")), pt(mg(SEQ, pt(el("b"), 0, 1)))))))
    assert_equal 1, S.is_particle_emptiable(nested)
  end

  def test_total_range
    p1 = pt(mg(SEQ, pt(el("a"), 2, 3), pt(el("b"), 1, 4)), 2, 2)
    assert_equal 6, S.get_particle_total_range_min(p1)
    assert_equal 14, S.get_particle_total_range_max(p1)
    p2 = pt(mg(CHO, pt(el("a"), 2, 3), pt(el("b"), 1, UNB)))
    assert_equal 1, S.get_particle_total_range_min(p2)
    assert_equal UNB, S.get_particle_total_range_max(p2)
  end
end

class TestTypeHelpers < Minitest::Test
  include UnitC

  def basic(bt, base = nil, flags: 0)
    S::SchemaType.new(type: S::XML_SCHEMA_TYPE_BASIC, built_in_type: bt, base_type: base,
      subtypes: base, flags: flags)
  end

  def test_derived_from_builtin
    any_st = basic(S::XML_SCHEMAS_ANYSIMPLETYPE)
    str = basic(S::XML_SCHEMAS_STRING, any_st, flags: S::XML_SCHEMAS_TYPE_BUILTIN_PRIMITIVE)
    ncname = basic(S::XML_SCHEMAS_NCNAME, str)
    id = basic(S::XML_SCHEMAS_ID, ncname)
    user = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE, base_type: id, subtypes: id)
    assert_equal 1, S.is_derived_from_built_in_type(user, S::XML_SCHEMAS_ID)
    assert_equal 1, S.is_derived_from_built_in_type(user, S::XML_SCHEMAS_STRING)
    assert_equal 0, S.is_derived_from_built_in_type(ncname, S::XML_SCHEMAS_ID)
    assert_equal 0, S.is_derived_from_built_in_type(nil, S::XML_SCHEMAS_ID)
    assert_same str, S.get_primitive_type(user)
    assert_same any_st, S.get_primitive_type(any_st)
    assert_equal 1, S.are_equal_types(str, str)
    assert_equal 0, S.are_equal_types(str, nil)
  end

  def test_effective_value_constraint
    decl = S::SchemaAttribute.new(def_value: "d", def_val: :dv, flags: S::XML_SCHEMAS_ATTR_FIXED)
    use = S::SchemaAttributeUse.new(attr_decl: decl)
    assert_equal [1, 1, "d", :dv], S.get_effective_value_constraint(use)
    use.def_value = "u"
    use.def_val = :uv
    assert_equal [1, 0, "u", :uv], S.get_effective_value_constraint(use)
    use.flags = S::XML_SCHEMA_ATTR_USE_FIXED
    assert_equal [1, 1, "u", :uv], S.get_effective_value_constraint(use)
    assert_equal [0, 0, nil, nil],
      S.get_effective_value_constraint(S::SchemaAttributeUse.new(attr_decl: S::SchemaAttribute.new))
  end

  def test_white_space_facet_value
    assert_equal S::XML_SCHEMA_WHITESPACE_PRESERVE, S.get_white_space_facet_value(basic(S::XML_SCHEMAS_STRING))
    assert_equal S::XML_SCHEMA_WHITESPACE_REPLACE, S.get_white_space_facet_value(basic(S::XML_SCHEMAS_NORMSTRING))
    assert_equal S::XML_SCHEMA_WHITESPACE_COLLAPSE, S.get_white_space_facet_value(basic(S::XML_SCHEMAS_INT))
    t = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE, flags: S::XML_SCHEMAS_TYPE_VARIETY_UNION)
    assert_equal S::XML_SCHEMA_WHITESPACE_UNKNOWN, S.get_white_space_facet_value(t)
    t.flags = S::XML_SCHEMAS_TYPE_VARIETY_ATOMIC | S::XML_SCHEMAS_TYPE_WHITESPACE_REPLACE
    assert_equal S::XML_SCHEMA_WHITESPACE_REPLACE, S.get_white_space_facet_value(t)
  end

  def test_facet_type_to_string
    assert_equal "whiteSpace", S.facet_type_to_string(S::XML_SCHEMA_FACET_WHITESPACE)
    assert_equal "Internal Error", S.facet_type_to_string(S::XML_SCHEMA_TYPE_SIMPLE)
  end

  def test_final_and_member_types
    t = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE, flags: S::XML_SCHEMAS_TYPE_FINAL_LIST)
    assert_equal 1, S.type_final_contains(t, S::XML_SCHEMAS_TYPE_FINAL_LIST)
    assert_equal 0, S.type_final_contains(t, S::XML_SCHEMAS_TYPE_FINAL_UNION)
    link = S::SchemaTypeLink.new(type: t)
    u = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE, member_types: link)
    d = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_SIMPLE, base_type: u)
    assert_same link, S.get_union_simple_type_member_types(d)
  end
end

class TestFacetErrors < Minitest::Test
  include UnitC

  def test_derive_facet_err_messages
    errs = []
    pctxt = S::SchemaParserCtxt.new(serror: ->(e) { errs << e })
    len = S::SchemaFacet.new(type: S::XML_SCHEMA_FACET_LENGTH)
    maxinc = S::SchemaFacet.new(type: S::XML_SCHEMA_FACET_MAXINCLUSIVE)
    mininc = S::SchemaFacet.new(type: S::XML_SCHEMA_FACET_MININCLUSIVE)
    S.derive_facet_err(pctxt, len, len, 0, 0, 1)
    S.derive_facet_err(pctxt, maxinc, mininc, 1, 1, 0)
    # native: "facet 'length': 'length' has to be equal to less than 'length' of the base type."
    assert_equal "facet 'length': 'length' has to be equal to less than 'length' of the base type.\n",
      errs[0].message
    assert_equal "facet 'maxInclusive': 'maxInclusive' has to be greater than or equal to 'minInclusive'.\n",
      errs[1].message
    assert_equal P::ErrCode::SCHEMAP_INVALID_FACET_VALUE, errs[0].code
  end
end

class TestAttrGroupExpansion < Minitest::Test
  include UnitC

  def attr_use(name, ns = nil)
    S::SchemaAttributeUse.new(attr_decl: S::SchemaAttribute.new(name: name, target_namespace: ns))
  end

  def list(*items)
    l = S::SchemaItemList.new
    l.items.concat(items)
    l
  end

  def test_expand_refs_and_prohibitions
    errs = []
    pctxt = S::SchemaParserCtxt.new(serror: ->(e) { errs << e })
    g1 = S::SchemaAttributeGroup.new(name: "g1", attr_uses: list(attr_use("x"), attr_use("y")),
      flags: S::XML_SCHEMAS_ATTRGROUP_WILDCARD_BUILDED)
    g2 = S::SchemaAttributeGroup.new(name: "g2", attr_uses: nil,
      flags: S::XML_SCHEMAS_ATTRGROUP_WILDCARD_BUILDED)
    ref1 = S::SchemaQNameRef.new(item_type: S::XML_SCHEMA_TYPE_ATTRIBUTEGROUP, item: g1)
    ref2 = S::SchemaQNameRef.new(item_type: S::XML_SCHEMA_TYPE_ATTRIBUTEGROUP, item: g2)
    prohib = S::SchemaAttributeUseProhib.new(name: "zz")
    a = attr_use("a")
    uses = list(a, ref1, prohib, ref2, attr_use("b"))
    prohibs = list(:stale)
    owner = S::SchemaType.new(type: S::XML_SCHEMA_TYPE_COMPLEX)
    ret, wc = S.expand_attribute_group_refs(pctxt, owner, nil, uses, prohibs)
    assert_equal 0, ret
    assert_nil wc
    assert_equal %w[a x y b], uses.items.map { |u| u.attr_decl.name }
    assert_equal [prohib], prohibs.items
    assert_empty errs
  end

  def test_wildcard_intersection_creates_copy
    pctxt = S::SchemaParserCtxt.new(serror: ->(_e) {})
    w1 = wild(set: %w[a b c])
    w2 = wild(set: %w[b c d])
    g1 = S::SchemaAttributeGroup.new(attribute_wildcard: w1, attr_uses: nil,
      flags: S::XML_SCHEMAS_ATTRGROUP_WILDCARD_BUILDED)
    g2 = S::SchemaAttributeGroup.new(attribute_wildcard: w2, attr_uses: nil,
      flags: S::XML_SCHEMAS_ATTRGROUP_WILDCARD_BUILDED)
    uses = list(S::SchemaQNameRef.new(item_type: S::XML_SCHEMA_TYPE_ATTRIBUTEGROUP, item: g1),
      S::SchemaQNameRef.new(item_type: S::XML_SCHEMA_TYPE_ATTRIBUTEGROUP, item: g2))
    created = nil
    S.define_singleton_method(:add_wildcard) do |_c, _s, type, node|
      created = S::SchemaWildcard.new(type: type, node: node)
    end
    ret, wc = S.expand_attribute_group_refs(pctxt, S::SchemaType.new, nil, uses, nil)
    assert_equal 0, ret
    assert_same created, wc
    assert_equal %w[b c], ns_values(wc.ns_set)
    assert_equal %w[a b c], ns_values(w1.ns_set) # the group's own wildcard is untouched
    assert_empty uses.items
  ensure
    S.singleton_class.send(:remove_method, :add_wildcard) rescue nil
  end
end
