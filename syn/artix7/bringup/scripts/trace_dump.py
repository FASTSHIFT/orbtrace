#!/usr/bin/env python3
"""Stage-4 V3: dump the FPGA's captured raw trace byte stream to a file.

trace_stream_top captures a contiguous block (DEPTH bytes) of the raw TPIU
byte stream off the STM32 ETM into BRAM, one-shot, then serves it on UDP
:5001 with a paged readout:
  request payload: byte0/1 = 16-bit base offset (LE), rest = don't-care pad
  reply:           byte0/1 = echo of base (discard), byte2.. = source[base..]

We page through DEPTH bytes in CHUNK-sized requests and write the assembled
stream to a file for offline decode:
  orbmortem -f trace.bin -e proj.axf -P ETM3.5

Usage: python3 trace_dump.py [--ip 192.168.10.42] [--depth 16384] [-o trace.bin]
"""
import argparse
import socket
import struct
import sys

CHUNK = 1024  # data bytes per request (reply = CHUNK+2)


def req(sock, ip, port, base, n, timeout):
    # payload: 2-byte LE base + n+2 pad (reply length mirrors request length)
    payload = struct.pack("<H", base) + bytes(n)
    sock.sendto(payload, (ip, port))
    data, _ = sock.recvfrom(2048)
    # reply[2:] = source[base : base+n]
    return data[2:2 + n]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--port", type=int, default=5001)
    ap.add_argument("--depth", type=int, default=16384)
    ap.add_argument("-o", "--out", default="trace.bin")
    ap.add_argument("--timeout", type=float, default=2.0)
    a = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(a.timeout)

    # read status (DEPTH, full) at addr depth..depth+2
    try:
        st = req(s, a.ip, a.port, a.depth, 4, a.timeout)
        dev_depth = st[0] | (st[1] << 8)
        full = st[2] & 1
        print(f"  device DEPTH={dev_depth}  full={full}")
    except (socket.timeout, OSError) as e:
        print(f"ERROR reading status: {e}")
        return 2
    if not full:
        print("  WARNING: capture buffer not full yet (still filling or no sync).")

    out = bytearray()
    base = 0
    while base < a.depth:
        n = min(CHUNK, a.depth - base)
        try:
            # Readout off-by-one fix (deterministic, doc 14 §31): the CAP_RAW
            # BRAM read has 1 cycle latency, so the FIRST data byte of every
            # reply repeats source[base] (stale read). Request n+1 bytes and
            # drop the leading duplicate -> contiguous, correct stream.
            # (Verified 0.000% unknown on real trace; an RTL-side fix did not
            # reliably remove it due to a first-beat AXI stall.)
            chunk = req(s, a.ip, a.port, base, n + 1, a.timeout)
            chunk = chunk[1:1 + n]
        except (socket.timeout, OSError) as e:
            print(f"ERROR at base {base}: {e}")
            return 2
        if len(chunk) < n:
            print(f"  short chunk @{base}: {len(chunk)}<{n}")
        out.extend(chunk[:n])
        base += n

    with open(a.out, "wb") as f:
        f.write(out)
    print(f"  wrote {len(out)} bytes -> {a.out}")
    # quick content sanity: TPIU sync 0xFFFFFF7F frequency
    sync = out.count(b"\xff\xff\xff\x7f")
    print(f"  TPIU full-sync (ff ff ff 7f) occurrences: {sync}")
    nonzero = sum(1 for b in out if b != 0)
    print(f"  non-zero bytes: {nonzero}/{len(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
