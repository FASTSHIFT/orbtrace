#!/usr/bin/env python3
"""Generate EXTEST boundary-scan DR vectors for a connectivity sweep, and
decode the readback into a jumper adjacency list. Pure JTAG, no bitstream.

Boundary register = 812 cells. For each pin under test we emit two vectors:
  phase0: drive that pin's OUTPUT cell = 0, its CONTROL cell = drive-enable,
          ALL other pins released (control = disable -> Hi-Z).
  phase1: same but OUTPUT cell = 1.
Then we read back every pin's INPUT cell. A sink pin S is "connected" to the
driven pin D iff S read 0 in phase0 AND 1 in phase1 (followed the driver
both ways) -- this rejects floating inputs and stuck pins.

7-series EXTEST control-cell convention (BC_2, disval=1, disrslt=Z): writing
0 into the control cell ENABLES the output driver; writing 1 makes it Hi-Z
(matches the BSDL "1 (controlr,1)" / "(... ,1, Z)" disable value).

This module just builds/parses bit vectors; the actual JTAG shifting is done
by run_scan.tcl which calls scan_dr_hw_jtag per vector.
"""
import json
import sys

BR_LEN = 812


def load_pinmap(path="pinmap.json"):
    return json.load(open(path))


def make_dr(drive_pin, value, pinmap, pool):
    """Return a list of 812 bits (index = cell number) for one EXTEST DR.
    All pins in `pool` are released except `drive_pin`, which drives `value`.
    """
    bits = [0] * BR_LEN
    # default: every controllable cell = 1 (Hi-Z / disabled), outputs = 0
    for net in pool:
        c = pinmap[net]
        bits[c["ctrl"]] = 1          # disabled (Hi-Z) by default
        bits[c["out"]] = 0
    # enable just the driver
    d = pinmap[drive_pin]
    bits[d["ctrl"]] = 0              # 0 = enable output
    bits[d["out"]] = value & 1
    return bits


def bits_to_hex(bits):
    """Cell 0 is shifted in first. scan_dr_hw_jtag -tdi takes a hex string;
    we pack cell i into bit i of a big integer (cell 0 = LSB) then hex it,
    width = ceil(BR_LEN/4) nibbles. run_scan.tcl uses the same convention on
    readback (see hex_to_bits)."""
    val = 0
    for i, b in enumerate(bits):
        if b:
            val |= (1 << i)
    nib = (BR_LEN + 3) // 4
    return f"{val:0{nib}x}"


def hex_to_bits(hexstr):
    val = int(hexstr, 16)
    return [(val >> i) & 1 for i in range(BR_LEN)]


def decode(readbacks, pinmap, pool):
    """readbacks: dict (drive_pin, phase) -> bits list. Return adjacency:
    list of (pinA, pinB) unordered jumper pairs."""
    follow = {}  # drive_pin -> set of sinks that followed both phases
    for dp in pool:
        b0 = readbacks[(dp, 0)]
        b1 = readbacks[(dp, 1)]
        sinks = set()
        for s in pool:
            if s == dp:
                continue
            si = pinmap[s]["in"]
            if b0[si] == 0 and b1[si] == 1:
                sinks.add(s)
        follow[dp] = sinks
    # a real jumper shows up symmetrically (a drives b AND b drives a)
    pairs = set()
    for a in pool:
        for b in follow[a]:
            if a in follow.get(b, set()):
                pairs.add(tuple(sorted((a, b))))
    return sorted(pairs), follow


if __name__ == "__main__":
    pm = load_pinmap()
    pool = sys.argv[1:] or list(pm)
    # emit vector file: one line per "drive,phase,hex"
    with open("vectors.txt", "w") as f:
        for dp in pool:
            for ph in (0, 1):
                f.write(f"{dp},{ph},{bits_to_hex(make_dr(dp, ph, pm, pool))}\n")
    print(f"wrote {2*len(pool)} vectors for {len(pool)} pins -> vectors.txt")
