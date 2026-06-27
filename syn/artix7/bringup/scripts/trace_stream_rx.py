#!/usr/bin/env python3
"""trace_stream_rx — receive the continuous MMCM trace UDP stream (trace_mmcm_
stream_top) on :5555, strip the 4-byte big-endian per-packet sequence number,
detect gaps (dropped packets), and write the concatenated trace bytes to a file.

Each UDP packet = [seq:4 BE][PAYLOAD trace bytes]. A monotonic seq lets us flag
any lost packet (network/host drop) and, with the FPGA's lost_cnt CSR, separate
capture-side drops from transport drops.

Usage:
  trace_stream_rx.py [-o out.bin] [--port 5555] [--seconds N] [--max-bytes N]
"""
import argparse
import socket
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default="/tmp/trace_stream.bin")
    ap.add_argument("--port", type=int, default=5555)
    ap.add_argument("--seconds", type=float, default=5.0,
                    help="stop after this many seconds of no-progress idle too")
    ap.add_argument("--max-bytes", type=int, default=0,
                    help="stop after this many trace bytes (0 = until idle)")
    a = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 << 20)
    s.bind(("0.0.0.0", a.port))
    s.settimeout(a.seconds)

    out = open(a.out, "wb")
    expect = None
    pkts = 0
    lost_pkts = 0
    trace_bytes = 0
    first = True
    t0 = time.time()
    try:
        while True:
            try:
                d, _ = s.recvfrom(65535)
            except socket.timeout:
                break
            if len(d) < 4:
                continue
            seq = int.from_bytes(d[:4], "big")
            payload = d[4:]
            if expect is not None and seq != expect:
                gap = (seq - expect) & 0xFFFFFFFF
                lost_pkts += gap
                # mark the gap with a sentinel so decode can resync per-packet
                # (we simply note it; bytes are concatenated contiguously)
            expect = (seq + 1) & 0xFFFFFFFF
            out.write(payload)
            pkts += 1
            trace_bytes += len(payload)
            if first:
                first = False
                print(f"  first packet seq={seq} payload={len(payload)}B")
            if a.max_bytes and trace_bytes >= a.max_bytes:
                break
    finally:
        out.close()
    dt = time.time() - t0
    rate = trace_bytes / dt / 1e6 if dt > 0 else 0
    print(f"  packets={pkts} lost_pkts={lost_pkts} trace_bytes={trace_bytes} "
          f"({trace_bytes/1024:.1f} KiB) in {dt:.2f}s = {rate:.2f} MB/s")
    print(f"  wrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
