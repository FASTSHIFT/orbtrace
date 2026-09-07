#!/usr/bin/env python3
"""lane_eye_check — probe the physical eye of each TRACED lane against TRACECLK.

Goal: given the r38/r39 investigation flagged lane-0 bit-0 corruption on the
FPGA side, decide whether the source (STM32 PE3 TRACED0 or the probe) already
looks weird, or whether the FPGA IDDR is the sole suspect.

For each digital channel Dn (D1..D4 = TRACED0..3):
  * count rising and falling edges (should be balanced ~= half the TRACECLK
    edges = period/2 pulses on each data lane if the ETM data is 50%-balanced)
  * count consecutive-same-state runs of length 1 (glitch/short pulse count)
  * time-align relative to CLK: mean sample-index of Dn edge relative to
    nearest CLK edge; big offsets on ONE lane => that lane is off-eye

TRACECLK on D0 provides the reference. All data lines are LA-captured
simultaneously so any per-lane skew is a real physical effect (not a
scope-side artefact).

Usage:
    lane_eye_check.py [timebase_s_per_div] [mdepth]

Prints a per-lane report + a verdict.
"""
import os
import sys
import time
from statistics import mean, pstdev

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from scope_visa import Scope


def read_line(s, src, n, q):
    s.w(f":WAVeform:SOURce {src}")
    s.w(":WAVeform:MODE RAW")
    s.w(":WAVeform:FORMat BYTE")
    pts = q(":WAVeform:POINts?")
    try:
        avail = int(float(pts))
    except ValueError:
        raise RuntimeError(f":WAVeform:POINts? returned {pts!r} for {src}")
    m = min(avail, int(n))
    out = []
    start, CH = 1, 1_000_000
    while start <= m:
        stop = min(start + CH - 1, m)
        s.w(f":WAVeform:STARt {start}")
        s.w(f":WAVeform:STOP {stop}")
        out.extend(b & 1 for b in s.read_block(":WAVeform:DATA?", timeout_ms=60000))
        start = stop + 1
    return out, avail


def edges(sig):
    """Return list of (index, direction) where direction=+1 rising, -1 falling."""
    e = []
    for i in range(1, len(sig)):
        if sig[i - 1] == 0 and sig[i] == 1:
            e.append((i, +1))
        elif sig[i - 1] == 1 and sig[i] == 0:
            e.append((i, -1))
    return e


def glitches(sig, min_run=1):
    """Count runs of length == min_run (1 sample) = shortest possible glitches."""
    n = 0
    if not sig:
        return 0
    run = 1
    for i in range(1, len(sig)):
        if sig[i] == sig[i - 1]:
            run += 1
        else:
            if run == min_run:
                n += 1
            run = 1
    if run == min_run:
        n += 1
    return n


def nearest_clk_offset(dedges, cedges):
    """For each data edge, find offset to nearest CLK edge (in sample units).
    Returns mean, stdev, and histogram of small offsets around 0 (mid-eye
    should be a specific offset; deviation from that reveals a delayed lane).
    """
    # cedges is sorted by index; use pointer.
    ci = 0
    offsets = []
    for di, _ in dedges:
        while ci + 1 < len(cedges) and cedges[ci + 1][0] < di:
            ci += 1
        # nearest of cedges[ci] and cedges[ci+1] to di
        cand = [cedges[ci]]
        if ci + 1 < len(cedges):
            cand.append(cedges[ci + 1])
        best = min(cand, key=lambda ce: abs(ce[0] - di))
        offsets.append(di - best[0])
    return offsets


def capture(timebase="1e-7", mdepth="10M", maxpts=1_000_000):
    s = Scope(timeout_ms=10000)

    def q(c, t=8000):
        try:
            return s.q(c, t)
        except Exception as e:
            return f"ERR {e!r}"

    s.w(":LA:STATe ON")
    s.w(":LA:POD1:THReshold 1.65")
    for d in range(16):
        s.w(f":LA:DIGital:DISPlay D{d},{'ON' if d <= 4 else 'OFF'}")
    for d, lab in [(0, "CLK"), (1, "TD0"), (2, "TD1"), (3, "TD2"), (4, "TD3")]:
        s.w(f":LA:DIGital:LABel D{d},{lab}")
    s.w(f":TIMebase:MAIN:SCALe {timebase}")
    s.w(":TRIGger:MODE EDGE")
    s.w(":TRIGger:EDGE:SOURce D0")
    s.w(":TRIGger:EDGE:SLOPe POSitive")
    s.w(":TRIGger:SWEep AUTO")
    s.w(":RUN")
    time.sleep(0.5)
    s.w(f":ACQuire:MDEPth {mdepth}")
    time.sleep(1.2)
    s.w(":STOP")
    time.sleep(0.5)

    srate = float(q(":ACQuire:SRATe?"))
    print(f"srate = {srate:.3e} S/s")
    print(f"mdepth = {q(':ACQuire:MDEPth?')}")

    print("reading lines...")
    clk, avail = read_line(s, "D0", maxpts, q)
    d0, _ = read_line(s, "D1", maxpts, q)
    d1, _ = read_line(s, "D2", maxpts, q)
    d2, _ = read_line(s, "D3", maxpts, q)
    d3, _ = read_line(s, "D4", maxpts, q)
    n = min(len(clk), len(d0), len(d1), len(d2), len(d3))
    print(f"aligned samples: {n}")
    s.close()

    cedges = edges(clk[:n])
    print(f"CLK edges: {len(cedges)} ({sum(1 for _,d in cedges if d==+1)} rise,"
          f" {sum(1 for _,d in cedges if d==-1)} fall)")

    print()
    print(f"  lane  |  rise    fall   glitches  mean-offset(samp)  stdev  hi%")
    print(f"  ------+------------------------------------------------------------")
    verdicts = []
    for name, sig in [("TD0(D1)", d0), ("TD1(D2)", d1),
                      ("TD2(D3)", d2), ("TD3(D4)", d3)]:
        sig = sig[:n]
        rise = sum(1 for _, d in edges(sig) if d == +1)
        fall = sum(1 for _, d in edges(sig) if d == -1)
        gl = glitches(sig)
        offs = nearest_clk_offset(edges(sig), cedges)
        if offs:
            mo = mean(offs); so = pstdev(offs)
        else:
            mo = so = 0
        hi = 100.0 * sum(sig) / len(sig)
        print(f"  {name:8s}| {rise:6d}  {fall:6d}   {gl:6d}    "
              f"{mo:+8.2f}         {so:6.2f}  {hi:5.1f}")
        verdicts.append((name, rise, fall, gl, mo, so))

    print()
    print("interpretation:")
    print("  * a lane with mean-offset FAR from the others => sampled at a")
    print("    different phase of TRACECLK (physical or IDELAY skew).")
    print("  * a lane with glitches != others  => reflection / crosstalk /")
    print("    threshold marginal (probe or PCB trace).")
    print("  * rise vs fall imbalance   => asymmetric slew (unlikely at 112 MHz).")


if __name__ == "__main__":
    a = sys.argv[1:]
    kw = {}
    if len(a) > 0: kw["timebase"] = a[0]
    if len(a) > 1: kw["mdepth"] = a[1]
    capture(**kw)
