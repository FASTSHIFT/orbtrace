#!/usr/bin/env python3
"""perlane_idelay_cal — proposal 33: per-lane IDELAY calibration scored by
REAL ETM decode quality (deframed A-sync count), NOT walking (its eye is too
wide to see the tap) and NOT set-coverage vanity metrics.

Procedure (greedy per-lane hill-climb):
  1. start from a global best tap (found by a quick global sweep)
  2. for each lane 0..3, sweep its tap 0..N while holding the others, pick the
     tap that maximises deframed A-sync count on a fresh real-ETM capture
  3. optionally repeat a second pass (skew between lanes can interact)

Assumes: ETM already enabled (BB=1), CURTPM cleared, FPGA bit has per-lane tap
CSR 0x06 (trace_ctrl set-tap-lane). Real ETM must be flowing.

Usage:
  perlane_idelay_cal.py [--ip IP] [--depth N] [--taps 0,2,4,..] [--passes 2]
"""
import argparse, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "decode"))
import tpiu_official as T   # noqa: E402


def capture(ip, depth):
    subprocess.run([sys.executable, f"{HERE}/trace_ctrl.py", "--ip", ip,
                    "rearm"], capture_output=True)
    time.sleep(0.4)
    cap = "/tmp/plc.bin"
    subprocess.run([sys.executable, f"{HERE}/trace_dump.py", "--ip", ip,
                    "--depth", str(depth), "-o", cap],
                   capture_output=True)
    return open(cap, "rb").read()


def score(raw):
    """Real-ETM quality = deframed A-sync count (higher is better)."""
    etm, st = T.deframe(raw, want_stream=2)
    a = z = ti = 0
    for i, c in enumerate(etm):
        if c == 0:
            z += 1
        elif c == 0x80 and z >= 11:
            a += 1
            if i + 1 < len(etm) and etm[i + 1] == 0x01:
                ti += 1
            z = 0
        else:
            z = 0
    return a, ti, len(etm)


def set_lane(ip, lane, tap):
    subprocess.run([sys.executable, f"{HERE}/trace_ctrl.py", "--ip", ip,
                    "set-tap-lane", str(lane), str(tap)], capture_output=True)


def set_all(ip, tap):
    subprocess.run([sys.executable, f"{HERE}/trace_ctrl.py", "--ip", ip,
                    "set-tap", str(tap)], capture_output=True)


def measure(ip, depth, reps=2):
    """Median-ish: take best A-sync over `reps` captures (robust to a bad grab)."""
    best = (-1, -1, 0)
    for _ in range(reps):
        a, ti, n = score(capture(ip, depth))
        if a > best[0]:
            best = (a, ti, n)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--depth", type=int, default=61440)
    ap.add_argument("--taps", default="0,1,2,3,4,6,8,12,16,20,24,28")
    ap.add_argument("--passes", type=int, default=2)
    a = ap.parse_args()
    taps = [int(x) for x in a.taps.split(",")]

    # 1) global sweep to seed
    print("=== global tap seed ===")
    gbest = (-1, 0); gtap = taps[0]
    for t in taps:
        set_all(a.ip, t)
        asc, ti, n = measure(a.ip, a.depth)
        print(f"  all={t:2d}  A-sync={asc:3d} trinfo={ti:3d} deframed={n}")
        if asc > gbest[0]:
            gbest = (asc, ti); gtap = t
    print(f"  -> global best tap = {gtap} (A-sync={gbest[0]})")

    lane_tap = [gtap, gtap, gtap, gtap]
    for l in range(4):
        set_lane(a.ip, l, lane_tap[l])

    # 2) per-lane greedy hill-climb
    for p in range(a.passes):
        print(f"\n=== per-lane pass {p+1} ===")
        for l in range(4):
            best = (-1, lane_tap[l])
            for t in taps:
                set_lane(a.ip, l, t)
                asc, ti, n = measure(a.ip, a.depth)
                mark = ""
                if asc > best[0]:
                    best = (asc, t); mark = " *"
                print(f"  lane{l} tap={t:2d}  A-sync={asc:3d} trinfo={ti:3d}{mark}")
            lane_tap[l] = best[1]
            set_lane(a.ip, l, lane_tap[l])
            print(f"  -> lane{l} best tap = {lane_tap[l]} (A-sync={best[0]})")
        print(f"  taps after pass {p+1}: {lane_tap}")

    print(f"\n=== FINAL per-lane taps = {lane_tap} ===")
    for l in range(4):
        set_lane(a.ip, l, lane_tap[l])
    asc, ti, n = measure(a.ip, a.depth, reps=3)
    print(f"final: A-sync={asc} trinfo={ti} deframed={n}")
    print("taps:", " ".join(f"L{l}={lane_tap[l]}" for l in range(4)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
