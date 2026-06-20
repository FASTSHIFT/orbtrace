"""swo_make_orbetto_time — build orbetto inputs WITH a real FPGA time axis.

Pipeline (proposal 18 §9.3, A2):
  capture.bin + capture.bin.ts.json (FPGA timebase, from swo_dump_banked --timebase)
    -> tpiu_deframe_walk_offsets : pure ETM stream-2 bytes + each byte's RAW src offset
    -> fpga_timebase.TimeBase     : RAW offset -> wall-clock ns per ETM byte
    -> etm_to_tpiu.reframe         : re-wrap ETM as dense-FSYNC TPIU (orbetto -f)
    -> write <out>.tpiu  AND  <out>.fpga_ns  (u64 LE ns, one per ETM byte)

orbetto consumes:  orbetto -C <khz> -t 2 -f <out>.tpiu -e <elf> -F <out>.fpga_ns
The -F array is per ETM byte in stream order; reframe is a 1:1 ETM-byte->TPIU
mapping and orbetto re-deframes to the SAME ETM byte order, so ns aligns 1:1.

Usage: swo_make_orbetto_time.py <capture.bin> <ts.json> <out_prefix>
"""
import struct
import sys

sys.path.insert(0, "decode")
sys.path.insert(0, ".")
import etm35lib as L
from etm_to_tpiu import reframe
from fpga_timebase import TimeBase


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    cap_path, ts_path, out_prefix = sys.argv[1:4]
    raw = open(cap_path, "rb").read()
    tb = TimeBase.load(ts_path)

    # deframe with source-offset tracking: each ETM byte -> its RAW capture index
    etm, offs = L.tpiu_deframe_walk_offsets(raw, want_stream=2)
    # map each ETM byte's RAW source offset -> wall-clock ns
    ns = [int(tb.ns_for_raw(o)) for o in offs]

    # reframe ETM -> dense-FSYNC TPIU for orbetto -f
    tpiu = reframe(etm)

    out_tpiu = out_prefix + ".tpiu"
    out_ns = out_prefix + ".fpga_ns"
    open(out_tpiu, "wb").write(tpiu)
    with open(out_ns, "wb") as f:
        f.write(b"".join(struct.pack("<Q", max(0, t)) for t in ns))

    span = (max(ns) - min(ns)) if ns else 0
    print(f"ETM bytes: {len(etm)}  reframed TPIU: {len(tpiu)}")
    print(f"ns entries: {len(ns)}  span: {span} ns ({span/1e6:.3f} ms)")
    print(f"  monotonic: {all(ns[k] <= ns[k+1] for k in range(len(ns)-1))}")
    print(f"wrote {out_tpiu} and {out_ns}")
    print(f"run: orbetto -C 168000 -t 2 -f {out_tpiu} -e <elf> -F {out_ns}")


if __name__ == "__main__":
    main()
