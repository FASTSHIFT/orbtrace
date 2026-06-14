#!/usr/bin/env python3
"""etm_to_perfetto — function-level Perfetto timeline straight from our own
decode + the FPGA capture-time base. No orbetto/Mortrall needed.

Why roll our own: Mortrall is a ~1200-line instruction-level call-stack
rebuilder coupled to orbuculum's decoder, and it times everything off the ETM
cycleCount — which is 0 on the F429 (no TSGEN, doc 15 §24). We only need
FUNCTION level, and we already have all three ingredients:
  * clean ETM bytes (tpiu_deframe_walk, 0.000% unknown),
  * an absolute PC anchor + its byte offset at every I-sync packet
    (etm35lib.find_isyncs -> ISync.addr / ISync.offset),
  * the wall-clock ns of every ETM byte (FPGA time base, fpga_timebase).

So: each I-sync gives (PC, time). Map PC -> ELF function (arm-none-eabi-nm
symbol ranges). Emit a Perfetto/Chrome JSON trace where each function occupies
the interval from its anchor to the next. Drag the .json into
https://ui.perfetto.dev to view.

NOTE (honest scope): branch TARGET decode is not implemented in etm35lib
(addresses between anchors are not advanced), so this is FUNCTION-resolution,
anchored at I-sync points — not exact per-instruction PC. That is exactly what
a function-level timeline needs; the I-syncs on the F429 are periodic and dense
enough to follow function changes.

Usage:
  etm_to_perfetto.py <etm.bin> <etm.bin.time.json> <proj.axf> <out.json>
  # <etm.bin> and <.time.json> come from etm_with_time.py
"""
import json
import subprocess
import sys
from bisect import bisect_right

import etm35lib as L


def load_symbols(elf):
    """Return (starts[], sym[start]=(end,name)) for FUNC/text symbols via nm.
    nm -nSC prints demangled: <addr> <size> <type> <name>. We keep code symbols
    (t/T/w/W) with a size, sorted by address, and synthesize end = addr+size.
    -C demangles C++ names so Perfetto shows loop_sum(int) not _Z8loop_sumi."""
    out = subprocess.check_output(
        ["arm-none-eabi-nm", "-nSC", "--defined-only", elf],
        text=True, errors="replace")
    funcs = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        addr_s, size_s, typ, name = parts[0], parts[1], parts[2], parts[3]
        if typ not in ("t", "T", "w", "W"):
            continue
        try:
            addr = int(addr_s, 16)
            size = int(size_s, 16)
        except ValueError:
            continue
        if size == 0:
            continue
        funcs.append((addr, addr + size, name))
    funcs.sort()
    starts = [f[0] for f in funcs]
    return starts, funcs


def func_for_pc(pc, starts, funcs):
    """Return the function name whose [start,end) contains pc, else a hex bucket."""
    k = bisect_right(starts, pc) - 1
    if 0 <= k < len(funcs):
        s, e, name = funcs[k]
        if s <= pc < e:
            return name
    return f"0x{pc & ~1:08x}"


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        return 2
    etm_path, time_path, elf, out_path = sys.argv[1:5]
    etm = open(etm_path, "rb").read()
    tj = json.load(open(time_path))
    times_ns = tj["times_ns"]               # wall-clock ns per ETM byte
    starts, funcs = load_symbols(elf)

    # Anchors: every Normal I-sync gives an absolute PC at a known byte offset.
    isyncs = L.find_isyncs(etm)
def build_stack_events(named_anchors, end_ns, pid=1, tid=1):
    """Pure call-stack reconstruction (testable). Input: a time-sorted list of
    (time_ns, function_name) anchors and the end time. Output: a list of
    Chrome/Perfetto trace events (process/thread metadata + nested B/E).

    Heuristic (no exact call/return available — see module docstring): walk
    anchors;
      * same function as stack top         -> still running, nothing to do;
      * function already lower in the stack -> a RETURN: pop frames above it;
      * otherwise                          -> a CALL: push it.
    Exact for non-recursive flows like proj_add (loop_sum -> add). Recursion or
    tail-calls would fool it (documented limitation). Returns (events, calls).
    """
    events = [
        {"name": "process_name", "ph": "M", "pid": pid, "tid": tid,
         "args": {"name": "ETM (FPGA wall-clock)"}},
        {"name": "thread_name", "ph": "M", "pid": pid, "tid": tid,
         "args": {"name": "call stack"}},
    ]

    def us(ns):
        return ns / 1000.0          # Chrome trace timestamps are microseconds

    stack = []          # list of function names, bottom..top
    calls = 0
    for t_ns, name in named_anchors:
        if stack and stack[-1] == name:
            continue                                   # same function running
        if name in stack:                              # RETURN to an ancestor
            while stack and stack[-1] != name:
                stack.pop()
                events.append({"ph": "E", "pid": pid, "tid": tid, "ts": us(t_ns)})
        else:                                          # CALL into a new function
            stack.append(name)
            events.append({"name": name, "ph": "B", "pid": pid, "tid": tid,
                           "ts": us(t_ns)})
            calls += 1
    # close any still-open frames at the end time
    if named_anchors:
        end = max(end_ns, named_anchors[-1][0])
    else:
        end = end_ns
    while stack:
        stack.pop()
        events.append({"ph": "E", "pid": pid, "tid": tid, "ts": us(end)})
    return events, calls


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        return 2
    etm_path, time_path, elf, out_path = sys.argv[1:5]
    etm = open(etm_path, "rb").read()
    tj = json.load(open(time_path))
    times_ns = tj["times_ns"]               # wall-clock ns per ETM byte
    starts, funcs = load_symbols(elf)

    # Anchors: every Normal I-sync gives an absolute PC at a known byte offset.
    isyncs = L.find_isyncs(etm)
    if not isyncs:
        print("no I-sync anchors found; cannot build a timeline")
        return 1

    # Build (time_ns, pc) anchor points.
    anchors = []
    for s in isyncs:
        off = min(s.offset, len(times_ns) - 1)
        anchors.append((times_ns[off], s.addr & ~1))
    anchors.sort()

    # Resolve PC -> function name, then reconstruct the nested call stack.
    named = [(t_ns, func_for_pc(pc, starts, funcs)) for t_ns, pc in anchors]
    events, calls = build_stack_events(named, times_ns[-1])

    with open(out_path, "w") as f:
        json.dump({"traceEvents": events, "displayTimeUnit": "ns"}, f)

    span_ns = anchors[-1][0] - anchors[0][0]
    print(f"anchors (I-sync): {len(anchors)}, calls (stack pushes): {calls}")
    print(f"time span: {span_ns/1e3:.1f} us ({span_ns/1e9:.6f} s)")
    # quick function histogram
    from collections import Counter
    hist = Counter(name for _, name in named)
    print("top functions by anchor count:")
    for name, c in hist.most_common(8):
        print(f"  {c:6d}  {name}")
    print(f"wrote {out_path}  -> drag into https://ui.perfetto.dev")
    return 0


if __name__ == "__main__":
    sys.exit(main())
