#!/usr/bin/env python3
"""Read trace_mmcm_top status: DEPTH, MMCM locked, rfull, gen (0xFF00 region)."""
import socket, struct, sys, time

ip = sys.argv[1] if len(sys.argv) > 1 else "192.168.10.42"
DATA, CTRL = 5001, 5002

def req(s, base, n):
    s.sendto(struct.pack("<H", base) + bytes(n), (ip, DATA))
    d, _ = s.recvfrom(2048)
    return d[2:2+n]

def csr(addr, val):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.0)
    s.sendto(bytes([addr & 0xFF, val & 0xFF, 0, 0]), (ip, CTRL))
    try: s.recvfrom(2048)
    except socket.timeout: pass
    s.close()

if len(sys.argv) > 2 and sys.argv[2] == "rearm":
    csr(0x02, 1)
    time.sleep(1.0)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2.0)
st = req(s, 0xFF00, 6)
depth = st[0] | (st[1]<<8) | (st[2]<<16) | (st[3]<<24)
rfull = st[4] & 1
locked = (st[4] >> 1) & 1
gen = st[5]
print(f"DEPTH={depth} locked={locked} rfull={rfull} gen={gen}")
