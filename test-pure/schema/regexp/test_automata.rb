# frozen_string_literal: true

# Readable unit tests of the XmlRegexp API as used by xmlschemas.c / relaxng.c. The expected
# values are libxml2's (the same scenarios are covered, with many more, by the differential
# fixtures of test_regexp_diff.rb).
require "minitest/autorun"
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "nokogiri/pure/xmlregexp"

class TestXmlRegexpAutomata < Minitest::Test
  X = Nokogiri::Pure::XmlRegexp

  def test_sequence_compact_form
    am = X.new_automata
    s = X.automata_get_init_state(am)
    s = X.automata_new_transition2(am, s, nil, "a", nil, :da)
    s = X.automata_new_transition2(am, s, nil, "b", "urn:x", :db)
    X.automata_set_final_state(am, s)
    comp = X.automata_compile(am)
    refute_nil comp.compact # deterministic string automaton -> compact form
    assert_equal 1, X.regexp_is_determinist(comp)

    cbs = []
    exec = X.reg_new_exec_ctxt(comp, ->(data, tok, transdata, inputdata) { cbs << [data, tok, transdata, inputdata] }, :vctxt)
    assert_equal [0, 1, 0, ["a"], 0], X.reg_exec_next_values(exec, 10)
    assert_equal 0, X.reg_exec_push_string(exec, "a", :i1)
    assert_equal [0, 1, 0, ["b|urn:x"], 0], X.reg_exec_next_values(exec, 10)
    assert_equal(-1, X.reg_exec_push_string(exec, "b", :i2))
    assert_equal [0, "b", 1, 0, ["b|urn:x"], 0], X.reg_exec_err_info(exec, 10)
    assert_equal [[:vctxt, "a", :da, :i1]], cbs

    exec = X.reg_new_exec_ctxt(comp, nil, nil)
    assert_equal 0, X.reg_exec_push_string(exec, "a", 1)
    assert_equal 1, X.reg_exec_push_string2(exec, "b", "urn:x", 1)
    assert_equal 1, X.reg_exec_push_string(exec, nil, nil)
  end

  def test_all_group
    am = X.new_automata
    start = X.automata_get_init_state(am)
    tmp = X.automata_new_state(am)
    X.automata_new_epsilon(am, start, tmp)
    X.automata_new_once_trans2(am, tmp, tmp, "a", nil, 1, 1, :a)
    X.automata_new_count_trans2(am, tmp, tmp, "b", nil, 0, 1, :b)
    fin = X.automata_new_all_trans(am, tmp, nil, 0)
    X.automata_set_final_state(am, fin)
    comp = X.automata_compile(am)
    assert_nil comp.compact # counters -> no compact form
    assert_equal 1, X.regexp_is_determinist(comp)

    exec = X.reg_new_exec_ctxt(comp, nil, nil)
    assert_equal 0, X.reg_exec_push_string(exec, "b", 1)
    assert_equal [0, 1, 0, ["a"], 0], X.reg_exec_next_values(exec, 10)
    assert_equal(-1, X.reg_exec_push_string(exec, "b", 1))
    assert_equal [0, "b", 1, 0, ["a"], 0], X.reg_exec_err_info(exec, 10)

    exec = X.reg_new_exec_ctxt(comp, nil, nil)
    assert_equal 0, X.reg_exec_push_string(exec, "b", 1)
    assert_equal(-1, X.reg_exec_push_string(exec, nil, nil)) # "a" missing
    assert_equal [0, 2, 0, %w[a b], 0], X.reg_exec_next_values(exec, 10)
  end

  def test_not_determinist
    am = X.new_automata
    s = X.automata_get_init_state(am)
    e1 = X.automata_new_transition(am, s, nil, "a", nil)
    X.automata_new_transition(am, e1, nil, "b", nil)
    e2 = X.automata_new_transition(am, s, nil, "a", nil)
    X.automata_set_final_state(am, e2)
    comp = X.automata_compile(am)
    assert_equal 0, X.regexp_is_determinist(comp)
  end

  def test_regexp_basics
    comp = X.regexp_compile("[a-z-[aeiou]]{2,3}\\d")
    assert_equal 1, X.regexp_exec(comp, "bcd1")
    assert_equal 0, X.regexp_exec(comp, "bad1")
    assert_equal 1, X.regexp_is_determinist(comp)
    comp = X.regexp_compile("\\p{IsNoSuchBlock}")
    assert_equal X::XML_REGEXP_INTERNAL_ERROR, X.regexp_exec(comp, "a")
  end

  def test_compile_errors_are_reported_globally
    errs = []
    comp = Nokogiri::Pure::Errors.with_handler(->(e) { errs << e }) { X.regexp_compile("[a") }
    assert_nil comp
    assert_equal ["failed to compile: Expecting ']'\n", "failed to compile: xmlFAParseCharClass: ']' expected\n"], errs.map(&:message)
    e = errs.first
    assert_equal [Nokogiri::Pure::Domain::REGEXP, Nokogiri::Pure::ErrCode::REGEXP_COMPILE_ERROR, Nokogiri::Pure::Level::FATAL],
      [e.domain, e.code, e.level]
    assert_equal ["Expecting ']'", "[a", 2], [e.str1, e.str2, e.int1]
  end
end
