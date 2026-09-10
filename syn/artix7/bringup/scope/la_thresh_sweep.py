#!/usr/bin/env python3
"""Sweep the LA digital-pod threshold and count runt (false) CLK edges at each,
to find the threshold that minimises ringing/overshoot-induced false edges.
Only knob available on MSO8000 digital pods is POD1 threshold (no hysteresis).
"""
import os
import sys
import time
import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from scope_visa import Scope


def grab_clk(s, q, maxpts=500000):
    s.w(":WAVeform:SOURce D0")
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


def runt_count(clk):
    ch = np.flatnonzero(np.diff(clk.astype(np.int8))) + 1
    bounds = np.concatenate(([0], ch, [len(clk)]))
    r = np.diff(bounds)[1:-1]
    if len(r) == 0:
        return 0, 0, 0
    med = int(np.median(r))
    runt = int(np.count_nonzero(r < med * 0.5))
    return runt, med, len(r)


def main():
    s = Scope(timeout_ms=15000)

    def q(c, t=8000):
        return s.q(c, t)

    s.w(":LA:STATe ON")
    for d in range(16):
        s.w(f":LA:DIGital:DISPlay D{d},{'ON' if d <= 4 else 'OFF'}")
    s.w(":TIMebase:MAIN:SCALe 5e-7")
    s.w(":TRIGger:MODE EDGE")
    s.w(":TRIGger:EDGE:SOURce D0")
    s.w(":TRIGger:SWEep AUTO")

    print(f"{'thr(V)':>7}  {'runt-edges':>10}  {'half-med':>8}  {'total-halves':>12}")
    for thr in [1.20, 1.40, 1.65, 1.80, 2.00, 2.20, 2.40]:
        s.w(f":LA:POD1:THReshold {thr}")
        s.w(":RUN")
        time.sleep(0.4)
        s.w(":ACQuire:MDEPth 10M")
        time.sleep(0.8)
        s.w(":STOP")
        time.sleep(0.3)
        clk, xinc = grab_clk(s, q)
        runt, med, tot = runt_count(clk)
        print(f"{thr:7.2f}  {runt:10d}  {med:8d}  {tot:12d}")
    s.close()


if __name__ == "__main__":
    main()
