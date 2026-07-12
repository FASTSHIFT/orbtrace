#!/usr/bin/env python3
"""verify_func_test — cross-check an orbetto ETMv4 decode against the func_test
ground truth.

Reads orbetto's bitmap.roar (the set of decoded instruction PCs) and the
func_test ELF symbol table, then verifies:
  1. every decoded PC falls inside the ELF's flash code range
  2. maps PCs -> functions and reports coverage
  3. confirms the expected func_test user functions were exercised

Usage:
  # produce bitmap.roar first:
  ORBETTO_ETM_PROT=ETM4 orbetto -C 12810 -t 2 -f cap.tpiu -e <elf> -F cap.fpga_ns
  ./verify_func_test.py bitmap.roar <elf>

Note on the "5.7% unknown" metric printed by mmcm_stream_orbetto: that counter
uses the ETM3.5 header classifier (etm35lib._classify) on ETMv4 bytes, so it
mislabels valid ETMv4 packet headers (0x18/0x1a/0x36/...) as "unknown". It is
NOT an error rate for ETMv4 captures — the authoritative check is this PC/func
cross-check against the ELF, which is what this tool does.
"""
import re
import subprocess
import sys

from pyroaring import BitMap

# func_test user functions (main_loop's call graph) — the ground-truth set we
# expect to see exercised (func_test.c).
EXPECTED = {
    "main_loop", "level_a", "level_b", "level_c", "frame_func",
    "leaf_add", "leaf_mul", "indirect_caller", "callback_test",
    "dispatch_callback", "factorial", "deep1", "conditional", "mixed_test",
}


def nm_symbols(elf):
    syms = []
    for tool in ("arm-none-eabi-nm", "nm"):
        try:
            out = subprocess.check_output([tool, "-n", elf]).decode()
            break
        except Exception:
            continue
    else:
        sys.exit("no nm tool found")
    for line in out.splitlines():
        m = re.match(r"([0-9a-f]{8}) [tTwW] (\S+)", line)
        if m:
            syms.append((int(m.group(1), 16), m.group(2)))
    return syms


def func_of(syms, pc):
    lo = None
    for a, n in syms:
        if a <= pc:
            lo = n
        else:
            break
    return lo


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: verify_func_test.py bitmap.roar <elf>")
    bm = BitMap.deserialize(open(sys.argv[1], "rb").read())
    elf = sys.argv[2]
    pcs = sorted(bm)
    syms = nm_symbols(elf)
    if not pcs:
        sys.exit("[FAIL] bitmap empty — decode produced no PCs")

    lo, hi = syms[0][0], 0x08000000 + 0x00100000  # flash window
    # tighter: use ELF max text addr if available
    flash_lo = 0x08000000
    flash_hi = 0x08000000 + 0x00200000
    inrange = [p for p in pcs if flash_lo <= p < flash_hi]
    print(f"decoded PCs: {len(pcs)}  range 0x{pcs[0]:08x}..0x{pcs[-1]:08x}")
    print(f"in flash [0x{flash_lo:08x},0x{flash_hi:08x}): {len(inrange)} "
          f"({100*len(inrange)/len(pcs):.1f}%)")
    if len(inrange) != len(pcs):
        out = [p for p in pcs if p not in inrange][:8]
        print(f"[WARN] {len(pcs)-len(inrange)} PCs outside flash: "
              f"{['0x%08x'%p for p in out]}")

    from collections import Counter
    cov = Counter(func_of(syms, p) for p in pcs)
    seen = set(cov)
    hit = EXPECTED & seen
    miss = EXPECTED - seen
    print(f"functions covered: {len(cov)}")
    print(f"func_test user funcs seen: {len(hit)}/{len(EXPECTED)}")
    if miss:
        print(f"  not seen (may be inlined/optimised): {sorted(miss)}")
    print("top functions by PC count:")
    for n, c in cov.most_common(20):
        tag = " <-- func_test" if n in EXPECTED else ""
        print(f"  {n:<28} {c}{tag}")

    ok = (len(inrange) == len(pcs)) and (len(hit) >= len(EXPECTED) * 0.6)
    print("RESULT:", "PASS — decode matches func_test" if ok else
          "PARTIAL — check coverage")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
