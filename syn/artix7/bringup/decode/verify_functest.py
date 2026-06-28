#!/usr/bin/env python3
"""verify_functest — score a reconstructed call-stack (orbetto Perfetto trace OR
an orbetm instruction dump) against func_test.c's KNOWN call tree.

func_test.c (proj.axf) is deterministic, no interrupts, no RTOS. Known truths:
  - factorial(4): 4-deep recursion (factorial calls itself n-1 times)
  - deep1->deep2->...->deep6: 6-deep direct call chain
  - indirect_caller -> op_table[idx] (op_add/op_sub/op_mul via BLX)
  - dispatch_callback -> cb_handler_a/cb_handler_b (callback via BLX)
  - repeat_test -> pingpong x5 (each B/E paired)
  - level_a->level_b->level_c (3-deep chain)

This reads an orbetto .perf (B|/E| ftrace slices) and checks how well the known
relationships appear. It is a RELATIVE quality metric for A/B comparing decoders
on the SAME capture.

Usage: verify_functest.py <orbetto.perf>
"""
import sys, collections

data = open(sys.argv[1], "rb").read()

def rv(b, i):
    s = r = 0
    while True:
        x = b[i]; i += 1; r |= (x & 0x7f) << s
        if not x & 0x80: break
        s += 7
    return r, i

def parse(b):
    o = []; i = 0; n = len(b)
    while i < n:
        try: key, i = rv(b, i)
        except: break
        fn = key >> 3; wt = key & 7
        if wt == 0: v, i = rv(b, i); o.append((fn, wt, v))
        elif wt == 2:
            ln, i = rv(b, i); o.append((fn, wt, b[i:i+ln])); i += ln
        elif wt == 5: o.append((fn, wt, b[i:i+4])); i += 4
        elif wt == 1: o.append((fn, wt, b[i:i+8])); i += 8
        else: break
    return o

# extract ordered (ts, kind, name) B/E events
events = []
for fn, wt, v in parse(data):
    if fn != 1 or wt != 2: continue
    for pfn, pwt, pv in parse(v):
        if pfn == 1 and pwt == 2:
            for bfn, bwt, bv in parse(pv):
                if bfn == 2 and bwt == 2:
                    ev = parse(bv)
                    ts = None; buf = None
                    for efn, ewt, evv in ev:
                        if efn == 1 and ewt == 0: ts = evv
                        if ewt == 2 and isinstance(evv,(bytes,bytearray)):
                            for sfn,swt,sv in parse(evv):
                                if swt==2 and isinstance(sv,(bytes,bytearray)):
                                    s=bytes(sv)
                                    if s[:2] in (b"B|",b"E|"): buf=s
                    if buf is not None and ts is not None:
                        events.append((ts, buf.decode('latin1','replace')))

events.sort(key=lambda x: x[0])

def demangle(n):
    # The orbetto decoder now emits already-demangled, prefix-stripped names
    # like "mydelay(unsigned int)", "level_a(unsigned int)", "main_loop()", and
    # sometimes still "(anonymous namespace)::foo(...)" or a raw length-prefixed
    # mangling. Reduce any of these to the bare identifier and match the known
    # set exactly.
    KNOWN = ("factorial","deep1","deep2","deep3","deep4","deep5","deep6",
             "op_add","op_sub","op_mul","cb_handler_a","cb_handler_b",
             "pingpong","level_a","level_b","level_c","leaf_add","leaf_mul",
             "mydelay","conditional","frame_func","indirect_caller",
             "dispatch_callback","callback_test","mixed_test","repeat_test",
             "main_loop")
    # core identifier: drop namespace qualifier and parameter list
    core = n
    if "::" in core:
        core = core.split("::")[-1]
    core = core.split("(")[0].strip()
    if core in KNOWN:
        return core
    # fallback for still-mangled forms (length-prefixed)
    for k in KNOWN:
        if (str(len(k))+k) in n or n.endswith(k) or n == k:
            return k
    return n

# walk B/E into nested call records; track max recursion of factorial,
# max depth of deep chain, indirect targets seen, pingpong pairings.
stack = []
b_total = e_total = 0
factorial_max_nest = 0
deep_max = 0
indirect_targets = set()
callback_targets = set()
pingpong_pairs = 0
funcs_seen = collections.Counter()
cur_deepchain = 0

DEEP = {f"deep{i}" for i in range(1,7)}
INDIR = {"op_add","op_sub","op_mul"}
CB = {"cb_handler_a","cb_handler_b"}

for ts, buf in events:
    if buf.startswith("B|"):
        b_total += 1
        name = demangle(buf.split("|",2)[2]) if buf.count("|")>=2 else buf
        stack.append(name)
        funcs_seen[name]+=1
        # factorial recursion depth
        fc = sum(1 for x in stack if x=="factorial")
        factorial_max_nest=max(factorial_max_nest,fc)
        # deep chain depth
        dc = sum(1 for x in stack if x in DEEP)
        deep_max=max(deep_max,dc)
        if name in INDIR: indirect_targets.add(name)
        if name in CB: callback_targets.add(name)
        if name=="pingpong": pingpong_pairs+=1
    elif buf.startswith("E|"):
        e_total += 1
        if stack: stack.pop()

print(f"total B={b_total} E={e_total} (orphan E={max(0,e_total-b_total)}, unclosed={max(0,b_total-e_total)})")
print(f"--- func_test ground-truth checks ---")
print(f"factorial max recursion nesting : {factorial_max_nest}  (truth: 4 for factorial(4))")
print(f"deep chain max nesting          : {deep_max}  (truth: 6 for deep1..deep6)")
print(f"indirect op_* targets resolved  : {sorted(indirect_targets)}  (truth: op_add/op_sub/op_mul)")
print(f"callback cb_* targets resolved  : {sorted(callback_targets)}  (truth: cb_handler_a/b)")
print(f"pingpong B events               : {pingpong_pairs}  (truth: multiple, B/E paired)")
print(f"distinct funcs in stack         : {len(funcs_seen)}")
# crude score
score = 0
score += min(factorial_max_nest,4)          # up to 4
score += min(deep_max,6)                     # up to 6
score += len(indirect_targets)               # up to 3
score += len(callback_targets)               # up to 2
print(f"\nGROUND-TRUTH SCORE = {score} / 15  (higher=more accurate nesting)")
