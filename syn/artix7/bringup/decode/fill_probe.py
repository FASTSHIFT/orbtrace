"""Probe how fast the one-shot capture buffer fills after a soft re-arm.
At a slow TRACECLK the fill should be observably gradual; at a fast one it is
near-instant. Lets us confirm DIV actually changes the trace rate."""
import socket
import struct
import time
import sys

IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.10.42"
DEPTH = 61440

rd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rd.settimeout(2.0)
ctrl = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
ctrl.settimeout(1.0)


def req(base, n):
    rd.sendto(struct.pack("<H", base) + bytes(n), (IP, 5001))
    d, _ = rd.recvfrom(2048)
    return d[2:2 + n]


def rearm():
    ctrl.sendto(bytes([0x02, 1, 0, 0]), (IP, 5002))
    try:
        ctrl.recvfrom(2048)
    except socket.timeout:
        pass


rearm()
t0 = time.time()
for i in range(40):
    st = req(DEPTH, 4)
    full = st[2] & 1
    dt = (time.time() - t0) * 1000
    print(f"t+{dt:6.1f}ms: full={full}")
    if full:
        break
    time.sleep(0.02)
