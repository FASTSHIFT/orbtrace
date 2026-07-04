#!/usr/bin/env python3
"""anomaly — find decode anomalies in the MAIN callstack of an orbetto .perf:
  * functions that should never appear in func_test (TwoWire/HardwareSerial/..)
  * raw 0x........ slices (symbol lookup gaps)
  * slices whose B..E wall-clock duration is absurdly long (stack desync)
Usage: anomaly.py <perf> [pid]
"""
import sys, collections
from perfproto import load_ftrace_prints

path = sys.argv[1]
want_pid = int(sys.argv[2]) if len(sys.argv) > 2 else 400000
events = load_ftrace_prints(path)

evs = [(ts,buf) for ts,pid,buf in events if pid==want_pid]

# known-impossible substrings for func_test (no C++ objects, no serial/i2c)
IMPOSSIBLE = ("TwoWire","HardwareSerial","USART","Stream","Wire","__sti__",
              "setup_stackheap","signal","IRQHandler","TIM","__user")

def name(buf):
    return buf.split("|",2)[2] if buf.startswith("B|") and buf.count("|")>=2 else None

# B/E durations
stack = []
durations = []   # (name, dur_us, start_us)
raw_hex = collections.Counter()
impossible = collections.Counter()
allfuncs = collections.Counter()
tsmin = evs[0][0]
for ts, buf in evs:
    if buf.startswith("B|"):
        nm = name(buf)
        stack.append((nm, ts))
        allfuncs[nm]+=1
        if nm and nm.startswith("0x"): raw_hex[nm]+=1
        for k in IMPOSSIBLE:
            if nm and k in nm: impossible[nm]+=1; break
    elif buf.startswith("E|"):
        if stack:
            nm, bts = stack.pop()
            durations.append((nm,(ts-bts)/1000.0,(bts-tsmin)/1000.0))

print(f"PID {want_pid}: {len(evs)} events, {len(allfuncs)} distinct funcs")
print("\n=== IMPOSSIBLE symbols (should not exist in func_test) ===")
for nm,c in impossible.most_common(): print(f"  {c:5d}  {nm}")
print("\n=== raw 0x hex slices (symbol lookup gaps) ===")
for nm,c in raw_hex.most_common(15): print(f"  {c:5d}  {nm}")
print("\n=== longest-duration slices (stack desync suspects) ===")
for nm,dur,st in sorted(durations,key=lambda x:-x[1])[:20]:
    print(f"  {dur:10.1f} us  @{st:9.1f}us  {nm}")
print("\n=== top funcs by count ===")
for nm,c in allfuncs.most_common(25): print(f"  {c:5d}  {nm}")
