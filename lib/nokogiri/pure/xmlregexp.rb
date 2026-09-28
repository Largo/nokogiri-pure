# frozen_string_literal: true

# Pure-Ruby port of libxml2 2.13.9 xmlregexp.c (regular expressions of XML Schema Part 2
# Appendix F, and the finite automata API used by xmlschemas.c / relaxng.c for content
# models), plus the parts of xmlunicode.c / chvalid.c it needs (tables generated into
# xmlregexp/unicode.rb by test-pure/schema/regexp/gen_unicode.rb -- libxml2's own Unicode 4.0.1
# data, NOT Ruby's \p{} classes).
#
# The port is function-by-function (same control flow, same state/transition numbering, same
# compact-form construction), so determinism results, "expected values" orders and error
# messages are identical to libxml2.
#
# == Public API (Nokogiri::Pure::XmlRegexp, module functions)
#
# Regular expressions:
#   regexp_compile(str)             -> Regexp or nil   (xmlRegexpCompile; on syntax errors each
#                                      problem is reported through the *global* structured error
#                                      handler (Pure::Errors.report): domain REGEXP, code
#                                      ErrCode::REGEXP_COMPILE_ERROR, level FATAL,
#                                      message "failed to compile: <extra>\n", str1 = extra,
#                                      str2 = the regexp, int1 = byte offset)
#   regexp_exec(comp, str)          -> 1 match, 0 no match, < 0 error (xmlRegexpExec;
#                                      -4 internal error e.g. \p{IsUnknownBlock}, -6 push limit,
#                                      -7 invalid UTF-8)
#   regexp_is_determinist(comp)     -> 1 / 0 / -1       (xmlRegexpIsDeterminist)
#   reg_free_regexp(comp)           -> no-op
#
# Automata (xmlautomata.h); states are XmlRegexp::State objects, +am+ is a ParserCtxt:
#   new_automata                                    -> Automata (= ParserCtxt)
#   free_automata(am)                               -> no-op
#   automata_set_flags(am, flags)                   (AM_AUTOMATA_RNG = 1 for RelaxNG)
#   automata_get_init_state(am)                     -> State
#   automata_set_final_state(am, state)             -> 0 / -1
#   automata_new_state(am)                          -> State
#   automata_new_transition(am, from, to, token, data)               -> State (to or new) / nil
#   automata_new_transition2(am, from, to, token, token2, data)      -> State / nil
#   automata_new_neg_trans(am, from, to, token, token2, data)        -> State / nil
#   automata_new_count_trans(am, from, to, token, min, max, data)    -> State / nil
#   automata_new_count_trans2(am, from, to, token, token2, min, max, data) -> State / nil
#   automata_new_once_trans(am, from, to, token, min, max, data)     -> State / nil
#   automata_new_once_trans2(am, from, to, token, token2, min, max, data)  -> State / nil
#   automata_new_epsilon(am, from, to)                                -> State / nil
#   automata_new_all_trans(am, from, to, lax)                         -> State / nil
#   automata_new_counter(am, min, max)                                -> Integer counter / -1
#   automata_new_counted_trans(am, from, to, counter)                 -> State / nil
#   automata_new_counter_trans(am, from, to, counter)                 -> State / nil
#   automata_compile(am)                            -> Regexp or nil
#   automata_is_determinist(am)                     -> 1 / 0 / -1
#   (+to+ may be nil everywhere: a new target state is created, like the C API)
#
# Progressive (push) execution:
#   reg_new_exec_ctxt(comp, callback, data) -> ExecCtxt or nil. +callback+ is nil or a callable
#       invoked exactly like the C xmlRegExecCallbacks:
#       callback.call(data, token, transdata, inputdata), where +data+ is the third argument
#       given here (xmlschemas.c passes the validation context), +token+ the matched atom's
#       string, +transdata+ the +data+ given when the transition was created and +inputdata+
#       the +data+ passed to reg_exec_push_string(2).
#   reg_free_exec_ctxt(exec)                           -> no-op
#   reg_exec_push_string(exec, value, data)            -> 1 final state reached, 0 not final,
#                                                         < 0 error (-1 = not found). value nil
#                                                         = end of input.
#   reg_exec_push_string2(exec, value, value2, data)   -> same (value2 = namespace; the pushed
#                                                         token is "value|value2")
#   reg_exec_next_values(exec, maxval)  -> [ret, nbval, nbneg, values, terminal]
#   reg_exec_err_info(exec, maxval)     -> [ret, string, nbval, nbneg, values, terminal]
#       +maxval+ is the C *nbval input capacity (xmlschemas.c passes 10). +values+ is an Array
#       of nbval + nbneg Strings exactly as the C array (accepted values first, then the
#       negative ones). ret is 0 or -1. +terminal+ is 1/0 (nil when C would leave it unset).
#       +string+ is the token that failed (nil unless the exec status is an error).
#
# Everything else (fa_parse_reg_exp, fa_eliminate_epsilon_transitions, fa_computes_determinism,
# reg_epx_from_parse, fa_reg_exec, reg_exec_push_string_internal, reg_compact_push_string,
# reg_exec_get_values, ...) is kept with the C structure for reference; names follow
# test-pure/schema/c_names.txt.

require_relative "errors"
require_relative "parser/codes"
require_relative "xmlregexp/unicode"

module Nokogiri
  module Pure
    module XmlRegexp
      extend self

      MAX_PUSH = 10_000_000
      MAX_ITEMS = 1_000_000_000
      INT_MAX = 2_147_483_647
      XML_REG_STRING_SEPARATOR = 0x7C # '|'

      # xmlRegAtomType (the order is significant)
      XML_REGEXP_EPSILON = 1
      XML_REGEXP_CHARVAL = 2
      XML_REGEXP_RANGES = 3
      XML_REGEXP_SUBREG = 4
      XML_REGEXP_STRING = 5
      XML_REGEXP_ANYCHAR = 6
      XML_REGEXP_ANYSPACE = 7
      XML_REGEXP_NOTSPACE = 8
      XML_REGEXP_INITNAME = 9
      XML_REGEXP_NOTINITNAME = 10
      XML_REGEXP_NAMECHAR = 11
      XML_REGEXP_NOTNAMECHAR = 12
      XML_REGEXP_DECIMAL = 13
      XML_REGEXP_NOTDECIMAL = 14
      XML_REGEXP_REALCHAR = 15
      XML_REGEXP_NOTREALCHAR = 16
      XML_REGEXP_LETTER = 100
      XML_REGEXP_LETTER_UPPERCASE = 101
      XML_REGEXP_LETTER_LOWERCASE = 102
      XML_REGEXP_LETTER_TITLECASE = 103
      XML_REGEXP_LETTER_MODIFIER = 104
      XML_REGEXP_LETTER_OTHERS = 105
      XML_REGEXP_MARK = 106
      XML_REGEXP_MARK_NONSPACING = 107
      XML_REGEXP_MARK_SPACECOMBINING = 108
      XML_REGEXP_MARK_ENCLOSING = 109
      XML_REGEXP_NUMBER = 110
      XML_REGEXP_NUMBER_DECIMAL = 111
      XML_REGEXP_NUMBER_LETTER = 112
      XML_REGEXP_NUMBER_OTHERS = 113
      XML_REGEXP_PUNCT = 114
      XML_REGEXP_PUNCT_CONNECTOR = 115
      XML_REGEXP_PUNCT_DASH = 116
      XML_REGEXP_PUNCT_OPEN = 117
      XML_REGEXP_PUNCT_CLOSE = 118
      XML_REGEXP_PUNCT_INITQUOTE = 119
      XML_REGEXP_PUNCT_FINQUOTE = 120
      XML_REGEXP_PUNCT_OTHERS = 121
      XML_REGEXP_SEPAR = 122
      XML_REGEXP_SEPAR_SPACE = 123
      XML_REGEXP_SEPAR_LINE = 124
      XML_REGEXP_SEPAR_PARA = 125
      XML_REGEXP_SYMBOL = 126
      XML_REGEXP_SYMBOL_MATH = 127
      XML_REGEXP_SYMBOL_CURRENCY = 128
      XML_REGEXP_SYMBOL_MODIFIER = 129
      XML_REGEXP_SYMBOL_OTHERS = 130
      XML_REGEXP_OTHER = 131
      XML_REGEXP_OTHER_CONTROL = 132
      XML_REGEXP_OTHER_FORMAT = 133
      XML_REGEXP_OTHER_PRIVATE = 134
      XML_REGEXP_OTHER_NA = 135
      XML_REGEXP_BLOCK_NAME = 136

      # xmlRegQuantType
      XML_REGEXP_QUANT_EPSILON = 1
      XML_REGEXP_QUANT_ONCE = 2
      XML_REGEXP_QUANT_OPT = 3
      XML_REGEXP_QUANT_MULT = 4
      XML_REGEXP_QUANT_PLUS = 5
      XML_REGEXP_QUANT_ONCEONLY = 6
      XML_REGEXP_QUANT_ALL = 7
      XML_REGEXP_QUANT_RANGE = 8

      # xmlRegStateType
      XML_REGEXP_START_STATE = 1
      XML_REGEXP_FINAL_STATE = 2
      XML_REGEXP_TRANS_STATE = 3
      XML_REGEXP_SINK_STATE = 4
      XML_REGEXP_UNREACH_STATE = 5

      # xmlRegMarkedType
      XML_REGEXP_MARK_NORMAL = 0
      XML_REGEXP_MARK_START = 1
      XML_REGEXP_MARK_VISITED = 2

      AM_AUTOMATA_RNG = 1

      REGEXP_ALL_COUNTER = 0x123456
      REGEXP_ALL_LAX_COUNTER = 0x123457

      # private/regexp.h
      XML_REGEXP_OK = 0
      XML_REGEXP_NOT_FOUND = -1
      XML_REGEXP_INTERNAL_ERROR = -4
      XML_REGEXP_OUT_OF_MEMORY = -5
      XML_REGEXP_INTERNAL_LIMIT = -6
      XML_REGEXP_INVALID_UTF8 = -7

      # xmlRegRange
      class Range
        attr_accessor :neg, :type, :start, :end, :block_name

        def initialize(neg, type, start, end_)
          @neg = neg
          @type = type
          @start = start
          @end = end_
          @block_name = nil
        end
      end

      # xmlRegAtom (ranges: Array or nil; nb_ranges = ranges.size)
      class Atom
        attr_accessor :no, :type, :quant, :min, :max, :valuep, :valuep2, :neg, :codepoint,
          :start, :start0, :stop, :ranges, :data

        def initialize(type)
          @no = 0
          @type = type
          @quant = XML_REGEXP_QUANT_ONCE
          @min = 0
          @max = 0
          @valuep = nil
          @valuep2 = nil
          @neg = 0
          @codepoint = 0
          @start = nil
          @start0 = nil
          @stop = nil
          @ranges = nil
          @data = nil
        end

        def nb_ranges = @ranges ? @ranges.size : 0
      end

      # xmlRegCounter
      class Counter
        attr_accessor :min, :max

        def initialize(min, max)
          @min = min
          @max = max
        end
      end

      # xmlRegTrans
      class Trans
        attr_accessor :atom, :to, :counter, :count, :nd

        def initialize(atom, to, counter, count)
          @atom = atom
          @to = to
          @counter = counter
          @count = count
          @nd = 0
        end
      end

      # xmlAutomataState / xmlRegState (trans: Array of Trans, trans_to: Array of Integer)
      class State
        attr_accessor :type, :mark, :markd, :reached, :no, :trans, :trans_to

        def initialize
          @type = XML_REGEXP_TRANS_STATE
          @mark = XML_REGEXP_MARK_NORMAL
          @markd = XML_REGEXP_MARK_NORMAL
          @reached = XML_REGEXP_MARK_NORMAL
          @no = 0
          @trans = []
          @trans_to = []
        end

        def nb_trans = @trans.size

        def inspect = "#<XmlRegexp::State #{@no} type=#{@type} trans=#{@trans.size}>"
      end

      # xmlRegParserCtxt == xmlAutomata. +string+ is the regexp as a binary String (nil for
      # automata), +cur+ the byte offset into it.
      class ParserCtxt
        attr_accessor :string, :cur, :error, :neg, :start, :end, :state, :atom, :atoms, :states,
          :counters, :determinist, :negs, :flags, :depth

        def initialize
          @string = nil
          @cur = 0
          @error = 0
          @neg = 0
          @start = nil
          @end = nil
          @state = nil
          @atom = nil
          @atoms = []
          @states = []
          @counters = []
          @determinist = -1
          @negs = 0
          @flags = 0
          @depth = 0
        end

        def nb_states = @states.size
        def nb_atoms = @atoms.size
        def nb_counters = @counters.size

        def inspect = "#<XmlRegexp::ParserCtxt states=#{@states.size} atoms=#{@atoms.size}>"
      end
      Automata = ParserCtxt

      # xmlRegexp. After compaction (deterministic string automata) states/atoms are nil and
      # compact/string_map/transdata are set.
      class Regexp
        attr_accessor :string, :states, :atoms, :counters, :determinist, :flags, :nbstates,
          :compact, :transdata, :nbstrings, :string_map

        def initialize
          @string = nil
          @states = nil
          @atoms = nil
          @counters = []
          @determinist = -1
          @flags = 0
          @nbstates = 0
          @compact = nil
          @transdata = nil
          @nbstrings = 0
          @string_map = nil
        end

        def nb_states = @states ? @states.size : 0
        def nb_atoms = @atoms ? @atoms.size : 0
        def nb_counters = @counters ? @counters.size : 0

        def inspect = "#<XmlRegexp::Regexp #{@string.inspect} states=#{nb_states} compact=#{!@compact.nil?}>"
      end

      # xmlRegExecRollback
      class Rollback
        attr_accessor :state, :index, :nextbranch, :counts

        def initialize
          @state = nil
          @index = 0
          @nextbranch = 0
          @counts = nil
        end
      end

      # xmlRegExecCtxt. input_stack/input_data are the xmlRegInputToken array (nil until the
      # first save); input_string is the codepoint Array used by fa_reg_exec.
      class ExecCtxt
        attr_accessor :status, :determinist, :comp, :callback, :data, :state, :transno,
          :transcount, :rollbacks, :nb_rollbacks, :counts, :input_stack, :input_data,
          :input_stack_nr, :index, :input_string, :err_state_no, :err_state, :err_string,
          :err_counts, :nb_push

        def initialize
          @status = XML_REGEXP_OK
          @determinist = 1
          @comp = nil
          @callback = nil
          @data = nil
          @state = nil
          @transno = 0
          @transcount = 0
          @rollbacks = []
          @nb_rollbacks = 0
          @counts = nil
          @input_stack = nil
          @input_data = nil
          @input_stack_nr = 0
          @index = 0
          @input_string = nil
          @err_state_no = -1
          @err_state = nil
          @err_string = nil
          @err_counts = nil
          @nb_push = 0
        end

        def inspect = "#<XmlRegexp::ExecCtxt status=#{@status} index=#{@index}>"
      end

      # ------------------------------------------------------------------
      # helpers
      # ------------------------------------------------------------------

      # C logical not on an int
      def c_not(v) = v == 0 ? 1 : 0

      # xmlGetUTF8Char on a binary String at byte offset +pos+ (NUL beyond the end).
      # Returns [codepoint, len] or [-1, 0].
      def get_utf8_char(str, pos)
        c = str.getbyte(pos) || 0
        return [c, 1] if c < 0x80

        c1 = str.getbyte(pos + 1) || 0
        return [-1, 0] if (c1 & 0xc0) != 0x80

        if c < 0xe0
          return [-1, 0] if c < 0xc2

          return [((c & 0x1f) << 6) | (c1 & 0x3f), 2]
        end
        c2 = str.getbyte(pos + 2) || 0
        return [-1, 0] if (c2 & 0xc0) != 0x80

        if c < 0xf0
          v = ((c & 0xf) << 12) | ((c1 & 0x3f) << 6) | (c2 & 0x3f)
          return [-1, 0] if v < 0x800 || (v >= 0xd800 && v < 0xe000)

          return [v, 3]
        end
        c3 = str.getbyte(pos + 3) || 0
        return [-1, 0] if (c3 & 0xc0) != 0x80

        v = ((c & 0x7) << 18) | ((c1 & 0x3f) << 12) | ((c2 & 0x3f) << 6) | (c3 & 0x3f)
        return [-1, 0] if v < 0x10000 || v >= 0x110000

        [v, 4]
      end

      # Decode +content+ the way the C engine walks it with xmlGetUTF8Char: an Array of
      # codepoints terminated by 0 (the C NUL). An undecodable sequence becomes -1 (decoding it
      # fails, like the C) and the input is cut at an embedded NUL.
      def input_codepoints(content)
        s = content
        s = s.byteslice(0, s.index("\0")) if s.include?("\0")
        u = s.encoding == ::Encoding::UTF_8 ? s : s.dup.force_encoding(::Encoding::UTF_8)
        if u.valid_encoding?
          cps = u.unpack("U*")
          cps << 0
          return cps
        end
        b = s.b
        cps = []
        pos = 0
        n = b.bytesize
        while pos < n
          c, len = get_utf8_char(b, pos)
          if c < 0
            cps << -1
            break
          end
          cps << c
          pos += len
        end
        cps << 0
        cps
      end

      # binary search in a flat sorted [lo, hi, lo, hi, ...] table
      def in_table(tbl, c)
        low = 0
        high = (tbl.size >> 1) - 1
        while low <= high
          mid = (low + high) >> 1
          if c < tbl[mid << 1]
            high = mid - 1
          elsif c > tbl[(mid << 1) + 1]
            low = mid + 1
          else
            return 1
          end
        end
        0
      end

      BLOCK_TABLE = Unicode::BLOCKS.to_h { |name, ranges| [name, ranges] }.freeze

      # xmlUCSIsBlock: 1 / 0, -1 for an unknown block name
      def ucs_is_block(code, block)
        tbl = BLOCK_TABLE[block]
        return -1 if tbl.nil?

        in_table(tbl, code)
      end

      # IS_CHAR (xmlIsCharQ)
      def is_char(c)
        if c < 0x100
          (c >= 0x20 || c == 0x9 || c == 0xa || c == 0xd) ? true : false
        else
          (c <= 0xd7ff) || (c >= 0xe000 && c <= 0xfffd) || (c >= 0x10000 && c <= 0x10ffff)
        end
      end

      # IS_LETTER = IS_BASECHAR || IS_IDEOGRAPHIC
      def is_letter(c)
        in_table(Unicode::BASE_CHAR, c) == 1 || (c >= 0x100 && in_table(Unicode::IDEOGRAPHIC, c) == 1)
      end

      def is_digit(c) = in_table(Unicode::DIGIT, c) == 1
      def is_combining(c) = c >= 0x100 && in_table(Unicode::COMBINING, c) == 1
      def is_extender(c) = in_table(Unicode::EXTENDER, c) == 1

      # ------------------------------------------------------------------
      # Regexp memory / error handlers
      # ------------------------------------------------------------------

      # xmlRegexpErrMemory
      def regexp_err_memory(ctxt)
        ctxt.error = ErrCode::ERR_NO_MEMORY if ctxt
      end

      # xmlRegexpErrCompile
      def regexp_err_compile(ctxt, extra)
        regexp = nil
        idx = 0
        if ctxt
          regexp = ctxt.string&.dup&.force_encoding(::Encoding::UTF_8)
          idx = ctxt.cur
          ctxt.error = ErrCode::REGEXP_COMPILE_ERROR
        end
        err = XmlError.new(domain: Domain::REGEXP, code: ErrCode::REGEXP_COMPILE_ERROR,
          message: "failed to compile: #{extra}\n", level: Level::FATAL, file: nil, line: 0,
          str1: extra, str2: regexp, str3: nil, int1: idx, int2: 0, node: nil)
        Errors.report(err)
      end

      # the ERROR(str) macro
      def reg_error(ctxt, str)
        ctxt.error = ErrCode::REGEXP_COMPILE_ERROR
        regexp_err_compile(ctxt, str)
      end

      # ------------------------------------------------------------------
      # Allocation
      # ------------------------------------------------------------------

      # xmlRegEpxFromParse
      def reg_epx_from_parse(ctxt)
        ret = Regexp.new
        ret.string = ctxt.string_utf8
        ret.states = ctxt.states
        ret.atoms = ctxt.atoms
        ret.counters = ctxt.counters
        ret.determinist = ctxt.determinist
        ret.flags = ctxt.flags
        return nil if ret.determinist == -1 && regexp_is_determinist(ret) < 0

        catch(:not_determ) do
          atoms = ret.atoms
          if ret.determinist != 0 && ret.counters.empty? && ctxt.negs == 0 &&
              !atoms.empty? && atoms[0] && atoms[0].type == XML_REGEXP_STRING
            # Switch to a compact representation
            states = ret.states
            nb = states.size
            state_remap = Array.new(nb)
            nbstates = 0
            nb.times do |i|
              if states[i]
                state_remap[i] = nbstates
                nbstates += 1
              else
                state_remap[i] = -1
              end
            end
            string_map = []
            string_remap = Array.new(atoms.size)
            atoms.each_with_index do |atom, i|
              if atom.type == XML_REGEXP_STRING && atom.quant == XML_REGEXP_QUANT_ONCE
                value = atom.valuep
                j = string_map.index(value)
                if j
                  string_remap[i] = j
                else
                  string_remap[i] = string_map.size
                  string_map << value.dup
                end
              else
                return nil
              end
            end
            nbatoms = string_map.size
            stride = nbatoms + 1
            transitions = Array.new((nbstates + 1) * stride, 0)
            transdata = nil
            nb.times do |i|
              stateno = state_remap[i]
              next if stateno == -1

              state = states[i]
              transitions[stateno * stride] = state.type
              state.trans.each do |trans|
                next if trans.to < 0 || trans.atom.nil?

                atomno = string_remap[trans.atom.no]
                transdata = Array.new(nbstates * nbatoms) if !trans.atom.data.nil? && transdata.nil?
                targetno = state_remap[trans.to]
                # if the same atom can generate transitions to 2 different states then it
                # means the automata is not deterministic and the compact form can't be used
                prev = transitions[stateno * stride + atomno + 1]
                if prev != 0
                  if prev != targetno + 1
                    ret.determinist = 0
                    throw :not_determ
                  end
                else
                  transitions[stateno * stride + atomno + 1] = targetno + 1 # to avoid 0
                  transdata[stateno * nbatoms + atomno] = trans.atom.data if transdata
                end
              end
            end
            ret.determinist = 1
            ret.states = nil
            ret.atoms = nil
            ret.compact = transitions
            ret.transdata = transdata
            ret.string_map = string_map
            ret.nbstrings = nbatoms
            ret.nbstates = nbstates
          end
        end
        ctxt.string = nil
        ctxt.states = []
        ctxt.atoms = []
        ctxt.counters = []
        ret
      end

      # xmlRegNewParserCtxt
      def reg_new_parser_ctxt(string)
        ret = ParserCtxt.new
        unless string.nil?
          s = string.b
          nul = s.index("\0")
          s = s.byteslice(0, nul) if nul
          ret.string = s
        end
        ret.cur = 0
        ret.neg = 0
        ret.negs = 0
        ret.error = 0
        ret.determinist = -1
        ret
      end

      class ParserCtxt
        def string_utf8
          @string && @string.dup.force_encoding(::Encoding::UTF_8)
        end
      end

      # xmlRegNewRange
      def reg_new_range(ctxt, neg, type, start, end_)
        Range.new(neg, type, start, end_)
      end

      # xmlRegFreeRange
      def reg_free_range(range); end

      # xmlRegCopyRange
      def reg_copy_range(ctxt, range)
        return nil if range.nil?

        ret = reg_new_range(ctxt, range.neg, range.type, range.start, range.end)
        ret.block_name = range.block_name.dup if range.block_name
        ret
      end

      # xmlRegNewAtom
      def reg_new_atom(ctxt, type)
        Atom.new(type)
      end

      # xmlRegFreeAtom
      def reg_free_atom(atom); end

      # xmlRegCopyAtom
      def reg_copy_atom(ctxt, atom)
        ret = Atom.new(atom.type)
        ret.quant = atom.quant
        ret.min = atom.min
        ret.max = atom.max
        ret.ranges = atom.ranges.map { |r| reg_copy_range(ctxt, r) } if atom.nb_ranges > 0
        ret
      end

      # xmlRegNewState
      def reg_new_state(ctxt)
        State.new
      end

      # xmlRegFreeState
      def reg_free_state(state); end

      # xmlRegFreeParserCtxt
      def reg_free_parser_ctxt(ctxt); end

      # ------------------------------------------------------------------
      # Finite Automata structures manipulations
      # ------------------------------------------------------------------

      # xmlRegAtomAddRange
      def reg_atom_add_range(ctxt, atom, neg, type, start, end_, block_name)
        if atom.nil?
          reg_error(ctxt, "add range: atom is NULL")
          return nil
        end
        if atom.type != XML_REGEXP_RANGES
          reg_error(ctxt, "add range: atom is not ranges")
          return nil
        end
        atom.ranges ||= []
        range = reg_new_range(ctxt, neg, type, start, end_)
        range.block_name = block_name
        atom.ranges << range
        range
      end

      # xmlRegGetCounter
      def reg_get_counter(ctxt)
        ctxt.counters << Counter.new(-1, -1)
        ctxt.counters.size - 1
      end

      # xmlRegAtomPush
      def reg_atom_push(ctxt, atom)
        if atom.nil?
          reg_error(ctxt, "atom push: atom is NULL")
          return -1
        end
        atom.no = ctxt.atoms.size
        ctxt.atoms << atom
        0
      end

      # xmlRegStateAddTransTo
      def reg_state_add_trans_to(ctxt, target, from)
        target.trans_to << from
      end

      # xmlRegStateAddTrans
      def reg_state_add_trans(ctxt, state, atom, target, counter, count)
        if state.nil?
          reg_error(ctxt, "add state: state is NULL")
          return
        end
        if target.nil?
          reg_error(ctxt, "add state: target is NULL")
          return
        end
        # Other routines follow the philosophy 'When in doubt, add a transition' so we check
        # here whether such a transition is already present and, if so, silently ignore it.
        trans = state.trans
        target_no = target.no
        nrtrans = trans.size - 1
        while nrtrans >= 0
          t = trans[nrtrans]
          return if t.atom.equal?(atom) && t.to == target_no && t.counter == counter && t.count == count

          nrtrans -= 1
        end
        trans << Trans.new(atom, target_no, counter, count)
        reg_state_add_trans_to(ctxt, target, state.no)
      end

      # xmlRegStatePush
      def reg_state_push(ctxt)
        state = reg_new_state(ctxt)
        state.no = ctxt.states.size
        ctxt.states << state
        state
      end

      # xmlFAGenerateAllTransition
      def fa_generate_all_transition(ctxt, from, to, lax)
        if to.nil?
          to = reg_state_push(ctxt)
          ctxt.state = to
        end
        if lax != 0 && lax
          reg_state_add_trans(ctxt, from, nil, to, -1, REGEXP_ALL_LAX_COUNTER)
        else
          reg_state_add_trans(ctxt, from, nil, to, -1, REGEXP_ALL_COUNTER)
        end
        0
      end

      # xmlFAGenerateEpsilonTransition
      def fa_generate_epsilon_transition(ctxt, from, to)
        if to.nil?
          to = reg_state_push(ctxt)
          ctxt.state = to
        end
        reg_state_add_trans(ctxt, from, nil, to, -1, -1)
        0
      end

      # xmlFAGenerateCountedEpsilonTransition
      def fa_generate_counted_epsilon_transition(ctxt, from, to, counter)
        if to.nil?
          to = reg_state_push(ctxt)
          ctxt.state = to
        end
        reg_state_add_trans(ctxt, from, nil, to, counter, -1)
        0
      end

      # xmlFAGenerateCountedTransition
      def fa_generate_counted_transition(ctxt, from, to, counter)
        if to.nil?
          to = reg_state_push(ctxt)
          ctxt.state = to
        end
        reg_state_add_trans(ctxt, from, nil, to, -1, counter)
        0
      end

      # xmlFAGenerateTransitions
      def fa_generate_transitions(ctxt, from, to, atom)
        nullable = false
        if atom.nil?
          reg_error(ctxt, "generate transition: atom == NULL")
          return -1
        end
        if atom.type == XML_REGEXP_SUBREG
          # this is a subexpression handling one should not need to create a new node except
          # for XML_REGEXP_QUANT_RANGE.
          if to && !atom.stop.equal?(to) && atom.quant != XML_REGEXP_QUANT_RANGE
            # Generate an epsilon transition to link to the target
            fa_generate_epsilon_transition(ctxt, atom.stop, to)
          end
          case atom.quant
          when XML_REGEXP_QUANT_OPT
            atom.quant = XML_REGEXP_QUANT_ONCE
            # transition done to the state after end of atom.
            #      1. set transition from atom start to new state
            #      2. set transition from atom end to this state.
            if to.nil?
              fa_generate_epsilon_transition(ctxt, atom.start, nil)
              fa_generate_epsilon_transition(ctxt, atom.stop, ctxt.state)
            else
              fa_generate_epsilon_transition(ctxt, atom.start, to)
            end
          when XML_REGEXP_QUANT_MULT
            atom.quant = XML_REGEXP_QUANT_ONCE
            fa_generate_epsilon_transition(ctxt, atom.start, atom.stop)
            fa_generate_epsilon_transition(ctxt, atom.stop, atom.start)
          when XML_REGEXP_QUANT_PLUS
            atom.quant = XML_REGEXP_QUANT_ONCE
            fa_generate_epsilon_transition(ctxt, atom.stop, atom.start)
          when XML_REGEXP_QUANT_RANGE
            # create the final state now if needed
            newstate = to || reg_state_push(ctxt)
            # The principle here is to use counted transition to avoid explosion in the
            # number of states in the graph.
            if atom.min == 0 && atom.start0.nil?
              # duplicate a transition based on atom to count next occurrences after 1.
              copy = reg_copy_atom(ctxt, atom)
              copy.quant = XML_REGEXP_QUANT_ONCE
              copy.min = 0
              copy.max = 0
              return -1 if fa_generate_transitions(ctxt, atom.start, nil, copy) < 0

              inter = ctxt.state
              counter = reg_get_counter(ctxt)
              ctxt.counters[counter].min = atom.min - 1
              ctxt.counters[counter].max = atom.max - 1
              # count the number of times we see it again
              fa_generate_counted_epsilon_transition(ctxt, inter, atom.stop, counter)
              # allow a way out based on the count
              fa_generate_counted_transition(ctxt, inter, newstate, counter)
              # and also allow a direct exit for 0
              fa_generate_epsilon_transition(ctxt, atom.start, newstate)
            else
              # either we need the atom at least once or there is an atom->start0 allowing
              # to easily plug the epsilon transition.
              counter = reg_get_counter(ctxt)
              ctxt.counters[counter].min = atom.min - 1
              ctxt.counters[counter].max = atom.max - 1
              # allow a way out based on the count
              fa_generate_counted_transition(ctxt, atom.stop, newstate, counter)
              # count the number of times we see it again
              fa_generate_counted_epsilon_transition(ctxt, atom.stop, atom.start, counter)
              # and if needed allow a direct exit for 0
              fa_generate_epsilon_transition(ctxt, atom.start0, newstate) if atom.min == 0
            end
            atom.min = 0
            atom.max = 0
            atom.quant = XML_REGEXP_QUANT_ONCE
            ctxt.state = newstate
          end
          return -1 if reg_atom_push(ctxt, atom) < 0

          return 0
        end
        if atom.min == 0 && atom.max == 0 && atom.quant == XML_REGEXP_QUANT_RANGE
          # we can discard the atom and generate an epsilon transition instead
          to = reg_state_push(ctxt) if to.nil?
          fa_generate_epsilon_transition(ctxt, from, to)
          ctxt.state = to
          reg_free_atom(atom)
          return 0
        end
        to = reg_state_push(ctxt) if to.nil?
        end_ = to
        if atom.quant == XML_REGEXP_QUANT_MULT || atom.quant == XML_REGEXP_QUANT_PLUS
          # Do not pollute the target state by adding transitions from it as it is likely to
          # be the shared target of multiple branches. So isolate with an epsilon transition.
          tmp = reg_state_push(ctxt)
          fa_generate_epsilon_transition(ctxt, tmp, to)
          to = tmp
        end
        if atom.quant == XML_REGEXP_QUANT_RANGE && atom.min == 0 && atom.max > 0
          nullable = true
          atom.min = 1
          atom.quant = XML_REGEXP_QUANT_OPT if atom.max == 1
        end
        reg_state_add_trans(ctxt, from, atom, to, -1, -1)
        ctxt.state = end_
        case atom.quant
        when XML_REGEXP_QUANT_OPT
          atom.quant = XML_REGEXP_QUANT_ONCE
          fa_generate_epsilon_transition(ctxt, from, to)
        when XML_REGEXP_QUANT_MULT
          atom.quant = XML_REGEXP_QUANT_ONCE
          fa_generate_epsilon_transition(ctxt, from, to)
          reg_state_add_trans(ctxt, to, atom, to, -1, -1)
        when XML_REGEXP_QUANT_PLUS
          atom.quant = XML_REGEXP_QUANT_ONCE
          reg_state_add_trans(ctxt, to, atom, to, -1, -1)
        when XML_REGEXP_QUANT_RANGE
          fa_generate_epsilon_transition(ctxt, from, to) if nullable
        end
        return -1 if reg_atom_push(ctxt, atom) < 0

        0
      end

      # xmlFAReduceEpsilonTransitions
      def fa_reduce_epsilon_transitions(ctxt, fromnr, tonr, counter)
        states = ctxt.states
        from = states[fromnr]
        return if from.nil?

        to = states[tonr]
        return if to.nil?
        return if to.mark == XML_REGEXP_MARK_START || to.mark == XML_REGEXP_MARK_VISITED

        to.mark = XML_REGEXP_MARK_VISITED
        from.type = XML_REGEXP_FINAL_STATE if to.type == XML_REGEXP_FINAL_STATE
        trans = to.trans
        transnr = 0
        while transnr < trans.size
          t1 = trans[transnr]
          transnr += 1
          next if t1.to < 0

          tcounter = t1.counter >= 0 ? t1.counter : counter
          if t1.atom.nil?
            # Don't remove counted transitions, don't loop either
            if t1.to != fromnr
              if t1.count >= 0
                reg_state_add_trans(ctxt, from, nil, states[t1.to], -1, t1.count)
              else
                fa_reduce_epsilon_transitions(ctxt, fromnr, t1.to, tcounter)
              end
            end
          else
            reg_state_add_trans(ctxt, from, t1.atom, states[t1.to], tcounter, -1)
          end
        end
      end

      # xmlFAFinishReduceEpsilonTransitions
      def fa_finish_reduce_epsilon_transitions(ctxt, tonr)
        to = ctxt.states[tonr]
        return if to.nil?
        return if to.mark == XML_REGEXP_MARK_START || to.mark == XML_REGEXP_MARK_NORMAL

        to.mark = XML_REGEXP_MARK_NORMAL
        trans = to.trans
        transnr = 0
        while transnr < trans.size
          t1 = trans[transnr]
          transnr += 1
          fa_finish_reduce_epsilon_transitions(ctxt, t1.to) if t1.to >= 0 && t1.atom.nil?
        end
      end

      # xmlFAEliminateSimpleEpsilonTransitions
      def fa_eliminate_simple_epsilon_transitions(ctxt)
        states = ctxt.states
        statenr = 0
        while statenr < states.size
          state = states[statenr]
          if state.nil? || state.trans.size != 1 ||
              state.type == XML_REGEXP_UNREACH_STATE || state.type == XML_REGEXP_FINAL_STATE
            statenr += 1
            next
          end
          t0 = state.trans[0]
          # is the only transition out a basic transition
          if t0.atom.nil? && t0.to >= 0 && t0.to != statenr && t0.counter < 0 && t0.count < 0
            newto = t0.to
            if state.type != XML_REGEXP_START_STATE
              i = 0
              while i < state.trans_to.size
                tmp = states[state.trans_to[i]]
                j = 0
                while j < tmp.trans.size
                  tj = tmp.trans[j]
                  if tj.to == statenr
                    tj.to = -1
                    reg_state_add_trans(ctxt, tmp, tj.atom, states[newto], tj.counter, tj.count)
                  end
                  j += 1
                end
                i += 1
              end
              states[newto].type = XML_REGEXP_FINAL_STATE if state.type == XML_REGEXP_FINAL_STATE
              # eliminate the transition completely
              state.trans.clear
              state.type = XML_REGEXP_UNREACH_STATE
            end
          end
          statenr += 1
        end
      end

      # xmlFAEliminateEpsilonTransitions
      def fa_eliminate_epsilon_transitions(ctxt)
        states = ctxt.states
        return if states.empty?

        # Eliminate simple epsilon transition and the associated unreachable states.
        fa_eliminate_simple_epsilon_transitions(ctxt)
        states.each_index do |statenr|
          state = states[statenr]
          states[statenr] = nil if state && state.type == XML_REGEXP_UNREACH_STATE
        end

        has_epsilon = false

        # Build the completed transitions bypassing the epsilons. Use a marking algorithm to
        # avoid loops. Mark sink states too. Process from the latest states backward to the
        # start.
        statenr = states.size - 1
        while statenr >= 0
          state = states[statenr]
          if state
            state.type = XML_REGEXP_SINK_STATE if state.trans.empty? && state.type != XML_REGEXP_FINAL_STATE
            transnr = 0
            while transnr < state.trans.size
              t = state.trans[transnr]
              if t.atom.nil? && t.to >= 0
                if t.to == statenr
                  t.to = -1
                elsif t.count < 0
                  newto = t.to
                  has_epsilon = true
                  t.to = -2
                  state.mark = XML_REGEXP_MARK_START
                  fa_reduce_epsilon_transitions(ctxt, statenr, newto, t.counter)
                  fa_finish_reduce_epsilon_transitions(ctxt, newto)
                  state.mark = XML_REGEXP_MARK_NORMAL
                end
              end
              transnr += 1
            end
          end
          statenr -= 1
        end

        # Eliminate the epsilon transitions
        if has_epsilon
          states.each do |st|
            next if st.nil?

            st.trans.each do |trans|
              trans.to = -1 if trans.atom.nil? && trans.count < 0 && trans.to >= 0
            end
          end
        end

        # Use this pass to detect unreachable states too
        states.each { |st| st.reached = XML_REGEXP_MARK_NORMAL if st }
        state = states[0]
        state.reached = XML_REGEXP_MARK_START if state
        while state
          target = nil
          state.reached = XML_REGEXP_MARK_VISITED
          # Mark all states reachable from the current reachable state
          state.trans.each do |t|
            next unless t.to >= 0 && (t.atom || t.count >= 0)

            newto = t.to
            ns = states[newto]
            next if ns.nil?

            if ns.reached == XML_REGEXP_MARK_NORMAL
              ns.reached = XML_REGEXP_MARK_START
              target = ns
            end
          end
          # find the next accessible state not explored
          if target.nil?
            i = 1
            while i < states.size
              st = states[i]
              if st && st.reached == XML_REGEXP_MARK_START
                target = st
                break
              end
              i += 1
            end
          end
          state = target
        end
        states.each_index do |i|
          st = states[i]
          states[i] = nil if st && st.reached == XML_REGEXP_MARK_NORMAL
        end
      end

      # xmlFACompareRanges
      def fa_compare_ranges(range1, range2)
        ret = 0
        if range1.type == XML_REGEXP_RANGES || range2.type == XML_REGEXP_RANGES ||
            range2.type == XML_REGEXP_SUBREG || range1.type == XML_REGEXP_SUBREG ||
            range1.type == XML_REGEXP_STRING || range2.type == XML_REGEXP_STRING
          return -1
        end

        # put them in order
        range1, range2 = range2, range1 if range1.type > range2.type
        t1 = range1.type
        t2 = range2.type
        if t1 == XML_REGEXP_ANYCHAR || t2 == XML_REGEXP_ANYCHAR
          ret = 1
        elsif t1 == XML_REGEXP_EPSILON || t2 == XML_REGEXP_EPSILON
          return 0
        elsif t1 == t2
          ret = if t1 != XML_REGEXP_CHARVAL
            1
          elsif range1.end < range2.start || range2.end < range1.start
            0
          else
            1
          end
        elsif t1 == XML_REGEXP_CHARVAL
          neg = 0
          # just check all codepoints in the range for acceptance
          neg = 1 if (range1.neg == 0 && range2.neg != 0) || (range1.neg != 0 && range2.neg == 0)
          codepoint = range1.start
          while codepoint <= range1.end
            ret = reg_check_character_range(t2, codepoint, 0, range2.start, range2.end, range2.block_name)
            return -1 if ret < 0
            return 1 if (neg == 1 && ret == 0) || (neg == 0 && ret == 1)

            codepoint += 1
          end
          return 0
        elsif t1 == XML_REGEXP_BLOCK_NAME || t2 == XML_REGEXP_BLOCK_NAME
          if t1 == t2
            ret = range1.block_name == range2.block_name ? 1 : 0
          else
            # comparing a block range with anything else is way too costly
            return 1
          end
        elsif t1 < XML_REGEXP_LETTER || t2 < XML_REGEXP_LETTER
          if (t1 == XML_REGEXP_ANYSPACE && t2 == XML_REGEXP_NOTSPACE) ||
              (t1 == XML_REGEXP_INITNAME && t2 == XML_REGEXP_NOTINITNAME) ||
              (t1 == XML_REGEXP_NAMECHAR && t2 == XML_REGEXP_NOTNAMECHAR) ||
              (t1 == XML_REGEXP_DECIMAL && t2 == XML_REGEXP_NOTDECIMAL) ||
              (t1 == XML_REGEXP_REALCHAR && t2 == XML_REGEXP_NOTREALCHAR)
            ret = 0
          else
            # same thing to limit complexity
            return 1
          end
        else
          ret = 0
          # range1->type < range2->type here
          case t1
          when XML_REGEXP_LETTER
            # all disjoint except in the subgroups
            ret = 1 if t2 >= XML_REGEXP_LETTER_UPPERCASE && t2 <= XML_REGEXP_LETTER_OTHERS
          when XML_REGEXP_MARK
            ret = 1 if t2 >= XML_REGEXP_MARK_NONSPACING && t2 <= XML_REGEXP_MARK_ENCLOSING
          when XML_REGEXP_NUMBER
            ret = 1 if t2 >= XML_REGEXP_NUMBER_DECIMAL && t2 <= XML_REGEXP_NUMBER_OTHERS
          when XML_REGEXP_PUNCT
            ret = 1 if t2 >= XML_REGEXP_PUNCT_CONNECTOR && t2 <= XML_REGEXP_PUNCT_OTHERS
          when XML_REGEXP_SEPAR
            ret = 1 if t2 >= XML_REGEXP_SEPAR_SPACE && t2 <= XML_REGEXP_SEPAR_PARA
          when XML_REGEXP_SYMBOL
            ret = 1 if t2 >= XML_REGEXP_SYMBOL_MATH && t2 <= XML_REGEXP_SYMBOL_OTHERS
          when XML_REGEXP_OTHER
            ret = 1 if t2 >= XML_REGEXP_OTHER_CONTROL && t2 <= XML_REGEXP_OTHER_PRIVATE
          else
            if t2 >= XML_REGEXP_LETTER && t2 < XML_REGEXP_BLOCK_NAME
              ret = 0
            else
              # safety net !
              return 1
            end
          end
        end
        ret = c_not(ret) if (range1.neg == 0 && range2.neg != 0) || (range1.neg != 0 && range2.neg == 0)
        ret
      end

      # xmlFACompareAtomTypes
      def fa_compare_atom_types(type1, type2)
        return 1 if type1 <= XML_REGEXP_ANYCHAR # EPSILON CHARVAL RANGES SUBREG STRING ANYCHAR
        return 1 if type2 <= XML_REGEXP_ANYCHAR
        return 1 if type1 == type2

        # simplify subsequent compares by making sure type1 < type2
        type1, type2 = type2, type1 if type1 > type2
        case type1
        when XML_REGEXP_ANYSPACE # \s
          # can't be a letter, number, mark, punctuation, symbol
          return 0 if type2 == XML_REGEXP_NOTSPACE ||
            (type2 >= XML_REGEXP_LETTER && type2 <= XML_REGEXP_LETTER_OTHERS) ||
            (type2 >= XML_REGEXP_NUMBER && type2 <= XML_REGEXP_NUMBER_OTHERS) ||
            (type2 >= XML_REGEXP_MARK && type2 <= XML_REGEXP_MARK_ENCLOSING) ||
            (type2 >= XML_REGEXP_PUNCT && type2 <= XML_REGEXP_PUNCT_OTHERS) ||
            (type2 >= XML_REGEXP_SYMBOL && type2 <= XML_REGEXP_SYMBOL_OTHERS)
        when XML_REGEXP_NOTSPACE, XML_REGEXP_NOTINITNAME, XML_REGEXP_NOTNAMECHAR,
          XML_REGEXP_NOTDECIMAL, XML_REGEXP_NOTREALCHAR
          nil
        when XML_REGEXP_INITNAME # \l
          # can't be a number, mark, separator, punctuation, symbol or other
          return 0 if type2 == XML_REGEXP_NOTINITNAME ||
            (type2 >= XML_REGEXP_NUMBER && type2 <= XML_REGEXP_NUMBER_OTHERS) ||
            (type2 >= XML_REGEXP_MARK && type2 <= XML_REGEXP_MARK_ENCLOSING) ||
            (type2 >= XML_REGEXP_SEPAR && type2 <= XML_REGEXP_SEPAR_PARA) ||
            (type2 >= XML_REGEXP_PUNCT && type2 <= XML_REGEXP_PUNCT_OTHERS) ||
            (type2 >= XML_REGEXP_SYMBOL && type2 <= XML_REGEXP_SYMBOL_OTHERS) ||
            (type2 >= XML_REGEXP_OTHER && type2 <= XML_REGEXP_OTHER_NA)
        when XML_REGEXP_NAMECHAR # \c
          # can't be a mark, separator, punctuation, symbol or other
          return 0 if type2 == XML_REGEXP_NOTNAMECHAR ||
            (type2 >= XML_REGEXP_MARK && type2 <= XML_REGEXP_MARK_ENCLOSING) ||
            (type2 >= XML_REGEXP_PUNCT && type2 <= XML_REGEXP_PUNCT_OTHERS) ||
            (type2 >= XML_REGEXP_SEPAR && type2 <= XML_REGEXP_SEPAR_PARA) ||
            (type2 >= XML_REGEXP_SYMBOL && type2 <= XML_REGEXP_SYMBOL_OTHERS) ||
            (type2 >= XML_REGEXP_OTHER && type2 <= XML_REGEXP_OTHER_NA)
        when XML_REGEXP_DECIMAL # \d
          # can't be a letter, mark, separator, punctuation, symbol or other
          return 0 if type2 == XML_REGEXP_NOTDECIMAL ||
            type2 == XML_REGEXP_REALCHAR ||
            (type2 >= XML_REGEXP_LETTER && type2 <= XML_REGEXP_LETTER_OTHERS) ||
            (type2 >= XML_REGEXP_MARK && type2 <= XML_REGEXP_MARK_ENCLOSING) ||
            (type2 >= XML_REGEXP_PUNCT && type2 <= XML_REGEXP_PUNCT_OTHERS) ||
            (type2 >= XML_REGEXP_SEPAR && type2 <= XML_REGEXP_SEPAR_PARA) ||
            (type2 >= XML_REGEXP_SYMBOL && type2 <= XML_REGEXP_SYMBOL_OTHERS) ||
            (type2 >= XML_REGEXP_OTHER && type2 <= XML_REGEXP_OTHER_NA)
        when XML_REGEXP_REALCHAR # \w
          # can't be a mark, separator, punctuation, symbol or other
          return 0 if type2 == XML_REGEXP_NOTDECIMAL ||
            (type2 >= XML_REGEXP_MARK && type2 <= XML_REGEXP_MARK_ENCLOSING) ||
            (type2 >= XML_REGEXP_PUNCT && type2 <= XML_REGEXP_PUNCT_OTHERS) ||
            (type2 >= XML_REGEXP_SEPAR && type2 <= XML_REGEXP_SEPAR_PARA) ||
            (type2 >= XML_REGEXP_SYMBOL && type2 <= XML_REGEXP_SYMBOL_OTHERS) ||
            (type2 >= XML_REGEXP_OTHER && type2 <= XML_REGEXP_OTHER_NA)
        # at that point we know both type 1 and type2 are from character categories are
        # ordered and are different, it becomes simple because this is a partition
        when XML_REGEXP_LETTER
          return type2 <= XML_REGEXP_LETTER_OTHERS ? 1 : 0
        when XML_REGEXP_LETTER_UPPERCASE..XML_REGEXP_LETTER_OTHERS
          return 0
        when XML_REGEXP_MARK
          return type2 <= XML_REGEXP_MARK_ENCLOSING ? 1 : 0
        when XML_REGEXP_MARK_NONSPACING..XML_REGEXP_MARK_ENCLOSING
          return 0
        when XML_REGEXP_NUMBER
          return type2 <= XML_REGEXP_NUMBER_OTHERS ? 1 : 0
        when XML_REGEXP_NUMBER_DECIMAL..XML_REGEXP_NUMBER_OTHERS
          return 0
        when XML_REGEXP_PUNCT
          return type2 <= XML_REGEXP_PUNCT_OTHERS ? 1 : 0
        when XML_REGEXP_PUNCT_CONNECTOR..XML_REGEXP_PUNCT_OTHERS
          return 0
        when XML_REGEXP_SEPAR
          return type2 <= XML_REGEXP_SEPAR_PARA ? 1 : 0
        when XML_REGEXP_SEPAR_SPACE..XML_REGEXP_SEPAR_PARA
          return 0
        when XML_REGEXP_SYMBOL
          return type2 <= XML_REGEXP_SYMBOL_OTHERS ? 1 : 0
        when XML_REGEXP_SYMBOL_MATH..XML_REGEXP_SYMBOL_OTHERS
          return 0
        when XML_REGEXP_OTHER
          return type2 <= XML_REGEXP_OTHER_NA ? 1 : 0
        when XML_REGEXP_OTHER_CONTROL..XML_REGEXP_OTHER_NA
          return 0
        end
        1
      end

      # xmlFAEqualAtoms
      def fa_equal_atoms(atom1, atom2, deep)
        return 1 if atom1.equal?(atom2)
        return 0 if atom1.nil? || atom2.nil?
        return 0 if atom1.type != atom2.type

        case atom1.type
        when XML_REGEXP_STRING
          if deep == 0
            atom1.valuep.equal?(atom2.valuep) ? 1 : 0
          else
            atom1.valuep == atom2.valuep ? 1 : 0
          end
        when XML_REGEXP_CHARVAL
          atom1.codepoint == atom2.codepoint ? 1 : 0
        else
          0
        end
      end

      # xmlFACompareAtoms
      def fa_compare_atoms(atom1, atom2, deep)
        ret = 1
        return 1 if atom1.equal?(atom2)
        return 0 if atom1.nil? || atom2.nil?
        return 1 if atom1.type == XML_REGEXP_ANYCHAR || atom2.type == XML_REGEXP_ANYCHAR

        atom1, atom2 = atom2, atom1 if atom1.type > atom2.type
        if atom1.type != atom2.type
          ret = fa_compare_atom_types(atom1.type, atom2.type)
          # if they can't intersect at the type level break now
          return 0 if ret == 0
        end
        case atom1.type
        when XML_REGEXP_STRING
          if deep == 0
            ret = atom1.valuep.equal?(atom2.valuep) ? 0 : 1
          else
            val1 = atom1.valuep
            val2 = atom2.valuep
            compound1 = val1.include?("|")
            compound2 = val2.include?("|")
            # Ignore negative match flag for ##other namespaces
            return 0 if compound1 != compound2

            ret = reg_str_equal_wildcard(val1, val2)
          end
        when XML_REGEXP_EPSILON
          return 1 # not_determinist
        when XML_REGEXP_CHARVAL
          if atom2.type == XML_REGEXP_CHARVAL
            ret = atom1.codepoint == atom2.codepoint ? 1 : 0
          else
            ret = reg_check_character(atom2, atom1.codepoint)
            ret = 1 if ret < 0
          end
        when XML_REGEXP_RANGES
          if atom2.type == XML_REGEXP_RANGES
            # need to check that none of the ranges eventually matches
            ret = 0
            r1s = atom1.ranges || []
            r2s = atom2.ranges || []
            found = false
            r1s.each do |r1|
              r2s.each do |r2|
                if fa_compare_ranges(r1, r2) == 1
                  found = true
                  break
                end
              end
              break if found
            end
            ret = 1 if found
          end
        else
          return 1 # not_determinist
        end
        # done:
        ret = c_not(ret) if atom1.neg != atom2.neg
        return 0 if ret == 0

        1
      end

      # xmlFARecurseDeterminism
      def fa_recurse_determinism(ctxt, state, fromnr, tonr, atom)
        ret = 1
        deep = 1
        return ret if state.nil?
        return ret if state.markd == XML_REGEXP_MARK_VISITED

        deep = 0 if (ctxt.flags & AM_AUTOMATA_RNG) != 0

        # don't recurse on transitions potentially added in the course of the elimination.
        nb_trans = state.trans.size
        transnr = 0
        while transnr < nb_trans
          t1 = state.trans[transnr]
          transnr += 1
          # check transitions conflicting with the one looked at
          next if t1.to < 0 || t1.to == fromnr

          if t1.atom.nil?
            state.markd = XML_REGEXP_MARK_VISITED
            res = fa_recurse_determinism(ctxt, ctxt.states[t1.to], fromnr, tonr, atom)
            ret = 0 if res == 0
            next
          end
          if fa_compare_atoms(t1.atom, atom, deep) != 0
            # Treat equal transitions as deterministic.
            ret = 0 if t1.to != tonr || fa_equal_atoms(t1.atom, atom, deep) == 0
            # mark the transition as non-deterministic
            t1.nd = 1
          end
        end
        ret
      end

      # xmlFAFinishRecurseDeterminism
      def fa_finish_recurse_determinism(ctxt, state)
        return if state.nil?
        return if state.markd != XML_REGEXP_MARK_VISITED

        state.markd = 0
        nb_trans = state.trans.size
        transnr = 0
        while transnr < nb_trans
          t1 = state.trans[transnr]
          transnr += 1
          fa_finish_recurse_determinism(ctxt, ctxt.states[t1.to]) if t1.atom.nil? && t1.to >= 0
        end
      end

      # xmlFAComputesDeterminism
      def fa_computes_determinism(ctxt)
        ret = 1
        deep = 1
        return ctxt.determinist if ctxt.determinist != -1

        deep = 0 if (ctxt.flags & AM_AUTOMATA_RNG) != 0
        states = ctxt.states

        # First cleanup the automata removing cancelled transitions
        states.each do |state|
          next if state.nil?

          trans = state.trans
          next if trans.size < 2

          transnr = 0
          while transnr < trans.size
            t1 = trans[transnr]
            # Determinism checks in case of counted or all transitions will have to be
            # handled separately
            if t1.atom.nil? || t1.to < 0
              transnr += 1
              next
            end
            i = 0
            while i < transnr
              t2 = trans[i]
              i += 1
              next if t2.to < 0 # eliminated

              if t2.atom && t1.to == t2.to
                # Here we use deep because we want to keep the transitions which indicate a
                # conflict
                if fa_equal_atoms(t1.atom, t2.atom, deep) != 0 &&
                    t1.counter == t2.counter && t1.count == t2.count
                  t2.to = -1 # eliminated
                end
              end
            end
            transnr += 1
          end
        end

        # Check for all states that there aren't 2 transitions with the same atom and a
        # different target.
        states.each_with_index do |state, statenr|
          next if state.nil?

          trans = state.trans
          next if trans.size < 2

          last = nil
          transnr = 0
          while transnr < trans.size
            t1 = trans[transnr]
            if t1.atom.nil? || t1.to < 0
              transnr += 1
              next
            end
            i = 0
            while i < transnr
              t2 = trans[i]
              i += 1
              next if t2.to < 0 # eliminated

              if t2.atom
                # But here we don't use deep because we want to find transitions which
                # indicate a conflict
                if fa_compare_atoms(t1.atom, t2.atom, 1) != 0
                  # Treat equal counter transitions that couldn't be eliminated as
                  # deterministic.
                  if t1.to != t2.to || t1.counter == t2.counter ||
                      fa_equal_atoms(t1.atom, t2.atom, deep) == 0
                    ret = 0
                  end
                  # mark the transitions as non-deterministic ones
                  t1.nd = 1
                  t2.nd = 1
                  last = t1
                end
              else
                # do the closure in case of remaining specific epsilon transitions like
                # choices or all
                res = fa_recurse_determinism(ctxt, states[t2.to], statenr, t1.to, t1.atom)
                fa_finish_recurse_determinism(ctxt, states[t2.to])
                if res == 0
                  t1.nd = 1
                  last = t1
                  ret = 0
                end
              end
            end
            transnr += 1
          end
          # mark specifically the last non-deterministic transition from a state since there
          # is no need to set-up rollback from it
          last.nd = 2 if last
        end

        ctxt.determinist = ret
        ret
      end

      # ------------------------------------------------------------------
      # Routines to check input against transition atoms
      # ------------------------------------------------------------------

      # xmlRegCheckCharacterRange
      def reg_check_character_range(type, codepoint, neg, start, end_, block_name)
        ret = 0
        case type
        when XML_REGEXP_STRING, XML_REGEXP_SUBREG, XML_REGEXP_RANGES, XML_REGEXP_EPSILON
          return -1
        when XML_REGEXP_ANYCHAR
          ret = (codepoint != 0xA && codepoint != 0xD) ? 1 : 0
        when XML_REGEXP_CHARVAL
          ret = (codepoint >= start && codepoint <= end_) ? 1 : 0
        when XML_REGEXP_NOTSPACE, XML_REGEXP_ANYSPACE
          neg = c_not(neg) if type == XML_REGEXP_NOTSPACE
          ret = (codepoint == 0xA || codepoint == 0xD || codepoint == 0x9 || codepoint == 0x20) ? 1 : 0
        when XML_REGEXP_NOTINITNAME, XML_REGEXP_INITNAME
          neg = c_not(neg) if type == XML_REGEXP_NOTINITNAME
          ret = (is_letter(codepoint) || codepoint == 0x5F || codepoint == 0x3A) ? 1 : 0
        when XML_REGEXP_NOTNAMECHAR, XML_REGEXP_NAMECHAR
          neg = c_not(neg) if type == XML_REGEXP_NOTNAMECHAR
          ret = (is_letter(codepoint) || is_digit(codepoint) ||
                 codepoint == 0x2E || codepoint == 0x2D ||
                 codepoint == 0x5F || codepoint == 0x3A ||
                 is_combining(codepoint) || is_extender(codepoint)) ? 1 : 0
        when XML_REGEXP_NOTDECIMAL, XML_REGEXP_DECIMAL
          neg = c_not(neg) if type == XML_REGEXP_NOTDECIMAL
          ret = in_table(Unicode::CAT_ND, codepoint)
        when XML_REGEXP_REALCHAR, XML_REGEXP_NOTREALCHAR
          neg = c_not(neg) if type == XML_REGEXP_REALCHAR
          ret = in_table(Unicode::CAT_P, codepoint)
          ret = in_table(Unicode::CAT_Z, codepoint) if ret == 0
          ret = in_table(Unicode::CAT_C, codepoint) if ret == 0
        when XML_REGEXP_LETTER then ret = in_table(Unicode::CAT_L, codepoint)
        when XML_REGEXP_LETTER_UPPERCASE then ret = in_table(Unicode::CAT_LU, codepoint)
        when XML_REGEXP_LETTER_LOWERCASE then ret = in_table(Unicode::CAT_LL, codepoint)
        when XML_REGEXP_LETTER_TITLECASE then ret = in_table(Unicode::CAT_LT, codepoint)
        when XML_REGEXP_LETTER_MODIFIER then ret = in_table(Unicode::CAT_LM, codepoint)
        when XML_REGEXP_LETTER_OTHERS then ret = in_table(Unicode::CAT_LO, codepoint)
        when XML_REGEXP_MARK then ret = in_table(Unicode::CAT_M, codepoint)
        when XML_REGEXP_MARK_NONSPACING then ret = in_table(Unicode::CAT_MN, codepoint)
        when XML_REGEXP_MARK_SPACECOMBINING then ret = in_table(Unicode::CAT_MC, codepoint)
        when XML_REGEXP_MARK_ENCLOSING then ret = in_table(Unicode::CAT_ME, codepoint)
        when XML_REGEXP_NUMBER then ret = in_table(Unicode::CAT_N, codepoint)
        when XML_REGEXP_NUMBER_DECIMAL then ret = in_table(Unicode::CAT_ND, codepoint)
        when XML_REGEXP_NUMBER_LETTER then ret = in_table(Unicode::CAT_NL, codepoint)
        when XML_REGEXP_NUMBER_OTHERS then ret = in_table(Unicode::CAT_NO, codepoint)
        when XML_REGEXP_PUNCT then ret = in_table(Unicode::CAT_P, codepoint)
        when XML_REGEXP_PUNCT_CONNECTOR then ret = in_table(Unicode::CAT_PC, codepoint)
        when XML_REGEXP_PUNCT_DASH then ret = in_table(Unicode::CAT_PD, codepoint)
        when XML_REGEXP_PUNCT_OPEN then ret = in_table(Unicode::CAT_PS, codepoint)
        when XML_REGEXP_PUNCT_CLOSE then ret = in_table(Unicode::CAT_PE, codepoint)
        when XML_REGEXP_PUNCT_INITQUOTE then ret = in_table(Unicode::CAT_PI, codepoint)
        when XML_REGEXP_PUNCT_FINQUOTE then ret = in_table(Unicode::CAT_PF, codepoint)
        when XML_REGEXP_PUNCT_OTHERS then ret = in_table(Unicode::CAT_PO, codepoint)
        when XML_REGEXP_SEPAR then ret = in_table(Unicode::CAT_Z, codepoint)
        when XML_REGEXP_SEPAR_SPACE then ret = in_table(Unicode::CAT_ZS, codepoint)
        when XML_REGEXP_SEPAR_LINE then ret = in_table(Unicode::CAT_ZL, codepoint)
        when XML_REGEXP_SEPAR_PARA then ret = in_table(Unicode::CAT_ZP, codepoint)
        when XML_REGEXP_SYMBOL then ret = in_table(Unicode::CAT_S, codepoint)
        when XML_REGEXP_SYMBOL_MATH then ret = in_table(Unicode::CAT_SM, codepoint)
        when XML_REGEXP_SYMBOL_CURRENCY then ret = in_table(Unicode::CAT_SC, codepoint)
        when XML_REGEXP_SYMBOL_MODIFIER then ret = in_table(Unicode::CAT_SK, codepoint)
        when XML_REGEXP_SYMBOL_OTHERS then ret = in_table(Unicode::CAT_SO, codepoint)
        when XML_REGEXP_OTHER then ret = in_table(Unicode::CAT_C, codepoint)
        when XML_REGEXP_OTHER_CONTROL then ret = in_table(Unicode::CAT_CC, codepoint)
        when XML_REGEXP_OTHER_FORMAT then ret = in_table(Unicode::CAT_CF, codepoint)
        when XML_REGEXP_OTHER_PRIVATE then ret = in_table(Unicode::CAT_CO, codepoint)
        when XML_REGEXP_OTHER_NA
          # ret = xmlUCSIsCatCn(codepoint); seems it doesn't exist anymore
          ret = 0
        when XML_REGEXP_BLOCK_NAME
          ret = ucs_is_block(codepoint, block_name)
        end
        return c_not(ret) if neg != 0

        ret
      end

      # xmlRegCheckCharacter
      def reg_check_character(atom, codepoint)
        return -1 if atom.nil? || !is_char(codepoint)

        case atom.type
        when XML_REGEXP_SUBREG, XML_REGEXP_EPSILON
          -1
        when XML_REGEXP_CHARVAL
          codepoint == atom.codepoint ? 1 : 0
        when XML_REGEXP_RANGES
          accept = 0
          atom.ranges&.each do |range|
            ret = reg_check_character_range(range.type, codepoint, 0, range.start, range.end, range.block_name)
            if range.neg == 2
              return 0 if ret != 0 # excluded char
            elsif range.neg != 0
              return 0 if ret != 0

              accept = 1
            elsif ret != 0
              accept = 1 # might still be excluded
            end
          end
          accept
        when XML_REGEXP_STRING
          # printf("TODO: XML_REGEXP_STRING\n");
          -1
        else
          ret = reg_check_character_range(atom.type, codepoint, 0, 0, 0, atom.valuep)
          ret = c_not(ret) if atom.neg != 0
          ret
        end
      end

      # ------------------------------------------------------------------
      # Saving and restoring state of an execution context
      # ------------------------------------------------------------------

      # xmlFARegExecSave
      def fa_reg_exec_save(exec)
        if exec.nb_push > MAX_PUSH
          exec.status = XML_REGEXP_INTERNAL_LIMIT
          return
        end
        exec.nb_push += 1
        rb = exec.rollbacks[exec.nb_rollbacks]
        if rb.nil?
          rb = Rollback.new
          exec.rollbacks[exec.nb_rollbacks] = rb
        end
        rb.state = exec.state
        rb.index = exec.index
        rb.nextbranch = exec.transno + 1
        n = exec.comp.counters.size
        if n > 0
          if rb.counts
            rb.counts.replace(exec.counts)
          else
            rb.counts = exec.counts.dup
          end
        end
        exec.nb_rollbacks += 1
      end

      # xmlFARegExecRollBack
      def fa_reg_exec_roll_back(exec)
        return if exec.status != XML_REGEXP_OK

        if exec.nb_rollbacks <= 0
          exec.status = XML_REGEXP_NOT_FOUND
          return
        end
        exec.nb_rollbacks -= 1
        rb = exec.rollbacks[exec.nb_rollbacks]
        exec.state = rb.state
        exec.index = rb.index
        exec.transno = rb.nextbranch
        if exec.comp.counters.size > 0
          if rb.counts.nil?
            exec.status = XML_REGEXP_INTERNAL_ERROR
            return
          end
          exec.counts&.replace(rb.counts)
        end
      end

      # ------------------------------------------------------------------
      # Verifier, running an input against a compiled regexp
      # ------------------------------------------------------------------

      # xmlFARegExec. +content+ is a String; it is walked as codepoints (see input_codepoints).
      def fa_reg_exec(comp, content)
        exec = ExecCtxt.new
        input = input_codepoints(content)
        exec.input_string = input
        exec.index = 0
        exec.nb_push = 0
        exec.determinist = 1
        exec.status = XML_REGEXP_OK
        exec.comp = comp
        states = comp.states
        exec.state = states[0]
        exec.transno = 0
        exec.transcount = 0
        counters = comp.counters
        counts = counters.empty? ? nil : Array.new(counters.size, 0)
        exec.counts = counts
        error = false
        while exec.status == XML_REGEXP_OK && exec.state &&
            (input[exec.index] != 0 || exec.state.type != XML_REGEXP_FINAL_STATE)
          # If end of input on non-terminal state, rollback, however we may still have epsilon
          # like transition for counted transitions on counters, in that case don't break too
          # early. Additionally, if we are working on a range like "AB{0,2}", where B is not
          # present, we don't want to break.
          len = 1
          action = nil
          if input[exec.index] == 0 && counts.nil?
            # if there is a transition, we must check if atom allows minOccurs of 0
            if exec.transno < exec.state.trans.size
              trans = exec.state.trans[exec.transno]
              if trans.to >= 0
                atom = trans.atom
                action = :rollback unless atom.min == 0 && atom.max > 0
              end
            else
              action = :rollback
            end
          end

          if action.nil?
            exec.transcount = 0
            state_trans = exec.state.trans
            while exec.transno < state_trans.size
              trans = state_trans[exec.transno]
              if trans.to < 0
                exec.transno += 1
                next
              end
              atom = trans.atom
              ret = 0
              deter = 1
              if trans.count >= 0
                if counts.nil?
                  exec.status = XML_REGEXP_INTERNAL_ERROR
                  action = :error
                  break
                end
                # A counted transition.
                count = counts[trans.count]
                counter = counters[trans.count]
                ret = (count >= counter.min && count <= counter.max) ? 1 : 0
                deter = 0 if ret == 1 && counter.min != counter.max
              elsif atom.nil?
                # epsilon transition left at runtime
                exec.status = XML_REGEXP_INTERNAL_ERROR
                break
              elsif input[exec.index] != 0
                codepoint = input[exec.index]
                if codepoint < 0
                  exec.status = XML_REGEXP_INVALID_UTF8
                  action = :error
                  break
                end
                ret = reg_check_character(atom, codepoint)
                if ret == 1 && atom.min >= 0 && atom.max > 0
                  to = states[trans.to]
                  # this is a multiple input sequence. If there is a counter associated
                  # increment it now. do not increment if the counter is already over the
                  # maximum limit in which case get to next transition
                  if trans.counter >= 0
                    if counts.nil?
                      exec.status = XML_REGEXP_INTERNAL_ERROR
                      action = :error
                      break
                    end
                    counter = counters[trans.counter]
                    if counts[trans.counter] >= counter.max
                      exec.transno += 1
                      next # for loop on transitions
                    end
                  end
                  # Save before incrementing
                  if state_trans.size > exec.transno + 1
                    fa_reg_exec_save(exec)
                    if exec.status != XML_REGEXP_OK
                      action = :error
                      break
                    end
                  end
                  counts[trans.counter] += 1 if trans.counter >= 0
                  exec.transcount = 1
                  loop do
                    # Try to progress as much as possible on the input
                    break if exec.transcount == atom.max

                    exec.index += len
                    # End of input: stop here
                    if input[exec.index] == 0
                      exec.index -= len
                      break
                    end
                    if exec.transcount >= atom.min
                      transno = exec.transno
                      state = exec.state
                      # The transition is acceptable save it
                      exec.transno = -1 # trick
                      exec.state = to
                      fa_reg_exec_save(exec)
                      if exec.status != XML_REGEXP_OK
                        action = :error
                        break
                      end
                      exec.transno = transno
                      exec.state = state
                    end
                    codepoint = input[exec.index]
                    if codepoint < 0
                      exec.status = XML_REGEXP_INVALID_UTF8
                      action = :error
                      break
                    end
                    ret = reg_check_character(atom, codepoint)
                    exec.transcount += 1
                    break unless ret == 1
                  end
                  break if action == :error

                  ret = 0 if exec.transcount < atom.min
                  # If the last check failed but one transition was found possible, rollback
                  ret = 0 if ret < 0
                  if ret == 0
                    action = :rollback
                    break
                  end
                  if trans.counter >= 0
                    if counts.nil?
                      exec.status = XML_REGEXP_INTERNAL_ERROR
                      action = :error
                      break
                    end
                    counts[trans.counter] -= 1
                  end
                elsif ret == 0 && atom.min == 0 && atom.max > 0
                  # we don't match on the codepoint, but minOccurs of 0 says that's ok.
                  # Setting len to 0 inhibits stepping over the codepoint.
                  exec.transcount = 1
                  len = 0
                  ret = 1
                end
              elsif atom.min == 0 && atom.max > 0
                # another spot to match when minOccurs is 0
                exec.transcount = 1
                len = 0
                ret = 1
              end
              if ret == 1
                if trans.nd == 1 ||
                    (trans.count >= 0 && deter == 0 && state_trans.size > exec.transno + 1)
                  fa_reg_exec_save(exec)
                  if exec.status != XML_REGEXP_OK
                    action = :error
                    break
                  end
                end
                if trans.counter >= 0
                  # make sure we don't go over the counter maximum value
                  if counts.nil?
                    exec.status = XML_REGEXP_INTERNAL_ERROR
                    action = :error
                    break
                  end
                  counter = counters[trans.counter]
                  if counts[trans.counter] >= counter.max
                    exec.transno += 1
                    next # for loop on transitions
                  end
                  counts[trans.counter] += 1
                end
                if trans.count >= 0 && trans.count < REGEXP_ALL_COUNTER
                  if counts.nil?
                    exec.status = XML_REGEXP_INTERNAL_ERROR
                    action = :error
                    break
                  end
                  counts[trans.count] = 0
                end
                exec.state = states[trans.to]
                exec.transno = 0
                exec.index += len if trans.atom
                action = :progress
                break
              elsif ret < 0
                exec.status = XML_REGEXP_INTERNAL_ERROR
                break
              end
              exec.transno += 1
            end
          end
          next if action == :progress

          if action == :error
            error = true
            break
          end
          if action == :rollback || exec.transno != 0 || exec.state.trans.empty?
            # Failed to find a way out
            exec.determinist = 0
            fa_reg_exec_roll_back(exec)
          end
        end
        _ = error
        return XML_REGEXP_INTERNAL_ERROR if exec.state.nil?
        return 1 if exec.status == XML_REGEXP_OK
        return 0 if exec.status == XML_REGEXP_NOT_FOUND

        exec.status
      end

      # ------------------------------------------------------------------
      # Progressive interface to the verifier one atom at a time
      # ------------------------------------------------------------------

      # xmlRegNewExecCtxt
      def reg_new_exec_ctxt(comp, callback, data)
        return nil if comp.nil?
        return nil if comp.compact.nil? && comp.states.nil?

        exec = ExecCtxt.new
        exec.input_string = nil
        exec.index = 0
        exec.determinist = 1
        exec.status = XML_REGEXP_OK
        exec.comp = comp
        exec.state = comp.states[0] if comp.compact.nil?
        exec.transno = 0
        exec.transcount = 0
        exec.callback = callback
        exec.data = data
        n = comp.nb_counters
        if n > 0
          # For error handling, exec->counts is allocated twice the size the second half is
          # used to store the data in case of rollback
          exec.counts = Array.new(n, 0)
          exec.err_counts = Array.new(n, 0)
        else
          exec.counts = nil
          exec.err_counts = nil
        end
        exec.input_stack = nil
        exec.input_data = nil
        exec.input_stack_nr = 0
        exec.err_state_no = -1
        exec.err_string = nil
        exec.nb_push = 0
        exec
      end

      # xmlRegFreeExecCtxt
      def reg_free_exec_ctxt(exec); end

      # xmlRegExecSetErrString
      def reg_exec_set_err_string(exec, value)
        exec.err_string = value.nil? ? nil : value.dup
        0
      end

      # xmlFARegExecSaveInputString
      def fa_reg_exec_save_input_string(exec, value, data)
        if exec.input_stack.nil?
          exec.input_stack = []
          exec.input_data = []
        end
        exec.input_stack[exec.input_stack_nr] = value&.dup
        exec.input_data[exec.input_stack_nr] = data
        exec.input_stack_nr += 1
        exec.input_stack[exec.input_stack_nr] = nil
        exec.input_data[exec.input_stack_nr] = nil
      end

      # xmlRegStrEqualWildcard: Checks if both strings are equal or have the same content. "*"
      # can be used as a wildcard in valStr; "|" is used as a separator of substrings in both
      # expStr and valStr. Returns 1 / 0.
      def reg_str_equal_wildcard(exp_str, val_str)
        return 1 if exp_str.equal?(val_str)
        return 0 if exp_str.nil? || val_str.nil?
        return 1 if exp_str == val_str
        return 0 if !exp_str.include?("*") && !val_str.include?("*")

        eb = exp_str.b
        vb = val_str.b
        e = 0
        v = 0
        loop do
          # Eval if we have a wildcard for the current item.
          ec = eb.getbyte(e) || 0
          vc = vb.getbyte(v) || 0
          if ec != vc
            # if one of them starts with a wildcard make valStr be it
            if vc == 0x2A
              eb, vb = vb, eb
              e, v = v, e
              ec, vc = vc, ec
            end
            if vc != 0 && ec != 0 && ec == 0x2A
              e += 1
              loop do
                break if (vb.getbyte(v) || 0) == XML_REG_STRING_SEPARATOR

                v += 1
                break if (vb.getbyte(v) || 0) == 0
              end
              break if (vb.getbyte(v) || 0) == 0

              next
            else
              return 0
            end
          end
          e += 1
          v += 1
          break if (vb.getbyte(v) || 0) == 0
        end
        (eb.getbyte(e) || 0) != 0 ? 0 : 1
      end

      # xmlRegCompactPushString
      def reg_compact_push_string(exec, comp, value, data)
        state = exec.index
        return -1 if comp.nil? || comp.compact.nil? || comp.string_map.nil?

        compact = comp.compact
        nbstrings = comp.nbstrings
        stride = nbstrings + 1
        if value.nil?
          # are we at a final state ?
          return compact[state * stride] == XML_REGEXP_FINAL_STATE ? 1 : 0
        end

        # Examine all outside transitions from current state
        base = state * stride + 1
        string_map = comp.string_map
        nbstates = comp.nbstates
        i = 0
        while i < nbstrings
          target = compact[base + i]
          if target > 0 && target <= nbstates
            target -= 1 # to avoid 0
            if reg_str_equal_wildcard(string_map[i], value) == 1
              exec.index = target
              if exec.callback && comp.transdata
                exec.callback.call(exec.data, value, comp.transdata[state * nbstrings + i], data)
              end
              ttype = compact[target * stride]
              break if ttype == XML_REGEXP_SINK_STATE # goto error
              return 1 if ttype == XML_REGEXP_FINAL_STATE

              return 0
            end
          end
          i += 1
        end
        # Failed to find an exit transition out from current state for the current token
        exec.err_state_no = state
        exec.status = XML_REGEXP_NOT_FOUND
        reg_exec_set_err_string(exec, value)
        exec.status
      end

      # xmlRegExecPushStringInternal
      def reg_exec_push_string_internal(exec, value, data, compound)
        final = 0
        progress = 1
        return -1 if exec.nil?

        comp = exec.comp
        return -1 if comp.nil?
        return exec.status if exec.status != XML_REGEXP_OK
        return reg_compact_push_string(exec, comp, value, data) if comp.compact

        if value.nil?
          return 1 if exec.state.type == XML_REGEXP_FINAL_STATE

          final = 1
        end

        # If we have an active rollback stack push the new value there and get back to where
        # we were left
        if value && exec.input_stack_nr > 0
          fa_reg_exec_save_input_string(exec, value, data)
          value = exec.input_stack[exec.index]
          data = exec.input_data[exec.index]
        end

        states = comp.states
        counters = comp.counters
        while exec.status == XML_REGEXP_OK &&
            (value || (final == 1 && exec.state.type != XML_REGEXP_FINAL_STATE))
          # End of input on non-terminal state, rollback, however we may still have epsilon
          # like transition for counted transitions on counters, in that case don't break too
          # early.
          action = nil
          action = :rollback if value.nil? && exec.counts.nil?

          if action.nil?
            exec.transcount = 0
            state_trans = exec.state.trans
            while exec.transno < state_trans.size
              trans = state_trans[exec.transno]
              if trans.to < 0
                exec.transno += 1
                next
              end
              atom = trans.atom
              ret = 0
              if trans.count == REGEXP_ALL_LAX_COUNTER
                ret = 0
                # Check all counted transitions from the current state
                if value.nil? && final != 0
                  ret = 1
                elsif value
                  state_trans.each do |t|
                    next if t.counter < 0 || t.equal?(trans)

                    counter = counters[t.counter]
                    count = exec.counts[t.counter]
                    if count < counter.max && t.atom && value == t.atom.valuep
                      ret = 0
                      break
                    end
                    if count >= counter.min && count < counter.max && t.atom && value == t.atom.valuep
                      ret = 1
                      break
                    end
                  end
                end
              elsif trans.count == REGEXP_ALL_COUNTER
                ret = 1
                # Check all counted transitions from the current state
                state_trans.each do |t|
                  next if t.counter < 0 || t.equal?(trans)

                  counter = counters[t.counter]
                  count = exec.counts[t.counter]
                  if count < counter.min || count > counter.max
                    ret = 0
                    break
                  end
                end
              elsif trans.count >= 0
                # A counted transition.
                count = exec.counts[trans.count]
                counter = counters[trans.count]
                ret = (count >= counter.min && count <= counter.max) ? 1 : 0
              elsif atom.nil?
                # epsilon transition left at runtime
                exec.status = XML_REGEXP_INTERNAL_ERROR
                break
              elsif value
                ret = reg_str_equal_wildcard(atom.valuep, value)
                if atom.neg != 0
                  ret = c_not(ret)
                  ret = 0 if compound == 0
                end
                if ret == 1 && trans.counter >= 0
                  count = exec.counts[trans.counter]
                  counter = counters[trans.counter]
                  ret = 0 if count >= counter.max
                end

                if ret == 1 && atom.min > 0 && atom.max > 0
                  to = states[trans.to]
                  # this is a multiple input sequence
                  if state_trans.size > exec.transno + 1
                    fa_reg_exec_save_input_string(exec, value, data) if exec.input_stack_nr <= 0
                    fa_reg_exec_save(exec)
                  end
                  exec.transcount = 1
                  loop do
                    # Try to progress as much as possible on the input
                    break if exec.transcount == atom.max

                    exec.index += 1
                    value = exec.input_stack&.[](exec.index)
                    data = exec.input_data&.[](exec.index)
                    # End of input: stop here
                    if value.nil?
                      exec.index -= 1
                      break
                    end
                    if exec.transcount >= atom.min
                      transno = exec.transno
                      state = exec.state
                      # The transition is acceptable save it
                      exec.transno = -1 # trick
                      exec.state = to
                      fa_reg_exec_save_input_string(exec, value, data) if exec.input_stack_nr <= 0
                      fa_reg_exec_save(exec)
                      exec.transno = transno
                      exec.state = state
                    end
                    ret = value == atom.valuep ? 1 : 0
                    exec.transcount += 1
                    break unless ret == 1
                  end
                  ret = 0 if exec.transcount < atom.min
                  # If the last check failed but one transition was found possible, rollback
                  ret = 0 if ret < 0
                  if ret == 0
                    action = :rollback
                    break
                  end
                end
              end
              if ret == 1
                if exec.callback && atom && !data.nil?
                  exec.callback.call(exec.data, atom.valuep, atom.data, data)
                end
                if state_trans.size > exec.transno + 1
                  fa_reg_exec_save_input_string(exec, value, data) if exec.input_stack_nr <= 0
                  fa_reg_exec_save(exec)
                end
                exec.counts[trans.counter] += 1 if trans.counter >= 0
                exec.counts[trans.count] = 0 if trans.count >= 0 && trans.count < REGEXP_ALL_COUNTER
                target = states[trans.to]
                if target && target.type == XML_REGEXP_SINK_STATE
                  # entering a sink state, save the current state as error state.
                  reg_exec_set_err_string(exec, value)
                  exec.err_state = exec.state
                  exec.err_counts&.replace(exec.counts)
                end
                exec.state = target
                exec.transno = 0
                if trans.atom
                  if exec.input_stack
                    exec.index += 1
                    if exec.index < exec.input_stack_nr
                      value = exec.input_stack[exec.index]
                      data = exec.input_data[exec.index]
                    else
                      value = nil
                      data = nil
                    end
                  else
                    value = nil
                    data = nil
                  end
                end
                action = :progress
                break
              elsif ret < 0
                exec.status = XML_REGEXP_INTERNAL_ERROR
                break
              end
              exec.transno += 1
            end
            action = :rollback if action.nil? && (exec.transno != 0 || exec.state.trans.empty?)
          end
          if action == :progress
            progress = 1
            next
          end
          next unless action == :rollback

          # if we didn't yet rollback on the current input store the current state as the
          # error state.
          if progress != 0 && exec.state && exec.state.type != XML_REGEXP_SINK_STATE
            progress = 0
            reg_exec_set_err_string(exec, value)
            exec.err_state = exec.state
            exec.err_counts.replace(exec.counts) if counters.size > 0
          end

          # Failed to find a way out
          exec.determinist = 0
          fa_reg_exec_roll_back(exec)
          if exec.input_stack && exec.status == XML_REGEXP_OK
            value = exec.input_stack[exec.index]
            data = exec.input_data[exec.index]
          end
        end
        return exec.state.type == XML_REGEXP_FINAL_STATE ? 1 : 0 if exec.status == XML_REGEXP_OK

        exec.status
      end

      # xmlRegExecPushString: value nil means end of input.
      # Returns 1 if the regexp reached a final state, 0 if non-final, < 0 on error.
      def reg_exec_push_string(exec, value, data)
        reg_exec_push_string_internal(exec, value, data, 0)
      end

      # xmlRegExecPushString2
      def reg_exec_push_string2(exec, value, value2, data)
        return -1 if exec.nil?
        return -1 if exec.comp.nil?
        return exec.status if exec.status != XML_REGEXP_OK
        return reg_exec_push_string(exec, value, data) if value2.nil?

        str = "#{value}|#{value2}"
        if exec.comp.compact
          reg_compact_push_string(exec, exec.comp, str, data)
        else
          reg_exec_push_string_internal(exec, str, data, 1)
        end
      end

      # xmlRegExecGetValues. +maxval+ is the C *nbval input value.
      # Returns [ret, nbval, nbneg, values, terminal].
      def reg_exec_get_values(exec, err, maxval)
        return [-1, maxval, 0, [], nil] if exec.nil? || maxval.nil? || maxval <= 0

        values = []
        nbval = 0
        nbneg = 0
        terminal = nil
        comp = exec.comp
        if comp && comp.compact
          compact = comp.compact
          stride = comp.nbstrings + 1
          if err != 0
            return [-1, nbval, nbneg, values, terminal] if exec.err_state_no == -1

            state = exec.err_state_no
          else
            state = exec.index
          end
          terminal = compact[state * stride] == XML_REGEXP_FINAL_STATE ? 1 : 0
          i = 0
          while i < comp.nbstrings && values.size < maxval
            target = compact[state * stride + i + 1]
            if target > 0 && target <= comp.nbstates &&
                compact[(target - 1) * stride] != XML_REGEXP_SINK_STATE
              values << comp.string_map[i]
              nbval += 1
            end
            i += 1
          end
          i = 0
          while i < comp.nbstrings && values.size < maxval
            target = compact[state * stride + i + 1]
            if target > 0 && target <= comp.nbstates &&
                compact[(target - 1) * stride] == XML_REGEXP_SINK_STATE
              values << comp.string_map[i]
              nbneg += 1
            end
            i += 1
          end
        else
          terminal = exec.state.type == XML_REGEXP_FINAL_STATE ? 1 : 0

          if err != 0
            return [-1, nbval, nbneg, values, terminal] if exec.err_state.nil?

            state = exec.err_state
          else
            return [-1, nbval, nbneg, values, terminal] if exec.state.nil?

            state = exec.state
          end
          trans_list = state.trans
          transno = 0
          while transno < trans_list.size && values.size < maxval
            trans = trans_list[transno]
            transno += 1
            next if trans.to < 0

            atom = trans.atom
            next if atom.nil? || atom.valuep.nil?

            if trans.count == REGEXP_ALL_LAX_COUNTER || trans.count == REGEXP_ALL_COUNTER
              # this should not be reached but ...
            elsif trans.counter >= 0
              count = err != 0 ? exec.err_counts[trans.counter] : exec.counts[trans.counter]
              counter = comp ? comp.counters[trans.counter] : nil
              if counter.nil? || count < counter.max
                values << (atom.neg != 0 ? atom.valuep2 : atom.valuep)
                nbval += 1
              end
            elsif comp && comp.states[trans.to] &&
                comp.states[trans.to].type != XML_REGEXP_SINK_STATE
              values << (atom.neg != 0 ? atom.valuep2 : atom.valuep)
              nbval += 1
            end
          end
          transno = 0
          while transno < trans_list.size && values.size < maxval
            trans = trans_list[transno]
            transno += 1
            next if trans.to < 0

            atom = trans.atom
            next if atom.nil? || atom.valuep.nil?
            next if trans.count == REGEXP_ALL_LAX_COUNTER || trans.count == REGEXP_ALL_COUNTER
            next if trans.counter >= 0

            if comp.states[trans.to] && comp.states[trans.to].type == XML_REGEXP_SINK_STATE
              values << (atom.neg != 0 ? atom.valuep2 : atom.valuep)
              nbneg += 1
            end
          end
        end
        [0, nbval, nbneg, values, terminal]
      end

      # xmlRegExecNextValues -> [ret, nbval, nbneg, values, terminal]
      def reg_exec_next_values(exec, maxval)
        reg_exec_get_values(exec, 0, maxval)
      end

      # xmlRegExecErrInfo -> [ret, string, nbval, nbneg, values, terminal]
      def reg_exec_err_info(exec, maxval)
        return [-1, nil, maxval, 0, [], nil] if exec.nil?

        string = exec.status != XML_REGEXP_OK ? exec.err_string : nil
        ret, nbval, nbneg, values, terminal = reg_exec_get_values(exec, 1, maxval)
        [ret, string, nbval, nbneg, values, terminal]
      end

      # ------------------------------------------------------------------
      # Parser for the Schemas Datatype Regular Expressions
      # http://www.w3.org/TR/2001/REC-xmlschema-2-20010502/#regexs
      # ------------------------------------------------------------------

      # CUR / NXT(i) / PREV / NEXT / NEXTL(l)
      def cur_b(ctxt) = ctxt.string.getbyte(ctxt.cur) || 0
      def nxt_b(ctxt, i) = ctxt.string.getbyte(ctxt.cur + i) || 0
      def prev_b(ctxt) = ctxt.string.getbyte(ctxt.cur - 1) || 0
      def next_b(ctxt) = ctxt.cur += 1

      # xmlFAIsChar: [10] Char ::= [^.\?*+()|#x5B#x5D]
      def fa_is_char(ctxt)
        cur, = get_utf8_char(ctxt.string, ctxt.cur)
        if cur < 0
          reg_error(ctxt, "Invalid UTF-8")
          return 0
        end
        case cur
        when 0x2E, 0x5C, 0x3F, 0x2A, 0x2B, 0x28, 0x29, 0x7C, 0x5B, 0x5D, 0
          return -1
        end
        cur
      end

      CHAR_PROP_SUBTYPES = {
        0x4C => [XML_REGEXP_LETTER, { 0x75 => XML_REGEXP_LETTER_UPPERCASE, 0x6C => XML_REGEXP_LETTER_LOWERCASE,
                                      0x74 => XML_REGEXP_LETTER_TITLECASE, 0x6D => XML_REGEXP_LETTER_MODIFIER,
                                      0x6F => XML_REGEXP_LETTER_OTHERS, },],
        0x4D => [XML_REGEXP_MARK, { 0x6E => XML_REGEXP_MARK_NONSPACING, 0x63 => XML_REGEXP_MARK_SPACECOMBINING,
                                    0x65 => XML_REGEXP_MARK_ENCLOSING, },],
        0x4E => [XML_REGEXP_NUMBER, { 0x64 => XML_REGEXP_NUMBER_DECIMAL, 0x6C => XML_REGEXP_NUMBER_LETTER,
                                      0x6F => XML_REGEXP_NUMBER_OTHERS, },],
        0x50 => [XML_REGEXP_PUNCT, { 0x63 => XML_REGEXP_PUNCT_CONNECTOR, 0x64 => XML_REGEXP_PUNCT_DASH,
                                     0x73 => XML_REGEXP_PUNCT_OPEN, 0x65 => XML_REGEXP_PUNCT_CLOSE,
                                     0x69 => XML_REGEXP_PUNCT_INITQUOTE, 0x66 => XML_REGEXP_PUNCT_FINQUOTE,
                                     0x6F => XML_REGEXP_PUNCT_OTHERS, },],
        0x5A => [XML_REGEXP_SEPAR, { 0x73 => XML_REGEXP_SEPAR_SPACE, 0x6C => XML_REGEXP_SEPAR_LINE,
                                     0x70 => XML_REGEXP_SEPAR_PARA, },],
        0x53 => [XML_REGEXP_SYMBOL, { 0x6D => XML_REGEXP_SYMBOL_MATH, 0x63 => XML_REGEXP_SYMBOL_CURRENCY,
                                      0x6B => XML_REGEXP_SYMBOL_MODIFIER, 0x6F => XML_REGEXP_SYMBOL_OTHERS, },],
        0x43 => [XML_REGEXP_OTHER, { 0x63 => XML_REGEXP_OTHER_CONTROL, 0x66 => XML_REGEXP_OTHER_FORMAT,
                                     0x6F => XML_REGEXP_OTHER_PRIVATE, 0x6E => XML_REGEXP_OTHER_NA, },],
      }.freeze

      def block_name_char?(c)
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x2D
      end

      # xmlFAParseCharProp
      #   [27] charProp ::= IsCategory | IsBlock
      #   [36] IsBlock  ::= 'Is' [a-zA-Z0-9#x2D]+
      def fa_parse_char_prop(ctxt)
        block_name = nil
        cur = cur_b(ctxt)
        if (sub = CHAR_PROP_SUBTYPES[cur])
          next_b(ctxt)
          cur = cur_b(ctxt)
          if (t = sub[1][cur])
            next_b(ctxt)
            type = t
          else
            type = sub[0]
          end
        elsif cur == 0x49 # 'I'
          next_b(ctxt)
          cur = cur_b(ctxt)
          if cur != 0x73 # 's'
            reg_error(ctxt, "IsXXXX expected")
            return
          end
          next_b(ctxt)
          start = ctxt.cur
          cur = cur_b(ctxt)
          if block_name_char?(cur)
            next_b(ctxt)
            cur = cur_b(ctxt)
            while block_name_char?(cur)
              next_b(ctxt)
              cur = cur_b(ctxt)
            end
          end
          type = XML_REGEXP_BLOCK_NAME
          block_name = ctxt.string.byteslice(start, ctxt.cur - start).force_encoding(::Encoding::UTF_8)
        else
          reg_error(ctxt, "Unknown char property")
          return
        end
        if ctxt.atom.nil?
          ctxt.atom = reg_new_atom(ctxt, type)
          ctxt.atom.valuep = block_name
        elsif ctxt.atom.type == XML_REGEXP_RANGES
          reg_atom_add_range(ctxt, ctxt.atom, ctxt.neg, type, 0, 0, block_name)
        end
      end

      # parse_escaped_codeunit
      def parse_escaped_codeunit(ctxt)
        val = 0
        4.times do
          next_b(ctxt)
          val *= 16
          cur = cur_b(ctxt)
          if cur >= 0x30 && cur <= 0x39
            val += cur - 0x30
          elsif cur >= 0x41 && cur <= 0x46
            val += cur - 0x41 + 10
          elsif cur >= 0x61 && cur <= 0x66
            val += cur - 0x61 + 10
          else
            reg_error(ctxt, "Expecting hex digit")
            return -1
          end
        end
        val
      end

      # parse_escaped_codepoint
      def parse_escaped_codepoint(ctxt)
        val = parse_escaped_codeunit(ctxt)
        if val >= 0xD800 && val <= 0xDBFF
          next_b(ctxt)
          if cur_b(ctxt) == 0x5C
            next_b(ctxt)
            if cur_b(ctxt) == 0x75
              low = parse_escaped_codeunit(ctxt)
              return (val - 0xD800) * 0x400 + (low - 0xDC00) + 0x10000 if low >= 0xDC00 && low <= 0xDFFF
            end
          end
          reg_error(ctxt, "Invalid low surrogate pair code unit")
          val = -1
        end
        val
      end

      SINGLE_ESCAPES = "nrt\\|.?*+(){}-[]^!\"\#$%,/:;=>@`~u".bytes.to_h { |b| [b, true] }.freeze
      MULTI_ESCAPES = {
        0x73 => XML_REGEXP_ANYSPACE, 0x53 => XML_REGEXP_NOTSPACE,
        0x69 => XML_REGEXP_INITNAME, 0x49 => XML_REGEXP_NOTINITNAME,
        0x63 => XML_REGEXP_NAMECHAR, 0x43 => XML_REGEXP_NOTNAMECHAR,
        0x64 => XML_REGEXP_DECIMAL, 0x44 => XML_REGEXP_NOTDECIMAL,
        0x77 => XML_REGEXP_REALCHAR, 0x57 => XML_REGEXP_NOTREALCHAR,
      }.freeze

      # xmlFAParseCharClassEsc
      #   [23] charClassEsc ::= ( SingleCharEsc | MultiCharEsc | catEsc | complEsc )
      def fa_parse_char_class_esc(ctxt)
        if cur_b(ctxt) == 0x2E # '.'
          if ctxt.atom.nil?
            ctxt.atom = reg_new_atom(ctxt, XML_REGEXP_ANYCHAR)
          elsif ctxt.atom.type == XML_REGEXP_RANGES
            reg_atom_add_range(ctxt, ctxt.atom, ctxt.neg, XML_REGEXP_ANYCHAR, 0, 0, nil)
          end
          next_b(ctxt)
          return
        end
        if cur_b(ctxt) != 0x5C
          reg_error(ctxt, "Escaped sequence: expecting \\")
          return
        end
        next_b(ctxt)
        cur = cur_b(ctxt)
        if cur == 0x70 # 'p'
          next_b(ctxt)
          if cur_b(ctxt) != 0x7B
            reg_error(ctxt, "Expecting '{'")
            return
          end
          next_b(ctxt)
          fa_parse_char_prop(ctxt)
          if cur_b(ctxt) != 0x7D
            reg_error(ctxt, "Expecting '}'")
            return
          end
          next_b(ctxt)
        elsif cur == 0x50 # 'P'
          next_b(ctxt)
          if cur_b(ctxt) != 0x7B
            reg_error(ctxt, "Expecting '{'")
            return
          end
          next_b(ctxt)
          fa_parse_char_prop(ctxt)
          ctxt.atom.neg = 1 if ctxt.atom
          if cur_b(ctxt) != 0x7D
            reg_error(ctxt, "Expecting '}'")
            return
          end
          next_b(ctxt)
        elsif SINGLE_ESCAPES[cur]
          if ctxt.atom.nil?
            ctxt.atom = reg_new_atom(ctxt, XML_REGEXP_CHARVAL)
            case cur
            when 0x6E then ctxt.atom.codepoint = 0xA
            when 0x72 then ctxt.atom.codepoint = 0xD
            when 0x74 then ctxt.atom.codepoint = 0x9
            when 0x75
              cur = parse_escaped_codepoint(ctxt)
              return if cur < 0

              ctxt.atom.codepoint = cur
            else
              ctxt.atom.codepoint = cur
            end
          elsif ctxt.atom.type == XML_REGEXP_RANGES
            case cur
            when 0x6E then cur = 0xA
            when 0x72 then cur = 0xD
            when 0x74 then cur = 0x9
            end
            reg_atom_add_range(ctxt, ctxt.atom, ctxt.neg, XML_REGEXP_CHARVAL, cur, cur, nil)
          end
          next_b(ctxt)
        elsif (type = MULTI_ESCAPES[cur])
          next_b(ctxt)
          if ctxt.atom.nil?
            ctxt.atom = reg_new_atom(ctxt, type)
          elsif ctxt.atom.type == XML_REGEXP_RANGES
            reg_atom_add_range(ctxt, ctxt.atom, ctxt.neg, type, 0, 0, nil)
          end
        else
          reg_error(ctxt, "Wrong escape sequence, misuse of character '\\'")
        end
      end

      RANGE_ESCAPES = "\\|.-^?*+{}()[]".bytes.to_h { |b| [b, b] }.merge(0x6E => 0xA, 0x72 => 0xD, 0x74 => 0x9).freeze

      # xmlFAParseCharRange
      #   [17] charRange ::= seRange | XmlCharRef | XmlCharIncDash
      #   [18] seRange   ::= charOrEsc '-' charOrEsc
      def fa_parse_char_range(ctxt)
        start = -1
        end_ = -1

        if cur_b(ctxt) == 0
          reg_error(ctxt, "Expecting ']'")
          return
        end

        cur = cur_b(ctxt)
        if cur == 0x5C
          next_b(ctxt)
          cur = cur_b(ctxt)
          start = RANGE_ESCAPES[cur]
          if start.nil?
            reg_error(ctxt, "Invalid escape value")
            return
          end
          end_ = start
          len = 1
        elsif cur != 0x5B && cur != 0x5D
          start, len = get_utf8_char(ctxt.string, ctxt.cur)
          end_ = start
          if start < 0
            reg_error(ctxt, "Invalid UTF-8")
            return
          end
        else
          reg_error(ctxt, "Expecting a char range")
          return
        end
        # Since we are "inside" a range, we can assume ctxt->cur is past the start of
        # ctxt->string, and PREV should be safe
        if start == 0x2D && nxt_b(ctxt, 1) != 0x5D && prev_b(ctxt) != 0x5B && prev_b(ctxt) != 0x5E
          ctxt.cur += len
          return
        end
        ctxt.cur += len
        cur = cur_b(ctxt)
        if cur != 0x2D || nxt_b(ctxt, 1) == 0x5B || nxt_b(ctxt, 1) == 0x5D
          reg_atom_add_range(ctxt, ctxt.atom, ctxt.neg, XML_REGEXP_CHARVAL, start, end_, nil)
          return
        end
        next_b(ctxt)
        cur = cur_b(ctxt)
        if cur == 0x5C
          next_b(ctxt)
          cur = cur_b(ctxt)
          end_ = RANGE_ESCAPES[cur]
          if end_.nil?
            reg_error(ctxt, "Invalid escape value")
            return
          end
          len = 1
        elsif cur != 0 && cur != 0x5B && cur != 0x5D
          end_, len = get_utf8_char(ctxt.string, ctxt.cur)
          if end_ < 0
            reg_error(ctxt, "Invalid UTF-8")
            return
          end
        else
          reg_error(ctxt, "Expecting the end of a char range")
          return
        end

        # TODO check that the values are acceptable character ranges for XML
        if end_ < start
          reg_error(ctxt, "End of range is before start of range")
        else
          ctxt.cur += len
          reg_atom_add_range(ctxt, ctxt.atom, ctxt.neg, XML_REGEXP_CHARVAL, start, end_, nil)
        end
      end

      # xmlFAParsePosCharGroup: [14] posCharGroup ::= ( charRange | charClassEsc )+
      def fa_parse_pos_char_group(ctxt)
        loop do
          if cur_b(ctxt) == 0x5C
            fa_parse_char_class_esc(ctxt)
          else
            fa_parse_char_range(ctxt)
          end
          c = cur_b(ctxt)
          break unless c != 0x5D && c != 0x2D && c != 0 && ctxt.error == 0
        end
      end

      # xmlFAParseCharGroup
      #   [13] charGroup    ::= posCharGroup | negCharGroup | charClassSub
      #   [15] negCharGroup ::= '^' posCharGroup
      #   [16] charClassSub ::= ( posCharGroup | negCharGroup ) '-' charClassExpr
      def fa_parse_char_group(ctxt)
        neg = ctxt.neg

        if cur_b(ctxt) == 0x5E # '^'
          next_b(ctxt)
          ctxt.neg = c_not(ctxt.neg)
          fa_parse_pos_char_group(ctxt)
          ctxt.neg = neg
        end
        while cur_b(ctxt) != 0x5D && ctxt.error == 0
          if cur_b(ctxt) == 0x2D && nxt_b(ctxt, 1) == 0x5B
            next_b(ctxt) # eat the '-'
            next_b(ctxt) # eat the '['
            ctxt.neg = 2
            fa_parse_char_group(ctxt)
            ctxt.neg = neg
            if cur_b(ctxt) == 0x5D
              next_b(ctxt)
            else
              reg_error(ctxt, "charClassExpr: ']' expected")
            end
            break
          else
            fa_parse_pos_char_group(ctxt)
          end
        end
      end

      # xmlFAParseCharClass: [11] charClass ::= charClassEsc | charClassExpr
      def fa_parse_char_class(ctxt)
        if cur_b(ctxt) == 0x5B
          next_b(ctxt)
          ctxt.atom = reg_new_atom(ctxt, XML_REGEXP_RANGES)
          fa_parse_char_group(ctxt)
          if cur_b(ctxt) == 0x5D
            next_b(ctxt)
          else
            reg_error(ctxt, "xmlFAParseCharClass: ']' expected")
          end
        else
          fa_parse_char_class_esc(ctxt)
        end
      end

      # xmlFAParseQuantExact: [8] QuantExact ::= [0-9]+ ; returns -1 on error
      def fa_parse_quant_exact(ctxt)
        ret = 0
        ok = false
        overflow = false
        while (c = cur_b(ctxt)) >= 0x30 && c <= 0x39
          if ret > INT_MAX / 10
            overflow = true
          else
            digit = c - 0x30
            ret *= 10
            if ret > INT_MAX - digit
              overflow = true
            else
              ret += digit
            end
          end
          ok = true
          next_b(ctxt)
        end
        return -1 if !ok || overflow

        ret
      end

      # xmlFAParseQuantifier: [4] quantifier ::= [?*+] | ( '{' quantity '}' )
      def fa_parse_quantifier(ctxt)
        cur = cur_b(ctxt)
        if cur == 0x3F || cur == 0x2A || cur == 0x2B
          if ctxt.atom
            ctxt.atom.quant = if cur == 0x3F
              XML_REGEXP_QUANT_OPT
            elsif cur == 0x2A
              XML_REGEXP_QUANT_MULT
            else
              XML_REGEXP_QUANT_PLUS
            end
          end
          next_b(ctxt)
          return 1
        end
        if cur == 0x7B
          min = 0
          max = 0
          next_b(ctxt)
          cur = fa_parse_quant_exact(ctxt)
          if cur >= 0
            min = cur
          else
            reg_error(ctxt, "Improper quantifier")
          end
          if cur_b(ctxt) == 0x2C
            next_b(ctxt)
            if cur_b(ctxt) == 0x7D
              max = INT_MAX
            else
              cur = fa_parse_quant_exact(ctxt)
              if cur >= 0
                max = cur
              else
                reg_error(ctxt, "Improper quantifier")
              end
            end
          end
          if cur_b(ctxt) == 0x7D
            next_b(ctxt)
          else
            reg_error(ctxt, "Unterminated quantifier")
          end
          max = min if max == 0
          if ctxt.atom
            ctxt.atom.quant = XML_REGEXP_QUANT_RANGE
            ctxt.atom.min = min
            ctxt.atom.max = max
          end
          return 1
        end
        0
      end

      # xmlFAParseAtom: [9] atom ::= Char | charClass | ( '(' regExp ')' )
      def fa_parse_atom(ctxt)
        codepoint = fa_is_char(ctxt)
        if codepoint > 0
          ctxt.atom = reg_new_atom(ctxt, XML_REGEXP_CHARVAL)
          codepoint, len = get_utf8_char(ctxt.string, ctxt.cur)
          if codepoint < 0
            reg_error(ctxt, "Invalid UTF-8")
            return -1
          end
          ctxt.atom.codepoint = codepoint
          ctxt.cur += len
          return 1
        end
        cur = cur_b(ctxt)
        if cur == 0x7C || cur == 0 || cur == 0x29
          return 0
        elsif cur == 0x28
          next_b(ctxt)
          if ctxt.depth >= 50
            reg_error(ctxt, "xmlFAParseAtom: maximum nesting depth exceeded")
            return -1
          end
          # this extra Epsilon transition is needed if we count with 0 allowed unfortunately
          # this can't be known at that point
          fa_generate_epsilon_transition(ctxt, ctxt.state, nil)
          start0 = ctxt.state
          fa_generate_epsilon_transition(ctxt, ctxt.state, nil)
          start = ctxt.state
          oldend = ctxt.end
          ctxt.end = nil
          ctxt.atom = nil
          ctxt.depth += 1
          fa_parse_reg_exp(ctxt, 0)
          ctxt.depth -= 1
          if cur_b(ctxt) == 0x29
            next_b(ctxt)
          else
            reg_error(ctxt, "xmlFAParseAtom: expecting ')'")
          end
          ctxt.atom = reg_new_atom(ctxt, XML_REGEXP_SUBREG)
          ctxt.atom.start = start
          ctxt.atom.start0 = start0
          ctxt.atom.stop = ctxt.state
          ctxt.end = oldend
          return 1
        elsif cur == 0x5B || cur == 0x5C || cur == 0x2E
          fa_parse_char_class(ctxt)
          return 1
        end
        0
      end

      # xmlFAParsePiece: [3] piece ::= atom quantifier?
      def fa_parse_piece(ctxt)
        ctxt.atom = nil
        ret = fa_parse_atom(ctxt)
        return 0 if ret == 0

        reg_error(ctxt, "internal: no atom generated") if ctxt.atom.nil?
        fa_parse_quantifier(ctxt)
        1
      end

      # xmlFAParseBranch: [2] branch ::= piece*
      # +to+ is used to optimize by removing duplicate path in automata in expressions like
      # (a|b)(c|d)
      def fa_parse_branch(ctxt, to)
        previous = ctxt.state
        ret = fa_parse_piece(ctxt)
        if ret == 0
          # Empty branch
          fa_generate_epsilon_transition(ctxt, previous, to)
        else
          c = cur_b(ctxt)
          if fa_generate_transitions(ctxt, previous, (c == 0x7C || c == 0x29 || c == 0) ? to : nil, ctxt.atom) < 0
            ctxt.atom = nil
            return -1
          end
          previous = ctxt.state
          ctxt.atom = nil
        end
        while ret != 0 && ctxt.error == 0
          ret = fa_parse_piece(ctxt)
          next if ret == 0

          c = cur_b(ctxt)
          if fa_generate_transitions(ctxt, previous, (c == 0x7C || c == 0x29 || c == 0) ? to : nil, ctxt.atom) < 0
            ctxt.atom = nil
            return -1
          end
          previous = ctxt.state
          ctxt.atom = nil
        end
        0
      end

      # xmlFAParseRegExp: [1] regExp ::= branch ( '|' branch )*
      def fa_parse_reg_exp(ctxt, top)
        # if not top start should have been generated by an epsilon trans
        start = ctxt.state
        ctxt.end = nil
        fa_parse_branch(ctxt, nil)
        ctxt.state.type = XML_REGEXP_FINAL_STATE if top != 0
        if cur_b(ctxt) != 0x7C
          ctxt.end = ctxt.state
          return
        end
        end_ = ctxt.state
        while cur_b(ctxt) == 0x7C && ctxt.error == 0
          next_b(ctxt)
          ctxt.state = start
          ctxt.end = nil
          fa_parse_branch(ctxt, end_)
        end
        if top == 0
          ctxt.state = end_
          ctxt.end = end_
        end
      end

      # ------------------------------------------------------------------
      # The basic API
      # ------------------------------------------------------------------

      # xmlRegexpCompile: returns the compiled Regexp or nil (errors reported globally)
      def regexp_compile(regexp)
        return nil if regexp.nil?

        ctxt = reg_new_parser_ctxt(regexp)

        # initialize the parser
        ctxt.state = reg_state_push(ctxt)
        ctxt.start = ctxt.state
        ctxt.end = nil

        # parse the expression building an automata
        fa_parse_reg_exp(ctxt, 1)
        reg_error(ctxt, "xmlFAParseRegExp: extra characters") if cur_b(ctxt) != 0
        return nil if ctxt.error != 0

        ctxt.end = ctxt.state
        ctxt.start.type = XML_REGEXP_START_STATE
        ctxt.end.type = XML_REGEXP_FINAL_STATE

        # remove the Epsilon except for counted transitions
        fa_eliminate_epsilon_transitions(ctxt)

        return nil if ctxt.error != 0

        ret = reg_epx_from_parse(ctxt)
        ret.string = regexp.dup.freeze if ret
        ret
      end

      # xmlRegexpExec: 1 if it matches, 0 if not and a negative value in case of error
      def regexp_exec(comp, content)
        return -1 if comp.nil? || content.nil?

        fa_reg_exec(comp, content)
      end

      # xmlRegexpIsDeterminist: 1 if yes, 0 if not and a negative value in case of error
      def regexp_is_determinist(comp)
        return -1 if comp.nil?
        return comp.determinist if comp.determinist != -1

        am = ParserCtxt.new
        am.atoms = comp.atoms
        am.states = comp.states
        am.determinist = -1
        am.flags = comp.flags
        ret = fa_computes_determinism(am)
        comp.determinist = ret
        ret
      end

      # xmlRegFreeRegexp
      def reg_free_regexp(regexp); end

      # ------------------------------------------------------------------
      # The Automata interface
      # ------------------------------------------------------------------

      # xmlNewAutomata
      def new_automata
        ctxt = reg_new_parser_ctxt(nil)
        # initialize the parser
        ctxt.state = reg_state_push(ctxt)
        ctxt.start = ctxt.state
        ctxt.end = nil
        ctxt.start.type = XML_REGEXP_START_STATE
        ctxt.flags = 0
        ctxt
      end

      # xmlFreeAutomata
      def free_automata(am); end

      # xmlAutomataSetFlags
      def automata_set_flags(am, flags)
        return if am.nil?

        am.flags |= flags
      end

      # xmlAutomataGetInitState
      def automata_get_init_state(am)
        am&.start
      end

      # xmlAutomataSetFinalState
      def automata_set_final_state(am, state)
        return -1 if am.nil? || state.nil?

        state.type = XML_REGEXP_FINAL_STATE
        0
      end

      # token|token2 concatenation used by the *2 functions
      def join_tokens(token, token2)
        (token2.nil? || token2.empty?) ? token.dup : "#{token}|#{token2}"
      end
      private :join_tokens

      # xmlAutomataNewTransition
      def automata_new_transition(am, from, to, token, data)
        return nil if am.nil? || from.nil? || token.nil?

        atom = reg_new_atom(am, XML_REGEXP_STRING)
        atom.data = data
        atom.valuep = token.dup
        return nil if fa_generate_transitions(am, from, to, atom) < 0
        return am.state if to.nil?

        to
      end

      # xmlAutomataNewTransition2
      def automata_new_transition2(am, from, to, token, token2, data)
        return nil if am.nil? || from.nil? || token.nil?

        atom = reg_new_atom(am, XML_REGEXP_STRING)
        atom.data = data
        atom.valuep = join_tokens(token, token2)
        return nil if fa_generate_transitions(am, from, to, atom) < 0
        return am.state if to.nil?

        to
      end

      # xmlAutomataNewNegTrans
      def automata_new_neg_trans(am, from, to, token, token2, data)
        return nil if am.nil? || from.nil? || token.nil?

        atom = reg_new_atom(am, XML_REGEXP_STRING)
        atom.data = data
        atom.neg = 1
        atom.valuep = join_tokens(token, token2)
        err_msg = "not #{atom.valuep}"
        # snprintf(err_msg, 199, ...)
        err_msg = err_msg.byteslice(0, 198).force_encoding(::Encoding::UTF_8) if err_msg.bytesize > 198
        atom.valuep2 = err_msg
        return nil if fa_generate_transitions(am, from, to, atom) < 0

        am.negs += 1
        return am.state if to.nil?

        to
      end

      # xmlAutomataNewCountTrans2
      def automata_new_count_trans2(am, from, to, token, token2, min, max, data)
        return nil if am.nil? || from.nil? || token.nil?
        return nil if min < 0
        return nil if max < min || max < 1

        atom = reg_new_atom(am, XML_REGEXP_STRING)
        atom.valuep = join_tokens(token, token2)
        atom.data = data
        atom.min = min == 0 ? 1 : min
        atom.max = max

        # associate a counter to the transition.
        counter = reg_get_counter(am)
        am.counters[counter].min = min
        am.counters[counter].max = max

        to = reg_state_push(am) if to.nil?
        reg_state_add_trans(am, from, atom, to, counter, -1)
        return nil if reg_atom_push(am, atom) < 0

        am.state = to
        fa_generate_epsilon_transition(am, from, to) if min == 0
        to
      end

      # xmlAutomataNewCountTrans
      def automata_new_count_trans(am, from, to, token, min, max, data)
        return nil if am.nil? || from.nil? || token.nil?
        return nil if min < 0
        return nil if max < min || max < 1

        atom = reg_new_atom(am, XML_REGEXP_STRING)
        atom.valuep = token.dup
        atom.data = data
        atom.min = min == 0 ? 1 : min
        atom.max = max

        # associate a counter to the transition.
        counter = reg_get_counter(am)
        am.counters[counter].min = min
        am.counters[counter].max = max

        to = reg_state_push(am) if to.nil?
        reg_state_add_trans(am, from, atom, to, counter, -1)
        return nil if reg_atom_push(am, atom) < 0

        am.state = to
        fa_generate_epsilon_transition(am, from, to) if min == 0
        to
      end

      # xmlAutomataNewOnceTrans2
      def automata_new_once_trans2(am, from, to, token, token2, min, max, data)
        return nil if am.nil? || from.nil? || token.nil?
        return nil if min < 1
        return nil if max < min

        atom = reg_new_atom(am, XML_REGEXP_STRING)
        atom.valuep = join_tokens(token, token2)
        atom.data = data
        atom.quant = XML_REGEXP_QUANT_ONCEONLY
        atom.min = min
        atom.max = max
        # associate a counter to the transition.
        counter = reg_get_counter(am)
        am.counters[counter].min = 1
        am.counters[counter].max = 1

        to = reg_state_push(am) if to.nil?
        reg_state_add_trans(am, from, atom, to, counter, -1)
        return nil if reg_atom_push(am, atom) < 0

        am.state = to
        to
      end

      # xmlAutomataNewOnceTrans
      def automata_new_once_trans(am, from, to, token, min, max, data)
        return nil if am.nil? || from.nil? || token.nil?
        return nil if min < 1
        return nil if max < min

        atom = reg_new_atom(am, XML_REGEXP_STRING)
        atom.valuep = token.dup
        atom.data = data
        atom.quant = XML_REGEXP_QUANT_ONCEONLY
        atom.min = min
        atom.max = max
        # associate a counter to the transition.
        counter = reg_get_counter(am)
        am.counters[counter].min = 1
        am.counters[counter].max = 1

        to = reg_state_push(am) if to.nil?
        reg_state_add_trans(am, from, atom, to, counter, -1)
        return nil if reg_atom_push(am, atom) < 0

        am.state = to
        to
      end

      # xmlAutomataNewState
      def automata_new_state(am)
        return nil if am.nil?

        reg_state_push(am)
      end

      # xmlAutomataNewEpsilon
      def automata_new_epsilon(am, from, to)
        return nil if am.nil? || from.nil?

        fa_generate_epsilon_transition(am, from, to)
        return am.state if to.nil?

        to
      end

      # xmlAutomataNewAllTrans
      def automata_new_all_trans(am, from, to, lax)
        return nil if am.nil? || from.nil?

        fa_generate_all_transition(am, from, to, lax)
        return am.state if to.nil?

        to
      end

      # xmlAutomataNewCounter
      def automata_new_counter(am, min, max)
        return -1 if am.nil?

        ret = reg_get_counter(am)
        am.counters[ret].min = min
        am.counters[ret].max = max
        ret
      end

      # xmlAutomataNewCountedTrans
      def automata_new_counted_trans(am, from, to, counter)
        return nil if am.nil? || from.nil? || counter < 0

        fa_generate_counted_epsilon_transition(am, from, to, counter)
        return am.state if to.nil?

        to
      end

      # xmlAutomataNewCounterTrans
      def automata_new_counter_trans(am, from, to, counter)
        return nil if am.nil? || from.nil? || counter < 0

        fa_generate_counted_transition(am, from, to, counter)
        return am.state if to.nil?

        to
      end

      # xmlAutomataCompile: the compiled Regexp or nil
      def automata_compile(am)
        return nil if am.nil? || am.error != 0

        fa_eliminate_epsilon_transitions(am)
        return nil if am.error != 0

        # xmlFAComputesDeterminism(am);
        reg_epx_from_parse(am)
      end

      # xmlAutomataIsDeterminist: 1 if true, 0 if not, and -1 in case of error
      def automata_is_determinist(am)
        return -1 if am.nil?

        fa_computes_determinism(am)
      end
    end
  end
end
