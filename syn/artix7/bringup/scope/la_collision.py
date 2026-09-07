#!/usr/bin/env python3
"""la_collision — digital (LA pod) per-lane CLK/DATA collision check.

Captures D0=CLK, D1..D4=TRACED0..3 simultaneously on the MSO8304A logic pods
and, for EACH data lane, histograms where its transitions fall within the
TRACECLK UI. A lane whose edges pile up ON the clock edges (phase ~0 or ~1)
is racing the IDDR sample; a lane centred at ~0.5 is safe.

This is the all-lanes-at-once version of the analog cross_eye, using the same
tap type as the FPGA (digital threshold), so it directly answers "which lane
is colliding" that the raw-byte drop stats (rise-lane3 45%, fall-lane0/3 ~38%)
flagged.

True LA sample rate = 1/:WAVeform:XINCrement (NOT :ACQuire:SRATe, which reports
the analog rate). Usage: la_collision.py [timebase=2e-8] [maxpts=200000]
"""
import os
import sys
import time
import bisect

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from scope_visa import Scope


def read_digi(s, src, q, maxpts):
    s.w(f":WAVeform:SOURce {src}")
    s.w(":WAVeform:MODE RAW")
    s.w(":WAVeform:FORMat BYTE")
    xinc = float(q(":WAVeform:XINCrement?"))
    avail = int(float(q(":WAVeform:POINts?")))
    m = min(avail, maxpts)
    out = []
    start, CH = 1, 1_000_000
    while start <= m:
        stop = min(start + CH - 1, m)
        s.w(f":WAVeform:STARt {start}")
        s.w(f":WAVeform:STOP {stop}")
        out.extend(b & 1 for b in s.read_block(":WAVeform:DATA?", timeout_ms=60000))
        start = stop + 1
    return out, xinc


def edges(sig):
    e = []
    for i in range(1, len(sig)):
        if sig[i] != sig[i - 1]:
            e.append((i, 1 if sig[i] else -1))
    return e


def main(timebase="2e-8", maxpts=200000):
    s = Scope(timeout_ms=10000)

    def q(c, t=8000):
        return s.q(c, t)

    s.w(":LA:STATe ON")
    s.w(":LA:POD1:THReshold 1.65")
    for d in range(16):
        s.w(f":LA:DIGital:DISPlay D{d},{'ON' if d <= 4 else 'OFF'}")
    s.w(f":TIMebase:MAIN:SCALe {timebase}")
    s.w(":TRIGger:MODE EDGE")
    s.w(":TRIGger:EDGE:SOURce D0")
    s.w(":TRIGger:EDGE:SLOPe POSitive")
    s.w(":TRIGger:SWEep AUTO")
    s.w(":RUN")
    time.sleep(0.5)
    s.w(":ACQuire:MDEPth 1M")
    time.sleep(1.0)
    s.w(":STOP")
    time.sleep(0.4)

    clk, xinc = read_digi(s, "D0", q, maxpts)
    lanes = []
    for d, nm in [("D1", "TD0/PE3"), ("D2", "TD1/PE4"),
                  ("D3", "TD2/PE5"), ("D4", "TD3/PE6")]:
        sig, _ = read_digi(s, d, q, maxpts)
        lanes.append((nm, sig))
    s.close()

    n = min([len(clk)] + [len(x[1]) for x in lanes])
    clk = clk[:n]
    print(f"samples={n}  xinc={xinc:.3e}s ({1/xinc:.3e} S/s TRUE LA rate)")
    ce = edges(clk[:n])
    rise = [i for i, d in ce if d > 0]
    if len(rise) < 4:
        print(f"!! only {len(rise)} CLK rising edges; check D0=CLK wiring")
        return
    per = sorted(rise[i + 1] - rise[i] for i in range(len(rise) - 1))
    ui = per[len(per) // 2]
    print(f"CLK: {len(ce)} edges  full-UI={ui} samp = {ui*xinc*1e9:.2f} ns "
          f"({1/(ui*xinc)/1e6:.1f} MHz)")
    if ui < 4:
        print(f"!! only {ui} samples/UI -- LA rate too low for phase histogram; "
              f"lower timebase or the pod maxed at 1.25GS/s")
    cidx = [i for i, _ in ce]
    print(f"\n  lane      | edges | edge-phase-in-UI histogram (0=on CLK edge, "
          f".5=mid) | within±15%%UI")
    print(f"  ----------+-------+"
          f"----------------------------------------------+-----------")
    for nm, sig in lanes:
        sig = sig[:n]
        pe = edges(sig)
        phases = []
        for di, _ in pe:
            k = bisect.bisect_right(cidx, di) - 1
            if k < 0:
                continue
            ph = ((di - cidx[k]) / ui) % 0.5 * 2  # fold to half-UI, norm 0..1
            phases.append(ph)
        if not phases:
            print(f"  {nm:9s} | {len(pe):5d} | (no edges)")
            continue
        bins = [0] * 10
        for p in phases:
            bins[min(9, int(p * 10))] += 1
        bar = "".join("#" if b > len(phases) * 0.05 else
                      ("." if b else " ") for b in bins)
        danger = sum(1 for p in phases if p < 0.15 or p > 0.85)
        print(f"  {nm:9s} | {len(pe):5d} | {bar}  | "
              f"{danger:4d} ({100*danger/len(phases):.1f}%)")
    print("\n  phase 0.0 = data edge lands ON a CLK (sampling) edge = COLLISION")
    print("  phase 0.5 = data edge at mid-UI = safe (CLK samples in the eye)")


if __name__ == "__main__":
    a = sys.argv[1:]
    kw = {}
    if len(a) > 0:
        kw["timebase"] = a[0]
    if len(a) > 1:
        kw["maxpts"] = int(a[1])
    main(**kw)
