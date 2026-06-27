#!/usr/bin/env python3
"""Exhaustive degrees-of-freedom scan for an MMCM raw capture, to pin the ONE
correct nibble->byte reconstruction and quantify completeness with the §14
golden pipeline (nibble stream -> pair -> TPIU deframe -> anchors+unknown).

RTL packs cap_byte each clk90 period. We do NOT assume how the two half-bit
nibbles sit in the byte; we explode to a time-ordered nibble stream under both
"low-nibble-first" and "high-nibble-first" interpretations, then for each:
  - offset 0/1 (half-bit boundary), order low/high, optional nibble bit-reverse
  - TPIU-deframe (HSYNC) if present
and score by flash I-sync anchors + unknown-byte rate. Prints the winner DOF so
the RTL can be made to emit that natively.
"""
import sys
import etm35lib as L

raw = open(sys.argv[1], "rb").read()


def bitrev4(n):
    return ((n & 1) << 3) | ((n & 2) << 1) | ((n & 4) >> 1) | ((n & 8) >> 3)
BR4 = [bitrev4(i) for i in range(16)]


def explode(raw, lo_first):
    nibs = bytearray()
    for byte in raw:
        lo, hi = byte & 0xF, (byte >> 4) & 0xF
        if lo_first:
            nibs.append(lo); nibs.append(hi)
        else:
            nibs.append(hi); nibs.append(lo)
    return nibs


def pair(nibs, offset, order, rev):
    out = bytearray()
    i = offset
    while i + 1 < len(nibs):
        n0, n1 = nibs[i], nibs[i + 1]
        if rev:
            n0, n1 = BR4[n0], BR4[n1]
        out.append((n0 << 4) | n1 if order else (n1 << 4) | n0)
        i += 2
    return bytes(out)


def measure(data):
    if L.has_tpiu_sync(data):
        ph, _ = L.find_tpiu_phase(data)
        etm = L.tpiu_deframe_hsync(data, ph)
    else:
        etm = data
    syncs = [s for s in L.find_isyncs(etm) if L.is_flash(s.addr)]
    unk = sum(1 for c in etm if L._classify(c) == "unknown")
    hsync = data.count(b"\xff\x7f")
    return len(syncs), unk, len(etm), hsync


results = []
for lo_first in (0, 1):
    nibs = explode(raw, lo_first)
    for offset in (0, 1):
        for order in (0, 1):
            for rev in (0, 1):
                data = pair(nibs, offset, order, rev)
                a, unk, n, hs = measure(data)
                rate = 100 * unk / max(1, n)
                results.append((a, -rate, lo_first, offset, order, rev, unk, n, hs))

results.sort(reverse=True)
print(f"{'anc':>4} {'unk%':>7} {'hsync':>6}  lo_first off order rev")
for r in results[:8]:
    a, negrate, lo_first, offset, order, rev, unk, n, hs = r
    print(f"{a:4d} {-negrate:7.3f} {hs:6d}  {lo_first}        {offset}   {order}     {rev}")
best = results[0]
print(f"\nBEST: anchors={best[0]} unknown={-best[1]:.3f}% "
      f"lo_first={best[2]} offset={best[3]} order={best[4]} rev={best[5]}")
