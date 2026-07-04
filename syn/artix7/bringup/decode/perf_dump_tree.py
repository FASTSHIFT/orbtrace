#!/usr/bin/env python3
"""perf_dump_tree — fully parse an orbetto Perfetto .perf and print the call
stack as an indented B/E tree per PID track, so we can eyeball whether the
nesting is sane, whether timestamps are real (FPGA wall-clock) or degenerate,
and whether C++ names are demangled.

Usage: perf_dump_tree.py <perf> [max_events]
"""
import sys, collections, subprocess, re
from perfproto import load_ftrace_prints

path = sys.argv[1]
maxev = int(sys.argv[2]) if len(sys.argv) > 2 else 120

# (ts, pid, buf) for every ftrace print event, sorted by timestamp.
events = load_ftrace_prints(path)

# demangle C++ names with c++filt (batch)
raw_names = set()
for ts, pid, buf in events:
    if buf.startswith("B|"):
        parts = buf.split("|", 2)
        if len(parts) == 3: raw_names.add(parts[2])
def demangle_batch(names):
    names = [n for n in names if n]
    if not names: return {}
    try:
        out = subprocess.run(["arm-none-eabi-c++filt"], input="\n".join(names),
                             capture_output=True, text=True).stdout.splitlines()
        return dict(zip(names, out))
    except Exception:
        return {}
dm = demangle_batch(raw_names)

# print tree per pid
depth = collections.Counter()
print(f"total ftrace print events: {len(events)}")
tsmin = min(e[0] for e in events); tsmax = max(e[0] for e in events)
print(f"timestamp span: {(tsmax-tsmin)/1e6:.3f} ms  (min={tsmin} ns, max={tsmax} ns)")
print(f"distinct PIDs: {sorted(set(e[1] for e in events))}")
print("--- first %d events (indented by depth, per pid) ---" % maxev)
for k,(ts,pid,buf) in enumerate(events[:maxev]):
    rel = (ts - tsmin)/1000.0  # us
    if buf.startswith("B|"):
        parts = buf.split("|",2); nm = parts[2] if len(parts)==3 else buf
        nm = dm.get(nm, nm)
        ind = "  "*depth[pid]
        print(f"[{rel:9.2f}us] pid{pid} {ind}> {nm}")
        depth[pid]+=1
    elif buf.startswith("E|"):
        depth[pid]=max(0,depth[pid]-1)
        ind = "  "*depth[pid]
        print(f"[{rel:9.2f}us] pid{pid} {ind}< ")
    else:
        print(f"[{rel:9.2f}us] pid{pid} {buf}")
