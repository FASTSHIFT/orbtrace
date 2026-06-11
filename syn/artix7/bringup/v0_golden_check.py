#!/usr/bin/env python3
"""Stage-4 V0: FPGA-originated golden-frame egress check.

The FPGA (net_test bitstream) replies on UDP port 5000 with an internal
GOLDEN frame instead of echoing: a 4-byte TPIU full-sync prefix
(FF FF FF 7F) followed by a monotonic ramp C0,C1,...  The reply LENGTH
mirrors the request length (the echo header machinery is reused), so we
send exactly GOLDEN_LEN bytes and expect GOLDEN_LEN golden bytes back.

This proves FPGA-sourced bytes cross the RGMII -> MAC -> IP -> UDP egress
byte-exact on real silicon: the foundation every later trace stage needs.

Usage:
    python3 v0_golden_check.py [--ip 192.168.10.42] [--len 32] [--iters 50]
"""
import argparse
import socket
import sys

GOLDEN_PORT = 5000


def golden_expected(n: int) -> bytes:
    out = bytearray()
    for i in range(n):
        if i < 3:
            out.append(0xFF)
        elif i == 3:
            out.append(0x7F)
        else:
            # mirrors RTL: 0xC0 + golden_idx[7:0]; ramp continues across the
            # whole frame and wraps at 256.
            out.append((0xC0 + i) & 0xFF)
    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--port", type=int, default=GOLDEN_PORT)
    ap.add_argument("--len", type=int, default=32, dest="length")
    ap.add_argument("--iters", type=int, default=50)
    ap.add_argument("--timeout", type=float, default=1.0)
    args = ap.parse_args()

    expected = golden_expected(args.length)
    # Request payload content is irrelevant (FPGA substitutes golden); only
    # its LENGTH matters, since the reply length mirrors the request.
    request = bytes(args.length)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(args.timeout)

    ok = 0
    lost = 0
    mism = 0
    for n in range(args.iters):
        try:
            sock.sendto(request, (args.ip, args.port))
            data, _ = sock.recvfrom(2048)
        except socket.timeout:
            lost += 1
            print(f"  iter {n}: TIMEOUT (no reply)")
            continue
        if data == expected:
            ok += 1
        else:
            mism += 1
            print(f"  iter {n}: MISMATCH")
            print(f"    got      {data.hex()}")
            print(f"    expected {expected.hex()}")
            # show first differing byte
            for i, (g, e) in enumerate(zip(data, expected)):
                if g != e:
                    print(f"    first diff @byte {i}: got {g:02x} exp {e:02x}")
                    break
            if len(data) != len(expected):
                print(f"    length: got {len(data)} exp {len(expected)}")

    print("\n==== V0 GOLDEN EGRESS RESULT ====")
    print(f"  iters={args.iters} len={args.length}  ok={ok} mismatch={mism} lost={lost}")
    print(f"  expected golden: {expected.hex()}")
    if ok == args.iters:
        print("  PASS: every reply byte-exact -> FPGA-sourced UDP egress is byte-clean")
        return 0
    print("  FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
