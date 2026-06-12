#!/usr/bin/env python3
"""Hand-walk an ETM3.5 byte stream from an A-sync, classifying each packet,
to see what actually follows A-sync and whether/where I-SYNC (0x08) appears.

Implements just enough of the ETM3.5 IDLE-state grammar (orbuculum
traceDecoder_etm35.c) to step packet-by-packet and report the packet type
sequence. This tells us if the decoder SHOULD be able to anchor.
"""
import sys

d = open(sys.argv[1] if len(sys.argv) > 1 else "/tmp/capA.bin", "rb").read()
A = bytes.fromhex("000000000080")
start = d.find(A)
if start < 0:
    print("no A-sync"); sys.exit(1)
i = start + 6  # past A-sync
end = min(len(d), i + 400)

from collections import Counter
types = Counter()
isync_offs = []
n = 0
while i < end and n < 200:
    c = d[i]
    if c & 1:  # branch packet: consume continuation bytes (bit7)
        types["BRANCH"] += 1
        i += 1
        # std format: continue while bit7 set, max 5
        k = 0
        while i < end and (d[i-1] & 0x80) and k < 5:
            i += 1; k += 1
        n += 1
        continue
    if c == 0x00:
        types["A-sync-zero"] += 1; i += 1; n += 1; continue
    if c == 0x04:
        types["CYCCNT"] += 1; i += 1
        while i < end and (d[i-1] & 0x80): i += 1
        n += 1; continue
    if c == 0x08:
        types["ISYNC"] += 1; isync_offs.append(i - start)
        # ISYNC: infobyte + 4 addr bytes (+context). Skip ~5.
        i += 6; n += 1; continue
    if c == 0x70:
        types["ISYNC+CYC"] += 1; isync_offs.append(i - start); i += 8; n += 1; continue
    if c == 0x0c:
        types["TRIGGER"] += 1; i += 1; n += 1; continue
    if (c & 0xFB) == 0x42:
        types["TIMESTAMP"] += 1; i += 1
        while i < end and (d[i-1] & 0x80): i += 1
        n += 1; continue
    if (c & 0x81) == 0x80:
        types["P-HEADER"] += 1; i += 1; n += 1; continue
    types[f"other:{c:#04x}"] += 1
    i += 1; n += 1

print(f"A-sync at byte {start}; walking {n} packets after it")
print("packet type counts:")
for t, c in types.most_common():
    print(f"  {t:16s}: {c}")
print(f"\nISYNC offsets (from A-sync): {isync_offs}")
print(f"first 24 bytes after A-sync: {d[start+6:start+30].hex()}")
