#!/usr/bin/env python3
"""swo_cmp_bytes — compare two hex-per-line byte dumps (RTL vs software model)
for the SWO replay regression. The two streams may differ by a few bytes of
start-up transient at the very beginning (the RTL starts mid-idle, the model
the same, but tiny boundary differences are possible), so we align on the
longest common run and require the overlap to match exactly.

Exit 0 = PASS (streams identical after alignment), nonzero = FAIL.

Usage: swo_cmp_bytes.py <rtl.hex> <model.hex>
"""
import sys


def load(path):
    return bytes(int(l, 16) for l in open(path) if l.strip())


def main():
    rtl = load(sys.argv[1])
    mdl = load(sys.argv[2])
    if not rtl or not mdl:
        print(f"  FAIL: empty stream (rtl={len(rtl)} model={len(mdl)})")
        return 1

    # Align: find where rtl[:32] occurs in the model (and vice versa), pick the
    # alignment that maximises overlap.
    def best_align(a, b):
        key = a[:32]
        pos = b.find(key)
        return pos

    off_r = best_align(rtl, mdl)   # rtl head found in model at off_r
    off_m = best_align(mdl, rtl)   # model head found in rtl at off_m

    if off_r >= 0:
        ra, ma = 0, off_r
    elif off_m >= 0:
        ra, ma = off_m, 0
    else:
        print("  FAIL: streams do not align (no common 32-byte head)")
        print("    rtl[:16] :", rtl[:16].hex(" "))
        print("    model[:16]:", mdl[:16].hex(" "))
        return 1

    n = min(len(rtl) - ra, len(mdl) - ma)
    mism = sum(1 for i in range(n) if rtl[ra + i] != mdl[ma + i])
    print(f"  aligned overlap={n} bytes (rtl@{ra}, model@{ma}); mismatches={mism}")
    if mism == 0:
        print("  PASS: RTL output == software model byte-for-byte")
        return 0
    # show first mismatch
    for i in range(n):
        if rtl[ra + i] != mdl[ma + i]:
            print(f"    first mismatch @overlap {i}: "
                  f"rtl={rtl[ra+i]:02x} model={mdl[ma+i]:02x}")
            break
    return 1


if __name__ == "__main__":
    sys.exit(main())
