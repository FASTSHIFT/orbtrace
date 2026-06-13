#!/usr/bin/env python3
"""Quick TRACECLK sanity check on a .dsl capture: edge-interval histogram,
burst structure, and data-vs-clock relationship. Tells us if CLK is a healthy
(gated, ~expected freq) source-synchronous clock or actually mis-wired/noisy.
"""
import sys, zipfile, configparser
from collections import Counter


def load(path, cap):
    z = zipfile.ZipFile(path)
    names = z.namelist()
    cp = configparser.ConfigParser(); cp.read_string(z.read("header").decode())
    srate = cp["header"]["samplerate"]
    chans = {}
    for ch in range(5):
        blks = sorted([n for n in names if n.startswith(f"L-{ch}/")],
                      key=lambda s: int(s.split("/")[1]))
        chans[ch] = b"".join(z.read(b) for b in blks)
    nsamp = min(min(len(v) for v in chans.values()) * 8, cap)
    def bits(raw):
        return bytes((raw[i >> 3] >> (i & 7)) & 1 for i in range(nsamp))
    return [bits(chans[c]) for c in range(5)], nsamp, srate


def main():
    path = sys.argv[1]
    cap = int(sys.argv[2]) if len(sys.argv) > 2 else 5_000_000
    ch, nsamp, srate = load(path, cap)
    clk = ch[0]
    print(f"samplerate={srate} samples(used)={nsamp} ({nsamp*20/1e6:.1f} ms)")

    # clk level stats
    hi = sum(clk); print(f"CLK high fraction: {100*hi/nsamp:.1f}%")

    # all edges + intervals
    edges = [i for i in range(1, nsamp) if clk[i] != clk[i-1]]
    print(f"total CLK edges: {len(edges)}")
    if len(edges) < 4:
        print("  -> almost no edges: CLK essentially static. Mis-wire or no trace.")
        return
    iv = [edges[k+1]-edges[k] for k in range(len(edges)-1)]
    c = Counter(iv)
    print("edge-interval histogram (samples : count), top 12:")
    for s, n in c.most_common(12):
        print(f"   {s:6d} samp ({s*20:5d} ns, {50e6/(2*s)/1e3:7.1f} kHz half-bit) : {n}")
    # burst analysis: gaps >> typical interval
    typical = c.most_common(1)[0][0]
    gaps = [g for g in iv if g > typical*8]
    print(f"\ntypical edge interval = {typical} samp ({typical*20} ns)")
    print(f"  -> implied TRACECLK ~ {50e6/(2*typical)/1e3:.0f} kHz (half-bit={typical*20}ns)")
    print(f"long gaps (>8x typical, = idle bursts): {len(gaps)}; "
          f"max gap {max(gaps) if gaps else 0} samp ({(max(gaps) if gaps else 0)*20/1000:.1f} us)")

    # data changes only near clock edges? sample D lines, count transitions that
    # are NOT within 2 samples of a clock edge (would indicate async/noise)
    edgeset = set()
    for e in edges:
        edgeset.update((e-1, e, e+1, e+2))
    bad = 0; dtot = 0
    for d in ch[1:]:
        for i in range(1, nsamp):
            if d[i] != d[i-1]:
                dtot += 1
                if i not in edgeset:
                    bad += 1
    print(f"\ndata transitions: {dtot}; not aligned to a clock edge: {bad} "
          f"({100*bad/max(dtot,1):.1f}%)  (high% => async/noise/mis-wire)")


if __name__ == "__main__":
    main()
