#!/usr/bin/env python3
"""walk_score — score a CURTPM walking-1s IDDR-raw capture.

Unlike AA/55 (all 4 lanes toggle together, so a dropped nibble pair still
reads 0xA5 -> undetectable), walking-1s puts a SINGLE bit rotating across the
4 data lanes: the ideal nibble stream is 4,2,1,8,4,2,1,8,... (right-rotate one
bit per DDR edge). This is a STRICT, DIRECTIONAL, LANE-DESYNCHRONISED pattern:

  * every nibble must be exactly one of {1,2,4,8} (single bit) -> catches
    lane skew / crosstalk (two bits set) and stuck lanes
  * the sequence must follow the 4->2->1->8 rotation -> catches a dropped or
    duplicated nibble (which AA/55 cannot see)

We lock onto the rotation phase from the first clean run, then count every
nibble that breaks the expected rotation. Reports err% = broken / total.

Usage: walk_score.py <capture.bin>
"""
import sys
from collections import Counter

# right-rotate order observed on the wire (DDR edge to edge)
ROT = [4, 2, 1, 8]
NEXT = {4: 2, 2: 1, 1: 8, 8: 4}


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/walk.bin"
    d = open(path, "rb").read()
    if not d:
        print("empty"); return 1

    # split each byte into (falling=hi nibble, rising=lo nibble); the wire
    # order is falling-then-rising within the byte as formed by the RTL, but
    # the ROTATION runs continuously across nibbles regardless of byte split.
    nibs = []
    for b in d:
        nibs.append((b >> 4) & 0xf)
        nibs.append(b & 0xf)
    n = len(nibs)

    # (1) single-bit check
    single = sum(1 for x in nibs if x != 0 and (x & (x - 1)) == 0)
    multibit = n - single

    # (2) rotation check: lock phase on the first nibble that is single-bit,
    # then require each subsequent nibble to equal NEXT[prev].
    breaks = 0
    prev = None
    locked = 0
    for x in nibs:
        is_single = (x != 0 and (x & (x - 1)) == 0)
        if not is_single:
            breaks += 1
            prev = None            # lose lock; re-lock on next clean nibble
            continue
        if prev is None:
            prev = x
            locked += 1
            continue
        if x == NEXT[prev]:
            pass                    # good rotation step
        else:
            breaks += 1
        prev = x

    err = breaks / n
    print(f"file={path} bytes={len(d)} nibbles={n}")
    print(f"  multi-bit nibbles (lane skew/crosstalk): {multibit} "
          f"({100*multibit/n:.3f}%)")
    print(f"  rotation breaks (dropped/dup/skew):      {breaks} "
          f"({100*breaks/n:.3f}%)")
    c = Counter(d)
    print(f"  distinct byte values: {len(c)}  "
          f"top: {[(f'0x{v:02x}',n2) for v,n2 in c.most_common(6)]}")
    print(f"  ERR = {err*100:.4f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
