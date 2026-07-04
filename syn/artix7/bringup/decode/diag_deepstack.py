#!/usr/bin/env python3
"""Diagnose where the func_test reconstructed stack over-nests (deep>6) or
under-nests (factorial<4): replay B/E and dump the stack at the anomaly, to
tell missed-E accumulation (decoder/noise) from a verifier miscount."""
import sys
from perfproto import load_ftrace_prints

KNOWN=("factorial","deep1","deep2","deep3","deep4","deep5","deep6","op_add",
       "op_sub","op_mul","cb_handler_a","cb_handler_b","pingpong","level_a",
       "level_b","level_c","leaf_add","leaf_mul","mydelay","conditional",
       "frame_func","indirect_caller","dispatch_callback","callback_test",
       "mixed_test","repeat_test","main_loop")
def dm(n):
    for k in KNOWN:
        if (str(len(k))+k) in n or n.endswith(k) or n==k: return k
    return n
events=[(ts,buf) for ts,pid,buf in load_ftrace_prints(sys.argv[1])]
DEEP={f"deep{i}" for i in range(1,7)}
stack=[]
max_deep=0; max_fact=0; reported_deep=False; reported_fact=False
for i,(ts,buf) in enumerate(events):
    if buf.startswith("B|"):
        nm=dm(buf.split("|",2)[2]) if buf.count("|")>=2 else buf
        stack.append(nm)
        dc=sum(1 for x in stack if x in DEEP)
        fc=sum(1 for x in stack if x=="factorial")
        if dc>max_deep:max_deep=dc
        if fc>max_fact:max_fact=fc
        if dc>6 and not reported_deep:
            reported_deep=True
            print(f"[OVER-NEST] deepcount={dc}>6 at ev{i} ts={ts}")
            print("  full stack:", stack[-16:])
        if fc==4 and not reported_fact:
            reported_fact=True
            print(f"[factorial=4 reached] at ev{i} ts={ts}")
    elif buf.startswith("E|"):
        if stack:stack.pop()
print(f"max deep nesting={max_deep} (truth 6), max factorial nesting={max_fact} (truth 4)")
print(f"final unclosed={len(stack)}")
