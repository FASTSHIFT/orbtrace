#!/usr/bin/env python3
"""Spec-correct ETM3.5 (Cortex-M4) I-sync anchor extractor (CLI).

Thin CLI over etm35lib (which is unit-tested). Grounded in IHI0014Q +
DDI0440C: a Normal I-sync packet carries a 4-byte uncompressed absolute PC,
and is the only absolute-PC anchor. See etm35lib.py for the spec references.

Usage: python3 etm_isync_decode.py cap1.bin [cap2.bin ...]
Writes the distinct flash PCs to /tmp/isync_pcs.txt for addr2line.
"""
import sys

import etm35lib as L


def main():
    files = sys.argv[1:] or ["/tmp/capGND.bin"]
    all_addrs = set()
    for f in files:
        d = open(f, "rb").read()
        syncs = L.find_isyncs(d)
        offs = [s.offset for s in syncs]
        gaps = [offs[k + 1] - offs[k] for k in range(len(offs) - 1)]
        print(f"{f}: {len(syncs)} I-sync anchors")
        if gaps:
            print(f"    anchor spacing: min={min(gaps)} max={max(gaps)} "
                  f"mean={sum(gaps) // len(gaps)}  (sync period = 1024 B trace)")
        all_addrs.update(s.addr for s in syncs)

    uniq = sorted(all_addrs)
    print(f"\nTOTAL distinct absolute PCs: {len(uniq)}")
    with open("/tmp/isync_pcs.txt", "w") as fh:
        fh.write("\n".join(f"0x{a:08x}" for a in uniq))
    print("wrote /tmp/isync_pcs.txt  (map with arm-none-eabi-addr2line)")


if __name__ == "__main__":
    main()
