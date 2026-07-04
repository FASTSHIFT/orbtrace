#!/usr/bin/env python3
"""nibble_completeness — measure capture quality with the CORRECT nibble->byte
alignment found empirically (phase/order that maximises TPIU HSYNC FF7F count),
instead of dsl_parse.assemble's fixed parity search which can mis-pair the
FPGA stream and inflate the unknown rate.

Steps:
  1. expand each captured byte {b<<4|a} into the time-ordered nibble stream,
  2. choose the (phase,order) that yields the most FF7F HSYNC fillers,
  3. TPIU-deframe (strip HSYNC + formatter), then
  4. report unknown-byte rate and flash I-sync anchors.

Usage: nibble_completeness.py <fpga_raw.bin>
"""
import sys
import etm35lib as L
from nibble_align import best_align


def main():
    raw = open(sys.argv[1], "rb").read()
    h, ph, order, framed = best_align(raw)
    print(f"{sys.argv[1]}: raw={len(raw)}B")
    print(f"  best nibble align: phase={ph} order={order}  HSYNC(FF7F)={h}")

    # TPIU deframe with continuous re-locking walker
    if L.has_tpiu_sync(framed):
        tph, _ = L.find_tpiu_phase(framed)
        etm = L.tpiu_deframe_walk(framed)
        deframed = f"deframed@tpiu_phase{tph}"
    else:
        etm = framed
        deframed = "NO-TPIU-SYNC"
    unk = sum(1 for c in etm if L._classify(c) == "unknown")
    syncs = [s for s in L.find_isyncs(etm) if L.is_flash(s.addr)]
    pcs = sorted({s.addr for s in syncs})
    print(f"  {deframed}: ETM={len(etm)}B  unknown={unk} "
          f"({100*unk/max(1,len(etm)):.4f}%)  flash-anchors={len(syncs)}  "
          f"distinct-PC={len(pcs)}")
    print(f"  PCs={[hex(p) for p in pcs[:20]]}")


if __name__ == "__main__":
    main()
