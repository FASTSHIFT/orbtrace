#!/usr/bin/env python3
"""
Convert a DSLogic/sigrok UART-decoder CSV export to a raw byte stream,
then report TPIU/ETM sync density to gauge capture quality.

Usage: python3 csv3.py <decoder.csv> [out.bin]
  decoder CSV format: "Id,Time[ns],<chan>:UART: RX/TX" with hex byte in col 3.
"""
import re, sys

src = sys.argv[1] if len(sys.argv) > 1 else None
out = sys.argv[2] if len(sys.argv) > 2 else "etm.bin"
if not src:
    print(__doc__)
    sys.exit(1)

b = bytearray()
for line in open(src):
    p = line.strip().split(',')
    if len(p) < 3:
        continue
    h = p[2].strip()
    if not h:
        continue
    try:
        b.append(int(h, 16))
    except ValueError:
        pass

open(out, 'wb').write(b)
data = bytes(b)
print(f"wrote {len(data)} bytes -> {out}")

ts = bytes([0xFF, 0xFF, 0xFF, 0x7F])
c = 0; i = 0
while True:
    j = data.find(ts, i)
    if j < 0:
        break
    c += 1; i = j + 1
print(f"TPIU-sync (0xFFFFFF7F): {c}")
asy = re.findall(b'\x00\x00\x00\x00\x00\x80', data)
print(f"ETM A-sync packets: {len(asy)}")
print(f"0xFF total: {data.count(0xFF)}")
print("first 48:", ' '.join(f'{x:02X}' for x in data[:48]))
