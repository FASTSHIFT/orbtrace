#!/usr/bin/env python3
"""iddr_tap_sweep — find the IDDR data-eye centre by sweeping the per-lane
IDELAY tap against a KNOWN CURTPM pattern (source-synchronous high-freq path).

This is the orbtrace-style deskew training, but scored with a predictable
byte stream instead of TPIU sync frames (so it works regardless of ETM sync
density -- red-team r23 Q3/Q5). With CURTPM AA/55 (0x00020004), every captured
RAW byte {falling_nibble, rising_nibble} must be 0xA5 or 0x5A (all 4 lanes
toggle together each TRACECLK edge). Any other byte = a mis-sampled bit at that
tap. The tap with the lowest error% sits in the eye centre.

For each tap 0..31:
  1. trace_ctrl set-tap <tap>   (loads the IDELAY, no reflash)
  2. trace_ctrl rearm           (fresh one-shot capture)
  3. trace_dump                 (read DEPTH raw bytes)
  4. score: fraction of bytes NOT in {0xA5, 0x5A}

Prints an error-vs-tap curve and the recommended eye-centre tap (widest
contiguous low-error span, pick its middle).

Usage:
  iddr_tap_sweep.py [--ip IP] [--depth N] [--pattern aa55|ff00]
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))

# expected raw-byte set per CURTPM pattern (4-bit port, all lanes toggle):
#   AA/55: rising nibble 0x5 or 0xA, falling the complement -> byte 0x5A/0xA5
#   FF/00: all-1 then all-0 -> byte 0xF0 or 0x0F
PATTERNS = {
    "aa55": {0xA5, 0x5A},
    "ff00": {0xF0, 0x0F},
}


def run(cmd, timeout=20):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def score(path, good_set):
    d = open(path, "rb").read()
    if not d:
        return 1.0, 0
    bad = sum(1 for b in d if b not in good_set)
    return bad / len(d), len(d)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--depth", type=int, default=61440)
    ap.add_argument("--pattern", choices=PATTERNS.keys(), default="aa55")
    ap.add_argument("--taps", default="0-31",
                    help="tap range 'a-b' or comma list")
    ap.add_argument("--settle", type=float, default=0.3,
                    help="seconds to wait after re-arm before dump")
    ap.add_argument("--outdir", default="/tmp/iddr_tap_sweep")
    a = ap.parse_args()

    good = PATTERNS[a.pattern]
    os.makedirs(a.outdir, exist_ok=True)
    if "-" in a.taps:
        lo, hi = a.taps.split("-")
        taps = list(range(int(lo), int(hi) + 1))
    else:
        taps = [int(x) for x in a.taps.split(",")]

    print(f"=== IDDR IDELAY tap sweep (pattern={a.pattern}, good={{{','.join(f'0x{v:02x}' for v in good)}}}) ===")
    rows = []
    for tap in taps:
        run([sys.executable, f"{HERE}/trace_ctrl.py", "--ip", a.ip,
             "set-tap", str(tap)])
        run([sys.executable, f"{HERE}/trace_ctrl.py", "--ip", a.ip, "rearm"])
        time.sleep(a.settle)
        cap = f"{a.outdir}/tap{tap:02d}.bin"
        r = run([sys.executable, f"{HERE}/trace_dump.py", "--ip", a.ip,
                 "--depth", str(a.depth), "-o", cap])
        if not os.path.exists(cap):
            print(f"  tap {tap:2d}: dump failed\n{r.stdout}\n{r.stderr}")
            rows.append((tap, 1.0, 0))
            continue
        err, n = score(cap, good)
        bar = "#" * int((1 - err) * 40)
        print(f"  tap {tap:2d}: err={err*100:6.2f}%  n={n:6d}  {bar}")
        rows.append((tap, err, n))

    # find widest contiguous span with err < threshold; report its centre
    THRESH = 0.01   # 1% -- eye "open"
    best_span = (0, -1)
    i = 0
    while i < len(rows):
        if rows[i][1] < THRESH:
            j = i
            while j + 1 < len(rows) and rows[j + 1][1] < THRESH:
                j += 1
            if (j - i) > (best_span[1] - best_span[0]):
                best_span = (i, j)
            i = j + 1
        else:
            i += 1

    print("\n=== SUMMARY ===")
    if best_span[1] >= best_span[0] and rows[best_span[0]][1] < THRESH:
        lo_tap = rows[best_span[0]][0]
        hi_tap = rows[best_span[1]][0]
        centre = (lo_tap + hi_tap) // 2
        width = hi_tap - lo_tap + 1
        print(f"eye open over taps {lo_tap}..{hi_tap} (width {width}); "
              f"recommended centre tap = {centre}")
        best = min(rows, key=lambda r: r[1])
        print(f"lowest-error tap = {best[0]} at {best[1]*100:.3f}%")
    else:
        print("NO tap achieved <1% error. Either the eye is closed at this "
              "TRACECLK (too fast for the current PCB/SI), the pattern is wrong, "
              "or the capture path is broken. Check a single dump manually.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
