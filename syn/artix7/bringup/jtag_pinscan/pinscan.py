#!/usr/bin/env python3
"""Pure-JTAG connectivity scanner orchestrator (no bitstream).

Flow:
  1. parse_bsdl.py has produced pinmap.json (pin -> pkg + cells)
  2. gen_vectors.py builds vectors.txt (EXTEST DR per pin/phase)
  3. run_scan.tcl shifts them via Vivado hw_server, writes results.txt
  4. here we decode results.txt into discovered jumper pairs

Usage:
  python3 pinscan.py [pin ...]      # scan given GPIO nets (default: all)
The Vivado step is invoked by the wrapper run.sh (needs settings64.sh).
This script does the pre (vector gen) and post (decode) steps.
"""
import json
import sys
import gen_vectors as gv


def gen(pool):
    pm = gv.load_pinmap()
    if not pool:
        pool = list(pm)
    with open("vectors.txt", "w") as f:
        for dp in pool:
            for ph in (0, 1):
                f.write(f"{dp},{ph},{gv.bits_to_hex(gv.make_dr(dp, ph, pm, pool))}\n")
    json.dump(pool, open("pool.json", "w"))
    print(f"[gen] {2*len(pool)} vectors for {len(pool)} pins")


def decode():
    pm = gv.load_pinmap()
    pool = json.load(open("pool.json"))
    rb = {}
    for line in open("results.txt"):
        line = line.strip()
        if not line:
            continue
        drive, phase, hexv = line.split(",")
        rb[(drive, int(phase))] = gv.hex_to_bits(hexv)
    pairs, follow = gv.decode(rb, pm, pool)
    print("\n==== DISCOVERED JUMPERS ====")
    if not pairs:
        print("  (none) — no connected pin pairs found.")
        print("  check jumpers are seated; or a pin may connect to a pin")
        print("  outside the scanned pool.")
    for a, b in pairs:
        print(f"  {a:11s} ({pm[a]['pkg']:>4s})  <-->  {b:11s} ({pm[b]['pkg']:>4s})")
    # report any asymmetric (one-way) follows as warnings
    for a in pool:
        for b in follow.get(a, ()):
            if a not in follow.get(b, set()):
                print(f"  [warn] {a}->{b} one-way only (floating? marginal?)")
    print(f"\n  {len(pairs)} jumper(s) found across {len(pool)} pins.")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    if mode == "gen":
        gen(sys.argv[2:])
    elif mode == "decode":
        decode()
    else:
        print("usage: pinscan.py gen [pins...] | decode")
