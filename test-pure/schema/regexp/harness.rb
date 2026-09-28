# frozen_string_literal: true

# Shared code of the XmlRegexp differential harness. Loaded both by the native oracle process
# (oracle_native.rb, libxml2 of the nokogiri 1.19.4 gem called through Fiddle) and by the pure
# side (pure_adapter.rb). A case is plain JSON data; running it against an "api" adapter
# produces a plain JSON-able result, and the two results must be identical.
#
# Regexp case:   {"kind"=>"regexp", "pattern"=>P, "strings"=>[S...]}
#   result: {"errors"=>[[domain, code, level, message, str1, str2, int1]...], "compiled"=>bool,
#            "print"=>xmlRegexpPrint output, "det"=>int, "exec"=>[int per string]}
# Automata case: {"kind"=>"model", "tree"=>T, "runs"=>[[[name, ns]...]...]}   (xmlschemas.c style)
#                {"kind"=>"program", "program"=>[[op, args...]...], "runs"=>[...]}  (raw API)
#   result: {"build"=>[...], "compiled"=>bool, "det"=>int, "print"=>..., "runs"=>[[push results]]}

module RegexpHarness
  UNBOUNDED = 1 << 30
  MAXVAL = 10

  module_function

  # printable form of a binary print dump (JSON needs valid UTF-8)
  def safe(str)
    return nil if str.nil?

    s = str.b
    s.gsub(/[^\x20-\x7e\n]/n) { |c| format("\\x%02x", c.ord) }.force_encoding(Encoding::UTF_8)
  end

  # xmlRegexpPrint masks: SUBREG atoms print pointers into possibly freed states
  def normalize_print(str)
    str&.gsub(/start -?\d+ end -?\d+/, "start ? end ?")
  end

  def run_regexp_case(api, kase)
    comp, errors = api.regexp_compile(decode_str(kase["pattern"]))
    errors = errors.map { |e| e.map { |v| v.is_a?(String) ? json_str(v) : v } }
    res = { "errors" => errors, "compiled" => !comp.nil? }
    if comp
      res["print"] = normalize_print(safe(api.regexp_print(comp)))
      res["det"] = api.regexp_is_determinist(comp)
      res["exec"] = kase["strings"].map { |s| api.regexp_exec(comp, decode_str(s)) }
    end
    res
  end

  def json_str(v)
    u = v.dup.force_encoding(Encoding::UTF_8)
    u.valid_encoding? ? u : "hex:#{v.unpack1("H*")}"
  end

  # strings in cases: plain String or {"hex"=>"..."} for arbitrary bytes
  def decode_str(s)
    s.is_a?(Hash) ? [s["hex"]].pack("H*") : s
  end

  # ------------------------------------------------------------------
  # xmlschemas.c content model construction (xmlSchemaBuildAContentModel & co), used to build
  # realistic automata. Tree nodes:
  #   ["elem", name, ns, min, max]            (max -1 = unbounded)
  #   ["subst", name, ns, [[name, ns]...], min, max]
  #   ["seq", min, max, [children]]
  #   ["choice", min, max, [children]]
  #   ["all", min, [["elem", name, ns, min(0/1), 1]...]]
  #   ["any", min, max, "any" | ["ns", [ns...]] | ["not", ns]]
  # ------------------------------------------------------------------
  class ModelBuilder
    attr_reader :api, :am

    def initialize(api)
      @api = api
      @data_ids = {}
    end

    def data_id(key)
      @data_ids[key] ||= 100 + @data_ids.size
    end

    def max_of(m) = m == -1 ? UNBOUNDED : m

    def build(tree)
      @am = api.new_automata
      @state = api.get_init(@am)
      build_particle(tree)
      api.set_final(@am, @state)
      api.automata_compile(@am)
    end

    def build_particle(p)
      case p[0]
      when "elem" then build_elem(p)
      when "subst" then build_subst(p, -1, nil)
      when "any" then build_any(p)
      when "seq" then build_seq(p)
      when "choice" then build_choice(p)
      when "all" then build_all(p)
      else raise "bad node #{p.inspect}"
      end
    end

    def build_any(p)
      _, min, max, kind = p
      max = max_of(max)
      wild = data_id(["any", p.object_id])
      start = @state
      end_ = api.new_state(@am)
      if max == 1
        add_any = lambda do |target|
          if kind == "any"
            @state = api.new_transition2(@am, start, nil, "*", "*", wild)
            api.epsilon(@am, @state, target)
            @state = api.new_transition2(@am, start, nil, "*", nil, wild)
            api.epsilon(@am, @state, target)
          elsif kind[0] == "ns"
            kind[1].each do |ns|
              @state = start
              @state = api.new_transition2(@am, @state, nil, "*", ns, wild)
              api.epsilon(@am, @state, target)
            end
          else
            @state = api.neg_trans(@am, start, target, "*", kind[1], wild)
          end
        end
        add_any.call(end_)
      else
        maxo = max == UNBOUNDED ? UNBOUNDED : max - 1
        mino = min < 1 ? 0 : min - 1
        counter = api.new_counter(@am, mino, maxo)
        hop = api.new_state(@am)
        if kind == "any"
          @state = api.new_transition2(@am, start, nil, "*", "*", wild)
          api.epsilon(@am, @state, hop)
          @state = api.new_transition2(@am, start, nil, "*", nil, wild)
          api.epsilon(@am, @state, hop)
        elsif kind[0] == "ns"
          kind[1].each do |ns|
            @state = api.new_transition2(@am, start, nil, "*", ns, wild)
            api.epsilon(@am, @state, hop)
          end
        else
          @state = api.neg_trans(@am, start, hop, "*", kind[1], wild)
        end
        api.counted_trans(@am, hop, start, counter)
        api.counter_trans(@am, hop, end_, counter)
      end
      ret = 0
      if min == 0
        api.epsilon(@am, start, end_)
        ret = 1
      end
      @state = end_
      ret
    end

    def build_subst(p, counter, end_)
      _, name, ns, members, min, max = p
      max = max_of(max)
      start = @state
      end_ ||= api.new_state(@am)
      head = data_id(["elem", name, ns])
      ret = 0
      if counter >= 0
        tmp = api.counted_trans(@am, start, nil, counter)
        api.new_transition2(@am, tmp, end_, name, ns, head)
        members.each { |mn, mns| api.new_transition2(@am, tmp, end_, mn, mns, data_id(["elem", mn, mns])) }
      elsif max == 1
        api.epsilon(@am, api.new_transition2(@am, start, nil, name, ns, head), end_)
        members.each do |mn, mns|
          tmp = api.new_transition2(@am, start, nil, mn, mns, data_id(["elem", mn, mns]))
          api.epsilon(@am, tmp, end_)
        end
      else
        maxo = max == UNBOUNDED ? UNBOUNDED : max - 1
        mino = min < 1 ? 0 : min - 1
        counter = api.new_counter(@am, mino, maxo)
        hop = api.new_state(@am)
        api.epsilon(@am, api.new_transition2(@am, start, nil, name, ns, head), hop)
        members.each do |mn, mns|
          api.epsilon(@am, api.new_transition2(@am, start, nil, mn, mns, data_id(["elem", mn, mns])), hop)
        end
        api.counted_trans(@am, hop, start, counter)
        api.counter_trans(@am, hop, end_, counter)
      end
      if min == 0
        api.epsilon(@am, start, end_)
        ret = 1
      end
      @state = end_
      ret
    end

    def build_elem(p)
      _, name, ns, min, max = p
      max = max_of(max)
      decl = data_id(["elem", name, ns])
      ret = 0
      if max == 1
        start = @state
        @state = api.new_transition2(@am, start, nil, name, ns, decl)
      elsif max >= UNBOUNDED && min < 2
        start = @state
        @state = api.new_transition2(@am, start, nil, name, ns, decl)
        @state = api.new_transition2(@am, @state, @state, name, ns, decl)
      else
        maxo = max == UNBOUNDED ? UNBOUNDED : max - 1
        mino = min < 1 ? 0 : min - 1
        start = api.epsilon(@am, @state, nil)
        counter = api.new_counter(@am, mino, maxo)
        @state = api.new_transition2(@am, start, nil, name, ns, decl)
        api.counted_trans(@am, @state, start, counter)
        @state = api.counter_trans(@am, @state, nil, counter)
      end
      if min == 0
        api.epsilon(@am, start, @state)
        ret = 1
      end
      ret
    end

    def build_children(children)
      ret = 1
      children.each { |sub| ret = 0 if build_particle(sub) != 1 }
      ret
    end

    def build_seq(p)
      _, min, max, children = p
      max = max_of(max)
      ret = 1
      if min == 1 && max == 1
        ret = build_children(children)
      else
        oldstate = @state
        if max >= UNBOUNDED
          if min > 1
            @state = api.epsilon(@am, oldstate, nil)
            oldstate = @state
            counter = api.new_counter(@am, min - 1, UNBOUNDED)
            ret = 0 if build_children(children) != 1
            tmp = @state
            api.counted_trans(@am, tmp, oldstate, counter)
            @state = api.counter_trans(@am, tmp, nil, counter)
            api.epsilon(@am, oldstate, @state) if ret == 1
          else
            @state = api.epsilon(@am, oldstate, nil)
            oldstate = @state
            ret = 0 if build_children(children) != 1
            api.epsilon(@am, @state, oldstate)
            @state = api.epsilon(@am, @state, nil)
            if min == 0
              api.epsilon(@am, oldstate, @state)
              ret = 1
            end
          end
        elsif max > 1 || min > 1
          @state = api.epsilon(@am, oldstate, nil)
          oldstate = @state
          counter = api.new_counter(@am, min - 1, max - 1)
          ret = 0 if build_children(children) != 1
          tmp = @state
          api.counted_trans(@am, tmp, oldstate, counter)
          @state = api.counter_trans(@am, tmp, nil, counter)
          if min == 0 || ret == 1
            api.epsilon(@am, oldstate, @state)
            ret = 1
          end
        else
          ret = 0 if build_children(children) != 1
          @state = api.epsilon(@am, @state, nil)
          if min == 0
            api.epsilon(@am, oldstate, @state)
            ret = 1
          end
        end
      end
      ret
    end

    def build_choice(p)
      _, min, max, children = p
      max = max_of(max)
      ret = 0
      start = @state
      end_ = api.new_state(@am)
      if max == 1
        children.each do |sub|
          @state = start
          ret = 1 if build_particle(sub) == 1
          api.epsilon(@am, @state, end_)
        end
      else
        maxo = max == UNBOUNDED ? UNBOUNDED : max - 1
        mino = min < 1 ? 0 : min - 1
        counter = api.new_counter(@am, mino, maxo)
        hop = api.new_state(@am)
        base = api.new_state(@am)
        children.each do |sub|
          @state = base
          ret = 1 if build_particle(sub) == 1
          api.epsilon(@am, @state, hop)
        end
        api.epsilon(@am, start, base)
        api.counted_trans(@am, hop, base, counter)
        api.counter_trans(@am, hop, end_, counter)
        api.epsilon(@am, base, end_) if ret == 1
      end
      if min == 0
        api.epsilon(@am, start, end_)
        ret = 1
      end
      @state = end_
      ret
    end

    def build_all(p)
      _, min, children = p
      return 1 if children.empty?

      start = @state
      tmp = api.new_state(@am)
      api.epsilon(@am, @state, tmp)
      @state = tmp
      children.each do |sub|
        @state = tmp
        if sub[0] == "subst"
          _, name, ns, _members, smin, smax = sub
          counter = api.new_counter(@am, smin, smax)
          build_subst(sub, counter, @state)
          _ = [name, ns]
        else
          _, name, ns, smin, smax = sub
          decl = data_id(["elem", name, ns])
          if smin == 1 && smax == 1
            api.once_trans2(@am, @state, @state, name, ns, 1, 1, decl)
          elsif smin == 0 && smax == 1
            api.count_trans2(@am, @state, @state, name, ns, 0, 1, decl)
          end
        end
      end
      @state = api.all_trans(@am, @state, nil, 0)
      ret = 0
      if min == 0
        api.epsilon(@am, start, @state)
        ret = 1
      end
      ret
    end
  end

  # ------------------------------------------------------------------
  # Raw automata programs: [op, args...]; state args are indexes into the states table
  # (index 0 = init state), nil = NULL. Ops returning a state append it to the table.
  # ------------------------------------------------------------------
  def run_program(api, program)
    am = api.new_automata
    states = [api.get_init(am)]
    build = []
    st = ->(i) { i.nil? ? nil : states[i] }
    program.each do |op, *a|
      r = case op
          when "state" then api.new_state(am)
          when "final" then api.set_final(am, st.(a[0]))
          when "trans" then api.new_transition(am, st.(a[0]), st.(a[1]), a[2], a[3])
          when "trans2" then api.new_transition2(am, st.(a[0]), st.(a[1]), a[2], a[3], a[4])
          when "neg" then api.neg_trans(am, st.(a[0]), st.(a[1]), a[2], a[3], a[4])
          when "count" then api.count_trans(am, st.(a[0]), st.(a[1]), a[2], a[3], a[4], a[5])
          when "count2" then api.count_trans2(am, st.(a[0]), st.(a[1]), a[2], a[3], a[4], a[5], a[6])
          when "once" then api.once_trans(am, st.(a[0]), st.(a[1]), a[2], a[3], a[4], a[5])
          when "once2" then api.once_trans2(am, st.(a[0]), st.(a[1]), a[2], a[3], a[4], a[5], a[6])
          when "eps" then api.epsilon(am, st.(a[0]), st.(a[1]))
          when "all" then api.all_trans(am, st.(a[0]), st.(a[1]), a[2])
          when "counter" then api.new_counter(am, a[0], a[1])
          when "counted" then api.counted_trans(am, st.(a[0]), st.(a[1]), a[2])
          when "countertrans" then api.counter_trans(am, st.(a[0]), st.(a[1]), a[2])
          when "isdet" then api.automata_is_determinist(am)
          else raise "bad op #{op}"
          end
      if %w[final counter isdet].include?(op)
        build << r
      else
        build << (r.nil? ? nil : api.state_no(r))
        states << r
      end
    end
    [api.automata_compile(am), build]
  end

  def run_automata_case(api, kase)
    res = {}
    if kase["kind"] == "model"
      comp = ModelBuilder.new(api).build(kase["tree"])
    else
      comp, build = run_program(api, kase["program"])
      res["build"] = build
    end
    res["compiled"] = !comp.nil?
    return res if comp.nil?

    res["det"] = api.regexp_is_determinist(comp)
    res["print"] = normalize_print(safe(api.regexp_print(comp)))
    res["runs"] = kase["runs"].map { |run| run_push(api, comp, run) }
    res
  end

  # one push sequence: tokens are [name, ns] (ns nil -> PushString, else PushString2), then
  # the end-of-input push. Records return values, callbacks, next values and err info.
  def run_push(api, comp, run)
    cbs = []
    exec = api.new_exec(comp, cbs)
    return "noexec" if exec.nil?

    out = []
    (run + [nil]).each_with_index do |tok, i|
      nv = api.next_values(exec, MAXVAL)
      r = if tok.nil?
        api.push(exec, nil, nil)
      elsif tok[1].nil?
        api.push(exec, tok[0], 1000 + i)
      else
        api.push2(exec, tok[0], tok[1], 1000 + i)
      end
      ei = api.err_info(exec, MAXVAL)
      out << { "ret" => r, "next" => nv, "err" => ei.map { |v| v.is_a?(String) ? json_str(v) : v }, "cb" => cbs.dup }
      cbs.clear
    end
    out
  end
end
