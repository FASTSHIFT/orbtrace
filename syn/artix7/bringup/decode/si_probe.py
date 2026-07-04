#!/usr/bin/env python3
"""si_probe — per-lane / per-half signal-integrity probe using TPIU HSYNC as a
KNOWN reference pattern, with NO need to find the loop period or decode.

TPIU half-sync (HSYNC) is the fixed 16-bit value 0xFF 0x7F. The FPGA packs one
byte per TRACECLK period as {trace_a[3:0], trace_b[3:0]} = {rising-half nibble,
falling-half nibble} across the 4 data lanes. So when the formatter emits HSYNC,
the captured nibbles take specific known values on each lane and each DDR half.

Method:
  1. expand to time-ordered nibbles, pick the (phase,order) that maximises HSYNC,
  2. locate every HSYNC occurrence (the known 0xFF7F pattern) in byte space,
  3. for the bytes that SHOULD be 0xFF and 0x7F, count how often each individual
     bit (= one data lane in one DDR half) deviates from its known value.

This isolates ENVIRONMENT B (sampling), and localises any error to a specific
LANE (which TRACEDx line) and HALF (rising trace_a vs falling trace_b). A pure
SI/skew problem concentrates on one lane or one half; a global phase error
spreads evenly. No logic analyser, no period alignment needed.

Usage: si_probe.py <fpga_raw.bin>
"""
import sys
import numpy as np
from nibble_align import best_align


def main():
    raw = open(sys.argv[1], "rb").read()
    h, ph, order, framed = best_align(raw)
    a = np.frombuffer(framed, dtype=np.uint8)
    print(f"{sys.argv[1]}: aligned (phase={ph} order={order}), HSYNC={h}")

    # Find HSYNC: byte i == 0xFF and byte i+1 == 0x7F. Use a relaxed locator:
    # a byte is "meant to be 0xFF" if it is part of a long FF run that ends with
    # a 0x7F (the formatter pads with FF and closes the half-sync with 7F).
    # Strict version: exact 0xFF followed by 0x7F.
    idx = np.where((a[:-1] == 0xFF) & (a[1:] == 0x7F))[0]
    print(f"strict HSYNC anchors: {len(idx)}")
    if len(idx) < 100:
        print("too few HSYNC to profile"); return

    # The byte BEFORE the 0xFF in a HSYNC filler is also usually 0xFF (long pad).
    # Profile the FF byte and the 7F byte of each HSYNC against their known value
    # to get per-bit deviation. But a clean FF/7F gives zero info on bits that
    # are '1' in both. Instead, profile the bytes ADJACENT to HSYNC that are
    # SUPPOSED to be 0xFF (pad) — deviations there are sampling errors on the
    # all-ones pattern, exercising every lane in the '1' state.
    # Known-value bit-deviation on the FF byte: any 0 bit is a lane that should
    # be 1 but sampled 0.
    ff_bytes = a[idx]          # all should be 0xFF
    sf_bytes = a[idx + 1]      # all should be 0x7F

    # byte layout = {trace_a[3:0], trace_b[3:0]} = bits7..4 rising, bits3..0 fall
    print("\n--- FF byte (known 0xFF): count of WRONG (=0) bits per position ---")
    total = len(ff_bytes)
    for bit in range(8):
        wrong = int(np.count_nonzero(((ff_bytes >> bit) & 1) == 0))
        half = "rising(a)" if bit >= 4 else "falling(b)"
        lane = bit % 4
        print(f"  bit{bit} [{half} lane{lane}]: {wrong}/{total} "
              f"({100*wrong/total:.3f}%)")

    print("\n--- 7F byte (known 0x7F=0111_1111): bit7 should be 0, rest 1 ---")
    for bit in range(8):
        exp = 0 if bit == 7 else 1
        wrong = int(np.count_nonzero(((sf_bytes >> bit) & 1) != exp))
        half = "rising(a)" if bit >= 4 else "falling(b)"
        lane = bit % 4
        print(f"  bit{bit} [{half} lane{lane}] exp={exp}: {wrong}/{total} "
              f"({100*wrong/total:.3f}%)")

    # aggregate per-lane and per-half on the FF byte (all-ones exercise)
    print("\n--- aggregate on FF pad bytes ---")
    lane_err = [0]*4; half_err = {"rising(a)":0,"falling(b)":0}
    for bit in range(8):
        wrong = int(np.count_nonzero(((ff_bytes >> bit) & 1) == 0))
        lane_err[bit % 4] += wrong
        half_err["rising(a)" if bit >= 4 else "falling(b)"] += wrong
    print(f"  per-lane (sum over both halves): {lane_err}")
    print(f"  per-half: {half_err}")


if __name__ == "__main__":
    main()
