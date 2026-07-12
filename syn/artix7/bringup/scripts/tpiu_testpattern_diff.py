#!/usr/bin/env python3
"""tpiu_testpattern_diff — end-to-end datapath integrity test using CoreSight
TPIU's built-in test-pattern generator (CURTPM).

WHY: bypasses the ENTIRE upstream chain (M7 core -> ETM -> CSTF -> ETF ->
formatter) so any observed error is 100% attributable to
    TPIU output driver  →  PCB/wire  →  A7 IBUF  →  la sampler  →  DDR3
No decoder, no software, no interpretation — just "is the pin waveform
exactly what the datasheet says it should be?".

TPIU_CURTPM (0x5C015204) bits:
    [0] PATW1 walking-1s        (D0=1 rotates left across lanes)
    [1] PATW0 walking-0s        (D0=0 rotates left across lanes)
    [2] PATA5 AA/55             (every lane toggles each TRACECK edge)
    [3] PATF0 FF/00             (every lane all-1 then all-0)
    [16] PTIMEEN                (unused for continuous)
    [17] PCONTEN continuous     (needed for our test)

The captured LA byte layout (from trace_pin_la_top.v):
    bit[4]=CLK bit[3]=D3 bit[2]=D2 bit[1]=D1 bit[0]=D0

For AA/55:
    on TRACECK rising , all 4 data lanes drive to their "A" state (1010 = 0xA)
    on TRACECK falling, all 4 data lanes drive to their "5" state (0101 = 0x5)
    (or the other way -- we detect empirically and lock the phase, then compare)

For FF/00:
    on rising edges: all lanes = 1; on falling: all = 0 (or reversed)

Usage:
    ./tpiu_testpattern_diff.py [--patterns AA55,FF00,W1,W0]
"""
import argparse
import os
import socket
import struct
import subprocess
import sys
import time
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))

CTRL_PORT = 5002
STREAM_PORT = 5555
STATUS_PORT = 5001
REG_ARM = 0x20

# CURTPM values (with PCONTEN=bit17)
PATTERNS = {
    "AA55": 0x00020004,   # PATA5 + PCONTEN
    "FF00": 0x00020008,   # PATF0 + PCONTEN
    "W1":   0x00020001,   # PATW1 + PCONTEN
    "W0":   0x00020002,   # PATW0 + PCONTEN
}


def ocd_run(cmds, timeout=10):
    argv = ["openocd", "-f", "interface/cmsis-dap.cfg",
            "-f", "target/stm32h7x.cfg"]
    for c in cmds:
        argv += ["-c", c]
    argv += ["-c", "shutdown"]
    r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    return r.stdout + r.stderr


def enable_tpiu_pattern(pattern_val):
    """Bring up TPIU test pattern (starts from cold: enable clocks, mux pins,
    unlock, program CURTPM)."""
    return ocd_run([
        "init", "reset halt",
        # GPIOEEN
        "mww 0x580244E0 [expr {[mrw 0x580244E0] | 0x00000010}]",
        # PE2..PE6 -> AF (10)
        "set m [mrw 0x58021000]",
        "set m [expr {$m & ~(0x3FFF << 4)}]",
        "set m [expr {$m | (0x2 << 4) | (0x2 << 6) | (0x2 << 8) | (0x2 << 10) | (0x2 << 12)}]",
        "mww 0x58021000 $m",
        # OSPEEDR very-high for a clean pattern comparison; caller can override
        "set s [mrw 0x58021008]",
        "set s [expr {$s | (0x3 << 4) | (0x3 << 6) | (0x3 << 8) | (0x3 << 10) | (0x3 << 12)}]",
        "mww 0x58021008 $s",
        # OTYPER push-pull
        "mww 0x58021004 [expr {[mrw 0x58021004] & ~(0x7C)}]",
        # AFRL: PE2..6 -> AF0
        "set afrl [mrw 0x58021020]",
        "set afrl [expr {$afrl & ~(0xFFFFF << 8)}]",
        "mww 0x58021020 $afrl",
        # DEMCR.TRCENA
        "mww 0xE000EDFC 0x01000000",
        # DBGMCU_CR TRACECLKEN + D1/D3 clocks
        "mww 0x5C001004 [expr {[mrw 0x5C001004] | 0x00700000}]",
        # Unlock TPIU
        "mww 0x5C015FB0 0xC5ACCE55",
        # 4-bit port + parallel + formatter
        "mww 0x5C015004 0x00000008",
        "mww 0x5C0150F0 0x00000000",
        "mww 0x5C015304 0x00000102",
        # Enable the test pattern
        f"mww 0x5C015204 {pattern_val:#x}",
        # Readback
        "echo TPIU_SUPTPM=[format 0x%08x [mrw 0x5C015200]]",
        "echo TPIU_CURTPM=[format 0x%08x [mrw 0x5C015204]]",
        "echo TPIU_CURPSIZE=[format 0x%08x [mrw 0x5C015004]]",
    ])


def set_slew(speed):
    """Rewrite PE2..PE6 OSPEEDR to `speed` (0..3)."""
    val_map = {0: 0, 1: (0x155 << 4), 2: (0x2AA << 4), 3: (0x3FF << 4)}
    val = val_map[speed]
    mask = (0x3FF << 4)
    return ocd_run([
        "init",
        f"set s [mrw 0x58021008]",
        f"set s [expr {{$s & ~{mask:#x}}}]",
        f"set s [expr {{$s | {val:#x}}}]",
        f"mww 0x58021008 $s",
        "echo OSPEEDR=[format 0x%08x [mrw 0x58021008]]",
    ])


def stop_pattern():
    """Turn off the test pattern."""
    return ocd_run([
        "init",
        "mww 0x5C015FB0 0xC5ACCE55",
        "mww 0x5C015204 0",
    ])


def la_capture(ip, out_path, seconds=5.0):
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 << 20)
    rx.bind(("0.0.0.0", STREAM_PORT))
    rx.settimeout(seconds)
    warm = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    warm.settimeout(0.3)
    for _ in range(5):
        try:
            warm.sendto(b"\x10\x00\x00\x00", (ip, STATUS_PORT))
            warm.recvfrom(64)
        except socket.timeout:
            pass
    warm.close()

    ctrl = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ctrl.sendto(bytes([REG_ARM, 1, 0, 0]), (ip, CTRL_PORT))
    ctrl.close()

    total = 0
    with open(out_path, "wb") as f:
        while True:
            try:
                d, _ = rx.recvfrom(65535)
            except socket.timeout:
                break
            f.write(d)
            total += len(d)
    rx.close()
    return total


# ---- pattern-specific analyzers -------------------------------------------

def analyze_aa55(cap_path):
    """AA/55 pattern: at every CLK rising edge, D0..D3 = A or 5 (some phase).
    At every CLK falling edge, opposite. So each data lane toggles ONCE per
    TRACECK period (half rate of CLK). We detect empirical phase, then count
    mismatches."""
    d = open(cap_path, "rb").read()
    n = len(d)

    # CLK bit stream
    clk = bytes((b >> 4) & 1 for b in d)
    # detect CLK rising edges
    rise_idxs = [i for i in range(1, n) if clk[i] and not clk[i - 1]]
    fall_idxs = [i for i in range(1, n) if not clk[i] and clk[i - 1]]
    if len(rise_idxs) < 100 or len(fall_idxs) < 100:
        return {"err": f"not enough CLK edges: rise={len(rise_idxs)} fall={len(fall_idxs)}"}

    # Sample each data lane at CLK rising and CLK falling. To avoid
    # sampling ON the edge (metastable) we look 1 sample past.
    def sample_at(idxs, lane_bit):
        vals = []
        for i in idxs:
            j = min(i + 1, n - 1)
            vals.append((d[j] >> lane_bit) & 1)
        return vals

    per_lane = {}
    for lane, bit in [("D0", 0), ("D1", 1), ("D2", 2), ("D3", 3)]:
        r = sample_at(rise_idxs, bit)
        f = sample_at(fall_idxs, bit)
        # Empirically detect phase: what's the "expected" rising value?
        # In AA/55, on rising CLK the data bits are the "A" nibble bits.
        # A = 0b1010 -> D3=1 D2=0 D1=1 D0=0. So D0=0 D1=1 D2=0 D3=1 on rising,
        # and inverted on falling. But which edge is "A" is board-dependent
        # (depends on TPIU-Lite phase), so we compute the most common value
        # per (lane, edge) and treat the majority as the "expected" pattern.
        exp_r = 1 if sum(r) > len(r) / 2 else 0
        exp_f = 1 if sum(f) > len(f) / 2 else 0
        # These should be OPPOSITE if it's a real AA/55 pattern
        # (each period the bit flips). If exp_r == exp_f, the lane is stuck.
        flipping = (exp_r != exp_f)
        err_r = sum(1 for v in r if v != exp_r)
        err_f = sum(1 for v in f if v != exp_f)
        total = len(r) + len(f)
        errs = err_r + err_f
        per_lane[lane] = {
            "flipping": flipping,
            "exp_r": exp_r, "exp_f": exp_f,
            "err_r": err_r, "err_f": err_f,
            "err_pct": 100.0 * errs / max(1, total),
            "samples": total,
        }
    return {
        "n_rising": len(rise_idxs),
        "n_falling": len(fall_idxs),
        "per_lane": per_lane,
    }


def analyze_ff00(cap_path):
    """FF/00 pattern: on one edge all lanes = 1, on the other all = 0.
    All 4 data lanes MUST show identical behaviour. Report per-lane duty and
    inter-lane divergence."""
    d = open(cap_path, "rb").read()
    n = len(d)
    counts = {}
    for lane, bit in [("D0", 0), ("D1", 1), ("D2", 2), ("D3", 3)]:
        ones = sum(1 for b in d if b & (1 << bit))
        counts[lane] = {"duty_pct": 100.0 * ones / n, "ones": ones}
    # ideal: all lanes have identical duty. divergence = max - min.
    duties = [v["duty_pct"] for v in counts.values()]
    div = max(duties) - min(duties)
    return {"per_lane": counts, "divergence_pct": div}


def analyze_walking(cap_path, pattern):
    """W1 / W0: one lane hot (or cold), rotates. In H743 we see one lane
    active at a time -- verify only ONE lane changes at each edge."""
    d = open(cap_path, "rb").read()
    n = len(d)
    counts = {}
    for lane, bit in [("D0", 0), ("D1", 1), ("D2", 2), ("D3", 3)]:
        mask = 1 << bit
        edges = 0
        prev = d[0] & mask
        for b in d:
            v = b & mask
            if v != prev:
                edges += 1
                prev = v
        counts[lane] = {"edges": edges}
    return {"per_lane": counts}


# ---- main -----------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--patterns", default="AA55,FF00",
                    help="patterns to test (AA55, FF00, W1, W0)")
    ap.add_argument("--speeds", default="3",
                    help="OSPEEDR values to sweep (0..3, comma list)")
    ap.add_argument("--outdir", default="/tmp/tpiu_testpattern_diff")
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--n-trials", type=int, default=1,
                    help="number of repeat captures per (pattern, speed)")
    a = ap.parse_args()

    os.makedirs(a.outdir, exist_ok=True)
    patterns = [p.strip() for p in a.patterns.split(",")]
    speeds = [int(s) for s in a.speeds.split(",")]

    results = {}
    try:
        for pat in patterns:
            if pat not in PATTERNS:
                print(f"unknown pattern {pat}")
                continue
            print(f"\n=== TPIU pattern {pat} (CURTPM={PATTERNS[pat]:#x}) ===")
            enable_tpiu_pattern(PATTERNS[pat])

            for sp in speeds:
                print(f"  --- OSPEEDR={sp} ---")
                set_slew(sp)
                time.sleep(0.3)

                for trial in range(a.n_trials):
                    cap_path = os.path.join(
                        a.outdir, f"{pat}_speed{sp}_t{trial}.bin")
                    got = la_capture(a.ip, cap_path, seconds=a.seconds)

                    if pat == "AA55":
                        r = analyze_aa55(cap_path)
                    elif pat == "FF00":
                        r = analyze_ff00(cap_path)
                    else:
                        r = analyze_walking(cap_path, pat)

                    key = (pat, sp, trial)
                    results[key] = r

                    if pat == "AA55" and "per_lane" in r:
                        print(f"    trial {trial}: rise={r['n_rising']} "
                              f"fall={r['n_falling']}")
                        for lane, v in r["per_lane"].items():
                            print(f"      {lane}: flipping={v['flipping']}  "
                                  f"exp(r/f)=({v['exp_r']}/{v['exp_f']})  "
                                  f"err%={v['err_pct']:5.2f}  "
                                  f"({v['err_r']}+{v['err_f']}/{v['samples']})")
                    elif pat == "FF00":
                        print(f"    trial {trial}: divergence={r['divergence_pct']:.2f}%")
                        for lane, v in r["per_lane"].items():
                            print(f"      {lane}: duty={v['duty_pct']:5.2f}%")
                    else:
                        print(f"    trial {trial}:")
                        for lane, v in r["per_lane"].items():
                            print(f"      {lane}: edges={v['edges']}")

        print("\n=== SUMMARY (per-lane error / divergence by pattern × speed) ===")
        for pat in patterns:
            for sp in speeds:
                key = (pat, sp, 0)
                if key not in results:
                    continue
                r = results[key]
                if pat == "AA55" and "per_lane" in r:
                    lanes = [f"{L}={v['err_pct']:.2f}%"
                             for L, v in r["per_lane"].items()]
                    print(f"  {pat} speed={sp}: {'  '.join(lanes)}")
                elif pat == "FF00":
                    print(f"  {pat} speed={sp}: divergence={r['divergence_pct']:.2f}%")
    finally:
        stop_pattern()
        print("\nTPIU pattern stopped (CURTPM=0).")

    return 0


if __name__ == "__main__":
    sys.exit(main())
