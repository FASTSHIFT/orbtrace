"""trace2_align2 — exhaustive 2-bit DDR bit-order search from CAP_RAW.

Each CAP_RAW byte = {b[3:0], a[3:0]} for one TRACECLK; valid 2-bit lanes are
a[0],a[1] (rising D0/D1) and b[0],b[1] (falling D0/D1). Per TRACECLK we have 4
real bits. We don't know the on-wire order, so try ALL 24 orderings of the 4
bit-sources, assemble LSB-first into bytes, deframe (which itself scans TPIU
phase), and score by flash I-sync anchors. Whichever ordering yields real
proj_add anchors is the correct 2-bit serialization.

Usage: trace2_align2.py <capraw.bin>
"""
import sys
import itertools
sys.path.insert(0, "decode")
sys.path.insert(0, ".")
import etm35lib as L

raw = open(sys.argv[1], "rb").read()
# 4 real bit sources per TRACECLK
A0 = [(x >> 0) & 1 for x in raw]
A1 = [(x >> 1) & 1 for x in raw]
B0 = [(x >> 4) & 1 for x in raw]
B1 = [(x >> 5) & 1 for x in raw]
srcs = {"a0": A0, "a1": A1, "b0": B0, "b1": B1}
names = ["a0", "a1", "b0", "b1"]

best = None
for order in itertools.permutations(names):
    # build bit stream in this order, LSB-first into bytes
    out = bytearray()
    acc = 0
    nb = 0
    cols = [srcs[n] for n in order]
    for t in range(len(raw)):
        for c in cols:
            acc |= (c[t] & 1) << nb
            nb += 1
            if nb == 8:
                out.append(acc)
                acc = 0
                nb = 0
    s = bytes(out)
    sync = s.count(b"\xff\xff\xff\x7f")
    anc = 0
    if sync:
        try:
            etm = L.tpiu_deframe_walk(s, want_stream=2)
            anc = len([x for x in L.find_isyncs(etm) if L.is_flash(x.addr)])
        except Exception:
            anc = 0
    if best is None or (anc, sync) > (best[1], best[2]):
        best = (order, anc, sync, s)
    if sync or anc:
        print(f"order={order}: fullsync={sync} flash_anchors={anc}")

print()
print(f"BEST {best[0]}: flash_anchors={best[1]} fullsync={best[2]}")
if best[1] > 0:
    open("/tmp/t2_best.bin", "wb").write(best[3])
    print("wrote /tmp/t2_best.bin")
