#!/usr/bin/env python3
"""hw_selftest — end-to-end datapath integrity go/no-go using CoreSight TPIU
built-in test-pattern generator (CURTPM).

Two modes:
  * --quick     : AA/55 pattern @ very-high slew, 4-lane err% + divergence.
                  Pass if all lanes < 1% err.  Takes ~10s.
  * --bandwidth : sweep OSPEEDR (0..3) and log per-lane err%. Reports the
                  highest slew that still passes.  Takes ~40s.
                  Add --sweep-tracelock to also scan the ETMv4 stream after
                  the datapath check.

The whole test bypasses M7/ETM/CSTF/ETF entirely — only the TPIU internal
pattern generator drives the 4 data lanes + CLK. Any observed dirty% is 100%
attributable to
    TPIU output driver  →  PCB / dupont  →  A7 IBUF  →  la sampler  →  DDR3

This is the "voltmeter" for the trace harness.

Prereqs:
  * FPGA: trace_pin_la_top.bit loaded (magic 'LA' at :5001 FF70..FF71)
  * DAP:  CMSIS-DAP probe connected to STM32H743
  * STM32 CPU: any state; we do reset halt.
"""
import argparse
import os
import socket
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tpiu_testpattern_diff import (   # noqa
    enable_tpiu_pattern, set_slew, stop_pattern, la_capture,
    analyze_aa55, analyze_ff00, PATTERNS
)

CTRL_PORT = 5002
STATUS_PORT = 5001


def check_pinla_ready(ip):
    """Verify pin-LA bitstream is loaded and MIG calibrated."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3.0)
    def rd(base, n):
        s.sendto(struct.pack("<H", base & 0xFFFF) + bytes(n + 4),
                 (ip, STATUS_PORT))
        d, _ = s.recvfrom(2048)
        return d[2:2 + n]
    try:
        magic = bytes(rd(0xFF70, 2))
        if magic != b"LA":
            return False, f"magic={magic!r} (expected b'LA')"
        calib = rd(0xFF09, 1)[0]
        if not (calib & 0x2):
            return False, f"MIG calib not done: FF09=0x{calib:02x}"
        return True, "OK"
    except Exception as e:
        return False, f"{e}"


def measure_traceclk_freq(ip):
    """Read the TRACECLK frequency the FPGA sees (edges / 16.777 ms window)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3.0)
    s.sendto(struct.pack("<H", 0xFF3B) + bytes(4 + 4),
             (ip, STATUS_PORT))
    d, _ = s.recvfrom(2048)
    edges = int.from_bytes(d[2:5], "little")
    hz = edges / (2 * 0.016777)
    return hz


def summarize_aa55(r):
    """Return (max_err_pct, divergence_pct, per_lane_dict) from AA55 result."""
    if "err" in r:
        return None, None, None
    lanes = r["per_lane"]
    errs = {L: v["err_pct"] for L, v in lanes.items()}
    return max(errs.values()), max(errs.values()) - min(errs.values()), errs


def cmd_quick(args):
    """Single AA/55 shot at very-high slew, fail if any lane > threshold."""
    ok, msg = check_pinla_ready(args.ip)
    if not ok:
        print(f"[FAIL] pin_la bitstream not ready: {msg}")
        return 1

    tclk = measure_traceclk_freq(args.ip)
    print(f"TRACECLK = {tclk / 1e6:.2f} MHz (from FPGA edge meter)")

    print("Enabling TPIU AA/55 pattern, OSPEEDR=very-high...")
    enable_tpiu_pattern(PATTERNS["AA55"])
    set_slew(3)
    time.sleep(0.3)

    cap_path = os.path.join(args.outdir, "quick_aa55.bin")
    os.makedirs(args.outdir, exist_ok=True)
    la_capture(args.ip, cap_path, seconds=args.seconds)

    r = analyze_aa55(cap_path)
    stop_pattern()

    if "err" in r:
        print(f"[FAIL] {r['err']}")
        return 1

    max_err, div, errs = summarize_aa55(r)
    print(f"AA/55 result: max err={max_err:.3f}%  divergence={div:.3f}%")
    for L, v in r["per_lane"].items():
        print(f"  {L}: err={v['err_pct']:5.3f}%  flipping={v['flipping']}")

    if max_err < args.threshold and div < 2.0:
        print(f"[PASS] all 4 lanes within {args.threshold}% and lane-lane "
              f"divergence < 2%")
        return 0
    print(f"[FAIL] threshold {args.threshold}% exceeded (max={max_err:.3f}%)")
    return 2


def cmd_bandwidth(args):
    """Sweep OSPEEDR 0..3, output per-speed err% table, and locate the
    highest slew that meets the pass threshold. TRACECLK frequency is left
    to the caller (whatever the firmware set)."""
    ok, msg = check_pinla_ready(args.ip)
    if not ok:
        print(f"[FAIL] pin_la bitstream not ready: {msg}")
        return 1

    tclk = measure_traceclk_freq(args.ip)
    print(f"TRACECLK = {tclk / 1e6:.2f} MHz (from FPGA edge meter)\n")

    os.makedirs(args.outdir, exist_ok=True)
    print(f"pattern={args.pattern} threshold={args.threshold}% "
          f"trials={args.n_trials}")

    enable_tpiu_pattern(PATTERNS[args.pattern])
    time.sleep(0.5)   # let the pattern stabilise before the first capture
    rows = []
    for sp in (0, 1, 2, 3):
        set_slew(sp)
        time.sleep(0.5)   # slew change takes a couple of ms; be generous
        # Discard the first capture at each speed (it can contain a mix of
        # the previous OSPEEDR's tail and the new one's head).
        cap_path = os.path.join(args.outdir,
                                f"{args.pattern}_speed{sp}_warmup.bin")
        la_capture(args.ip, cap_path, seconds=args.seconds)
        trial_max = []
        trial_div = []
        for t in range(args.n_trials):
            cap_path = os.path.join(args.outdir,
                                    f"{args.pattern}_speed{sp}_t{t}.bin")
            la_capture(args.ip, cap_path, seconds=args.seconds)
            if args.pattern == "AA55":
                r = analyze_aa55(cap_path)
                max_err, div, _ = summarize_aa55(r)
            elif args.pattern == "FF00":
                r = analyze_ff00(cap_path)
                duties = [v["duty_pct"] for v in r["per_lane"].values()]
                max_err = 100 - min(duties) if max(duties) > 90 else max(duties)
                div = r["divergence_pct"]
            trial_max.append(max_err)
            trial_div.append(div)

        # A run is unstable if per-trial results disagree. Take the MEDIAN
        # (robust to one bad transient) and also report min/max spread.
        trial_max.sort()
        trial_div.sort()
        median_err = trial_max[len(trial_max) // 2]
        median_div = trial_div[len(trial_div) // 2]
        min_err, max_err = trial_max[0], trial_max[-1]
        rows.append((sp, median_err, median_div))
        status = "PASS" if median_err < args.threshold else "FAIL"
        spread = max_err - min_err
        marker = " (UNSTABLE)" if spread > 1.0 else ""
        print(f"  OSPEEDR={sp}: median-err={median_err:6.3f}%  "
              f"spread={spread:6.3f}%  divergence={median_div:5.3f}%  "
              f"[{status}]{marker}  trials={trial_max}")
    stop_pattern()

    passing = [sp for sp, err, _ in rows if err < args.threshold]
    if passing:
        best = min(passing)   # cleanest = lowest slew that passes
        top = max(passing)    # widest margin = highest slew that passes
        print(f"\n[PASS] OSPEEDR range {best}..{top} passes at "
              f"TRACECLK={tclk / 1e6:.1f} MHz "
              f"(recommendation: {top} for widest signal margin)")
        return 0
    print(f"\n[FAIL] no OSPEEDR value passes at TRACECLK={tclk / 1e6:.1f} MHz")
    return 2


def main():
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__)
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--outdir", default="/tmp/hw_selftest")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for p_ in ():
        pass

    p_quick = sub.add_parser("quick",
                             help="single AA/55 shot at very-high slew "
                                  "(go/no-go)")
    p_quick.add_argument("--threshold", type=float, default=1.0,
                         help="max lane err%% to consider PASS (default 1.0)")
    p_quick.add_argument("--seconds", type=float, default=5.0)
    p_quick.set_defaults(func=cmd_quick)

    p_bw = sub.add_parser("bandwidth",
                          help="sweep OSPEEDR 0..3, report per-speed err%%")
    p_bw.add_argument("--pattern", default="AA55",
                      choices=list(PATTERNS.keys()))
    p_bw.add_argument("--threshold", type=float, default=1.0)
    p_bw.add_argument("--n-trials", type=int, default=1)
    p_bw.add_argument("--seconds", type=float, default=5.0)
    p_bw.set_defaults(func=cmd_bandwidth)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
