#!/usr/bin/env python3
"""Stage-4 V3 step 1: read the real decoded trace frames the FPGA captured.

trace_stream_top fixes the IDELAY tap (V2 eye centre) and rings the most
recent NFRM 128-bit frames decoded by traceIF from the live STM32 ETM trace.
This tool fetches them over UDP :5001 and prints them, plus the running
frame counter (so you can confirm frames are actually flowing and changing).

Layout (request NB+8 bytes; NB = NFRM*16):
    0 .. NB-1   = NFRM frames, 16 bytes each, MSB-first, slot order
    NB+0..NB+3  = frame_count (LE 32-bit)
    NB+4        = write pointer (current slot)

Usage: python3 trace_stream_read.py [--ip 192.168.10.42] [--nfrm 8] [--watch]
"""
import argparse
import socket
import sys
import time


def fetch(ip, port, n, timeout):
    nb = n * 16
    req = nb + 8
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    s.sendto(bytes(req), (ip, port))
    data, _ = s.recvfrom(2048)
    if len(data) < req:
        raise RuntimeError(f"short reply {len(data)} < {req}")
    return data[:req]


def show(data, n):
    nb = n * 16
    fc = int.from_bytes(data[nb:nb+4], "little")
    wr = data[nb+4]
    print(f"  frame_count = {fc}   write_slot = {wr}")
    for i in range(n):
        fr = data[i*16:(i+1)*16]
        mark = " <- newest" if i == (wr - 1) % n else ""
        print(f"    slot {i}: {fr.hex()}{mark}")
    return fc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--port", type=int, default=5001)
    ap.add_argument("--nfrm", type=int, default=8)
    ap.add_argument("--timeout", type=float, default=2.0)
    ap.add_argument("--watch", action="store_true", help="poll and show frame rate")
    a = ap.parse_args()

    if not a.watch:
        try:
            data = fetch(a.ip, a.port, a.nfrm, a.timeout)
        except (socket.timeout, OSError, RuntimeError) as e:
            print(f"ERROR: {e}")
            return 2
        show(data, a.nfrm)
        return 0

    # watch mode: sample frame_count over time to report a frame rate
    prev_fc, prev_t = None, None
    try:
        while True:
            data = fetch(a.ip, a.port, a.nfrm, a.timeout)
            fc = show(data, a.nfrm)
            now = time.time()
            if prev_fc is not None and now > prev_t:
                rate = (fc - prev_fc) / (now - prev_t)
                print(f"  ~{rate:.0f} frames/s")
            prev_fc, prev_t = fc, now
            print("-" * 40)
            time.sleep(1.0)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
