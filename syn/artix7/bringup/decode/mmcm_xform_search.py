#!/usr/bin/env python3
"""Search byte transformations of MMCM capture for a valid TPIU/ETM stream.

cap_byte = {trace_b[3:0], trace_a[3:0]} per TRACECLK period. The mapping of
physical half-bits to trace_a/trace_b and the nibble bit order may differ from
the LA-verified §14 format. Try: nibble swap, bit-reverse each nibble, full
byte bit-reverse, and a half-bit (period) phase shift by 4 bits. For each,
count TPIU full-sync words (ff ff ff 7f) and run the ETM decoder for anchors.
"""
import os, sys, subprocess

import etm35lib as L

raw = open(sys.argv[1], "rb").read()
ELF = os.environ.get("ELF", "/home/vifex/workpath/orbcode/proj_add.axf")

def bitrev4(n):
    return ((n & 1) << 3) | ((n & 2) << 1) | ((n & 4) >> 1) | ((n & 8) >> 3)

def bitrev8(b):
    r = 0
    for i in range(8):
        r |= ((b >> i) & 1) << (7 - i)
    return r

BR4 = [bitrev4(i) for i in range(16)]

def xform(data, swap_nibble, rev_nibble, rev_byte):
    out = bytearray(len(data))
    for i, b in enumerate(data):
        lo, hi = b & 0xF, (b >> 4) & 0xF
        if rev_nibble:
            lo, hi = BR4[lo], BR4[hi]
        if swap_nibble:
            lo, hi = hi, lo
        v = (hi << 4) | lo
        if rev_byte:
            v = bitrev8(v)
        out[i] = v
    return bytes(out)

def score(data):
    sync = 0
    for i in range(len(data) - 3):
        if data[i] == 0xff and data[i+1] == 0xff and data[i+2] == 0xff and data[i+3] == 0x7f:
            sync += 1
    try:
        ev = L.decode_all(data)
        isyncs = sum(1 for e in ev if e.kind == "isync"
                     and L.FLASH_LO <= e.addr < L.FLASH_HI)
    except Exception as e:
        isyncs = -1
    return sync, isyncs

best = []
for sn in (0, 1):
    for rn in (0, 1):
        for rb in (0, 1):
            d = xform(raw, sn, rn, rb)
            sync, isync = score(d)
            best.append((isync, sync, sn, rn, rb))
            print(f"swap_nib={sn} rev_nib={rn} rev_byte={rb}: full_sync={sync} isync_anchors={isync}")

best.sort(reverse=True)
print("\nBEST:", best[0])
