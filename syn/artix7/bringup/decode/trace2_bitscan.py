"""trace2_bitscan — pure bit-stream scan for TPIU sync in a 2-bit CAP_RAW
capture, independent of byte boundaries. Each TRACECLK gives 4 real bits
(a0,a1,b0,b1). Try every ordering of those 4 bits, build one long bit stream,
then for every bit phase (0..31) repack to bytes (LSB-first AND MSB-first) and
count the TPIU full-sync 0x7fffffff (as bytes ff ff ff 7f / and 7f ff ff ff).
Whatever yields many REGULARLY-spaced syncs is the right serialization.

Usage: trace2_bitscan.py <capraw.bin>
"""
import sys
import itertools

raw = open(sys.argv[1], "rb").read()
bitsrc = {
    "a0": [(x >> 0) & 1 for x in raw],
    "a1": [(x >> 1) & 1 for x in raw],
    "b0": [(x >> 4) & 1 for x in raw],
    "b1": [(x >> 5) & 1 for x in raw],
}


def pack(bits, msb_first):
    out = bytearray()
    acc = 0
    nb = 0
    if msb_first:
        for bit in bits:
            acc = (acc << 1) | bit
            nb += 1
            if nb == 8:
                out.append(acc & 0xFF)
                acc = 0
                nb = 0
    else:
        for bit in bits:
            acc |= bit << nb
            nb += 1
            if nb == 8:
                out.append(acc)
                acc = 0
                nb = 0
    return bytes(out)


def sync_regularity(b):
    pos = [i for i in range(len(b) - 3)
           if b[i] == 0xff and b[i + 1] == 0xff and b[i + 2] == 0xff and b[i + 3] == 0x7f]
    if len(pos) < 3:
        return len(pos), None
    difs = [pos[i + 1] - pos[i] for i in range(len(pos) - 1)]
    # regularity: how many intervals are a multiple of 16 (TPIU frame)
    reg = sum(1 for d in difs if d % 16 == 0)
    return len(pos), reg


best = None
for order in itertools.permutations(["a0", "a1", "b0", "b1"]):
    cols = [bitsrc[n] for n in order]
    bits = []
    for t in range(len(raw)):
        for c in cols:
            bits.append(c[t])
    for phase in range(8):
        for msb in (0, 1):
            b = pack(bits[phase:], msb)
            cnt, reg = sync_regularity(b)
            if cnt >= 2:
                score = (reg or 0, cnt)
                if best is None or score > best[0]:
                    best = (score, order, phase, msb, cnt, reg)
                    print(f"order={order} phase={phase} msb={msb}: "
                          f"fullsync={cnt} regular(mult16)={reg}")

print()
if best:
    print(f"BEST: order={best[1]} phase={best[2]} msb={best[3]} "
          f"fullsync={best[4]} regular={best[5]}")
else:
    print("NO TPIU full-sync found under any 2-bit bit-ordering/phase.")
    print(">>> strongly suggests the FPGA capture (a/b pairing or edge detect)")
    print("    is wrong, not just bit order.")
