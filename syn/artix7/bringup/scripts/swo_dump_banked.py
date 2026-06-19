#!/usr/bin/env python3
"""swo_dump_banked — read the SWO capture buffer that is larger than 64 KB, by
paging through 64 KB banks (CSR 0x05 selects the bank). Status (DEPTH/full/gen)
lives in bank 0 at fixed offset 0xFF00.

The bigger buffer gives a longer capture time window so a (time-periodic) TPIU
sync always lands even at high baud.

Usage: swo_dump_banked.py [--ip ..] [-o out.bin] [--rearm] [--bitlen N] [--acpr H]
"""
import argparse
import socket
import struct
import sys
import time

CHUNK = 1024
CTRL = 5002
DATA = 5001


def csr(ip, addr, val):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.0)
    s.sendto(bytes([addr & 0xFF, val & 0xFF, 0, 0]), (ip, CTRL))
    try:
        s.recvfrom(2048)
    except socket.timeout:
        pass
    s.close()


def req(s, ip, base, n, timeout=2.0):
    s.sendto(struct.pack("<H", base) + bytes(n), (ip, DATA))
    d, _ = s.recvfrom(2048)
    return d[2:2 + n]


def read_status(s, ip):
    st = req(s, ip, 0xFF00, 6)
    depth = st[0] | (st[1] << 8) | (st[2] << 16) | (st[3] << 24)
    full = st[4] & 1
    gen = st[5]
    return depth, full, gen


def read_bank(s, ip, bank, nbytes):
    csr(ip, 0x05, bank)
    time.sleep(0.02)
    out = bytearray()
    base = 0
    while base < nbytes:
        n = min(CHUNK, nbytes - base)
        chunk = req(s, ip, base, n + 1)   # +1 / drop-first (BRAM read latency)
        out.extend(chunk[1:1 + n])
        base += n
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("-o", "--out", default="/tmp/swo_big.bin")
    ap.add_argument("--rearm", action="store_true")
    ap.add_argument("--settle", type=float, default=1.0)
    a = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2.0)

    if a.rearm:
        csr(a.ip, 0x05, 0)            # bank 0 to read status
        csr(a.ip, 0x02, 1)            # re-arm
        time.sleep(a.settle)

    depth, full, gen = read_status(s, a.ip)
    print(f"  DEPTH={depth} full={full} gen={gen}")
    if not full:
        print("  WARNING: buffer not full yet")

    nbanks = (depth + 65535) // 65536
    out = bytearray()
    for b in range(nbanks):
        n = min(65536, depth - b * 65536)
        out.extend(read_bank(s, a.ip, b, n))
    csr(a.ip, 0x05, 0)                # restore bank 0
    with open(a.out, "wb") as f:
        f.write(out)
    sync = out.count(b"\xff\xff\xff\x7f")
    nz = sum(1 for x in out if x)
    print(f"  wrote {len(out)} bytes -> {a.out}  full-sync={sync} nonzero={nz}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
