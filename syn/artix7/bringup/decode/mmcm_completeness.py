#!/usr/bin/env python3
"""Quantify MMCM-capture completeness with the §14/§16 LA-golden methodology.

The MMCM RTL already packs the decodable ETM byte {trace_a[k], trace_b[k-1]},
so this is the post-pairing ETM byte stream (the same representation the LA
golden reaches after dsl_parse). Apply the SAME TPIU deframe, then measure the
ground-truth metrics:
  - HSYNC count (TPIU idle filler 0xFF 0x7F): the raw pin stream always carries
    these; if they vanish at high speed the stream is being corrupted.
  - unknown-byte rate AFTER deframe (M4 has no data trace; unknowns = errors).
    LA golden = 0.0018%.
  - flash I-sync anchor count (the ONLY ground-truth metric; r14).
Usage (run from decode/):  mmcm_completeness.py cap.bin [cap2.bin ...]
"""
import sys
import etm35lib as L


def measure(path):
    raw = open(path, "rb").read()
    hsync = raw.count(b"\xff\x7f")
    fsync = raw.count(b"\xff\xff\xff\x7f")
    has = L.has_tpiu_sync(raw)
    if has:
        ph, _ = L.find_tpiu_phase(raw)
        etm = L.tpiu_deframe_hsync(raw, ph)
        deframed = f"deframed@phase{ph}"
    else:
        etm = raw
        deframed = "NO-TPIU-SYNC (raw)"
    unk = sum(1 for c in etm if L._classify(c) == "unknown")
    syncs = [s for s in L.find_isyncs(etm) if L.is_flash(s.addr)]
    pcs = sorted({s.addr for s in syncs})
    print(f"{path}")
    print(f"  raw={len(raw)}B  HSYNC(FF7F)={hsync}  FSYNC={fsync}  {deframed}")
    print(f"  ETM={len(etm)}B  unknown={unk} ({100*unk/max(1,len(etm)):.4f}%)"
          f"  flash-anchors={len(syncs)}  distinct-PC={len(pcs)}")
    print(f"  PCs={[hex(p) for p in pcs]}")


for p in sys.argv[1:]:
    measure(p)
