#!/usr/bin/env python3
"""freq_ceiling_sweep — find this board's source-sync capture frequency ceiling.

For each PLL1 DIVN1 value (VCO = ref*N, DIVR1=0 so TRACECLK = VCO):
  1. set_pll_n.cfg (CPU halted) raises the VCO and re-arms CURTPM AA/55
  2. sweep the IDDR IDELAY tap; for each tap capture IDDR-raw and score the
     fraction of bytes NOT in {0xA5,0x5A}
  3. record the BEST-tap error and the measured TRACECLK (from the FPGA
     200 MHz timebase byte-rate -- alias-free, unlike edge counting)

The ceiling = the highest TRACECLK whose best-tap error stays under a
threshold. Reports the error-vs-frequency curve and the eye width (#good taps)
at each frequency -- a shrinking eye is the physical-layer limit approaching.

Usage:
  freq_ceiling_sweep.py [--ip IP] [--n-list 23,27,31,...] [--taps 0-31]
                        [--thresh 0.1]
"""
import argparse, json, os, subprocess, sys, time
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))

# CURTPM register value + scorer per pattern.
#   aa55    : all 4 lanes toggle together -> byte 0xA5/0x5A. LENIENT (a dropped
#             nibble pair still reads 0xA5, and lane skew is masked).
#   walk1   : single bit rotating across lanes -> nibbles 4,2,1,8,4,... STRICT:
#             exposes lane skew (multi-bit nibble) and dropped/dup nibbles.
CURTPM = {"aa55": 0x00020004, "walk1": 0x00020001, "walk0": 0x00020002}
NEXT_ROT = {4: 2, 2: 1, 1: 8, 8: 4}


def score_aa55(d):
    good = sum(1 for b in d if b in (0xA5, 0x5A))
    return 1.0 - good / len(d)


def score_walk(d):
    """Fraction of nibbles breaking the single-bit rotation 4->2->1->8."""
    nibs = []
    for b in d:
        nibs.append((b >> 4) & 0xf); nibs.append(b & 0xf)
    breaks = 0; prev = None
    for x in nibs:
        is_single = (x != 0 and (x & (x - 1)) == 0)
        if not is_single:
            breaks += 1; prev = None; continue
        if prev is not None and x != NEXT_ROT[prev]:
            breaks += 1
        prev = x
    return breaks / len(nibs)


SCORER = {"aa55": score_aa55, "walk1": score_walk, "walk0": score_walk}


def run(cmd, timeout=40, env=None):
    e = dict(os.environ)
    if env:
        e.update(env)
    return subprocess.run(cmd, capture_output=True, text=True,
                          timeout=timeout, env=e)


def set_vco(nfield, curtpm_val):
    """Set DIVN1 field (N=nfield+1), DIVR1=0, re-arm CURTPM. Returns cfg echo."""
    e = dict(os.environ); e["PLLN_VAL"] = str(nfield)
    e["CURTPM_VAL"] = hex(curtpm_val)
    r = subprocess.run(
        ["openocd", "-f", "interface/cmsis-dap.cfg",
         "-f", "target/stm32h7x.cfg",
         "-f", "syn/artix7/bringup/target/set_pll_n.cfg"],
        capture_output=True, text=True, timeout=40, cwd=ROOT, env=e)
    return r


def measure(ip, depth, tag, scorer):
    cap = f"/tmp/fcs_{tag}.bin"
    run([sys.executable, f"{HERE}/trace_ctrl.py", "--ip", ip, "rearm"])
    time.sleep(0.25)
    run([sys.executable, f"{HERE}/trace_dump.py", "--ip", ip,
         "--depth", str(depth), "-o", cap, "--timebase"])
    if not os.path.exists(cap):
        return None, None
    d = open(cap, "rb").read()
    if not d:
        return None, None
    err = scorer(d)
    freq = None
    ts = cap + ".ts.json"
    if os.path.exists(ts):
        tb = json.load(open(ts))
        tk = tb["ticks"]
        if len(tk) >= 2:
            nbytes = (len(tk) - 1) * tb["stride"]
            dt_ns = (tk[-1] - tk[0]) * tb["tick_ns"]
            if dt_ns > 0:
                freq = nbytes / dt_ns * 1e3  # MHz (1 byte / TRACECLK period)
    return err, freq


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--depth", type=int, default=61440)
    ap.add_argument("--n-list", default="23,27,31,35,39,43,47,51",
                    help="DIVN1 field values (N=field+1) to sweep")
    ap.add_argument("--taps", default="0,4,8,12,16,20,24,28",
                    help="IDELAY taps to try per frequency")
    ap.add_argument("--thresh", type=float, default=0.1,
                    help="best-tap err ceiling as a FRACTION (0.001 = 0.1%)")
    ap.add_argument("--pattern", choices=CURTPM.keys(), default="walk1",
                    help="CURTPM test pattern: aa55 (lenient) or walk1/walk0 "
                         "(strict, lane-desynchronised -- default)")
    a = ap.parse_args()

    nfields = [int(x) for x in a.n_list.split(",")]
    taps = [int(x) for x in a.taps.split(",")]
    curtpm_val = CURTPM[a.pattern]
    scorer = SCORER[a.pattern]

    print(f"=== frequency ceiling sweep (DIVR1=0, VCO=TRACECLK, pattern={a.pattern}) ===")
    print(f"{'Nfield':>6} {'TRACECLK':>9} {'best-tap':>8} {'best-err%':>9} {'eye(#good taps)':>16}")
    rows = []
    for nf in nfields:
        r = set_vco(nf, curtpm_val)
        combined = (r.stdout or "") + (r.stderr or "")
        if "PLLN field" not in combined:
            print(f"{nf:>6}  set_pll_n failed: {combined[-200:]}")
            continue
        time.sleep(0.3)
        best_err = 1.0
        best_tap = None
        freq_meas = None
        good_taps = 0
        for t in taps:
            run([sys.executable, f"{HERE}/trace_ctrl.py", "--ip", a.ip,
                 "set-tap", str(t)])
            err, freq = measure(a.ip, a.depth, f"n{nf}_t{t}", scorer)
            if err is None:
                continue
            if freq is not None:
                freq_meas = freq
            if err < 0.001:      # this tap is "in the eye"
                good_taps += 1
            if err < best_err:
                best_err = err
                best_tap = t
        fs = f"{freq_meas:.1f}M" if freq_meas else "  ?  "
        rows.append((nf, freq_meas, best_tap, best_err, good_taps))
        print(f"{nf:>6} {fs:>9} {str(best_tap):>8} {best_err*100:>8.3f}% {good_taps:>10}/{len(taps)}")

    print("\n=== CEILING ===")
    ok = [r for r in rows if r[3] < a.thresh and r[1]]
    if ok:
        top = max(ok, key=lambda r: r[1])
        print(f"highest TRACECLK with best-tap err < {a.thresh*100:.2f}%: "
              f"{top[1]:.1f} MHz (Nfield={top[0]}, tap={top[2]}, err={top[3]*100:.3f}%, "
              f"eye {top[4]}/{len(taps)} taps)")
        # note eye-closing trend
        print("\neye width vs frequency (a shrinking eye = approaching the SI limit):")
        for nf, f, bt, be, gt in rows:
            if f:
                bar = "#" * gt
                print(f"  {f:6.1f} MHz: {bar} ({gt}/{len(taps)})")
    else:
        print("no frequency met the threshold -- lower --n-list or check setup")
    return 0


if __name__ == "__main__":
    sys.exit(main())
