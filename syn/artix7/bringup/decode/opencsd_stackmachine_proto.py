#!/usr/bin/env python3
"""Minimal call-stack machine on top of opencsd INSTR_RANGE stream (v2).

Model (opencsd ranges are the ordered executed control flow):
  - current function = fn_at(range.start)
  - range ends in executed 'b+link' (BL/BLX)  -> CALL: next range.start is the
    callee entry; push return addr = range.end
  - range ends in executed 'impl ret'         -> RETURN: pop
  - we emit a B|<fn> (begin) whenever the top-of-stack function *changes to a
    new frame* via a call; E| on return. coremark_main should be 1.
"""
import re, sys, bisect
from collections import Counter

LISTER = sys.argv[1] if len(sys.argv) > 1 else "/tmp/cm100_lister.log"
DIS    = sys.argv[2] if len(sys.argv) > 2 else "/tmp/cm100.dis"

func_start = {}
with open(DIS) as f:
    for line in f:
        m = re.match(r"^([0-9a-f]+) <([^>]+)>:", line)
        if m:
            func_start[int(m.group(1), 16)] = m.group(2)
starts = sorted(func_start)
def fn_at(a):
    i = bisect.bisect_right(starts, a) - 1
    return func_start[starts[i]] if i >= 0 else "?"

RX = re.compile(
    r"INSTR_RANGE\(exec range=0x([0-9a-f]+):\[0x([0-9a-f]+)\].*?\)\s*([EN])\s+(i?BR)(.*?)\)")
ranges = []
with open(LISTER, errors="ignore") as f:
    for line in f:
        if "INSTR_RANGE" not in line:
            continue
        line = line.replace("\r", "")
        m = RX.search(line)
        if not m:
            continue
        ranges.append((int(m.group(1),16), int(m.group(2),16),
                       m.group(3)=="E", m.group(4)=="iBR",
                       "b+link" in m.group(5), "impl ret" in m.group(5)))

print(f"parsed {len(ranges)} INSTR_RANGE elements")

# stack of frames: each is [func_name, return_addr]
stack = []
begins = Counter()
ends = Counter()
max_depth = 0
mismatched_returns = 0

# seed with the function of the first range
if ranges:
    f0 = fn_at(ranges[0][0])
    stack.append([f0, None])
    begins[f0] += 1

for i, (start, end, ex, ibr, is_call, is_ret) in enumerate(ranges):
    fn = fn_at(start)
    # keep top frame's function name in sync (covers fallthrough within/into fn)
    if stack and stack[-1][0] != fn and not (ex and is_ret):
        # if we fell through into a different function without an explicit
        # call (tail-call / cond branch into another symbol), just relabel top
        stack[-1][0] = fn

    if ex and is_call:
        ret = end
        callee = fn_at(ranges[i+1][0]) if i+1 < len(ranges) else fn
        stack.append([callee, ret])
        begins[callee] += 1
        max_depth = max(max_depth, len(stack))
    elif ex and is_ret:
        if len(stack) > 1:
            popped = stack.pop()
            ends[popped[0]] += 1
        else:
            mismatched_returns += 1

print(f"max call depth: {max_depth}")
print(f"distinct functions entered: {len(begins)}")
print(f"mismatched returns (pop at depth<=1): {mismatched_returns}")
print(f"total begins: {sum(begins.values())}")
print()
print("=== begin counts (ground truth: coremark_main == 1) ===")
for name in ["coremark_main", "cm_benchmark_main", "core_bench_list",
             "core_state_transition", "crc16", "crcu32", "crcu16",
             "cmp_complex", "matrix_test", "cm_uart_send_char",
             "cm_uart_puts", "HAL_UART_Transmit", "ee_printf"]:
    print(f"  {name:26s}: begin={begins.get(name,0):6d}  end={ends.get(name,0):6d}")
