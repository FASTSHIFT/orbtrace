#!/usr/bin/env python3
"""fpga_la_crosscheck — compare the FPGA trace_stream capture against the
logic-analyser .dsl reference, after identical TPIU deframing + ETM decode.

Both paths see the SAME STM32 trace pins:
  * LA path:   .dsl -> dsl_parse (DDR align) -> tpiu_deframe_hsync -> ETM bytes
  * FPGA path: trace_stream UDP dump (raw TPIU bytes) -> tpiu_deframe_hsync -> ETM

If the FPGA capture front-end is correct, both deframed ETM streams should
decode (via OpenCSD/etm35lib) to the SAME set of flash I-sync anchors and the
SAME instruction flow. This script reports:
  * deframe cleanliness (unknown-byte fraction) for each
  * flash I-sync anchor sets and their overlap
  * any divergence, to pin FPGA-side bugs.

Usage:
  python3 fpga_la_crosscheck.py <fpga_raw.bin> <la.dsl> [--elf proj.axf]
"""
import argparse
import collections
import os
import subprocess
import sys

import etm35lib as L
import dsl_parse as D


def deframe_raw(raw):
    """Decode a raw FPGA dump.

    The FPGA packs one byte = {trace_b[3:0], trace_a[3:0]} per trace_clk
    period (falling-edge nibble in the high half, rising-edge in the low half).
    A logic-analyser-equivalent reconstruction (proven bit-exact against the
    golden .dsl via tb_dsl_replay, doc 14 §24) requires:
      1. expand each byte back into the time-ordered nibble stream
         (b first, then a),
      2. re-pair nibbles with the correct parity/order across period
         boundaries (the ETM byte boundary does NOT align with the trace_clk
         period — parity=1 / rise=low,fall=high is the match),
      3. TPIU-deframe.
    We search the 4 parity/order combos and keep the one with the most flash
    anchors, exactly like dsl_parse does for the LA path.
    """
    # 1. byte -> time-ordered nibbles (b = high half first, then a = low half)
    nibs = bytearray()
    for byte in raw:
        nibs.append((byte >> 4) & 0xF)   # trace_b (falling)
        nibs.append(byte & 0xF)          # trace_a (rising)

    # 2. re-pair, search parity/order
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
            if best is None or fl > best[0]:
                best = (fl, data)
    data = best[1]

    # 3. TPIU deframe
    if not L.has_tpiu_sync(data):
        return data, None
    ph, _ = L.find_tpiu_phase(data)
    return L.tpiu_deframe_hsync(data, ph), ph


def la_to_etm(dsl_path):
    """Run the .dsl through the same pipeline dsl_parse uses, return ETM bytes.
    (Re-implements the parse+align+deframe inline so we get the bytes directly.)"""
    chans, srate, nprobes = D.load_channels(dsl_path)
    nsamp = min(min(len(v) for v in chans.values()) * 8, 50_000_000)
    clk = D.unpack_bits(chans[0], nsamp)
    d = [D.unpack_bits(chans[ch], nsamp) for ch in range(1, 5)]
    edges, half = D.find_edges(clk, nsamp)
    eye = max(1, int(half * D.DEFAULT_EYE_FRACTION))
    nibs = D.sample_nibbles(d, edges, eye)
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
            if best is None or fl > best[0]:
                best = (fl, data)
    data = best[1]
    if L.has_tpiu_sync(data):
        ph, _ = L.find_tpiu_phase(data)
        data = L.tpiu_deframe_hsync(data, ph)
    return data


def summarize(name, etm):
    syncs = [s for s in L.find_isyncs(etm) if L.is_flash(s.addr)]
    unk = sum(1 for c in etm if L._classify(c) == "unknown")
    hist = collections.Counter(s.addr for s in syncs)
    print(f"\n[{name}] {len(etm)} ETM bytes; flash anchors={len(syncs)}; "
          f"unknown={unk} ({100*unk/max(1,len(etm)):.4f}%)")
    return set(hist), hist


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fpga_raw")
    ap.add_argument("dsl")
    ap.add_argument("--elf", default="/tmp/axf/proj_add.axf")
    a = ap.parse_args()

    fpga_raw = open(a.fpga_raw, "rb").read()
    fpga_etm, fph = deframe_raw(fpga_raw)
    la_etm = la_to_etm(a.dsl)

    print(f"FPGA raw {len(fpga_raw)}B (deframe phase {fph}); "
          f"LA dsl -> {len(la_etm)} ETM bytes")

    fset, fhist = summarize("FPGA", fpga_etm)
    lset, lhist = summarize("LA", la_etm)

    common = fset & lset
    only_f = fset - lset
    only_l = lset - fset
    print(f"\nanchor PC overlap: common={len(common)} "
          f"FPGA-only={len(only_f)} LA-only={len(only_l)}")
    if only_f:
        print("  FPGA-only PCs:", [hex(x) for x in sorted(only_f)][:10])
    if only_l:
        print("  LA-only PCs:  ", [hex(x) for x in sorted(only_l)][:10])

    verdict = "MATCH" if (not only_f and not only_l) else "DIVERGENCE"
    print(f"\n==> anchor-set verdict: {verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
