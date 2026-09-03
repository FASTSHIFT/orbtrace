#!/usr/bin/env python3
"""Cross-check the scope-source TRACE bytes against the FPGA-captured bytes to
localise the "loses a little, keeps losing" fault to ONE layer:

    STM32 TPIU pins  --(SI, 47R, flylead)-->  FPGA IDDR sample  -->  FIFO/UDP
    ^ scope taps here (source, golden)         ^ FPGA capture is here

Method (content-based, no shared trigger needed):
  * Both sides are CAP_RAW byte streams. Strip TPIU idle/halfsync (0x7f,0xff).
  * Measure how many of the FPGA's non-idle byte windows appear VERBATIM in the
    scope-source stream, and find the longest common run.

Verdict table:
  * high verbatim agreement (>~70%, limited only by the two captures not being
    the same time slice) + long identical run
      -> source and FPGA saw the SAME bytes. SI and FPGA sampling are NOT the
         fault. Losses are downstream (FIFO/UDP/NIC). On this rig that is the
         AX88179 USB NIC silently dropping frames at >~115 MB/s (AGENT.md 2).
  * low agreement / no long common run, scope stream clean
      -> FPGA sampling error (IDDR phase / tap). Re-check tap (eye centre =2).
  * scope stream itself full of bad/again-idle bytes
      -> SI / source problem at the pins.

Usage:
    python3 scope_fpga_diff.py <scope_capraw.bin> <fpga_capraw.bin>
"""
import sys

IDLE = (0x7F, 0xFF)


def strip_idle(raw):
    return bytes(b for b in raw if b not in IDLE)


def longest_common(a, b, cap=64):
    """Longest verbatim run of `a` that also appears in `b` (anchored search)."""
    best = (0, 0, 0)
    stride = max(1, len(a) // 4000)
    for apos in range(0, len(a) - 8, stride):
        seed = a[apos:apos + 8]
        bpos = b.find(seed)
        if bpos < 0:
            continue
        l = 8
        while (apos + l < len(a) and bpos + l < len(b)
               and a[apos + l] == b[bpos + l] and l < cap):
            l += 1
        if l > best[0]:
            best = (l, apos, bpos)
    return best


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    scope = open(sys.argv[1], "rb").read()
    fpga = open(sys.argv[2], "rb").read()
    S, F = strip_idle(scope), strip_idle(fpga)
    print(f"scope non-idle={len(S)}  fpga non-idle={len(F)}", flush=True)

    l, ap, bp = longest_common(F, S)
    print(f"longest common run: {l} bytes (fpga@{ap} scope@{bp})", flush=True)
    if l >= 8:
        print(f"  fpga : {F[ap:ap+l].hex()}")
        print(f"  scope: {S[bp:bp+l].hex()}")

    hits = tot = 0
    for apos in range(0, len(F) - 8, 8):
        tot += 1
        if S.find(F[apos:apos + 8]) >= 0:
            hits += 1
    pct = 100 * hits / max(tot, 1)
    print(f"8-byte fpga windows found verbatim in scope: {hits}/{tot} = {pct:.1f}%",
          flush=True)

    print("\nverdict:", flush=True)
    if pct > 60 and l >= 12:
        print("  SAME BYTES at source and FPGA -> SI & FPGA sampling OK.\n"
              "  Any loss is DOWNSTREAM (FIFO/UDP/NIC). See AGENT.md 2 (AX88179).")
    elif l < 8:
        print("  LOW agreement -> suspect FPGA sampling (IDDR phase/tap) or the\n"
              "  two captures are unrelated. Re-check tap=2 eye centre.")
    else:
        print("  PARTIAL -> inspect scope stream quality (SI) and re-run with a\n"
              "  longer/overlapping capture window.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
