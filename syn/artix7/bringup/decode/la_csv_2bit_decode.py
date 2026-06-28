"""la_csv_2bit_decode — decode a DSLogic CSV (TRACECLK, D0, D1 @ 100MHz) of a
2-bit edge-aligned DDR ETM trace into TPIU bytes, then run etm35lib to recover
flash I-sync anchors. Establishes a logic-analyzer GROUND TRUTH for the 2-bit
21MHz STM32 output (independent of the FPGA sampling path).

Edge-aligned DDR: data flips on each TRACECLK edge; sample mid-half-bit (a few
LA samples after each edge). Each edge gives 2 bits (D1,D0). Two consecutive
edges (rise+fall) give 4 bits; pack to bytes. We try both bit orders / edge
parities and score by flash anchors (like §14 dsl_parse auto-align).

Usage: la_csv_2bit_decode.py <csv> [max_samples]
"""
import sys
import itertools
sys.path.insert(0, "decode")
sys.path.insert(0, ".")
import etm35lib as L

csv = sys.argv[1]
maxn = int(sys.argv[2]) if len(sys.argv) > 2 else 8_000_000

# read samples (clk, d0, d1)
clk = []
d0 = []
d1 = []
with open(csv) as f:
    for _ in range(5):
        f.readline()
    for line in itertools.islice(f, maxn):
        p = line.split(',')
        if len(p) < 4:
            continue
        try:
            clk.append(int(p[1]))
            d0.append(int(p[2]))
            d1.append(int(p[3]))
        except ValueError:
            continue
n = len(clk)
print(f"read {n} samples")

# find edges, sample data mid-half-bit (3 samples after edge @100MHz ~30ns;
# half-bit @21MHz DDR ~24ns -> ~2 samples; use 1 to stay inside)
edges = []  # (index, direction) dir=1 rise,0 fall
for i in range(1, n):
    if clk[i] != clk[i - 1]:
        edges.append((i, clk[i]))
print(f"edges {len(edges)}")

OFF = 1  # samples after edge to sample data (mid half-bit)


def sample_at(idx):
    j = min(idx + OFF, n - 1)
    return d0[j], d1[j]


best = None
# bit order within an edge's 2 bits: (d0 first) or (d1 first); plus which edge
# parity starts a byte; plus rise=low-half vs fall=low-half
for d1_first in (0, 1):
    for start_par in (0, 1):
        bits = []
        for (idx, direction) in edges:
            a, b = sample_at(idx)  # a=d0, b=d1
            pair = (b, a) if d1_first else (a, b)
            bits.extend(pair)
        # byte pack LSB-first, with a starting bit phase
        for ph in range(start_par * 2, start_par * 2 + 1):
            out = bytearray()
            acc = 0
            nb = 0
            for bit in bits[ph:]:
                acc |= bit << nb
                nb += 1
                if nb == 8:
                    out.append(acc)
                    acc = 0
                    nb = 0
            s = bytes(out)
            sync = s.count(b"\xff\xff\xff\x7f")
            anc = 0
            try:
                etm = L.tpiu_deframe_walk(s, want_stream=2)
                anc = len([x for x in L.find_isyncs(etm) if L.is_flash(x.addr)])
            except Exception:
                pass
            tag = (d1_first, start_par, ph)
            if best is None or (anc, sync) > (best[1], best[2]):
                best = (tag, anc, sync, s)
            if sync or anc:
                print(f"d1_first={d1_first} ph={ph}: fullsync={sync} anchors={anc}")

print()
print(f"BEST {best[0]}: anchors={best[1]} fullsync={best[2]}")
if best[1] > 0:
    open("/tmp/la_2bit.bin", "wb").write(best[3])
    print("wrote /tmp/la_2bit.bin")
