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
import subprocess
import sys

import etm35lib as L

ADDR2LINE = os.environ.get("ADDR2LINE", "arm-none-eabi-addr2line")


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("captures", nargs="+")
    ap.add_argument("--elf", default=os.environ.get("ELF", "/tmp/axf/proj_new.axf"))
    a = ap.parse_args()

    all_events = []
    for f in a.captures:
        data = open(f, "rb").read()
        ev = L.decode_all(data)
        isyncs = [e for e in ev if e.kind == "isync"]
        exec_atoms = sum(e.eatoms for e in ev if e.kind == "atoms")
        branches = sum(1 for e in ev if e.kind == "branch")
        print(f"{f}: {len(data)}B  I-sync anchors={len(isyncs)}  "
              f"exec-atoms={exec_atoms}  branches={branches}")
        all_events.extend(ev)

    pcs = sorted({e.addr for e in all_events if e.kind == "isync"})
    print(f"\ndistinct absolute PC anchors: {len(pcs)}")

    funcs = resolve(pcs, a.elf)
    if not funcs:
        print(f"(no ELF at {a.elf}; PCs only)")
        for p in pcs:
            print(f"  0x{p:08x}")
        return 0

    # distinct functions, with one example PC each
    byfunc = {}
    for p, (fn, loc) in funcs.items():
        byfunc.setdefault(fn, (p, loc))
    print(f"distinct functions executed: {len(byfunc)}")
    for fn in sorted(byfunc):
        if fn in ("??", "__dso_handle"):
            continue
        p, loc = byfunc[fn]
        print(f"  0x{p:08x}  {fn}\t{loc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
