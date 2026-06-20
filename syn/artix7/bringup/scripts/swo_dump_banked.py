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


def read_timebase(s, ip):
    """Read the FPGA capture-time base (proposal 18 §9.3). Metadata is in the
    bank-0 status region at 0xFF06..; the per-stride 32-bit snapshot table is in
    a dedicated readout bank (0xFE). Returns a dict compatible with
    decode/fpga_timebase.TimeBase.load (stride/n/tick_ns/last_tick/ticks)."""
    csr(ip, 0x05, 0)                  # bank 0 for status/metadata
    time.sleep(0.02)
    md = req(s, ip, 0xFF06, 9)        # stride_log2, n_lo, n_hi, tick_ns, last(4)
    stride_log2 = md[0]
    n = md[1] | (md[2] << 8)
    tick_ns = md[3]
    last_tick = md[4] | (md[5] << 8) | (md[6] << 16) | (md[7] << 24)
    present = req(s, ip, 0xFF0E, 1)[0] & 1
    if not present or n == 0:
        return None
    tbl = read_bank(s, ip, 0xFE, 4 * n)
    ticks = [tbl[4 * k] | (tbl[4 * k + 1] << 8) | (tbl[4 * k + 2] << 16)
             | (tbl[4 * k + 3] << 24) for k in range(n)]
    csr(ip, 0x05, 0)                  # restore bank 0
    return {
        "stride": 1 << stride_log2,
        "n": n,
        "tick_ns": float(tick_ns),
        "last_tick": last_tick,
        "ticks": ticks,
        "skip": 0,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("-o", "--out", default="/tmp/swo_big.bin")
    ap.add_argument("--rearm", action="store_true")
    ap.add_argument("--settle", type=float, default=1.0)
    ap.add_argument("--timebase", action="store_true",
                    help="also read the FPGA capture-time base into <out>.ts.json")
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

    if a.timebase:
        import json
        tb = read_timebase(s, a.ip)
        if tb is None:
            print("  timebase: not present in this bitstream")
        else:
            tb["depth"] = depth
            side = a.out + ".ts.json"
            with open(side, "w") as f:
                json.dump(tb, f)
            span_us = tb["last_tick"] * tb["tick_ns"] / 1e3
            nonmono = sum(1 for k in range(1, len(tb["ticks"]))
                          if tb["ticks"][k] < tb["ticks"][k - 1])
            print(f"  timebase: {tb['n']} snapshots @ every {tb['stride']} B, "
                  f"tick {tb['tick_ns']}ns, span {span_us:.1f} us -> {side}"
                  + (f"  ({nonmono} wrap pts)" if nonmono else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
