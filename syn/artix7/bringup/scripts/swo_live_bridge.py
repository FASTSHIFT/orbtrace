#!/usr/bin/env python3
"""swo_live_bridge — stream live FPGA SWO capture into orbuculum.

Bridges the current known-good one-shot capture FPGA (swo_stream.bit) into a
*continuous* byte stream for `orbuculum -s`. Runs a TCP server; when orbuculum
connects, loops:  re-arm capture -> wait full -> dump banks -> send bytes.

The re-arm loop has small gaps between captures, but the r19 loss-test proved
orbuculum's `-N` keep-sync rides through gaps via per-frame HSYNC (degradation
linear ~= gap fraction, no avalanche). So this delivers real live decode on the
unmodified FPGA, no self-TX TX path needed.

  Terminal A:  python3 scripts/swo_live_bridge.py --ip 192.168.10.42 --port 5555
  Terminal B:  orbuculum -s localhost:5555 -T -N -t 2
  Terminal C:  orbtop -s localhost:3402 -E -e proj_add.axf   (or orbmortem)

Set --bitlen to match the STM32 baud at the FPGA sample rate
(IDDR 400MSa/s, 2 Mbaud -> 200).
"""
import argparse
import socket
import struct
import sys
import time

CTRL = 5002
DATA = 5001
CHUNK = 1024


def csr(ip, addr, val, timeout=1.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    s.sendto(bytes([addr & 0xFF, val & 0xFF, 0, 0]), (ip, CTRL))
    try:
        s.recvfrom(2048)
    except socket.timeout:
        pass
    s.close()


def req(s, ip, base, n):
    s.sendto(struct.pack("<H", base) + bytes(n), (ip, DATA))
    d, _ = s.recvfrom(2048)
    return d[2:2 + n]


def read_status(s, ip):
    st = req(s, ip, 0xFF00, 6)
    depth = st[0] | (st[1] << 8) | (st[2] << 16) | (st[3] << 24)
    return depth, st[4] & 1, st[5]


def read_bank(s, ip, bank, nbytes):
    csr(ip, 0x05, bank)
    time.sleep(0.01)
    out = bytearray()
    base = 0
    while base < nbytes:
        n = min(CHUNK, nbytes - base)
        chunk = req(s, ip, base, n + 1)   # +1 / drop-first (BRAM read latency)
        out.extend(chunk[1:1 + n])
        base += n
    return bytes(out)


def grab_one(s, ip, skip, prev_gen, wait):
    """Re-arm, wait for a fresh full capture, return its bytes (minus lead-in)."""
    csr(ip, 0x05, 0)
    csr(ip, 0x02, 1)                 # re-arm
    t0 = time.time()
    depth = full = gen = 0
    while time.time() - t0 < wait:
        depth, full, gen = read_status(s, ip)
        if full and gen != prev_gen:
            break
        time.sleep(0.05)
    nbanks = (depth + 65535) // 65536
    out = bytearray()
    for b in range(nbanks):
        n = min(65536, depth - b * 65536)
        out.extend(read_bank(s, ip, b, n))
    csr(ip, 0x05, 0)
    return bytes(out[skip:]), gen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--port", type=int, default=5555, help="TCP server port for orbuculum -s")
    ap.add_argument("--bitlen", type=int, default=200,
                    help="SWO bitlen in sample-ticks (IDDR 400MSa/s, 2Mbaud=200)")
    ap.add_argument("--skip", type=int, default=7680, help="drop capture lead-in transient")
    ap.add_argument("--wait", type=float, default=4.0, help="max s to wait for a fresh full capture")
    a = ap.parse_args()

    if a.bitlen:
        csr(a.ip, 0x03, a.bitlen & 0xFF)
        csr(a.ip, 0x04, (a.bitlen >> 8) & 0xFF)
        print(f"set bitlen={a.bitlen}", flush=True)

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.port))
    srv.listen(1)
    print(f"live bridge listening :{a.port}, FPGA {a.ip}; waiting for orbuculum...", flush=True)

    rs = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rs.settimeout(2.0)

    while True:
        c, addr = srv.accept()
        print(f"orbuculum connected {addr}; streaming live captures", flush=True)
        prev_gen = -1
        total = 0
        ncap = 0
        t0 = time.time()
        try:
            while True:
                data, prev_gen = grab_one(rs, a.ip, a.skip, prev_gen, a.wait)
                if data:
                    c.sendall(data)
                    total += len(data)
                    ncap += 1
                    if ncap % 5 == 0:
                        dt = time.time() - t0
                        sync = data.count(b"\xff\xff\xff\x7f")
                        print(f"  cap#{ncap} gen={prev_gen} {len(data)}B "
                              f"sync={sync} total={total/1024:.0f}KB "
                              f"{total/dt/1024:.1f}KB/s", flush=True)
        except (BrokenPipeError, ConnectionResetError):
            print("orbuculum disconnected; waiting for reconnect", flush=True)
            c.close()


if __name__ == "__main__":
    sys.exit(main())
