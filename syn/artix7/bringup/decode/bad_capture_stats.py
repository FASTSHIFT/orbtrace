"""bad_capture_stats — E0 (LA-free preliminary): characterise WHAT a bad
capture's errors look like, by lane / edge-half (a=rising,b=falling) / nibble
value, WITHOUT cross-session LA alignment.

Method: the trace loop is periodic. We don't have a per-capture ground truth,
but we DO have many GOOD captures (0.000%) of the same loop. We build a
"reference" by majority-voting GOOD captures' raw byte stream aligned on a
recurring anchor, then diff a BAD capture against it, classifying each
mismatch by:
  * which nibble half: low(=trace_a, rising) vs high(=trace_b, falling)
  * which lane (bit 0..3 within the nibble)
  * the value / transition

This distinguishes (per r16 §4):
  errors biased to b (falling)  -> duty distortion
  errors biased to one lane     -> lane skew
  errors uniform across lanes   -> metastability
This is the cheap LA-free version; the authoritative E0 is same-session LA diff.

Usage: python3 bad_capture_stats.py <bad.bin> <good1.bin> [good2.bin ...]
"""
import sys
import collections


def load_nibstream(path):
    """raw bytes -> time-ordered nibble list: a(low,rising) then b(high,falling)."""
    raw = open(path, "rb").read()
    nibs = []
    for byte in raw:
        nibs.append(("a", byte & 0xF))          # rising
        nibs.append(("b", (byte >> 4) & 0xF))   # falling
    return nibs, raw


def anchor_align(raw, anchor, length):
    """Return offsets of `anchor` in raw (for periodic alignment)."""
    al = len(anchor)
    return [i for i in range(len(raw) - al) if bytes(raw[i:i + al]) == anchor]


def main():
    bad = sys.argv[1]
    goods = sys.argv[2:]
    if not goods:
        print("need at least one good capture")
        return 1

    # pick a strong recurring 8-byte anchor from the first good capture
    graw = open(goods[0], "rb").read()
    sig = collections.Counter(bytes(graw[i:i + 8]) for i in range(len(graw) - 8))
    anchor = sig.most_common(1)[0][0]
    print(f"anchor = {anchor.hex()} (recurs {sig[anchor]}x in good[0])")

    braw = open(bad, "rb").read()
    bpos = anchor_align(braw, anchor, 8)
    gpos = anchor_align(graw, anchor, 8)
    if not bpos or not gpos:
        print("anchor not found in both; cannot align")
        return 1

    # Align bad[bpos[k]] to good[gpos[k]] segment-by-segment between anchors;
    # within each aligned run, diff byte-by-byte and classify.
    # Use the good capture as reference (it is 0.000%).
    lane_err = [0, 0, 0, 0]
    half_err = {"a": 0, "b": 0}
    total = {"a": 0, "b": 0}
    val_err = collections.Counter()
    compared = 0

    # walk paired anchor segments
    for bi, gi in zip(bpos, gpos):
        # compare until next anchor or divergence in length
        k = 0
        while (bi + k < len(braw) and gi + k < len(graw)):
            bb = braw[bi + k]
            gg = graw[gi + k]
            # low nibble = a/rising, high nibble = b/falling
            for half, shift in (("a", 0), ("b", 4)):
                bn = (bb >> shift) & 0xF
                gn = (gg >> shift) & 0xF
                total[half] += 1
                if bn != gn:
                    half_err[half] += 1
                    x = bn ^ gn
                    for lane in range(4):
                        if (x >> lane) & 1:
                            lane_err[lane] += 1
                    val_err[(gn, bn)] += 1
            compared += 1
            k += 1
            if k > 120:   # one loop-ish segment; re-anchor next
                break

    print(f"\ncompared {compared} byte-positions across anchor-aligned segments")
    print("per-edge-half error rate:")
    for h in ("a", "b"):
        print(f"  {h} ({'rising' if h=='a' else 'falling'}): "
              f"{half_err[h]} / {total[h]} = {100*half_err[h]/max(1,total[h]):.1f}%")
    print("per-lane error counts (within errored nibbles):", lane_err)
    print("top wrong (good->bad) nibble pairs:",
          [(f"{g:x}->{b:x}", n) for (g, b), n in val_err.most_common(8)])


if __name__ == "__main__":
    sys.exit(main())
