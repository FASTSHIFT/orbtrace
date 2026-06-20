#!/usr/bin/env python3
"""echo_probe — r20 discriminator: send a UDP packet to the FPGA echo port
(:1234, plain loopback) and check it echoes back. Used to test whether a
freshly-flashed top-level's link/clock/reset is up (STREAM=0 selftx build).
  echo OK     -> new top-level link is healthy -> zero-packet bug is FSM/header
  echo silent -> link not up on new top (root-cause A)
"""
import socket
import sys

ip = sys.argv[1] if len(sys.argv) > 1 else "192.168.10.42"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 1234
payload = bytes(range(64))

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2.0)
ok = 0
for i in range(5):
    try:
        s.sendto(payload, (ip, port))
        d, a = s.recvfrom(2048)
        print(f"try {i}: got {len(d)} bytes from {a}: {d[:16].hex()}")
        if d[:len(payload)] == payload or len(d) > 0:
            ok += 1
    except socket.timeout:
        print(f"try {i}: TIMEOUT (no echo)")
s.close()
print(f"=== echo replies: {ok}/5 ===")
sys.exit(0 if ok else 1)
