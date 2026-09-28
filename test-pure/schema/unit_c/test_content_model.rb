# frozen_string_literal: true

# Unit tests for lib/nokogiri/pure/schemas/build.rb (worker C): content model automata built
# from hand-made particle trees, run with Nokogiri::Pure::XmlRegexp and compared with what the
# native nokogiri 1.19.4 (libxml2 2.13.9) reports for the equivalent <xs:complexType>.
# Run: ruby -Ilib test-pure/schema/unit_c/test_content_model.rb

require_relative "helper"

class TestContentModel < Minitest::Test
  include UnitC

  # Mimics xmlSchemaValidateChildElem / xmlSchemaValidatorPopElem: returns nil if the child
  # sequence is accepted, else [:unexpected, name, expected_list] or [:missing, expected_list].
  def run_model(type, names)
    ex = R.reg_new_exec_ctxt(type.cont_model, nil, nil)
    names.each do |n|
      ret = R.reg_exec_push_string2(ex, n, nil, nil)
      if ret < 0
        _, _, nbval, _, values, = R.reg_exec_err_info(ex, 10)
        return [:unexpected, n, values[0, nbval]]
      end
    end
    _, nbval, _, values, = R.reg_exec_next_values(ex, 10)
    ret = R.reg_exec_push_string(ex, nil, nil)
    return [:missing, values[0, nbval]] if ret <= 0

    nil
  end

  def build(particle)
    errs = []
    pctxt = S::SchemaParserCtxt.new(serror: ->(e) { errs << e })
    t = ctype(particle)
    S.build_content_model(t, pctxt)
    [t, errs]
  end

  # <xs:sequence><a/><b minOccurs=0 maxOccurs=unbounded/></xs:sequence>
  def test_seq_a_bstar
    t, errs = build(pt(mg(SEQ, pt(el("a")), pt(el("b"), 0, UNB))))
    assert_empty errs
    assert_nil run_model(t, %w[a b b])
    assert_equal [:unexpected, "b", ["a"]], run_model(t, %w[b])
    assert_equal [:unexpected, "c", ["b"]], run_model(t, %w[a c])
    assert_equal [:missing, ["a"]], run_model(t, %w[])
  end

  # <xs:choice minOccurs=2 maxOccurs=3><a/><b/></xs:choice>
  def test_choice_2_3
    t, errs = build(pt(mg(CHO, pt(el("a")), pt(el("b"))), 2, 3))
    assert_empty errs
    assert_nil run_model(t, %w[a b])
    assert_equal [:missing, %w[a b]], run_model(t, %w[a])
    assert_equal [:unexpected, "b", []], run_model(t, %w[a b a b])
    assert_nil run_model(t, %w[a b a])
  end

  # <xs:all><a/><b minOccurs=0/></xs:all>
  def test_all
    t, errs = build(pt(mg(ALL, pt(el("a")), pt(el("b"), 0, 1))))
    assert_empty errs
    assert_nil run_model(t, %w[b a])
    assert_equal [:missing, ["a"]], run_model(t, %w[b])
    assert_equal [:unexpected, "a", []], run_model(t, %w[a a])
    assert_equal [:missing, %w[a b]], run_model(t, %w[])
  end

  # <xs:sequence minOccurs=2 maxOccurs=unbounded><a/><b/></xs:sequence>
  def test_seq_2_unbounded
    t, errs = build(pt(mg(SEQ, pt(el("a")), pt(el("b"))), 2, UNB))
    assert_empty errs
    assert_nil run_model(t, %w[a b a b])
    assert_equal [:missing, ["a"]], run_model(t, %w[a b])
    assert_equal [:missing, ["b"]], run_model(t, %w[a b a])
    assert_nil run_model(t, %w[a b a b a b])
  end

  # <xs:sequence><a minOccurs=2 maxOccurs=4/><c minOccurs=0/></xs:sequence>
  def test_counted_element
    t, errs = build(pt(mg(SEQ, pt(el("a"), 2, 4), pt(el("c"), 0, 1))))
    assert_empty errs
    assert_nil run_model(t, %w[a a])
    assert_equal [:missing, ["a"]], run_model(t, %w[a])
    assert_equal [:unexpected, "a", ["c"]], run_model(t, %w[a a a a a])
    assert_nil run_model(t, %w[a a c])
  end

  # <xs:sequence minOccurs=0 maxOccurs=3><a/><b minOccurs=0/></xs:sequence>
  def test_seq_optional_counted
    t, errs = build(pt(mg(SEQ, pt(el("a")), pt(el("b"), 0, 1)), 0, 3))
    assert_empty errs
    assert_nil run_model(t, %w[])
    assert_nil run_model(t, %w[a a b a])
    assert_equal [:unexpected, "a", []], run_model(t, %w[a a a a])
    assert_equal [:unexpected, "b", ["a"]], run_model(t, %w[b])
  end

  # <xs:choice minOccurs=0 maxOccurs=unbounded><a/><xs:sequence><b/><c/></xs:sequence></xs:choice>
  def test_choice_unbounded_nested
    t, errs = build(pt(mg(CHO, pt(el("a")), pt(mg(SEQ, pt(el("b")), pt(el("c"))))), 0, UNB))
    assert_empty errs
    assert_nil run_model(t, %w[a b c a])
    assert_equal [:unexpected, "a", ["c"]], run_model(t, %w[b a])
    assert_nil run_model(t, %w[])
    # the order "b, a" is what libxml2 reports
    assert_equal [:unexpected, "c", %w[b a]], run_model(t, %w[c])
  end

  # <xs:sequence maxOccurs=unbounded><a/><b minOccurs=0/></xs:sequence>
  def test_seq_unbounded_min1
    t, errs = build(pt(mg(SEQ, pt(el("a")), pt(el("b"), 0, 1)), 1, UNB))
    assert_empty errs
    assert_nil run_model(t, %w[a a b a])
    assert_equal [:unexpected, "b", ["a"]], run_model(t, %w[b])
    assert_equal [:missing, ["a"]], run_model(t, %w[])
  end

  # <xs:sequence><a/><xs:any namespace="##any" minOccurs=0 maxOccurs=2/></xs:sequence>
  def test_wildcard_any_counted
    w = S::SchemaWildcard.new(any: 1, process_contents: S::XML_SCHEMAS_ANY_SKIP)
    t, errs = build(pt(mg(SEQ, pt(el("a")), pt(w, 0, 2))))
    assert_empty errs
    assert_nil run_model(t, %w[a x y])
    assert_equal [:unexpected, "z", []], run_model(t, %w[a x y z])
    assert_equal [:unexpected, "x", ["a"]], run_model(t, %w[x])
  end

  # <xs:choice><xs:sequence><a/><b/></xs:sequence><xs:sequence><a/><c/></xs:sequence></xs:choice>
  def test_non_deterministic
    t, errs = build(pt(mg(CHO, pt(mg(SEQ, pt(el("a")), pt(el("b")))),
      pt(mg(SEQ, pt(el("a")), pt(el("c")))))))
    refute_nil t.cont_model
    assert_equal 1, errs.size
    assert_equal P::ErrCode::SCHEMAP_NOT_DETERMINISTIC, errs[0].code
    # native: "local complex type: The content model is not determinist." (the type here is
    # named "t", so worker A's formatter reports it as a global complex type)
    assert_match(/The content model is not determinist\.\n\z/, errs[0].message)
  end

  # Substitution group head in a sequence (members via the constructor's subst group table)
  def test_subst_group
    head = el("h", flags: S::XML_SCHEMAS_ELEM_SUBST_GROUP_HEAD)
    m1 = el("m1")
    m2 = el("m2")
    errs = []
    pctxt = S::SchemaParserCtxt.new(serror: ->(e) { errs << e })
    pctxt.constructor = S::SchemaConstructionCtxt.new
    sg = S::SchemaSubstGroup.new(head: head, members: S::SchemaItemList.new)
    sg.members.items << m1 << m2
    S.define_singleton_method(:subst_group_get) { |_p, h| h.equal?(head) ? sg : nil }
    t = ctype(pt(mg(SEQ, pt(head, 1, 2), pt(el("z"), 0, 1))))
    S.build_content_model(t, pctxt)
    assert_empty errs
    assert_nil run_model(t, %w[m2 h])
    assert_nil run_model(t, %w[m1])
    assert_equal [:unexpected, "m1", ["z"]], run_model(t, %w[h m2 m1])
    assert_equal [:missing, %w[h m1 m2]], run_model(t, %w[])
  ensure
    S.singleton_class.send(:remove_method, :subst_group_get) rescue nil
  end
end
