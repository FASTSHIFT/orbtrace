#!/usr/bin/env python3
"""fpga_errrate — quick quality metric for a raw FPGA capture.

Decodes a raw {trace_b,trace_a} dump exactly like fpga_la_crosscheck
(expand -> re-pair parity/order search -> TPIU deframe) and reports:
  * deframed byte count
  * flash I-sync anchors
  * unknown-byte fraction (the bit-error proxy: clean capture -> ~0%)
  * stray (non-flash but isync-shaped) anchors

Usage: python3 fpga_errrate.py <raw.bin> [raw2.bin ...]
"""
import sys
import collections
import etm35lib as L
import dsl_parse as D


def decode(raw):
    nibs = bytearray()
    for b in raw:
        nibs.append((b >> 4) & 0xF)
        nibs.append(b & 0xF)
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
            if best is None or fl > best[0]:
                best = (fl, parity, order, data)
    data = best[3]
    ph = None
    if L.has_tpiu_sync(data):
        ph, _ = L.find_tpiu_phase(data)
        data = L.tpiu_deframe_hsync(data, ph)
    return data, best[1], best[2], ph


def main():
    for path in sys.argv[1:]:
        raw = open(path, "rb").read()
        etm, parity, order, ph = decode(raw)
        syncs = L.find_isyncs(etm)
        flash = [s for s in syncs if L.is_flash(s.addr)]
        unk = sum(1 for c in etm if L._classify(c) == "unknown")
        pcs = collections.Counter(s.addr for s in flash)
        nonflash = len(syncs) - len(flash)
        print(f"{path}: raw={len(raw)}B parity={parity} order={order} phase={ph}")
        print(f"  deframed={len(etm)}B  flash_anchors={len(flash)} "
              f"distinct_PCs={len(pcs)}  nonflash_isync={nonflash}  "
              f"unknown={unk} ({100*unk/max(1,len(etm)):.3f}%)")
        # flag PCs outside the tight code window as likely bit-flips
        strays = [hex(a) for a in pcs if not (0x08000000 <= a < 0x08002000)]
        if strays:
            print(f"  stray flash PCs (likely bit-flips): {strays}")


if __name__ == "__main__":
    main()
