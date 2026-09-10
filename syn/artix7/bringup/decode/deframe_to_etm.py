#!/usr/bin/env python3
"""deframe_to_etm — one-shot: raw FPGA capture -> deframed ETMv4 bytes.

Does ONLY the capture-side recovery (nibble reassemble + official TPIU
deframe) and writes the bare ETMv4 byte stream. Hand the output to
cortrace-decode (fast C++), not the slow trc_pkt_lister python path.

Usage: deframe_to_etm.py <raw.bin> <out_etm.bin> [max_bytes]
"""
import sys
import opencsd_etm4_run as R
import tpiu_official as T

raw_path, out_path = sys.argv[1], sys.argv[2]
maxb = int(sys.argv[3]) if len(sys.argv) > 3 else 0
raw = open(raw_path, "rb").read()
if maxb:
    raw = raw[:maxb]
score, parity, order, data, fl, v4a, fsync = R.recover_assemble(raw)
etm, stats = T.deframe(data, want_stream=2)
open(out_path, "wb").write(etm)
print(f"raw={len(raw)} parity={parity} order={order} fsync={fsync} "
      f"pre-deframe-async={v4a} -> etm={len(etm)} bytes  frames={stats['packets']}")
