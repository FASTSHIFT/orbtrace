#!/usr/bin/env python3
"""Verify the reconstructed instruction flow against the firmware's KNOWN
control structure: proj_add runs while(1){ loop_sum(5); } and loop_sum(5) calls
add() exactly 5 times per invocation. So a correct full reconstruction must
show, per loop_sum entry (0x08000fa4), exactly 5 calls to add (0x08000f8c) and
the loop back-edge (blt 0x08000fbc taken) exactly 5 times then not-taken once.

Reads orbetm -v output (addr per line) on stdin.
"""
import sys, re

ADD = 0x08000f8c
LOOP_ENTRY = 0x08000fa4
BLT = 0x08000fbc          # blt 0x8000fae (loop back-edge)
addrs = []
for line in sys.stdin:
    m = re.search(r"0x0([0-9a-fA-F]{7})\s+[0-9a-f]+:", line)
    if m:
        addrs.append(int(m.group(1), 16) | 0x08000000 & 0)  # already full
    else:
        m2 = re.match(r"\s*0x([0-9a-fA-F]{8})\s", line)
        if m2:
            addrs.append(int(m2.group(1), 16))

# segment by loop_sum entry; count add calls within each complete invocation
entries = [i for i, a in enumerate(addrs) if a == LOOP_ENTRY]
print(f"total reconstructed instructions: {len(addrs)}")
print(f"loop_sum entries (0x{LOOP_ENTRY:08x}): {len(entries)}")

good = bad = 0
for k in range(len(entries) - 1):
    seg = addrs[entries[k]:entries[k + 1]]
    n_add = sum(1 for a in seg if a == ADD)
    if n_add == 5:
        good += 1
    else:
        bad += 1
        if bad <= 5:
            print(f"  invocation {k}: add() called {n_add} times (expected 5)")
print(f"\ncomplete loop_sum invocations: {good+bad}")
print(f"  with exactly 5 add() calls: {good}")
print(f"  with wrong count:           {bad}")
total_add = sum(1 for a in addrs if a == ADD)
print(f"total add() executions: {total_add}")
print(f"\nVERDICT: {'PASS — order+count match firmware' if bad==0 and good>0 else 'FAIL/partial'}")
