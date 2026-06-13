#!/usr/bin/env python3
"""Offline lane/phase sweep on a RAW nibble capture.

Input: a raw-nibble dump where each byte = {trace_b[3:0], trace_a[3:0]}
(trace_b = falling-edge nibble in high bits, trace_a = rising-edge in low),
exactly what trace_capture_a7 produces per trace_clk before traceIF.

We re-implement traceIF's 4-bit shift assembly (construct <= {dinb,dina,
construct[35:8]}; find 0x7FFFFFFF sync; emit 16-bit packets) but try every
candidate front-end transform:
  - swap trace_a <-> trace_b (rising/falling edge swap)
  - reverse the 4 data-lane bit order within each nibble
  - all 24 lane permutations (in case dupont wiring permuted the lanes)
For each, count how many TPIU full-syncs (0xFFFFFF7F) appear in the assembled
byte stream and how many ETM A-syncs. The correct mapping should make TPIU
full-sync appear (orbtrace's tpiuDecoder needs it).
"""
import sys
from itertools import permutations

raw = open(sys.argv[1] if len(sys.argv) > 1 else "/tmp/trace_etm.bin", "rb").read()


def nib(b, perm, rev):
    """remap a 4-bit nibble by lane permutation perm and optional bit reverse."""
    out = 0
    for dst, src in enumerate(perm):
        bit = (b >> src) & 1
        out |= bit << dst
    if rev:
        out = ((out & 1) << 3) | ((out & 2) << 1) | ((out & 4) >> 1) | ((out & 8) >> 3)
    return out


def assemble(raw, swap_ab, perm, rev):
    """traceIF 4-bit assembly with the given front-end transform.
    Returns the assembled byte stream (packets concatenated)."""
    construct = 0
    out = bytearray()
    # collect 16-bit packets after sync, like traceIF (width==3 path)
    synced = False
    rem = 0
    pending = []
    for byte in raw:
        a = byte & 0x0F
        b = (byte >> 4) & 0x0F
        a = nib(a, perm, rev)
        b = nib(b, perm, rev)
        if swap_ab:
            a, b = b, a
        # construct <= {b, a, construct[35:8]}  (36-bit)
        construct = ((b << 32) | (a << 28) | (construct >> 8)) & 0xFFFFFFFFF
        # sync detect: construct[35:4] == 0x7FFFFFFF (FE) or [35:35-31]
        top32 = (construct >> 4) & 0xFFFFFFFF
        if top32 == 0x7FFFFFFF:
            synced = True
            rem = 1
            continue
        if synced:
            if rem:
                rem -= 1
            else:
                rem = 1
                pkt = (construct >> 4) & 0xFFFF
                if pkt != 0x7FFF:
                    out.append(pkt & 0xFF)
                    out.append((pkt >> 8) & 0xFF)
    return bytes(out)


SYNC = bytes.fromhex("ffffff7f")
ASYNC = bytes.fromhex("000000000080")

best = []
for swap_ab in (False, True):
    for rev in (False, True):
        for perm in permutations(range(4)):
            s = assemble(raw, swap_ab, perm, rev)
            nsync = s.count(SYNC)
            na = s.count(ASYNC)
            if nsync or na:
                best.append((nsync, na, swap_ab, rev, perm, len(s)))

best.sort(reverse=True)
print(f"raw bytes in: {len(raw)}")
print("top transforms by TPIU-sync then A-sync:")
for nsync, na, swap_ab, rev, perm, ln in best[:15]:
    print(f"  TPIUsync={nsync:3d} Async={na:3d}  swap_ab={int(swap_ab)} revbits={int(rev)} laneperm={perm} out={ln}")
if not best:
    print("  (no syncs found in any transform)")
