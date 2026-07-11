#!/usr/bin/env python3
"""la_readout — arm the DDR3 black-box readback (proposal 32 P2b-2) and receive
the ring snapshot over the self-TX UDP stream (:5555).

Sequence:
  1. bind :5555 (host)
  2. send a :5002 CSR write REG_ARM(0x20) to the FPGA -> la_ddr_reader streams
     READ_WORDS*16 bytes (default 4MB) from the DDR3 ring start via self-TX.
  3. receive until idle; write the raw byte stream to a file.

The reader output has NO per-packet sequence prefix (it is a one-shot finite
snapshot), so every UDP payload byte is ring data, concatenated in order.

Usage: la_readout.py [ip] [-o out.bin] [--seconds N]
"""
import argparse
import socket
import sys
import time

CTRL_PORT = 5002
STREAM_PORT = 5555
REG_ARM = 0x20


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ip", nargs="?", default="192.168.10.42")
    ap.add_argument("-o", "--out", default="/tmp/blackbox.bin")
    ap.add_argument("--seconds", type=float, default=3.0,
                    help="idle timeout to stop receiving")
    a = ap.parse_args()

    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 << 20)
    rx.bind(("0.0.0.0", STREAM_PORT))
    rx.settimeout(a.seconds)

    # arm the readback
    ctrl = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ctrl.sendto(bytes([REG_ARM, 1, 0, 0]), (a.ip, CTRL_PORT))
    ctrl.close()
    print(f"armed DDR3 readback (REG_ARM) on {a.ip}:{CTRL_PORT}")

    out = open(a.out, "wb")
    total = 0
    pkts = 0
    t0 = time.time()
    try:
        while True:
            try:
                d, _ = rx.recvfrom(65535)
            except socket.timeout:
                break
            out.write(d)
            total += len(d)
            pkts += 1
    finally:
        out.close()
    dt = time.time() - t0
    print(f"received {pkts} packets, {total} bytes ({total/1024:.1f} KiB) "
          f"in {dt:.2f}s -> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
