#!/usr/bin/env python3
"""etm_decode_cli — end-to-end ETM3.5 decode report from a traceIF-frame capture.

The settled route (see docs/artix7-port/stage4-datapath/10-reuse-gap-audit.md):
  FPGA emits traceIF byte frames (trace_stream_top) -> PC anchors on I-sync
  directly via etm35lib (bypassing tpiu_demux, which destroys our bare stream)
  -> map absolute PCs to functions with addr2line.

Usage:
  python3 etm_decode_cli.py cap1.bin [cap2.bin ...] [--elf proj.axf]
  ELF=/tmp/axf/proj_new.axf python3 etm_decode_cli.py /tmp/cap.bin
"""
import argparse
import os
import re
import subprocess
import sys

import etm35lib as L

ADDR2LINE = os.environ.get("ADDR2LINE", "arm-none-eabi-addr2line")
READELF = os.environ.get("READELF", "arm-none-eabi-readelf")


def text_range(elf):
    """Return (lo, hi) covering the ELF's executable (.text-like) sections, so
    I-sync anchors are bounded by the real code extent (review r14 BUG-1),
    not a blanket 1 MB. Falls back to the default flash window on any error."""
    if not os.path.exists(elf):
        return (L.FLASH_LO, L.FLASH_HI)
    try:
        p = subprocess.run([READELF, "-S", "-W", elf],
                           capture_output=True, text=True)
    except OSError:
        return (L.FLASH_LO, L.FLASH_HI)
    lo, hi = None, None
    # readelf -SW columns: [Nr] Name Type Address Off Size ES Flg ...
    for line in p.stdout.splitlines():
        m = re.search(r"\]\s+\S+\s+\w+\s+([0-9a-fA-F]{8,16})\s+[0-9a-fA-F]+\s+"
                      r"([0-9a-fA-F]+)\s+\S+\s+([A-Zp]*)", line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        size = int(m.group(2), 16)
        flg = m.group(3)
        if "X" in flg and addr >= L.FLASH_LO:        # executable section in flash
            lo = addr if lo is None else min(lo, addr)
            hi = (addr + size) if hi is None else max(hi, addr + size)
    if lo is None:
        return (L.FLASH_LO, L.FLASH_HI)
    return (lo, hi)


def resolve(addrs, elf):
    """Map a list of flash PCs to 'func  file:line' via addr2line."""
    if not addrs or not os.path.exists(elf):
        return {}
    p = subprocess.run(
        [ADDR2LINE, "-f", "-e", elf] + [f"0x{a:08x}" for a in addrs],
        capture_output=True, text=True)
    lines = p.stdout.splitlines()
    out = {}
    for i, a in enumerate(addrs):
        fn = lines[2 * i] if 2 * i < len(lines) else "?"
        loc = lines[2 * i + 1] if 2 * i + 1 < len(lines) else "?"
        out[a] = (fn, loc)
    return out


def has_source(loc):
    """True if addr2line gave a real source location (not ??:0 / ??:?).
    Used to reject noise anchors that merely fall in flash (review r14 GAP-3)."""
    return loc not in ("??:0", "??:?", "?") and not loc.startswith("??:")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("captures", nargs="+")
    ap.add_argument("--elf", default=os.environ.get("ELF", "/tmp/axf/proj_new.axf"))
    ap.add_argument("--realign", action="store_true",
                    help="extend regions with sub-byte realignment (V4; flow "
                         "is indicative, only I-sync anchors are ground truth)")
    ap.add_argument("--loose", action="store_true",
                    help="skip the ELF .text range tightening + source-line "
                         "filter (debug; allows noise anchors)")
    a = ap.parse_args()

    lo, hi = (L.FLASH_LO, L.FLASH_HI) if a.loose else text_range(a.elf)
    if not a.loose and (lo, hi) != (L.FLASH_LO, L.FLASH_HI):
        print(f"anchor range tightened to ELF .text: "
              f"[0x{lo:08x}, 0x{hi:08x})")

    all_events = []
    for f in a.captures:
        data = open(f, "rb").read()
        # NOTE: decode_all/decode_all_realign use the default flash window for
        # region walking; we re-filter anchors by the tight range below.
        if a.realign:
            ev, realigns = L.decode_all_realign(data)
        else:
            ev, realigns = L.decode_all(data), 0
        isyncs = [e for e in ev if e.kind == "isync" and lo <= e.addr < hi]
        exec_atoms = sum(e.eatoms for e in ev if e.kind == "atoms")
        branches = sum(1 for e in ev if e.kind == "branch")
        extra = f"  realigns={realigns}" if a.realign else ""
        print(f"{f}: {len(data)}B  I-sync anchors={len(isyncs)}  "
              f"exec-atoms={exec_atoms}  branches={branches} (count-only){extra}")
        all_events.extend(e for e in ev if e.kind != "isync" or lo <= e.addr < hi)

    pcs = sorted({e.addr for e in all_events if e.kind == "isync"})
    print(f"\ndistinct absolute PC anchors (in .text): {len(pcs)}")

    funcs = resolve(pcs, a.elf)
    if not funcs:
        print(f"(no ELF at {a.elf}; PCs only)")
        for p in pcs:
            print(f"  0x{p:08x}")
        return 0

    # keep only anchors that addr2line resolves to a real source line, unless
    # --loose (review r14 GAP-3: addr2line names any flash addr, so require a
    # source line to reject noise that merely landed in .text).
    byfunc = {}
    dropped = 0
    for p, (fn, loc) in funcs.items():
        if fn in ("??", "__dso_handle"):
            dropped += 1
            continue
        if not a.loose and not has_source(loc):
            dropped += 1
            continue
        byfunc.setdefault(fn, (p, loc))
    print(f"distinct functions executed: {len(byfunc)}"
          + (f"  ({dropped} anchor(s) dropped: no source line)" if dropped else ""))
    for fn in sorted(byfunc):
        p, loc = byfunc[fn]
        print(f"  0x{p:08x}  {fn}\t{loc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
