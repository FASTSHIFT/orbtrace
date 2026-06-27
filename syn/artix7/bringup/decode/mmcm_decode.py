#!/usr/bin/env python3
"""mmcm_decode — reliable decode of a trace_mmcm_top raw capture, at ANY of the
supported TRACECLK frequencies (21/42/84 MHz), with no frequency-dependent
hardcoding.

WHY THIS EXISTS (proposal 22 §7.4 / §7.5): the MMCM front-end packs one byte
per TRACECLK period = {trace_a[k] (high nibble), trace_b[k-1] (low nibble)}.
The ETM byte boundary does NOT align to the TRACECLK period, and the half-bit
parity that recovers it SHIFTS with frequency (21M wants parity=1, 84M wants
parity=0 -- board-measured). A single hardcoded RTL pairing therefore cannot be
right at every frequency.

The robust approach is exactly the one the logic-analyser golden path uses
(stage4 doc 14): recover the time-ordered half-bit NIBBLE stream, then let
dsl_parse's parity/order SEARCH pick the alignment per capture by scoring flash
I-sync anchors, then TPIU-deframe. This auto-adapts to any frequency.

Usage:  mmcm_decode.py cap.bin [-o out_etm.bin] [--elf proj.axf]
"""
import argparse
import os
import subprocess
import sys

import etm35lib as L
import dsl_parse as D


def recover_nibbles(raw: bytes) -> bytearray:
    """RTL byte k = {trace_a[k] (hi), trace_b[k-1] (lo)}. Recover the
    time-ordered half-bit nibble stream a[k] (rising half) then b[k] (falling
    half): a[k] = hi(byte k), b[k] = lo(byte k+1)."""
    nibs = bytearray()
    for k in range(len(raw) - 1):
        nibs.append((raw[k] >> 4) & 0xF)   # trace_a[k]  (rising half)
        nibs.append(raw[k + 1] & 0xF)      # trace_b[k]  (falling half)
    return nibs


def decode(raw: bytes):
    """Return (etm_bytes, parity, order, deframe_phase). Picks the half-bit
    parity/order that maximises flash I-sync anchors (LA-golden method), then
    TPIU-deframes."""
    nibs = recover_nibbles(raw)
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
            if best is None or fl > best[0]:
                best = (fl, parity, order, data)
    _, parity, order, data = best
    ph = None
    if L.has_tpiu_sync(data):
        ph, _ = L.find_tpiu_phase(data)
        # Continuous re-aligning walker (doc 14 §19): a single global phase is
        # derailed by occasional corrupt ~1KB windows that shift the frame
        # boundary for the whole tail; the walker re-locks in place after each
        # bad window with no seam loss. Falls back to single-phase if absent.
        if hasattr(L, "tpiu_deframe_walk"):
            data = L.tpiu_deframe_walk(data)
        else:
            data = L.tpiu_deframe_hsync(data, ph)
    return data, parity, order, ph


def report(raw, etm, parity, order, ph, elf):
    syncs = [s for s in L.find_isyncs(etm) if L.is_flash(s.addr)]
    unk = sum(1 for c in etm if L._classify(c) == "unknown")
    pcs = sorted({s.addr for s in syncs})
    hs = raw and None
    print(f"raw={len(raw)}B  parity={parity} order={order} deframe_phase={ph}")
    print(f"ETM={len(etm)}B  flash-anchors={len(syncs)}  distinct-PC={len(pcs)}  "
          f"unknown={unk} ({100*unk/max(1,len(etm)):.4f}%)")
    if elf and os.path.exists(elf) and pcs:
        p = subprocess.run(["arm-none-eabi-addr2line", "-f", "-e", elf]
                           + [f"0x{a:08x}" for a in pcs],
                           capture_output=True, text=True)
        lines = p.stdout.splitlines()
        for i, a in enumerate(pcs):
            fn = lines[2*i] if 2*i < len(lines) else "?"
            loc = lines[2*i+1] if 2*i+1 < len(lines) else "?"
            print(f"  0x{a:08x}  {fn}\t{loc}")
    else:
        print("  PCs:", [hex(p) for p in pcs])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cap")
    ap.add_argument("-o", "--out")
    ap.add_argument("--elf", default=os.environ.get("ELF",
                    "/home/vifex/workpath/orbcode/proj_add.axf"))
    a = ap.parse_args()
    raw = open(a.cap, "rb").read()
    etm, parity, order, ph = decode(raw)
    if a.out:
        open(a.out, "wb").write(etm)
    report(raw, etm, parity, order, ph, a.elf)
    return 0


if __name__ == "__main__":
    sys.exit(main())
