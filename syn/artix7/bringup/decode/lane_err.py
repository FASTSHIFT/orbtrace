"""Align a board capture's nibbles to the LA golden and report per-lane
bit-error rate — distinguishes SI/wiring (one lane hot) from metastability
(spread across lanes)."""
import sys
import etm35lib as L
import dsl_parse as D

GOLDEN = "/home/vifex/workpath/orbcode/DSLogic U2Basic-la-260613-194702.dsl"


def board_nibbles(path):
    raw = open(path, "rb").read()
    bn = bytearray()
    for b in raw:
        bn.append((b >> 4) & 0xf)   # trace_b (falling)
        bn.append(b & 0xf)          # trace_a (rising)
    return bn


def la_nibbles(n):
    chans, sr, _ = D.load_channels(GOLDEN)
    clk = D.unpack_bits(chans[0], n)
    d = [D.unpack_bits(chans[ch], n) for ch in range(1, 5)]
    edges, half = D.find_edges(clk, n)
    eye = max(1, int(half * 0.5))
    return D.sample_nibbles(d, edges, eye)


def best_off(a, b, span=400000):
    best = (-1, 0)
    for off in range(0, min(span, len(b) - 3000)):
        m = sum(1 for i in range(1000) if a[2000 + i] == b[off + i])
        if m > best[0]:
            best = (m, off - 2000)
        if m > 980:
            break
    return best


def main():
    bn = board_nibbles(sys.argv[1])
    ln = la_nibbles(4000000)
    m, off = best_off(bn, ln)
    print("best align: match=%d/1000 offset=%d" % (m, off))
    mis = [0, 0, 0, 0]
    tot = 0
    for i in range(2000, min(len(bn), len(ln) - off - 2000)):
        j = i + off
        if j < 0 or j >= len(ln):
            continue
        tot += 1
        x = bn[i] ^ ln[j]
        for lane in range(4):
            if (x >> lane) & 1:
                mis[lane] += 1
        if tot >= 200000:
            break
    print("compared %d nibbles" % tot)
    print("per-lane bit-error counts:", mis)
    print("per-lane bit-error rate:", ["%.3f%%" % (100 * x / tot) for x in mis])
    print("overall nibble error rate: %.3f%%"
          % (100 * sum(1 for i in range(2000, 2000 + tot)
                       if i + off < len(ln) and bn[i] != ln[i + off]) / tot))


if __name__ == "__main__":
    main()
