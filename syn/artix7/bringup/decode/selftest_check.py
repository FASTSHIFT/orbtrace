"""selftest_check — validate a SELFTEST capture (red-team r15 E1).

In SELFTEST builds the OVERSAMPLE sampler is fed an FPGA-internal, async
(phy_rx_clk domain) CLEAN edge-aligned pseudo-trace whose 4-bit value advances
+7 (mod 16) on EVERY trace edge. The capture packs one byte {trace_b, trace_a}
per trace-clk period (b = falling nibble, a = rising nibble). In time order the
nibbles are: rising(a), falling(b), rising(a), ... i.e. a continuous stream
that must step +7 (mod 16) every nibble.

This has a built-in ground truth (the ramp), so NO cross-session alignment is
needed. Any nibble whose delta != 7 is a capture error caused purely by the
async oversampling architecture (clean edges, no SI, no IDELAY).

Verdict:
  * ~0 bad deltas  -> the async sampling ARCHITECTURE is correct; the on-board
                      8% must be physical SI.
  * many bad deltas -> the architecture itself errs under async clocking
                      (CDC / sampling-aperture fault) — must fix the design,
                      not the wiring.

Usage: python3 selftest_check.py <raw.bin>
"""
import sys
import collections


def main():
    raw = open(sys.argv[1], "rb").read()
    # time-ordered nibbles: a (low) then b (high) per captured byte
    nibs = []
    for byte in raw:
        nibs.append(byte & 0xF)         # rising (a), first in time
        nibs.append((byte >> 4) & 0xF)  # falling (b), second
    n = len(nibs)
    if n < 4:
        print("too short")
        return 1

    # Find the longest run that follows the +7 ramp, and overall bad-delta rate.
    deltas = collections.Counter()
    bad = 0
    runs = []
    cur = 1
    for i in range(1, n):
        d = (nibs[i] - nibs[i - 1]) & 0xF
        deltas[d] += 1
        if d == 7:
            cur += 1
        else:
            bad += 1
            runs.append(cur)
            cur = 1
    runs.append(cur)
    runs.sort(reverse=True)

    total = n - 1
    print(f"nibbles={n} delta-checks={total}")
    print(f"correct(+7) deltas={deltas[7]} ({100*deltas[7]/total:.3f}%)")
    print(f"bad deltas={bad} ({100*bad/total:.3f}%)")
    print("top delta values:",
          [(d, c) for d, c in deltas.most_common(6)])
    print(f"longest clean ramp run={runs[0]} nibbles; "
          f"runs>100: {sum(1 for r in runs if r > 100)}")

    verdict = ("ARCHITECTURE OK (async sampling clean -> on-board 8% is SI)"
               if bad / total < 0.005 else
               "ARCHITECTURE FAULT (async oversampling itself errs)")
    print(f"==> {verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
