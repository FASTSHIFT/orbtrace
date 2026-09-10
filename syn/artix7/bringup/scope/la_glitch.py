#!/usr/bin/env python3
"""Grab RAW per-sample LA data (D0=CLK, D1..D4=TRACED0..3) and hunt for
anomalies WITHOUT any nibble reconstruction:
  * CLK half-period distribution (glitches = runt half-periods)
  * data-edge position relative to CLK edges (collisions near the edge)
  * per-lane runt pulses (1-2 sample spikes = reflection/threshold marginal)
Pure raw-sample analysis, so it reflects the physical signal, not our packer.
"""
import os
import sys
import time
import numpy as np

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
    out = bytearray()
    start = 1
    while start <= m:
        stop = min(start + 999999, m)
        s.w(f":WAVeform:STARt {start}")
        s.w(f":WAVeform:STOP {stop}")
        out += bytes(b & 1 for b in s.read_block(":WAVeform:DATA?", 60000))
        start = stop + 1
    return np.frombuffer(bytes(out), np.uint8), xinc


def runs(sig):
    """Return array of run-lengths of constant level."""
    ch = np.flatnonzero(np.diff(sig)) + 1
    bounds = np.concatenate(([0], ch, [len(sig)]))
    return np.diff(bounds)


def main(timebase="5e-7", maxpts=1_000_000):
    s = Scope(timeout_ms=15000)

    def q(c, t=8000):
        return s.q(c, t)

    s.w(":LA:STATe ON")
    s.w(":LA:POD1:THReshold 1.65")
    for d in range(16):
        s.w(f":LA:DIGital:DISPlay D{d},{'ON' if d <= 4 else 'OFF'}")
    s.w(f":TIMebase:MAIN:SCALe {timebase}")
    s.w(":TRIGger:MODE EDGE")
    s.w(":TRIGger:EDGE:SOURce D0")
    s.w(":TRIGger:SWEep AUTO")
    s.w(":RUN")
    time.sleep(0.4)
    s.w(":ACQuire:MDEPth 10M")
    time.sleep(0.9)
    s.w(":STOP")
    time.sleep(0.3)

    clk, xinc = read_digi(s, "D0", q, maxpts)
    lanes = {}
    for d, nm in [("D1", "TD0/PE3"), ("D2", "TD1/PE4"),
                  ("D3", "TD2/PE5"), ("D4", "TD3/PE6")]:
        lanes[nm], _ = read_digi(s, d, q, maxpts)
    s.close()

    n = min([len(clk)] + [len(v) for v in lanes.values()])
    clk = clk[:n]
    print(f"samples={n}  xinc={xinc:.3e}s ({1/xinc/1e6:.0f} MS/s)")

    # ---- CLK half-period stats ----
    cr = runs(clk)
    cr = cr[1:-1]  # drop partial first/last
    med = int(np.median(cr))
    print(f"\nCLK half-period: median={med} samp ({med*xinc*1e9:.2f} ns), "
          f"min={cr.min()}, max={cr.max()}")
    runt = int(np.count_nonzero(cr < med * 0.5))
    long = int(np.count_nonzero(cr > med * 1.5))
    print(f"  runt half-periods (<50% median): {runt}  "
          f"(these = CLK glitches / double-edges)")
    print(f"  long half-periods (>150% median): {long}  "
          f"(these = CLK stalls / missed edges)")
    # histogram of half-period lengths
    vals, cnts = np.unique(cr, return_counts=True)
    order = np.argsort(-cnts)
    print("  half-period length histogram (top 8):")
    for k in order[:8]:
        print(f"     {vals[k]} samp : {cnts[k]}")

    # ---- CLK edge index list ----
    edges = np.flatnonzero(np.diff(clk.astype(np.int8)) != 0) + 1

    # ---- per-lane runts + edge-vs-clk proximity ----
    print("\nper-lane raw anomalies:")
    for nm, sig in lanes.items():
        sig = sig[:n]
        lr = runs(sig)
        lr = lr[1:-1]
        lrunt = int(np.count_nonzero(lr <= 2))  # 1-2 sample spikes
        ledges = np.flatnonzero(np.diff(sig.astype(np.int8)) != 0) + 1
        # nearest clk edge distance for each data edge
        if len(ledges) and len(edges):
            idx = np.searchsorted(edges, ledges)
            idx = np.clip(idx, 1, len(edges) - 1)
            d_prev = ledges - edges[idx - 1]
            d_next = edges[np.clip(idx, 0, len(edges) - 1)] - ledges
            nearest = np.minimum(d_prev, d_next)
            near_edge = int(np.count_nonzero(nearest < max(1, med // 6)))
            near_pct = 100.0 * near_edge / len(ledges)
        else:
            near_pct = 0.0
        print(f"  {nm:9s}: edges={len(ledges)}  runt(<=2samp)={lrunt}  "
              f"data-edge-within-1/6UI-of-CLK={near_pct:.2f}%")


if __name__ == "__main__":
    a = sys.argv[1:]
    kw = {}
    if len(a) > 0:
        kw["timebase"] = a[0]
    if len(a) > 1:
        kw["maxpts"] = int(a[1])
    main(**kw)
