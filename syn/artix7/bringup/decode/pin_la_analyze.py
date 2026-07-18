#!/usr/bin/env python3
"""Analyze a raw pin-LA waveform capture (trace_pin_la_top).

Sample format: 1 byte per 5 ns, {3'b0, clk, d3, d2, d1, d0}.

Answers:
  * TRACECLK frequency + jitter (via edge intervals)
  * Data-vs-clock phase per lane (data transitions relative to CLK edges)
  * Setup / hold window per lane at the FPGA input pin
  * Bit-flip identification: does any specific TRACECLK cycle have a data
    line change *at* the clock edge (i.e. sampling-window violation)?
"""
import argparse
import sys
from collections import Counter

CLK_BIT = 4
D_BITS = [0, 1, 2, 3]
SR_NS = 5.0   # sample rate = 200 MSPS


def edges(bits):
    """Return list of (idx, direction) where direction is +1 (rising) or -1
    (falling). bits: 1-D array of 0/1."""
    out = []
    prev = bits[0]
    for i in range(1, len(bits)):
        b = bits[i]
        if b != prev:
            out.append((i, +1 if b else -1))
        prev = b
    return out


def check_canary(raw):
    """Bit[7:5] is a 3-bit mod-8 counter incrementing every clk200 sample.
    Verify sequence is monotonically increasing modulo 8. Any break in the
    INTERIOR = FPGA/DDR3 path bug (write-side FIFO overflow / read-side gearbox
    glitch), NOT a SI issue.

    NB: breaks clustered in the last few hundred bytes are a benign SNAPSHOT
    BOUNDARY effect: arm() latches wr_ptr and freezes the writer, and the
    reader's 4MB window ends on the writer's in-flight burst boundary / ring
    wrap. Those tail breaks are deterministic, not data corruption, so we
    report interior vs tail separately.
    Returns (num_samples, total_breaks, first_break_offset, interior_breaks,
             tail_breaks, tail_start). """
    TAIL = 4096   # bytes at the end treated as the snapshot boundary region
    n = len(raw)
    tail_start = n - TAIL
    total = 0
    interior = 0
    tail = 0
    first = None
    prev = (raw[0] >> 5) & 0x7
    for i in range(1, n):
        cur = (raw[i] >> 5) & 0x7
        if cur != ((prev + 1) & 0x7):
            total += 1
            if first is None:
                first = i
            if i >= tail_start:
                tail += 1
            else:
                interior += 1
        prev = cur
    return n, total, first, interior, tail, tail_start


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cap")
    ap.add_argument("--limit", type=int, default=0,
                    help="only look at first N samples (0=all)")
    a = ap.parse_args()

    raw = open(a.cap, "rb").read()
    if a.limit:
        raw = raw[:a.limit]
    n = len(raw)
    print(f"samples: {n}  ({n * SR_NS / 1e6:.2f} ms of trace)")

    # Canary integrity gate first — if the FPGA/DDR3 path itself is broken,
    # any downstream analysis is meaningless.
    total_s, breaks, first_break, interior, tail, tail_start = check_canary(raw)
    ipct = 100.0 * interior / max(1, tail_start - 1)
    if breaks == 0:
        print(f"[canary] OK — {total_s} samples, sequence fully intact")
    elif interior == 0:
        print(f"[canary] OK — {interior} interior breaks; {tail} benign "
              f"boundary breaks in last {total_s - tail_start} bytes "
              f"(snapshot tail, expected)")
    else:
        print(f"[canary] {interior} INTERIOR breaks in {tail_start} samples "
              f"({ipct:.4f}%), first at offset {first_break}; "
              f"plus {tail} benign tail breaks")
        if ipct > 0.001:
            print(f"[canary] WARNING: FPGA/DDR3 path bug detected. "
                  f"Do NOT trust downstream SI numbers until this is fixed.")

    # Extract each bit vector.
    clk = bytes((b >> CLK_BIT) & 1 for b in raw)
    dbits = [bytes((b >> i) & 1 for b in raw) for i in D_BITS]

    # -- clock analysis ---
    ce = edges(clk)
    print(f"CLK edges: {len(ce)}")
    if len(ce) < 2:
        print("no clock activity, aborting")
        return 0
    # half-period histogram
    intervals = [ce[i + 1][0] - ce[i][0] for i in range(len(ce) - 1)]
    from statistics import median, mean, stdev
    med = median(intervals)
    print(f"CLK half-period: median={med} samples = {med * SR_NS:.2f} ns "
          f"-> TRACECLK ~{1000 / (2 * med * SR_NS):.2f} MHz")
    print(f"  mean={mean(intervals):.2f}, stdev={stdev(intervals):.3f}")
    hp_hist = Counter(intervals)
    print(f"  half-period histogram (top 10): "
          f"{sorted(hp_hist.most_common(10))}")

    # -- data-vs-clock phase per lane ---
    # For every data edge, find distance in samples to the nearest CLK edge.
    # In a TPIU stream data edges align with CLK EDGES (center-aligned so data
    # is stable at CLK edges — but our sampler is at 5 ns granularity, so
    # transitions we see in the SAMPLE stream may fall either just before or
    # just after the clock edge depending on how the ~10ns bit lands on the
    # 5ns grid).
    ce_idx = [e[0] for e in ce]
    ce_set = set(ce_idx)
    # For fast nearest-CLK-edge lookup, sort and binary-search.
    import bisect
    for i, db in enumerate(dbits):
        de = edges(db)
        if not de:
            print(f"lane D{i}: NO edges (line is stuck)")
            continue
        offsets = []
        for pos, _ in de:
            j = bisect.bisect_left(ce_idx, pos)
            near = []
            if j > 0: near.append(ce_idx[j - 1])
            if j < len(ce_idx): near.append(ce_idx[j])
            if not near: continue
            nearest = min(near, key=lambda x: abs(x - pos))
            offsets.append(pos - nearest)   # + = after CLK edge, - = before
        c = Counter(offsets)
        top = sorted(c.most_common(6))
        print(f"lane D{i}: {len(de)} edges  "
              f"offset-to-nearest-CLK top: {top}")

    # -- per-CLK-edge sampling window health ---
    # At each CLK edge, what did each data lane look like just before / after?
    # If we sampled ± 1 sample around the edge (5 ns) and it MATCHES the data
    # value taken 2 samples away, sampling is safe.  If the value at edge±1
    # differs from the "eye centre", we may have caught a transition.
    print("\nSetup/hold window per lane (at each CLK edge):")
    # Look at samples [-3, -2, -1, 0, +1, +2, +3] around every CLK edge
    W = 3
    for i, db in enumerate(dbits):
        # count: for each offset, how many CLK edges saw a bit different from
        # the value at offset 0? (offset 0 is the sample at the CLK edge)
        change_hist = [0] * (2 * W + 1)
        total = 0
        for pos, _ in ce:
            if pos - W < 0 or pos + W >= n: continue
            centre = db[pos]
            for k in range(-W, W + 1):
                if db[pos + k] != centre:
                    change_hist[k + W] += 1
            total += 1
        pct = ["%.1f" % (100 * v / max(1, total)) for v in change_hist]
        offsets_ns = ["%+d" % ((k - W) * SR_NS) for k in range(2 * W + 1)]
        print(f"  D{i}: offsets(ns) {offsets_ns}")
        print(f"       %-differ    {pct}")


if __name__ == "__main__":
    sys.exit(main())
