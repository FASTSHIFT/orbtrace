#!/usr/bin/env python3
"""Stage-4 V1 (orbtrace-aligned): read and render the eye-scan results.

The eyescan_top bitstream loops a real TPIU frame (FF FF FF 7F sync + 16
known payload bytes) through the DDR capture path into the UPSTREAM
traceIF.v, which locks the sync word and decodes 128-bit frames. For each
IDELAY tap 0..31 it counts GOOD frames (== golden) and BAD frames (sync but
wrong value) over a window. A tap is "in the eye" when it yields good frames
and zero bad frames.

Table on UDP :5001 (request 132 bytes):
    tap*4 + 0/1 = good count (LSB,MSB)
    tap*4 + 2/3 = bad  count (LSB,MSB)
    128 = best_tap, 129 = {eye_found[7], scan_done[6], ...}

Usage: python3 eyescan_read.py [--ip 192.168.10.42] [--port 5001]
"""
import argparse
import socket
import sys

N_TAPS = 32
TBL = 148


def fetch(ip, port, timeout):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    s.sendto(bytes(TBL), (ip, port))
    data, _ = s.recvfrom(2048)
    if len(data) < TBL:
        raise RuntimeError(f"short table: {len(data)} < {TBL}")
    return data[:TBL]


def render(t: bytes):
    if all(b == 0xFF for b in t):
        print("\n  RESULT: all-0xFF -> scan never completed.")
        print("  The FSM runs on the recovered loopback clock; if it never")
        print("  ran, trace_clk is dead. Check the clock jumper")
        print("  (txclk_out C13 -> trace_clk_in D17) and LED0 (IDELAYCTRL).")
        return 2

    good = [(t[tap*4+1] << 8) | t[tap*4+0] for tap in range(N_TAPS)]
    bad = [(t[tap*4+3] << 8) | t[tap*4+2] for tap in range(N_TAPS)]
    best = t[128] & 0x1F
    eye_found = (t[129] >> 7) & 1

    print("\n     tap | good  bad | status")
    print("    -----+-----------+----------------------")
    eye = []
    for tap in range(N_TAPS):
        g, b = good[tap], bad[tap]
        if g > 0 and b == 0:
            status = "OPEN  (frames decode clean)"
            eye.append(tap)
        elif g > 0 and b > 0:
            status = "marginal (some bad frames)"
        elif b > 0:
            status = "sync but all frames bad"
        else:
            status = "no sync / no frame"
        print(f"     {tap:3d} | {g:4d} {b:4d} | {status}")

    print(f"\n  FPGA best_tap = {best}   eye_found = {eye_found}")
    actual = t[132:148]
    if len(actual) == 16:
        print(f"  actual decoded frame = {actual.hex()}")
    if not eye:
        print("\n  RESULT: NO tap produced clean frames.")
        print("  traceIF never decoded the golden frame at any tap -> the")
        print("  loopback data never aligned. Check jumpers / lower the rate.")
        return 1
    # widest contiguous open run
    runs, s, p = [], eye[0], eye[0]
    for x in eye[1:]:
        if x == p + 1:
            p = x
        else:
            runs.append((s, p)); s = p = x
    runs.append((s, p))
    br = max(runs, key=lambda r: r[1] - r[0])
    centre = (br[0] + br[1]) // 2
    print(f"\n  RESULT: eye OPEN at taps {eye}")
    print(f"  widest run = taps {br[0]}..{br[1]} (width {br[1]-br[0]+1}); "
          f"centre = tap {centre}")
    print(f"  -> recommended IDELAY tap = {centre}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--port", type=int, default=5001)
    ap.add_argument("--timeout", type=float, default=2.0)
    a = ap.parse_args()
    try:
        t = fetch(a.ip, a.port, a.timeout)
    except (socket.timeout, OSError, RuntimeError) as e:
        print(f"ERROR fetching table: {e}")
        return 2
    return render(t)


if __name__ == "__main__":
    sys.exit(main())
