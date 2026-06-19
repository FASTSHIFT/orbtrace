#!/usr/bin/env python3
import serial, sys, time

dev = sys.argv[1] if len(sys.argv)>1 else "/dev/ttyACM0"
baud = int(sys.argv[2]) if len(sys.argv)>2 else 2000000
dur = float(sys.argv[3]) if len(sys.argv)>3 else 2.0
out = sys.argv[4] if len(sys.argv)>4 else "trace_eval/ch343.bin"

try:
    s = serial.Serial(dev, baud, timeout=0.2)
except Exception as e:
    print(f"open {dev}@{baud} FAILED: {e}")
    sys.exit(1)

print(f"opened {dev} @ {baud} baud, capturing {dur}s ...")
buf = bytearray()
t0 = time.time()
while time.time()-t0 < dur:
    chunk = s.read(65536)
    if chunk:
        buf += chunk
s.close()
open(out,"wb").write(buf)
rate = len(buf)/dur
print(f"captured {len(buf)} bytes -> {out}  ({rate/1000:.1f} kB/s)")
if buf:
    print("first 48:", ' '.join(f"{b:02X}" for b in buf[:48]))
