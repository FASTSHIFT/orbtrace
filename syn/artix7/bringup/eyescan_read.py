#!/usr/bin/env python3
"""Stage-4 V1: read and render the FPGA eye-scan results table.

The eyescan_top bitstream sweeps the IDELAY tap 0..31 on the self-looped
trace capture path and records, per tap and per lane, an 8-bit saturating
error count over a measurement window. It exposes a 132-byte table on UDP
port 5001:

    addr = tap*4 + lane           (0..127)  -> error count (0..255, sat)
    128 = live raw rx_byte (last sample)
    129 = per-bit "ever toggled" activity mask (bit n = trace bit n changed)
    130 = best_tap
    131 = {eye_found[7], scan_done[6], ...}

We fetch it, print the eye ('#' = errors, '.' = zero errors), and the
diagnostics (activity mask is gold for "which lane is dead vs mis-sampled").

Usage:
    python3 eyescan_read.py [--ip 192.168.10.42] [--port 5001]
"""
import argparse
import socket
import sys

N_TAPS = 32
N_LANES = 4
TBL = 228


def fetch_table(ip: str, port: int, timeout: float) -> bytes:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    s.sendto(bytes(TBL), (ip, port))  # reply length mirrors request
    data, _ = s.recvfrom(2048)
    if len(data) < TBL:
        raise RuntimeError(f"short table: got {len(data)} bytes, need {TBL}")
    return data[:TBL]


def render(table: bytes):
    if all(b == 0xFF for b in table):
        print("\n  RESULT: table is all-0xFF -> scan never completed.")
        print("  The eye-scan FSM is clocked by the RECOVERED loopback clock;")
        print("  if it never ran, trace_clk is dead. Check the clock jumper")
        print("  (txclk_out C13 -> trace_clk_in D17) and LED0 (IDELAYCTRL).")
        return 2

    err = [[table[tap * 4 + lane] for lane in range(N_LANES)] for tap in range(N_TAPS)]
    raw = table[128]
    act = table[129]
    best = table[130]
    flags = table[131]

    print("\n     tap | L0 L1 L2 L3 | eye (.<=thr  o=few  #=many) | snap d2->d1")
    print("    -----+-------------+------------------------------+------------")
    THR = 4  # tolerate a few marginal glitches over the ~1M-cycle window
    clean = []          # all lanes exactly 0
    usable = []         # all lanes <= THR
    best_tap_pc = None
    best_sum = 1 << 30
    for tap in range(N_TAPS):
        c = err[tap]
        s = sum(c)
        if s < best_sum:
            best_sum = s; best_tap_pc = tap
        if all(x == 0 for x in c):
            clean.append(tap)
        if all(x <= THR for x in c):
            usable.append(tap)
        def mk(x):
            return "." if x == 0 else ("o" if x <= THR else "#")
        eye = "".join(mk(x) for x in c)
        marks = " ".join(f"{x:3d}" for x in c)
        d2 = table[164 + tap]; d1 = table[196 + tap]; step = (d1 - d2) & 0xFF
        tags = "  <-CLEAN" if all(x==0 for x in c) else ("  <-usable" if all(x<=THR for x in c) else "")
        print(f"     {tap:3d} | {marks} | {eye}{tags:>10s} | {d2:02x}->{d1:02x} (+{step})")

    print("\n  ---- diagnostics ----")
    print(f"  last raw rx_byte = 0x{raw:02x}  ({raw:08b})")
    print(f"  activity mask    = 0x{act:02x}  ({act:08b})  "
          f"(bit n=1 => trace bit n toggled at least once)")
    # decode activity per lane: lane i owns bits i (rising) and 4+i (falling)
    for lane in range(N_LANES):
        rb = (act >> lane) & 1
        fb = (act >> (4 + lane)) & 1
        tag = "OK" if (rb and fb) else ("DEAD" if not (rb or fb) else "HALF")
        print(f"    lane{lane}: rising bit{lane}={rb} falling bit{4+lane}={fb} -> {tag}")
    print(f"  best_tap = {best}   eye_found = {(flags>>7)&1}   scan_done = {(flags>>6)&1}")

    # raw consecutive samples captured at best_tap
    raw_samples = list(table[132:164])
    print("\n  ---- 32 consecutive raw rx_byte samples @best_tap ----")
    print("  " + " ".join(f"{b:02x}" for b in raw_samples))
    # show the +1 expectation: each should be prev+1 if the link is clean
    diffs = [((raw_samples[i+1] - raw_samples[i]) & 0xFF) for i in range(len(raw_samples)-1)]
    n_plus1 = sum(1 for d in diffs if d == 1)
    print(f"  consecutive +1 steps: {n_plus1}/{len(diffs)} "
          f"(if low, the byte isn't a clean ramp -> sampling/skew issue)")

    print()
    eye_set = clean if clean else usable
    if not eye_set:
        print(f"  RESULT: no tap with all lanes <= {THR} errors.")
        print(f"  min-error tap = {best_tap_pc} (sum={best_sum}). Lanes have")
        print("  per-lane skew/SI; see snap column for which taps ramp cleanly.")
        return 1
    # widest run over the chosen set
    runs, start, prev = [], eye_set[0], eye_set[0]
    for t in eye_set[1:]:
        if t == prev + 1:
            prev = t
        else:
            runs.append((start, prev)); start = prev = t
    runs.append((start, prev))
    br = max(runs, key=lambda r: r[1] - r[0])
    centre = (br[0] + br[1]) // 2
    kind = "CLEAN (0 err)" if clean else f"usable (<={THR} err)"
    print(f"  RESULT: {kind} taps = {eye_set}")
    print(f"  widest open run = taps {br[0]}..{br[1]} (width {br[1]-br[0]+1}); "
          f"eye centre = tap {centre}  (FPGA best_tap={best}, PC min-err tap={best_tap_pc})")
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
    return render(table)


if __name__ == "__main__":
    sys.exit(main())
