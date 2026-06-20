"""etm_pkt_census — walk an ETM3.5 stream packet-by-packet from each I-sync
anchor and tally packet types, specifically to answer: does the raw ETM data
contain TIMESTAMP (0x42/0x46) or CYCLECOUNT (0x04 / I-sync-with-cyc 0x70)
packets? If not, orbetto's cycleCount-based time axis is degenerate (all ~0)
and FPGA time (-F) is required.

Usage: etm_pkt_census.py <capture.bin> [--deframe]
"""
import sys
import collections

sys.path.insert(0, "decode")
sys.path.insert(0, ".")
import etm35lib as L

cap = sys.argv[1]
deframe = "--deframe" in sys.argv[2:] if len(sys.argv) > 2 else False

raw = open(cap, "rb").read()
if deframe or L.has_tpiu_sync(raw):
    data = L.tpiu_deframe_walk(raw, want_stream=2)
    print(f"(deframed -> {len(data)} ETM bytes)")
else:
    data = raw

n = len(data)
tally = collections.Counter()
# consume packets starting right after each I-sync, walking until 'unknown'
syncs = L.find_isyncs(data)
print(f"I-sync anchors: {len(syncs)}")

# global packet walk anchored at the first sync, continuous
def consume(i):
    """return (kind, next_i) consuming one packet at i."""
    c = data[i]
    k = L._classify(c)
    j = i + 1
    if k == "branch":
        # branch addr: continuation while bit7 set, cap 5
        while j < n and (data[j - 1] & 0x80) and (j - i) < 5:
            j += 1
    elif k in ("timestamp", "cyccnt"):
        while j < n and (data[j - 1] & 0x80) and (j - i) < 7:
            j += 1
    elif k in ("isync", "isync_cyc"):
        j = i + 6  # Normal I-sync = 6 bytes (Cortex-M, ctxid=0)
    elif k == "contextid":
        j = i + 1
    return k, j

# walk from first anchor to end
start = syncs[0].offset if syncs else 0
i = start
steps = 0
while i < n and steps < 10_000_000:
    k, j = consume(i)
    tally[k] += 1
    if k == "unknown":
        # try to resync: jump to next isync header
        nxt = data.find(0x08, i + 1)
        if nxt < 0:
            break
        i = nxt
    else:
        i = j
    steps += 1

print("packet type tally (from first anchor, continuous walk):")
for k, c in tally.most_common():
    print(f"  {k:12s} {c}")

print()
print("=== TIME-SOURCE VERDICT ===")
ts = tally.get("timestamp", 0)
cc = tally.get("cyccnt", 0)
ic = tally.get("isync_cyc", 0)
print(f"timestamp packets : {ts}")
print(f"cyccnt packets    : {cc}")
print(f"isync_cyc packets : {ic}")
if ts == 0 and cc == 0 and ic == 0:
    print(">>> NO time information in the ETM stream.")
    print(">>> orbetto cycleCount path is degenerate (ns~0); MUST use -F (FPGA time).")
else:
    print(">>> ETM stream DOES carry some time packets; cycleCount path may work.")
