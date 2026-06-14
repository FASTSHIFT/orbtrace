#!/usr/bin/env python3
"""etm_with_time — attach the FPGA capture-time base to a decoded ETM stream.

Pipeline (doc 15 §24.2): the F429 ETM has no wall-clock, so the FPGA timestamps
RAW capture bytes (trace_dump --timebase -> <dump>.ts.json). Here we:
  1. deframe the RAW TPIU capture into ETM bytes, tracking the source RAW byte
     offset of each ETM byte (tpiu_deframe_walk_offsets),
  2. map each ETM byte's source offset -> wall-clock ns via the sidecar table
     (fpga_timebase.TimeBase),
  3. emit the clean ETM bytes (for etm_to_tpiu.py -> orbetto) AND a parallel
     <out>.time.json array of ETM-byte -> ns, so the downstream can place
     instructions on a real (frequency-agnostic) time axis instead of the
     degenerate ETM cycle-count path.

Usage:
  python3 etm_with_time.py <capture.bin> <capture.bin.ts.json> <out_etm.bin>
"""
import json
import sys

import etm35lib as L
from fpga_timebase import TimeBase


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    cap_path, ts_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    raw = open(cap_path, "rb").read()
    tb = TimeBase.load(ts_path)

    # Stage 1: assemble best-aligned byte stream is already done upstream
    # (trace_dump output is the correctly-assembled RAW byte stream). Deframe
    # with source-offset tracking so each ETM byte carries its RAW origin.
    etm, offs = L.tpiu_deframe_walk_offsets(raw)

    # Stage 2: map RAW source offset -> wall-clock ns. The dump file is the RAW
    # buffer with the first `skip` bytes dropped; offsets index into that file,
    # so they are OUT indices (add skip inside TimeBase.ns_for_out).
    times_ns = [tb.ns_for_out(o) for o in offs]

    with open(out_path, "wb") as f:
        f.write(etm)
    side = out_path + ".time.json"
    with open(side, "w") as f:
        json.dump({"tick_ns": tb.tick_ns,
                   "span_ns": tb.span_ns(),
                   "n_etm_bytes": len(etm),
                   "times_ns": times_ns}, f)

    # Report
    unk = sum(1 for c in etm if L._classify(c) == "unknown")
    print(f"deframed {len(raw)} RAW -> {len(etm)} ETM bytes "
          f"(unknown {100*unk/max(1,len(etm)):.3f}%)")
    if times_ns:
        span = times_ns[-1] - times_ns[0]
        nondec = sum(1 for k in range(1, len(times_ns))
                     if times_ns[k] < times_ns[k - 1] - 1e-6)
        print(f"time: {times_ns[0]/1e3:.1f}..{times_ns[-1]/1e3:.1f} us "
              f"(span {span/1e3:.1f} us), non-decreasing violations: {nondec}")
    print(f"wrote {out_path} + {side}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
