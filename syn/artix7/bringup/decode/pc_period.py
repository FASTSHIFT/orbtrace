#!/usr/bin/env python3
"""pc_period — parse the decoded INSTR_RANGE sequence and test periodicity.

The workload is a fixed, data-independent, interrupt-masked loop, so the
executed instruction-range sequence MUST be strictly periodic. This is immune
to TPIU filler, A-sync insertion timing, and address delta-encoding (all the
things that defeat raw-byte periodicity). Any aperiodicity is real corruption,
and the NO_SYNC/bad-packet markers show where.
"""
import re
import sys
import numpy as np

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pc_l.txt"
lines = open(path).read().splitlines()

seq = []          # list of (start,end) exec ranges, in order
markers = []      # index in seq where a bad/no-sync happened
rng = re.compile(r"exec range=0x([0-9a-fA-F]+):\[0x([0-9a-fA-F]+)\]")
for l in lines:
    m = rng.search(l)
    if m:
        seq.append((int(m.group(1), 16), int(m.group(2), 16)))
    elif "NO_SYNC" in l or "bad-packet" in l or "BAD_SEQUENCE" in l:
        markers.append(len(seq))

print(f"INSTR_RANGE elements: {len(seq)}   bad/no-sync markers: {len(markers)}")
if len(seq) < 20:
    print("too few ranges"); sys.exit()

starts = np.array([s for s, _ in seq])

# period search on the start-address sequence
L = min(400, len(starts) // 3)
ref = starts[100:100 + L]
best = (0.0, 0)
for lag in range(1, min(2000, len(starts) - 100 - L)):
    seg = starts[100 + lag:100 + lag + L]
    mm = np.count_nonzero(seg == ref) / L
    if mm > best[0]:
        best = (mm, lag)
print(f"PC-start-seq best self-match: {best[0]*100:.1f}% at period={best[1]} ranges")

# distance between bad markers (are corruptions periodic?)
if len(markers) > 2:
    dm = np.diff(markers)
    v, c = np.unique(dm, return_counts=True); o = np.argsort(-c)
    print("spacing between bad/no-sync markers (in # of ranges):")
    for i in o[:8]:
        print(f"   gap={v[i]} : {c[i]}")

# show the range sequence around the first few markers vs a clean stretch
uniq = sorted(set(starts.tolist()))
print(f"\ndistinct start addresses: {len(uniq)}")
for a in uniq[:20]:
    print(f"   0x{a:08x}  x{int(np.count_nonzero(starts==a))}")
