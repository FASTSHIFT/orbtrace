#!/usr/bin/env python3
"""trace_line_scope — read analog CH1 waveform aligned to LA D0 (TRACECLK) to
compare eye quality across probes/lines.

For characterising signal integrity on a single trace lane at the STM32 pin.
Usage:
    trace_line_scope.py [ch=1] [samples=100000]

Records analog waveform + shows min/max/mean, edge count, over/undershoot
statistics. Aim: see if the analog signal at the STM32 pin already shows
bit-value ambiguity (marginal levels, ringing) that could cause bit0 flips.
"""
import os
import sys
import time
import statistics

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from scope_visa import Scope


def main():
    ch = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    n_pts = int(sys.argv[2]) if len(sys.argv) > 2 else 100_000

    s = Scope(timeout_ms=10000)

    def q(c, t=8000):
        return s.q(c, t)

    print(f":IDN? = {q('*IDN?')}")
    print(f"probing analog channel {ch}...")

    # Setup analog channel for reading
    s.w(f":CHANnel{ch}:DISPlay ON")
    s.w(f":CHANnel{ch}:COUPling DC")
    s.w(f":CHANnel{ch}:PROBe 10")     # 10:1 probe assumed
    s.w(f":CHANnel{ch}:SCALe 0.5")    # 500 mV/div — 3.3V logic
    s.w(f":CHANnel{ch}:OFFSet 1.65")

    # Fast timebase for 112 MHz edges
    s.w(":TIMebase:MAIN:SCALe 20E-9")   # 20 ns/div; 2.5 GS/s -> 50 samp/div

    s.w(":RUN")
    time.sleep(1.0)
    s.w(":STOP")
    time.sleep(0.3)

    srate = float(q(":ACQuire:SRATe?"))
    print(f"  srate = {srate:.3e}")
    print(f"  vmin = {q(f':MEASure:VMIN? CHANnel{ch}')} V")
    print(f"  vmax = {q(f':MEASure:VMAX? CHANnel{ch}')} V")
    print(f"  vpp  = {q(f':MEASure:VPP?  CHANnel{ch}')} V")
    print(f"  vtop = {q(f':MEASure:VTOP? CHANnel{ch}')} V")
    print(f"  vbase= {q(f':MEASure:VBASe? CHANnel{ch}')} V")
    print(f"  rise = {q(f':MEASure:RTIMe? CHANnel{ch}')} s")
    print(f"  fall = {q(f':MEASure:FTIMe? CHANnel{ch}')} s")
    print(f"  duty = {q(f':MEASure:PDUTy? CHANnel{ch}')}")
    print(f"  freq = {q(f':MEASure:FREQuency? CHANnel{ch}')} Hz")
    print(f"  over_shoot = {q(f':MEASure:OVERshoot? CHANnel{ch}')}")
    print(f"  pre_shoot  = {q(f':MEASure:PREShoot?  CHANnel{ch}')}")
    s.close()


if __name__ == "__main__":
    main()
