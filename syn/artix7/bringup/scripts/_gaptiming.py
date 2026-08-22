#!/usr/bin/env python3
"""_gaptiming — receive the :5555 stream, and at every seq-gap record the
inter-arrival time to the previous packet. Distinguishes:
  * gap WITH a large inter-arrival delay  -> FPGA paused (egress/self-TX stall)
  * gap WITH normal inter-arrival          -> frames vanished mid-flight (drop)
Also logs the wall-clock time of each gap so it can be cross-referenced with a
parallel tcpdump (ARP etc). Pure passive, no CSR poll."""
import socket
import struct
import sys
import time

IFACE = sys.argv[1] if len(sys.argv) > 1 else "enxc8a36266dcae"
SECS = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 256 << 20)
s.setsockopt(socket.SOL_SOCKET, 25, (IFACE + "\0").encode())
s.bind(("192.168.10.245", 5555))
s.settimeout(1.0)

seq_prev = None
t_prev = None
npkt = 0
gaps = []
t0 = time.time()
while time.time() - t0 < SECS:
    try:
        pkt, _ = s.recvfrom(4096)
    except socket.timeout:
        continue
    now = time.perf_counter()
    if len(pkt) < 4:
        continue
    seq = struct.unpack(">I", pkt[:4])[0]
    if seq_prev is not None:
        d = (seq - seq_prev) & 0xFFFFFFFF
        if d != 1 and d < 0x80000000:
            iat_us = (now - t_prev) * 1e6 if t_prev else -1
            gaps.append((npkt, d - 1, iat_us, time.time()))
    seq_prev = seq
    t_prev = now
    npkt += 1
s.close()

print(f"packets={npkt} gaps={len(gaps)}")
# inter-arrival at the gap: is there a pause?
if gaps:
    iats = [g[2] for g in gaps if g[2] >= 0]
    normal = sum(1 for x in iats if x < 100)     # <100us = no pause
    paused = sum(1 for x in iats if x >= 100)     # >=100us = FPGA paused
    print(f"gaps with normal inter-arrival (<100us, vanished mid-flight): {normal}")
    print(f"gaps with pause (>=100us, FPGA egress stall): {paused}")
    print("\nsample gaps (pkt#, lost_frames, inter-arrival_us, wallclock):")
    for g in gaps[:20]:
        print(f"  pkt={g[0]:>9} lost={g[1]:>4} iat={g[2]:8.1f}us  t={g[3]:.6f}")
