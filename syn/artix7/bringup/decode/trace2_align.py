"""trace2_align — brute-force the correct 2-bit DDR byte assembly from a CAP_RAW
capture, by replicating traceIF's width=2 shift under every (a/b swap, bit
order, nibble order) variant and scoring each by TPIU full-sync count + decoded
flash I-sync anchors.

CAP_RAW byte = {trace_b[3:0], trace_a[3:0]} per TRACECLK; for 2-bit only the
low 2 bits of each nibble are valid (a[1:0] rising, b[1:0] falling).

traceIF width=2 shifts {b[1:0], a[1:0]} into the top of a 36-bit register each
TRACECLK (construct <= {b1b0,a1a0, construct[35:4]}), sync at construct[33-:32].
We replicate that here in software and try the orientation variants, because
the on-wire LSB/edge order vs traceIF's assumption is exactly what bring-up
must pin.

Usage: trace2_align.py <capraw.bin>
"""
import sys
sys.path.insert(0, "decode")
sys.path.insert(0, ".")
import etm35lib as L

raw = open(sys.argv[1], "rb").read()
# extract per-TRACECLK (a,b) 2-bit samples
samples = [((b & 0x03), ((b >> 4) & 0x03)) for b in raw]  # (a_lo, b_lo)


def assemble(samples, swap_ab, rev_a, rev_b, first_b):
    """Shift 2-bit pairs LSB-first into a byte stream under the given variant."""
    def rev2(x):
        return ((x & 1) << 1) | ((x >> 1) & 1)
    out = bytearray()
    acc = 0
    nbits = 0
    for a, b in samples:
        if swap_ab:
            a, b = b, a
        if rev_a:
            a = rev2(a)
        if rev_b:
            b = rev2(b)
        pair = (a, b) if not first_b else (b, a)
        for two in pair:           # each contributes 2 bits, LSB-first
            acc |= (two & 0x03) << nbits
            nbits += 2
            while nbits >= 8:
                out.append(acc & 0xFF)
                acc >>= 8
                nbits -= 8
    return bytes(out)


best = None
for swap_ab in (0, 1):
    for rev_a in (0, 1):
        for rev_b in (0, 1):
            for first_b in (0, 1):
                s = assemble(samples, swap_ab, rev_a, rev_b, first_b)
                sync = s.count(b"\xff\xff\xff\x7f")
                # try TPIU deframe + count flash anchors
                try:
                    etm = L.tpiu_deframe_walk(s, want_stream=2)
                    anc = len([x for x in L.find_isyncs(etm) if L.is_flash(x.addr)])
                except Exception:
                    anc = 0
                tag = (swap_ab, rev_a, rev_b, first_b)
                if best is None or (anc, sync) > (best[1], best[2]):
                    best = (tag, anc, sync, s)
                print(f"swap_ab={swap_ab} rev_a={rev_a} rev_b={rev_b} "
                      f"first_b={first_b}: fullsync={sync} flash_anchors={anc}")

print()
print(f"BEST variant {best[0]}: flash_anchors={best[1]} fullsync={best[2]}")
if best[1] > 0:
    open("/tmp/t2_best.bin", "wb").write(best[3])
    print("wrote /tmp/t2_best.bin (raw TPIU bytes for this variant)")
