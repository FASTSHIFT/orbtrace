"""err_classify (E0, software-only) — classify the errors in a BAD capture by
where they fall, without a same-session LA. Uses the loop's periodicity: a
GOOD capture (template) and a BAD capture both contain the same repeating loop
body, so we align the bad capture's nibble stream to the good one on a shared
window and, over the aligned span, histogram each nibble mismatch by:
  * lane (TD0..3)       -> skew/SI on one lane
  * half (a=rising / b=falling) -> duty distortion (one half-bit narrow)
  * transition direction at that nibble
This is the red-team r16 E0 done with periodicity instead of a live LA, to get
a first qualitative read on the error 'shape'.

Usage: python3 err_classify.py <good.bin> <bad.bin>
"""
import sys
import collections


def nibs_of(path):
    raw = open(path, "rb").read()
    a = []  # rising (low nibble), in capture order
    b = []  # falling (high nibble)
    for byte in raw:
        a.append(byte & 0xF)
        b.append((byte >> 4) & 0xF)
    return a, b, raw


def flat_time_order(path):
    """Time-ordered nibble stream: a0,b0,a1,b1,... (rising then falling)."""
    raw = open(path, "rb").read()
    seq = []
    for byte in raw:
        seq.append(byte & 0xF)        # a / rising
        seq.append((byte >> 4) & 0xF)  # b / falling
    return seq


def best_align(a, b, win=64, span=4000):
    """Find offset so a[i] == b[i+off] over a window (loop bodies coincide)."""
    A = a[2000:2000 + win]
    best = (-1, 0)
    for off in range(-span, span):
        j0 = 2000 + off
        if j0 < 0 or j0 + win >= len(b):
            continue
        m = sum(1 for k in range(win) if a[2000 + k] == b[j0 + k])
        if m > best[0]:
            best = (m, off)
        if m >= win - 1:
            break
    return best


def main():
    good, bad = sys.argv[1], sys.argv[2]
    g = flat_time_order(good)
    d = flat_time_order(bad)
    m, off = best_align(d, g)
    print(f"align: matched {m}/64 at offset {off}")
    if m < 50:
        print("WARNING: weak alignment; classification may be unreliable")

    lane_err = [0, 0, 0, 0]
    half_err = {"a/rising": 0, "b/falling": 0}
    tot = 0
    errs = 0
    val_hist = collections.Counter()
    # walk aligned span; index parity tells a (even) vs b (odd) in time order
    start = 2100
    for i in range(start, len(d) - 10):
        j = i + off
        if j < 0 or j >= len(g):
            break
        tot += 1
        x = d[i] ^ g[j]
        if x:
            errs += 1
            for lane in range(4):
                if (x >> lane) & 1:
                    lane_err[lane] += 1
            if i % 2 == 0:
                half_err["a/rising"] += 1
            else:
                half_err["b/falling"] += 1
            val_hist[(g[j], d[i])] += 1
        if tot >= 60000:
            break

    print(f"compared {tot} nibbles; mismatched {errs} ({100*errs/max(1,tot):.2f}%)")
    print("per-lane bit-error counts:", lane_err,
          "rates:", ["%.2f%%" % (100*x/max(1, tot)) for x in lane_err])
    print("per-half nibble-error counts:", half_err)
    print("top (true->got) confusions:",
          [(f"{t:x}->{g_:x}", c) for (t, g_), c in val_hist.most_common(8)])


if __name__ == "__main__":
    main()
