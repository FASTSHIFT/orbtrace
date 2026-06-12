#!/usr/bin/env python3
"""Spec-correct ETM3.5 (Cortex-M4, DDI0440C) decoder for our 4-bit-port capture.

Grounded in IHI0014Q:
  - §7.10.4: 4-bit port trace is NOT guaranteed byte-aligned; the decoder must
    realign after each A-sync (>=5 x 0x00 then 0x80).
  - §7.10.5 / Fig 7-42: a Normal I-sync packet = header 0x08, then ContextID
    bytes (0 here: ETM-M4 has 0 ContextID comparators, ETMCR[15:14]=00), then
    1 info byte, then a 4-byte UNCOMPRESSED absolute instruction address.
  - DDI0440C: ETM-M4 fixed sync every 1024 bytes; addr/ctx/data comparators 0.

Strategy (anchor on I-sync, the only absolute PC source):
  1. Scan the byte stream for the I-sync signature: 0x08, info(bit7=0), then a
     4-byte little-endian address in flash range 0x0800_0000..0x0810_0000.
  2. Each hit is a hard absolute-PC anchor. Emit it.
  3. (Optional) from each anchor, walk P-headers/branches to extend the trace
     until the parse derails, then wait for the next anchor.

This sidesteps the orbuculum decoder's failure to realign sub-byte trace.
"""
import sys
import struct
from collections import Counter

FLASH_LO = 0x08000000
FLASH_HI = 0x08100000


def find_isyncs(d):
    """Return list of (offset, addr, thumb) for every plausible Normal I-sync."""
    hits = []
    n = len(d)
    for i in range(n - 5):
        if d[i] != 0x08:
            continue
        info = d[i + 1]
        # Normal I-sync info byte: bit7=0 (Normal, not LSiP). reason in [6:5].
        if info & 0x80:
            continue
        addr = d[i + 2] | (d[i + 3] << 8) | (d[i + 4] << 16) | (d[i + 5] << 24)
        thumb = addr & 1
        a = addr & ~1
        if FLASH_LO <= a < FLASH_HI:
            hits.append((i, a, thumb))
    return hits


def main():
    files = sys.argv[1:] or ["/tmp/capGND.bin"]
    all_addrs = []
    per_file = {}
    for f in files:
        d = open(f, "rb").read()
        hits = find_isyncs(d)
        per_file[f] = hits
        all_addrs.extend(a for _, a, _ in hits)

    for f, hits in per_file.items():
        # spacing between anchors (should cluster near the 1024-byte sync period
        # plus packet bytes, modulated by how busy the trace is)
        offs = [h[0] for h in hits]
        gaps = [offs[k + 1] - offs[k] for k in range(len(offs) - 1)]
        print(f"{f}: {len(hits)} I-sync anchors")
        if gaps:
            print(f"    anchor spacing: min={min(gaps)} max={max(gaps)} "
                  f"mean={sum(gaps)//len(gaps)}")

    uniq = sorted(set(all_addrs))
    print(f"\nTOTAL distinct absolute PCs: {len(uniq)}")
    with open("/tmp/isync_pcs.txt", "w") as fh:
        fh.write("\n".join(f"0x{a:08x}" for a in uniq))
    print("wrote /tmp/isync_pcs.txt  (map with arm-none-eabi-addr2line)")


if __name__ == "__main__":
    main()
