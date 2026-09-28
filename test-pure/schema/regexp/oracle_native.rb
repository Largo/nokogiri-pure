# frozen_string_literal: true

# Oracle process: runs harness cases against the libxml2 2.13.9 embedded in the native
# nokogiri 1.19.4 gem, calling xmlRegexp*/xmlAutomata*/xmlRegExec* through Fiddle (the
# nokogiri.so exports them).
#
#   ruby test-pure/schema/regexp/oracle_native.rb cases.json results.json
#
# Never load nokogiri-pure's lib/ in this process.
gem "nokogiri", "1.19.4"
require "nokogiri"
require "fiddle"
require "fiddle/import"
require "json"
require_relative "harness"

module NativeXml
  extend Fiddle::Importer
  SO = $LOADED_FEATURES.grep(/nokogiri\.so\z/).first
  dlload SO
  extern "void* xmlRegexpCompile(char*)"
  extern "int xmlRegexpExec(void*, char*)"
  extern "int xmlRegexpIsDeterminist(void*)"
  extern "void xmlRegexpPrint(void*, void*)"
  extern "void* xmlNewAutomata()"
  extern "void* xmlAutomataGetInitState(void*)"
  extern "int xmlAutomataSetFinalState(void*, void*)"
  extern "void* xmlAutomataNewState(void*)"
  extern "void* xmlAutomataNewTransition(void*, void*, void*, char*, void*)"
  extern "void* xmlAutomataNewTransition2(void*, void*, void*, char*, char*, void*)"
  extern "void* xmlAutomataNewNegTrans(void*, void*, void*, char*, char*, void*)"
  extern "void* xmlAutomataNewCountTrans(void*, void*, void*, char*, int, int, void*)"
  extern "void* xmlAutomataNewCountTrans2(void*, void*, void*, char*, char*, int, int, void*)"
  extern "void* xmlAutomataNewOnceTrans(void*, void*, void*, char*, int, int, void*)"
  extern "void* xmlAutomataNewOnceTrans2(void*, void*, void*, char*, char*, int, int, void*)"
  extern "void* xmlAutomataNewEpsilon(void*, void*, void*)"
  extern "void* xmlAutomataNewAllTrans(void*, void*, void*, int)"
  extern "int xmlAutomataNewCounter(void*, int, int)"
  extern "void* xmlAutomataNewCountedTrans(void*, void*, void*, int)"
  extern "void* xmlAutomataNewCounterTrans(void*, void*, void*, int)"
  extern "void* xmlAutomataCompile(void*)"
  extern "int xmlAutomataIsDeterminist(void*)"
  extern "void* xmlRegNewExecCtxt(void*, void*, void*)"
  extern "int xmlRegExecPushString(void*, char*, void*)"
  extern "int xmlRegExecPushString2(void*, char*, char*, void*)"
  extern "int xmlRegExecNextValues(void*, void*, void*, void*, void*)"
  extern "int xmlRegExecErrInfo(void*, void*, void*, void*, void*, void*)"
  extern "void xmlSetStructuredErrorFunc(void*, void*)"

  ErrorStruct = struct([
    "int domain", "int code", "char* message", "int level", "char* file", "int line",
    "char* str1", "char* str2", "char* str3", "int int1", "int int2", "void* ctxt", "void* node",
  ])

  LIBC = Fiddle::Handle::DEFAULT
  OPEN_MEMSTREAM = Fiddle::Function.new(LIBC["open_memstream"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
  FCLOSE = Fiddle::Function.new(LIBC["fclose"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  FREE = Fiddle::Function.new(LIBC["free"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
end

def cstr(ptr)
  ptr = Fiddle::Pointer.new(ptr) if ptr.is_a?(Integer)
  return nil if ptr.nil? || ptr.null?

  ptr.to_s.force_encoding(Encoding::UTF_8)
end

class NativeRegexpAdapter
  N = NativeXml

  def initialize
    @errors = []
    @handler = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]) do |_ctx, perr|
      e = N::ErrorStruct.new(perr)
      @errors << [e.domain, e.code, e.level, cstr(e.message), cstr(e.str1), cstr(e.str2), e.int1]
    end
    @keep = []
  end

  def nullable(p) = (p.nil? || p.null?) ? nil : p

  def capture_errors
    @errors = []
    N.xmlSetStructuredErrorFunc(nil, @handler)
    r = yield
    N.xmlSetStructuredErrorFunc(nil, nil)
    [r, @errors]
  end

  def regexp_compile(pat) = capture_errors { nullable(N.xmlRegexpCompile(pat)) }
  def regexp_exec(comp, s) = N.xmlRegexpExec(comp, s)
  def regexp_is_determinist(comp) = N.xmlRegexpIsDeterminist(comp)

  def regexp_print(comp)
    bufp = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
    sizep = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T)
    f = N::OPEN_MEMSTREAM.call(bufp, sizep)
    N.xmlRegexpPrint(f, comp)
    N::FCLOSE.call(f)
    buf = Fiddle::Pointer.new(bufp[0, Fiddle::SIZEOF_VOIDP].unpack1("J"))
    size = sizep[0, Fiddle::SIZEOF_SIZE_T].unpack1("J")
    out = buf[0, size]
    N::FREE.call(buf)
    out
  end

  def new_automata = nullable(N.xmlNewAutomata)
  def get_init(am) = nullable(N.xmlAutomataGetInitState(am))
  def new_state(am) = nullable(N.xmlAutomataNewState(am))
  def set_final(am, s) = N.xmlAutomataSetFinalState(am, s)
  def new_transition(am, f, t, tok, d) = nullable(N.xmlAutomataNewTransition(am, f, t, tok, d.to_i))
  def new_transition2(am, f, t, tok, tok2, d) = nullable(N.xmlAutomataNewTransition2(am, f, t, tok, tok2, d.to_i))
  def neg_trans(am, f, t, tok, tok2, d) = nullable(N.xmlAutomataNewNegTrans(am, f, t, tok, tok2, d.to_i))
  def count_trans(am, f, t, tok, mi, ma, d) = nullable(N.xmlAutomataNewCountTrans(am, f, t, tok, mi, ma, d.to_i))
  def count_trans2(am, f, t, tok, tok2, mi, ma, d) = nullable(N.xmlAutomataNewCountTrans2(am, f, t, tok, tok2, mi, ma, d.to_i))
  def once_trans(am, f, t, tok, mi, ma, d) = nullable(N.xmlAutomataNewOnceTrans(am, f, t, tok, mi, ma, d.to_i))
  def once_trans2(am, f, t, tok, tok2, mi, ma, d) = nullable(N.xmlAutomataNewOnceTrans2(am, f, t, tok, tok2, mi, ma, d.to_i))
  def epsilon(am, f, t) = nullable(N.xmlAutomataNewEpsilon(am, f, t))
  def all_trans(am, f, t, lax) = nullable(N.xmlAutomataNewAllTrans(am, f, t, lax))
  def new_counter(am, mi, ma) = N.xmlAutomataNewCounter(am, mi, ma)
  def counted_trans(am, f, t, c) = nullable(N.xmlAutomataNewCountedTrans(am, f, t, c))
  def counter_trans(am, f, t, c) = nullable(N.xmlAutomataNewCounterTrans(am, f, t, c))
  def automata_compile(am) = nullable(N.xmlAutomataCompile(am))
  def automata_is_determinist(am) = N.xmlAutomataIsDeterminist(am)

  # xmlAutomataState.no is the 5th int (type, mark, markd, reached, no)
  def state_no(s) = s[16, 4].unpack1("l")

  def new_exec(comp, cbs)
    cb = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP] * 4) do |_data, token, transdata, inputdata|
      cbs << [cstr(token), transdata.to_i, inputdata.to_i]
    end
    @keep << cb
    nullable(N.xmlRegNewExecCtxt(comp, cb, 7))
  end

  def push(exec, v, d) = N.xmlRegExecPushString(exec, v, d.to_i)
  def push2(exec, v, v2, d) = N.xmlRegExecPushString2(exec, v, v2, d.to_i)

  def get_values(maxval)
    nbval = Fiddle::Pointer.malloc(4)
    nbval[0, 4] = [maxval].pack("l")
    nbneg = Fiddle::Pointer.malloc(4)
    nbneg[0, 4] = [-12345].pack("l")
    terminal = Fiddle::Pointer.malloc(4)
    terminal[0, 4] = [-12345].pack("l")
    values = Fiddle::Pointer.malloc(8 * maxval)
    values[0, 8 * maxval] = "\0" * (8 * maxval)
    ret = yield nbval, nbneg, values, terminal
    nv = nbval[0, 4].unpack1("l")
    nn = nbneg[0, 4].unpack1("l")
    t = terminal[0, 4].unpack1("l")
    t = nil if t == -12345
    nn = 0 if nn == -12345
    vals = values[0, 8 * maxval].unpack("J*").take_while { |x| x != 0 }.map { |x| cstr(x) }
    [ret, nv, nn, vals, t]
  end

  def next_values(exec, maxval)
    get_values(maxval) { |a, b, c, d| N.xmlRegExecNextValues(exec, a, b, c, d) }
  end

  def err_info(exec, maxval)
    strp = Fiddle::Pointer.malloc(8)
    strp[0, 8] = "\0" * 8
    ret, nv, nn, vals, t = get_values(maxval) { |a, b, c, d| N.xmlRegExecErrInfo(exec, strp, a, b, c, d) }
    [ret, cstr(strp[0, 8].unpack1("J")), nv, nn, vals, t]
  end
end

# Runs one case in a forked child so that cases on which libxml2 itself loops forever (e.g.
# "((){1}(){0,}){0,0}" against "ab") are reported as {"timeout"=>true} instead of hanging.
def run_case_forked(api, kase, timeout)
  rd, wr = IO.pipe
  pid = fork do
    rd.close
    $stderr.reopen(File::NULL) # crash reports of cases where libxml2 itself segfaults
    r = if kase["kind"] == "regexp"
      RegexpHarness.run_regexp_case(api, kase)
    else
      RegexpHarness.run_automata_case(api, kase)
    end
    wr.write(JSON.generate(r))
    wr.close
    exit!(0)
  end
  wr.close
  out = +""
  deadline = Time.now + timeout
  loop do
    left = deadline - Time.now
    if left <= 0
      Process.kill(:KILL, pid)
      Process.wait(pid)
      rd.close
      return { "timeout" => true }
    end
    ready = IO.select([rd], nil, nil, left)
    next unless ready

    chunk = rd.read_nonblock(65536, exception: false)
    break if chunk.nil?

    out << chunk unless chunk == :wait_readable
  end
  rd.close
  Process.wait(pid)
  return { "crash" => true } if out.empty? # libxml2 crashed (undefined behaviour in C)

  JSON.parse(out)
end

if $PROGRAM_NAME == __FILE__
  cases = JSON.parse(File.read(ARGV[0]))
  api = NativeRegexpAdapter.new
  timeout = (ENV["ORACLE_TIMEOUT"] || "10").to_f
  results = cases.map { |kase| run_case_forked(api, kase, timeout) }
  File.write(ARGV[1], JSON.generate(results))
end
