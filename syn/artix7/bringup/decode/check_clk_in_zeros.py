"""Verify the key assumption behind the OVERSAMPLE scheme: during the long
all-zero data stretches (ETM A-sync / idle), does TRACECLK keep toggling?

If yes, edge-on-TRACECLK oversampling never loses its bit reference -> no drift
through long-zero blind spots (Gemini's concern does not apply to our scheme).
If TRACECLK ALSO goes quiet, we'd have a problem.

Measures, from the golden .dsl:
  * locate the longest runs where all 4 data lanes are 0
  * inside those runs, count TRACECLK edges and check the half-period is the
    same as elsewhere (clock still healthy)
"""
import sys
import dsl_parse as D

GOLDEN = "/home/vifex/workpath/orbcode/DSLogic U2Basic-la-260613-194702.dsl"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else GOLDEN
    N = int(sys.argv[2]) if len(sys.argv) > 2 else 4_000_000
    chans, sr, np_ = D.load_channels(path)
    clk = D.unpack_bits(chans[0], N)
    d = [D.unpack_bits(chans[ch], N) for ch in range(1, 5)]

    # all-data-zero mask
    zero = bytearray(N)
    for i in range(N):
        zero[i] = 1 if (d[0][i] | d[1][i] | d[2][i] | d[3][i]) == 0 else 0

    # find runs of zero
    runs = []
    i = 0
    while i < N:
        if zero[i]:
            j = i
            while j < N and zero[j]:
                j += 1
            runs.append((i, j - i))
            i = j
        else:
            i += 1
    runs.sort(key=lambda r: -r[1])
    print(f"samples={N} sample period=20ns")
    print(f"total all-zero-data runs: {len(runs)}; "
          f"longest: {[r[1] for r in runs[:8]]} samples "
          f"(= {[r[1]*20 for r in runs[:8]]} ns)")

    # global clock half-period
    g_edges = sum(1 for k in range(1, N) if clk[k] != clk[k - 1])
    print(f"global TRACECLK edges over window: {g_edges} "
          f"(~{N/max(1,g_edges)*20:.0f} ns between edges)")

    # inside the longest few zero runs, is the clock still toggling at the
    # same rate?
    print("\nclock activity INSIDE the longest all-zero-data runs:")
    for start, length in runs[:8]:
        if length < 20:
            continue
        edges = sum(1 for k in range(start + 1, start + length)
                    if clk[k] != clk[k - 1])
        exp = length / (N / max(1, g_edges))   # expected edges if same rate
        print(f"  run @{start} len={length} samp ({length*20} ns): "
              f"clk edges={edges} (expected ~{exp:.1f} at normal rate)")


if __name__ == "__main__":
    main()
