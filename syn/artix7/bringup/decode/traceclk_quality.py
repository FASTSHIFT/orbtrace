"""traceclk_quality — examine the real TRACECLK edge regularity from the LA
capture, to test the "clock-edge-quality -> edge miscount" hypothesis for the
on-board 8% (vs classic eye-closure SI, which is implausible at 1 MHz).

A clean source-synchronous clock has TWO interval populations only: high-phase
and low-phase widths (roughly equal at ~50% duty). If TRACECLK has ringing /
slow edges that cross the threshold multiple times, the LA (50 MSa/s) will show
ANOMALOUSLY SHORT intervals (glitches) or a broad jitter spread — exactly what
would make the FPGA's edge detector miscount edges.

Reports the half-period histogram and flags any sub-threshold-short intervals.
"""
import sys
import collections
import dsl_parse as D

GOLDEN = "/home/vifex/workpath/orbcode/DSLogic U2Basic-la-260613-194702.dsl"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else GOLDEN
    N = int(sys.argv[2]) if len(sys.argv) > 2 else 4_000_000
    chans, sr, _ = D.load_channels(path)
    clk = D.unpack_bits(chans[0], N)

    # edge indices
    edges = [i for i in range(1, N) if clk[i] != clk[i - 1]]
    intervals = [edges[k + 1] - edges[k] for k in range(len(edges) - 1)]
    hist = collections.Counter(intervals)

    print(f"samples={N} (20ns each)  TRACECLK edges={len(edges)}")
    print("edge-interval histogram (samples : count) [20ns/sample]:")
    for iv, c in sorted(hist.items()):
        if c >= 3 or iv < 5:
            print(f"  {iv:4d} samp ({iv*20:5d} ns): {c}")

    # separate high vs low phase widths
    hi = []  # clk high duration
    lo = []
    for k in range(len(edges) - 1):
        dur = edges[k + 1] - edges[k]
        if clk[edges[k]] == 1:
            hi.append(dur)
        else:
            lo.append(dur)
    import statistics
    if hi and lo:
        print(f"\nhigh-phase: n={len(hi)} median={statistics.median(hi)} "
              f"min={min(hi)} max={max(hi)}")
        print(f"low-phase:  n={len(lo)} median={statistics.median(lo)} "
              f"min={min(lo)} max={max(lo)}")
        duty = statistics.median(hi) / (statistics.median(hi) + statistics.median(lo))
        print(f"duty (median hi/(hi+lo)) = {100*duty:.1f}%")

    # anomalously short intervals = glitch/ringing crossings
    med = statistics.median(intervals)
    glitches = [iv for iv in intervals if iv < med * 0.5]
    print(f"\nmedian interval={med} samp; intervals < 50% median (glitch "
          f"candidates): {len(glitches)} ({100*len(glitches)/len(intervals):.3f}%)")
    if glitches:
        print("  shortest few:", sorted(glitches)[:10], "samples")


if __name__ == "__main__":
    main()
