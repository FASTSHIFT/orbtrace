#!/usr/bin/env python3
"""Test the 'TPIU formatter is OFF, stream is raw ETM3.5' hypothesis.

If the STM32 TPIU runs in bypass/continuous mode, the captured bytes are raw
ETM3.5 (no 16-byte TPIU framing). We scan for the ETM3.5 A-sync sequence
(00 00 00 00 00 80) and for I-sync packets, across the raw byte stream and a
few bit/byte transforms, to see which interpretation yields dense sync.
"""
import sys

data = open(sys.argv[1] if len(sys.argv) > 1 else "/tmp/frames2.bin", "rb").read()

ASYNC = bytes.fromhex("000000000080")


def revbits(b):
    r = 0
    for i in range(8):
        if b & (1 << i):
            r |= 1 << (7 - i)
    return r


variants = {
    "raw": data,
    "nibble-swap": bytes(((b << 4) | (b >> 4)) & 0xFF for b in data),
    "bit-reverse": bytes(revbits(b) for b in data),
}

for name, d in variants.items():
    na = d.count(ASYNC)
    n5z = d.count(bytes.fromhex("0000000000"))
    print(f"{name:14s}: A-sync(000000000080)={na:4d}  5-zero={n5z:5d}")

# Also: ETM3.5 A-sync can be detected as "five 0x00 then 0x80". Show offsets
# of the first few to check spacing (regular spacing => real sync cadence).
d = data
offs = []
i = 0
while True:
    j = d.find(ASYNC, i)
    if j < 0:
        break
    offs.append(j)
    i = j + 1
print(f"\nraw A-sync count={len(offs)}; first offsets: {offs[:12]}")
if len(offs) > 1:
    deltas = [offs[k+1]-offs[k] for k in range(len(offs)-1)]
    print(f"deltas: {deltas[:12]}")
