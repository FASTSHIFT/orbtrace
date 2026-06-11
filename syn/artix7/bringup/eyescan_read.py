#!/usr/bin/env python3
"""Stage-4 V1: read and render the FPGA eye-scan results table.

The eyescan_top bitstream sweeps the IDELAY tap 0..31 on the self-looped
trace capture path and records, per tap and per lane, a 16-bit saturating
error count over a measurement window. It exposes the 256-byte table on
UDP port 5001:

    addr = tap*8 + lane*2 + {hi,lo}   (16-bit big-endian error count)

We fetch it (send any 256-byte frame, get the table back), then print an
eye diagram: '#' = errors (eye closed), '.' = zero errors (eye open).
Taps with zero errors on all 4 lanes are inside the common data eye; the
centre of the widest such run is the best tap.

Usage:
    python3 eyescan_read.py [--ip 192.168.10.42] [--port 5001]
"""
import argparse
import socket
import sys

N_TAPS = 32
N_LANES = 4


def fetch_table(ip: str, port: int, timeout: float) -> bytes:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    s.sendto(bytes(256), (ip, port))  # length 256 -> reply length 256
    data, _ = s.recvfrom(2048)
    if len(data) < 256:
        raise RuntimeError(f"short table: got {len(data)} bytes, need 256")
    return data[:256]


def parse(table: bytes):
    # err[tap][lane]
    err = [[0] * N_LANES for _ in range(N_TAPS)]
    for tap in range(N_TAPS):
        for lane in range(N_LANES):
            base = tap * 8 + lane * 2
            err[tap][lane] = (table[base] << 8) | table[base + 1]
    return err


def render(err, table: bytes):
    # all-0xFF table means the scan never completed (e.g. no loopback clock)
    if all(b == 0xFF for b in table):
        print("\n  RESULT: table is all-0xFF -> scan never completed.")
        print("  The eye-scan FSM is clocked by the RECOVERED loopback clock;")
        print("  if it never ran, trace_clk is dead. Check that the jumpers")
        print("  txclk_out->trace_clk_in and txd_out[i]->trace_data_in[i] are")
        print("  actually connected, and that LED0 (IDELAYCTRL ready) is on.")
        return 2

    print("\n     tap | L0 L1 L2 L3 | eye (.=clean  #=errors)")
    print("    -----+-------------+-------------------------")
    clean_taps = []
    for tap in range(N_TAPS):
        cells = err[tap]
        allclean = all(c == 0 for c in cells)
        if allclean:
            clean_taps.append(tap)
        marks = " ".join(f"{min(c,99):2d}" for c in cells)
        eye = "".join("." if c == 0 else "#" for c in cells)
        flag = "  <- clean" if allclean else ""
        print(f"     {tap:3d} | {marks} | {eye}{flag}")

    print()
    if not clean_taps:
        print("  RESULT: NO clean tap on all 4 lanes.")
        print("  -> signal-integrity problem: check jumpers, common ground,")
        print("     wire length/skew, or lower the pattern rate.")
        return 1

    # widest contiguous run of clean taps -> centre is best
    runs = []
    start = clean_taps[0]
    prev = clean_taps[0]
    for t in clean_taps[1:]:
        if t == prev + 1:
            prev = t
        else:
            runs.append((start, prev))
            start = prev = t
    runs.append((start, prev))
    best_run = max(runs, key=lambda r: r[1] - r[0])
    centre = (best_run[0] + best_run[1]) // 2
    width = best_run[1] - best_run[0] + 1
    print(f"  RESULT: clean taps = {clean_taps}")
    print(f"  widest open run = taps {best_run[0]}..{best_run[1]} "
          f"(width {width}); eye centre = tap {centre}")
    print(f"  -> use IDELAY tap {centre}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--port", type=int, default=5001)
    ap.add_argument("--timeout", type=float, default=2.0)
    args = ap.parse_args()
    try:
        table = fetch_table(args.ip, args.port, args.timeout)
    except (socket.timeout, OSError, RuntimeError) as e:
        print(f"ERROR fetching table: {e}")
        return 2
    err = parse(table)
    return render(err, table)


if __name__ == "__main__":
    sys.exit(main())
