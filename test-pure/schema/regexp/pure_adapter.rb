# frozen_string_literal: true

# Harness adapter for the pure-Ruby port (Nokogiri::Pure::XmlRegexp). Includes a port of
# xmlRegexpPrint (debug output, used only to compare automata structure with libxml2).
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "nokogiri/pure/xmlregexp"
require_relative "harness"

class PureRegexpAdapter
  X = Nokogiri::Pure::XmlRegexp

  def capture_errors
    errs = []
    h = ->(e) { errs << [e.domain, e.code, e.level, e.message, e.str1, e.str2, e.int1] }
    r = Nokogiri::Pure::Errors.with_handler(h) { yield }
    [r, errs]
  end

  def regexp_compile(pat) = capture_errors { X.regexp_compile(pat) }
  def regexp_exec(comp, s) = X.regexp_exec(comp, s)
  def regexp_is_determinist(comp) = X.regexp_is_determinist(comp)
  def regexp_print(comp) = self.class.regexp_print(comp)

  def new_automata = X.new_automata
  def get_init(am) = X.automata_get_init_state(am)
  def new_state(am) = X.automata_new_state(am)
  def set_final(am, s) = X.automata_set_final_state(am, s)
  def new_transition(am, f, t, tok, d) = X.automata_new_transition(am, f, t, tok, d)
  def new_transition2(am, f, t, tok, tok2, d) = X.automata_new_transition2(am, f, t, tok, tok2, d)
  def neg_trans(am, f, t, tok, tok2, d) = X.automata_new_neg_trans(am, f, t, tok, tok2, d)
  def count_trans(am, f, t, tok, mi, ma, d) = X.automata_new_count_trans(am, f, t, tok, mi, ma, d)
  def count_trans2(am, f, t, tok, tok2, mi, ma, d) = X.automata_new_count_trans2(am, f, t, tok, tok2, mi, ma, d)
  def once_trans(am, f, t, tok, mi, ma, d) = X.automata_new_once_trans(am, f, t, tok, mi, ma, d)
  def once_trans2(am, f, t, tok, tok2, mi, ma, d) = X.automata_new_once_trans2(am, f, t, tok, tok2, mi, ma, d)
  def epsilon(am, f, t) = X.automata_new_epsilon(am, f, t)
  def all_trans(am, f, t, lax) = X.automata_new_all_trans(am, f, t, lax)
  def new_counter(am, mi, ma) = X.automata_new_counter(am, mi, ma)
  def counted_trans(am, f, t, c) = X.automata_new_counted_trans(am, f, t, c)
  def counter_trans(am, f, t, c) = X.automata_new_counter_trans(am, f, t, c)
  def automata_compile(am) = X.automata_compile(am)
  def automata_is_determinist(am) = X.automata_is_determinist(am)
  def state_no(s) = s.no

  def new_exec(comp, cbs)
    cb = ->(_data, token, transdata, inputdata) { cbs << [token, transdata.to_i, inputdata.to_i] }
    X.reg_new_exec_ctxt(comp, cb, 7)
  end

  def push(exec, v, d) = X.reg_exec_push_string(exec, v, d)
  def push2(exec, v, v2, d) = X.reg_exec_push_string2(exec, v, v2, d)

  def next_values(exec, maxval)
    ret, nbval, nbneg, values, terminal = X.reg_exec_next_values(exec, maxval)
    [ret, nbval, nbneg, values, terminal]
  end

  def err_info(exec, maxval)
    ret, string, nbval, nbneg, values, terminal = X.reg_exec_err_info(exec, maxval)
    [ret, string, nbval, nbneg, values, terminal]
  end

  # ---- xmlRegexpPrint port ----
  ATOM_TYPE_NAMES = {
    1 => "epsilon ", 2 => "charval ", 3 => "ranges ", 4 => "subexpr ", 5 => "string ", 6 => "anychar ",
    7 => "anyspace ", 8 => "notspace ", 9 => "initname ", 10 => "notinitname ", 11 => "namechar ",
    12 => "notnamechar ", 13 => "decimal ", 14 => "notdecimal ", 15 => "realchar ", 16 => "notrealchar ",
    100 => "LETTER ", 101 => "LETTER_UPPERCASE ", 102 => "LETTER_LOWERCASE ", 103 => "LETTER_TITLECASE ",
    104 => "LETTER_MODIFIER ", 105 => "LETTER_OTHERS ", 106 => "MARK ", 107 => "MARK_NONSPACING ",
    108 => "MARK_SPACECOMBINING ", 109 => "MARK_ENCLOSING ", 110 => "NUMBER ", 111 => "NUMBER_DECIMAL ",
    112 => "NUMBER_LETTER ", 113 => "NUMBER_OTHERS ", 114 => "PUNCT ", 115 => "PUNCT_CONNECTOR ",
    116 => "PUNCT_DASH ", 117 => "PUNCT_OPEN ", 118 => "PUNCT_CLOSE ", 119 => "PUNCT_INITQUOTE ",
    120 => "PUNCT_FINQUOTE ", 121 => "PUNCT_OTHERS ", 122 => "SEPAR ", 123 => "SEPAR_SPACE ",
    124 => "SEPAR_LINE ", 125 => "SEPAR_PARA ", 126 => "SYMBOL ", 127 => "SYMBOL_MATH ",
    128 => "SYMBOL_CURRENCY ", 129 => "SYMBOL_MODIFIER ", 130 => "SYMBOL_OTHERS ", 131 => "OTHER ",
    132 => "OTHER_CONTROL ", 133 => "OTHER_FORMAT ", 134 => "OTHER_PRIVATE ", 135 => "OTHER_NA ",
    136 => "BLOCK ",
  }.freeze
  QUANT_NAMES = { 1 => "epsilon ", 2 => "once ", 3 => "? ", 4 => "* ", 5 => "+ ", 8 => "range ",
                  6 => "onceonly ", 7 => "all ", }.freeze

  def self.chr(c) = (c & 0xff).chr.b

  def self.print_atom(o, atom)
    o << " atom: "
    if atom.nil?
      o << "NULL\n"
      return
    end
    o << "not " if atom.neg != 0
    o << ATOM_TYPE_NAMES.fetch(atom.type, "")
    o << QUANT_NAMES.fetch(atom.quant, "")
    o << format("%d-%d ", atom.min, atom.max) if atom.quant == X::XML_REGEXP_QUANT_RANGE
    o << "'#{atom.valuep.b}' " if atom.type == X::XML_REGEXP_STRING
    if atom.type == X::XML_REGEXP_CHARVAL
      o << "char " << chr(atom.codepoint) << "\n"
    elsif atom.type == X::XML_REGEXP_RANGES
      o << format("%d entries\n", atom.nb_ranges)
      (atom.ranges || []).each do |r|
        o << "  range: "
        o << "negative " if r.neg != 0
        o << ATOM_TYPE_NAMES.fetch(r.type, "")
        o << chr(r.start) << " - " << chr(r.end) << "\n"
      end
    elsif atom.type == X::XML_REGEXP_SUBREG
      o << format("start %d end %d\n", atom.start.no, atom.stop.no)
    else
      o << "\n"
    end
  end

  def self.print_trans(o, t)
    o << "  trans: "
    if t.to < 0
      o << "removed\n"
      return
    end
    if t.nd != 0
      o << (t.nd == 2 ? "last not determinist, " : "not determinist, ")
    end
    o << format("counted %d, ", t.counter) if t.counter >= 0
    if t.count == X::REGEXP_ALL_COUNTER
      o << "all transition, "
    elsif t.count >= 0
      o << format("count based %d, ", t.count)
    end
    if t.atom.nil?
      o << format("epsilon to %d\n", t.to)
      return
    end
    o << "char " << chr(t.atom.codepoint) << " " if t.atom.type == X::XML_REGEXP_CHARVAL
    o << format("atom %d, to %d\n", t.atom.no, t.to)
  end

  def self.regexp_print(regexp)
    o = +"".b
    o << " regexp: "
    if regexp.nil?
      o << "NULL\n"
      return o
    end
    o << "'#{regexp.string.to_s.b}' "
    # C prints "(null)" for a NULL string
    o.sub!("''", "'(null)'") if regexp.string.nil?
    o << "\n"
    atoms = regexp.atoms || []
    o << format("%d atoms:\n", atoms.size)
    atoms.each_with_index do |a, i|
      o << format(" %02d ", i)
      print_atom(o, a)
    end
    states = regexp.states || []
    o << format("%d states:", states.size) << "\n"
    states.each do |s|
      o << " state: "
      if s.nil?
        o << "NULL\n"
        next
      end
      o << "START " if s.type == X::XML_REGEXP_START_STATE
      o << "FINAL " if s.type == X::XML_REGEXP_FINAL_STATE
      o << format("%d, %d transitions:\n", s.no, s.trans.size)
      s.trans.each { |t| print_trans(o, t) }
    end
    counters = regexp.counters || []
    o << format("%d counters:\n", counters.size)
    counters.each_with_index { |c, i| o << format(" %d: min %d max %d\n", i, c.min, c.max) }
    o
  end
end
