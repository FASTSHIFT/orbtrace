"""etm_ts_values — decode ETM3.5 timestamp packets (header 0x42, LEB128 payload)
from a capture and print the timestamp values to check they are monotonic and
sane. ETM3.5 timestamp packet: 0x42 then up to 9 continuation bytes (7 bits
each, bit7=continuation), gray-coded NO — plain LEB128 for ETMv3.5.

Usage: etm_ts_values.py <capture.bin>
"""
import sys
sys.path.insert(0, "decode")
sys.path.insert(0, ".")
import etm35lib as L

raw = open(sys.argv[1], "rb").read()
data = L.tpiu_deframe_walk(raw, want_stream=2) if L.has_tpiu_sync(raw) else raw
n = len(data)

vals = []
i = 0
while i < n:
    c = data[i]
    if (c & 0xFB) == 0x42:   # timestamp header (0x42 or 0x46)
        j = i + 1
        v = 0
        shift = 0
        cont = True
        cnt = 0
        while j < n and cnt < 9:
            b = data[j]
            v |= (b & 0x7F) << shift
            shift += 7
            j += 1
            cnt += 1
            if not (b & 0x80):
                cont = False
                break
        if not cont:
            vals.append(v)
            i = j
            continue
    i += 1

print(f"timestamp packets decoded: {len(vals)}")
if vals:
    print("first 12 values:", vals[:12])
    deltas = [vals[k+1] - vals[k] for k in range(len(vals)-1)]
    mono = all(d >= 0 for d in deltas)
    print("monotonic non-decreasing:", mono)
    print("min:", min(vals), "max:", max(vals), "span:", max(vals)-min(vals))
    pos = [d for d in deltas if d > 0]
    if pos:
        print("positive deltas:", len(pos), "of", len(deltas),
              "| min/med/max delta:", min(pos),
              sorted(pos)[len(pos)//2], max(pos))
