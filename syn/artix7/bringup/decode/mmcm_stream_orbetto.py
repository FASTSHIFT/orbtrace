#!/usr/bin/env python3
"""mmcm_stream_orbetto — turn a streamed MMCM capture into orbetto inputs with a
real (uniform-rate) wall-clock time axis.

The streaming top (trace_mmcm_stream_top) has NO FPGA tick-table timebase, but
the capture is strictly 1 byte per TRACECLK period at a constant rate, so each
RAW (post-nibble-assemble) byte advances wall-clock by exactly one TRACECLK
period. That gives an authoritative uniform time base (the only error is none:
HSYNC idle fillers are also 1 byte/period, so idle time still elapses correctly).

Pipeline:
  streamed {a,b} bytes
    -> recover time-ordered half-bit nibbles, parity-search assemble (1:1 with
       TRACECLK periods)  [same as mmcm_decode]
    -> tpiu_deframe_walk_offsets : ETM stream-2 bytes + each byte's source
       offset into the assembled (period-indexed) stream
    -> ns[k] = offset[k] * PERIOD_NS               (uniform wall-clock)
    -> etm_to_tpiu.reframe : re-wrap ETM as dense-FSYNC TPIU for orbetto -f
    -> write <out>.tpiu  AND  <out>.fpga_ns (u64 LE ns, one per ETM byte)

orbetto:  orbetto -C <khz> -t 2 -f <out>.tpiu -e <elf> -F <out>.fpga_ns

Usage: mmcm_stream_orbetto.py <stream.bin> <out_prefix> [--period-ns 47.6]
"""
import argparse
import struct
import sys

import etm35lib as L
import dsl_parse as D
from etm_to_tpiu import reframe


def recover_assemble(raw):
    """Streamed byte = {trace_a[k] hi, trace_b[k-1] lo}. Recover time-ordered
    half-bit nibbles and parity/order-search assemble to the period-indexed
    byte stream (1:1 with TRACECLK periods)."""
    nibs = bytearray()
    for k in range(len(raw) - 1):
        nibs.append((raw[k] >> 4) & 0xF)   # trace_a[k]
        nibs.append(raw[k + 1] & 0xF)      # trace_b[k]
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
            if best is None or fl > best[0]:
                best = (fl, parity, order, data)
    return best[3], best[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("out_prefix")
    ap.add_argument("--period-ns", type=float, default=47.6,
                    help="TRACECLK period (21MHz=47.6, 42MHz=23.8, 84MHz=11.9)")
    a = ap.parse_args()

    raw = open(a.stream, "rb").read()
    data, parity = recover_assemble(raw)

    # deframe with source-offset tracking (offsets index into `data`, which is
    # 1:1 with TRACECLK periods, so offset*period = wall-clock ns)
    if L.has_tpiu_sync(data):
        etm, offs = L.tpiu_deframe_walk_offsets(data, want_stream=2)
    else:
        etm = data
        offs = list(range(len(data)))
    ns = [int(round(o * a.period_ns)) for o in offs]

    tpiu = reframe(etm)
    out_tpiu = a.out_prefix + ".tpiu"
    out_ns = a.out_prefix + ".fpga_ns"
    open(out_tpiu, "wb").write(tpiu)
    with open(out_ns, "wb") as f:
        f.write(b"".join(struct.pack("<Q", max(0, t)) for t in ns))

    unk = sum(1 for c in etm if L._classify(c) == "unknown")
    span = (ns[-1] - ns[0]) if ns else 0
    nondec = sum(1 for k in range(1, len(ns)) if ns[k] < ns[k - 1])
    print(f"parity={parity}  ETM={len(etm)}B  unknown={100*unk/max(1,len(etm)):.4f}%")
    print(f"reframed TPIU={len(tpiu)}B  ns entries={len(ns)}  "
          f"span={span/1e6:.3f} ms  non-monotonic={nondec}")
    print(f"wrote {out_tpiu} + {out_ns}")
    print(f"run: build/orbetto -C 42000 -t 2 -f {out_tpiu} -e <elf> -F {out_ns}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
