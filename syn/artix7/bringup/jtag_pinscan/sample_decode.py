#!/usr/bin/env python3
"""Decode boundary-SAMPLE captures (sample_results.txt) to find which FPGA pin
carries a LIVE toggling signal — used to locate the SWO line plugged into an
unknown IO. Reports every pin whose INPUT cell was not constant across the
captures, ranked by how balanced its 0/1 split is (a real 2 MHz NRZ line
toggles a lot; a marginal/floating pin flips rarely).

Usage: python3 sample_decode.py [sample_results.txt]
"""
import json
import sys

BR_LEN = 812


def hex_to_bits(hexstr):
    val = int(hexstr, 16)
    return [(val >> i) & 1 for i in range(BR_LEN)]


def main():
    res = sys.argv[1] if len(sys.argv) > 1 else "sample_results.txt"
    pm = json.load(open("pinmap.json"))
    caps = []
    for line in open(res):
        line = line.strip()
        if line:
            caps.append(hex_to_bits(line))
    if len(caps) < 2:
        print("ERROR: need >=2 captures")
        return 1
    print(f"{len(caps)} captures, {len(pm)} pins")

    toggling = []
    for net, c in pm.items():
        si = c["in"]
        vals = [cap[si] for cap in caps]
        ones = sum(vals)
        zeros = len(vals) - ones
        if 0 < ones < len(vals):           # not constant -> toggled
            balance = min(ones, zeros) / max(ones, zeros)
            toggling.append((balance, ones, zeros, net, c["pkg"]))

    if not toggling:
        print("\nNo toggling pin found. Either SWO is not running, the pin is")
        print("outside the scanned set, or config wasn't cleared. Check OpenOCD")
        print("is still resident (SWO dies on debugger exit).")
        return 1

    toggling.sort(reverse=True)            # most balanced first = the live line
    print("\n==== TOGGLING PINS (most active first) ====")
    for bal, ones, zeros, net, pkg in toggling:
        print(f"  {net:11s} ({pkg:>4s})  1s={ones:3d} 0s={zeros:3d}  balance={bal:.2f}")
    bal, ones, zeros, net, pkg = toggling[0]
    print(f"\n==> SWO is most likely on {net} (FPGA pin {pkg}), "
          f"the most actively toggling IO.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
