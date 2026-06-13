#!/usr/bin/env python3
"""opencsd_region_probe — run OpenCSD (trc_pkt_lister) from EACH real Thumb
I-sync anchor independently and measure how many bytes / instruction ranges it
decodes before it aborts.

This is the authoritative "capture clean-ness" yardstick: OpenCSD is the ARM
reference decoder and is correct-or-abort, so the per-anchor clean-decode
length is a direct measure of how far the captured stream stays valid after a
ground-truth anchor. A long, consistent reach => capture is clean to that
horizon; a reach of ~1 packet => something diverges immediately (capture noise,
our DDR/parse bug, or an unhandled-but-legit packet).

Usage:
    python3 opencsd_region_probe.py <bare-etm.bin> <elf> [N_anchors]
"""
import os
import re
import subprocess
import sys
import tempfile

import etm35lib as L

LISTER = os.environ.get("TRC_PKT_LISTER", "trc_pkt_lister")
PACKER = os.path.join(os.path.dirname(__file__), "make_opencsd_snapshot.py")


def thumb_anchors(data):
    """Offsets of real Normal I-syncs with the Thumb bit set (addr bit0=1)."""
    out = []
    for i in range(len(data) - 5):
        if data[i] != 0x08:
            continue
        info = data[i + 1]
        if info & 0x80 or info & 0x14:
            continue
        addr = (data[i + 2] | (data[i + 3] << 8)
                | (data[i + 4] << 16) | (data[i + 5] << 24))
        if 0x08000000 <= (addr & ~1) < 0x08060000 and (addr & 1):
            out.append((i, addr))
    return out


def probe_region(region_bytes, elf, tmp):
    """Pack one region (prefixed with a synthetic A-sync) and decode it.
    Returns (n_instr_ranges, bytes_processed, aborted)."""
    snapdir = os.path.join(tmp, "snap")
    os.makedirs(snapdir, exist_ok=True)
    buf = bytes([0, 0, 0, 0, 0, 0x80]) + region_bytes
    open(os.path.join(tmp, "region.bin"), "wb").write(buf)
    subprocess.run([sys.executable, PACKER,
                    os.path.join(tmp, "region.bin"), elf, snapdir],
                   capture_output=True)
    p = subprocess.run([LISTER, "-ss_dir", snapdir, "-decode",
                        "-decode_only", "-logstdout"],
                       capture_output=True, text=True)
    out = p.stdout
    n_ranges = out.count("INSTR_RANGE")
    aborted = "fatal error" in out
    m = re.search(r"processed (\d+) bytes", out)
    nb = int(m.group(1)) if m else 0
    return n_ranges, nb, aborted


def main():
    data = open(sys.argv[1], "rb").read()
    elf = sys.argv[2]
    nmax = int(sys.argv[3]) if len(sys.argv) > 3 else 40

    anchors = thumb_anchors(data)
    print(f"real Thumb I-sync anchors: {len(anchors)}; probing first {nmax}")

    ranges_hist = []
    bytes_hist = []
    with tempfile.TemporaryDirectory() as tmp:
        for k, (off, addr) in enumerate(anchors[:nmax]):
            region = data[off:off + 2048]   # up to 2KB after the anchor
            nr, nb, ab = probe_region(region, elf, tmp)
            ranges_hist.append(nr)
            bytes_hist.append(nb)
            if k < 15:
                print(f"  anchor@{off} 0x{addr:08x}: "
                      f"{nr} instr-ranges, {nb} bytes decoded"
                      f"{' (abort)' if ab else ''}")

    if ranges_hist:
        import statistics
        print(f"\ninstr-ranges per anchor: max={max(ranges_hist)} "
              f"mean={statistics.mean(ranges_hist):.1f} "
              f"median={statistics.median(ranges_hist)}")
        print(f"bytes decoded per anchor: max={max(bytes_hist)} "
              f"mean={statistics.mean(bytes_hist):.0f}")


if __name__ == "__main__":
    main()
