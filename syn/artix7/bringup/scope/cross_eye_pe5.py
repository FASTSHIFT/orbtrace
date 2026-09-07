#!/usr/bin/env python3
"""cross_eye_pe5 — analog cross-eye of one TRACED lane vs TRACECLK.

Setup: CH1 = TRACECLK, CH2 = the data lane under test (here PE5 / TRACED2,
the lane doc 25 fingered as the 100%-bit6-recoverable single-lane fault).

What it answers: is the RAW analog eye on this lane actually open at the moment
the FPGA IDDR samples it? The FPGA samples on the TRACECLK edge (IDDR), so we:
  1. capture both channels at high sample rate (analog, real volts)
  2. find TRACECLK edges (CH1)
  3. fold CH2 into a UI-normalised eye around each clock edge
  4. report: V high/low, rise/fall time, overshoot, and — crucially — the
     CH2 level spread AT the clock-edge instant (the sampling point). A wide
     spread there = the bit is ambiguous when latched = the corruption source.

Pure measurement, no correction. Uses scope_visa (pyvisa).

Usage:
    cross_eye_pe5.py [timebase_s_per_div=5e-9] [--save prefix]
"""
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from scope_visa import Scope


def read_analog(s, src, q, maxpts=1_000_000):
    """Read an analog channel as float volts, plus x-increment (s/sample)."""
    s.w(f":WAVeform:SOURce {src}")
    s.w(":WAVeform:MODE RAW")
    s.w(":WAVeform:FORMat BYTE")
    yinc = float(q(":WAVeform:YINCrement?"))
    yorig = float(q(":WAVeform:YORigin?"))
    yref = float(q(":WAVeform:YREFerence?"))
    xinc = float(q(":WAVeform:XINCrement?"))
    avail = int(float(q(":WAVeform:POINts?")))
    m = min(avail, maxpts)
    raw = bytearray()
    start, CH = 1, 1_000_000
    while start <= m:
        stop = min(start + CH - 1, m)
        s.w(f":WAVeform:STARt {start}")
        s.w(f":WAVeform:STOP {stop}")
        raw.extend(s.read_block(":WAVeform:DATA?", timeout_ms=60000))
        start = stop + 1
    volts = [((b - yref) * yinc - yorig) if False else ((b - yorig - yref) * yinc)
             for b in raw]
    # RIGOL byte->volt: V = (raw - YORigin - YREFerence) * YINCrement
    return volts, xinc


def find_edges(v, thr, hyst):
    """Schmitt edge detect: returns (index, +1/-1). hyst is half-window."""
    hi = thr + hyst
    lo = thr - hyst
    st = 1 if v[0] > thr else 0
    e = []
    for i in range(1, len(v)):
        if st == 0 and v[i] > hi:
            st = 1
            e.append((i, +1))
        elif st == 1 and v[i] < lo:
            st = 0
            e.append((i, -1))
    return e


def pct(vals, p):
    if not vals:
        return 0.0
    xs = sorted(vals)
    k = max(0, min(len(xs) - 1, int(p / 100.0 * (len(xs) - 1))))
    return xs[k]


def analyze(timebase="5e-9", save=None):
    s = Scope(timeout_ms=10000)

    def q(c, t=8000):
        return s.q(c, t)

    # analog CH1=CLK, CH2=PE5. Assume the user set probe/coupling; we only set
    # timebase + trigger on CH1 so both channels share the same window.
    s.w(":CHANnel1:DISPlay ON")
    s.w(":CHANnel2:DISPlay ON")
    s.w(f":TIMebase:MAIN:SCALe {timebase}")
    s.w(":TRIGger:MODE EDGE")
    s.w(":TRIGger:EDGE:SOURce CHANnel1")
    s.w(":TRIGger:EDGE:SLOPe POSitive")
    s.w(":TRIGger:SWEep AUTO")
    s.w(":RUN")
    time.sleep(0.6)
    s.w(":STOP")
    time.sleep(0.4)

    srate = float(q(":ACQuire:SRATe?"))
    print(f"scope srate(reported) = {srate:.3e} S/s  timebase={timebase} s/div")

    clk, xinc = read_analog(s, "CHANnel1", q)
    pe5, _ = read_analog(s, "CHANnel2", q)
    s.close()
    n = min(len(clk), len(pe5))
    clk, pe5 = clk[:n], pe5[:n]
    print(f"samples={n}  xinc={xinc:.3e}s ({1/xinc:.3e} S/s effective)")

    # ---- CH2 (PE5) levels ----
    v01 = pct(pe5, 1); v99 = pct(pe5, 99)
    vlo = pct(pe5, 10); vhi = pct(pe5, 90)
    swing = v99 - v01
    thr2 = 0.5 * (v01 + v99)
    print(f"\nPE5 (CH2) levels:")
    print(f"  V(1%%)={v01:.3f}  V(99%%)={v99:.3f}  swing={swing:.3f} V")
    print(f"  V(10%%)={vlo:.3f}  V(90%%)={vhi:.3f}  mid-thr={thr2:.3f} V")

    # ---- CLK edges ----
    c01 = pct(clk, 1); c99 = pct(clk, 99)
    cthr = 0.5 * (c01 + c99)
    chyst = 0.1 * (c99 - c01)
    cedges = find_edges(clk, cthr, chyst)
    if len(cedges) < 8:
        print(f"\n!! only {len(cedges)} CLK edges found; is CH1 on TRACECLK and "
              f"the STM32 emitting? (swing {c99-c01:.3f} V)")
        return
    # UI = median spacing between consecutive edges (half-period, DDR)
    spac = sorted(cedges[i+1][0] - cedges[i][0] for i in range(len(cedges)-1))
    half_ui = spac[len(spac)//2]
    ui_ns = half_ui * xinc * 1e9
    print(f"\nCLK: {len(cedges)} edges  half-UI={half_ui} samp = {ui_ns:.2f} ns"
          f"  (=> {1e3/(2*ui_ns):.1f} MHz pin, {1e3/ui_ns:.1f} MHz bit)")

    # ---- PE5 edge rise/fall time (10-90%) ----
    p2thr = thr2
    p2hyst = 0.15 * swing
    pedges = find_edges(pe5, p2thr, p2hyst)
    print(f"PE5: {len(pedges)} edges "
          f"({sum(1 for _,d in pedges if d>0)} rise / "
          f"{sum(1 for _,d in pedges if d<0)} fall)")

    def transition_time(idx, direction):
        # walk out from the threshold crossing to 10%/90% levels
        lo_l = v01 + 0.1 * swing
        hi_l = v01 + 0.9 * swing
        i = idx
        if direction > 0:
            a = i
            while a > 0 and pe5[a] > lo_l: a -= 1
            b = i
            while b < len(pe5)-1 and pe5[b] < hi_l: b += 1
        else:
            a = i
            while a > 0 and pe5[a] < hi_l: a -= 1
            b = i
            while b < len(pe5)-1 and pe5[b] > lo_l: b += 1
        return abs(b - a) * xinc * 1e9
    rt = [transition_time(i, d) for i, d in pedges if d > 0]
    ft = [transition_time(i, d) for i, d in pedges if d < 0]
    if rt: print(f"  rise 10-90%%: med={sorted(rt)[len(rt)//2]:.2f} ns "
                 f"max={max(rt):.2f} ns")
    if ft: print(f"  fall 90-10%%: med={sorted(ft)[len(ft)//2]:.2f} ns "
                 f"max={max(ft):.2f} ns")

    # ---- the money metric: PE5 level AT the clock-edge sampling instant ----
    # The IDDR samples on BOTH clock edges. Gather PE5 volts at each clock edge
    # index; separate by whether PE5 is nominally high or low there, and look
    # at how close the sampled value sits to the mid threshold (ambiguous).
    at_edge = [pe5[i] for i, _ in cedges if 0 <= i < len(pe5)]
    highs = [v for v in at_edge if v > thr2]
    lows = [v for v in at_edge if v <= thr2]
    # margin = distance from mid threshold, normalised to half-swing
    def margin(vs, ref_hi):
        if not vs: return (0, 0)
        ms = [abs(v - thr2) / (0.5 * swing) for v in vs]
        return (sum(ms)/len(ms), min(ms))
    mh, mh_min = margin(highs, True)
    ml, ml_min = margin(lows, False)
    # count "ambiguous" samples: within 20% of half-swing of the threshold
    amb = sum(1 for v in at_edge if abs(v - thr2) < 0.2 * 0.5 * swing)
    print(f"\n*** PE5 level AT the {len(at_edge)} CLK-edge sampling instants ***")
    print(f"  high samples: {len(highs)}  mean-margin={mh:.2f} (min {mh_min:.2f}) of half-swing")
    print(f"  low  samples: {len(lows)}  mean-margin={ml:.2f} (min {ml_min:.2f}) of half-swing")
    print(f"  AMBIGUOUS (|v-thr| < 20%% half-swing): {amb}/{len(at_edge)} "
          f"= {100.0*amb/max(1,len(at_edge)):.1f}%%")

    # ---- verdict ----
    print("\nverdict:")
    ui_edge_frac = (sorted(rt+ft)[len(rt+ft)//2] / ui_ns) if (rt or ft) else 0
    print(f"  edge (rise/fall) eats ~{100*ui_edge_frac:.0f}%% of the {ui_ns:.2f} ns half-UI")
    if amb > 0.02 * len(at_edge):
        print(f"  FAIL: {100.0*amb/len(at_edge):.1f}%% of sampling instants land in the")
        print(f"        ambiguous band -> the IDDR latches a coin-flip on those "
              f"=> exactly the single-lane corruption doc 25 measured.")
    else:
        print(f"  eye at the sampling instant looks open (<2%% ambiguous); if the")
        print(f"  decoder still errors, suspect clock-edge PLACEMENT not this lane.")

    if save:
        import struct
        for nm, sig in [("clk", clk), ("pe5", pe5)]:
            p = f"{save}_{nm}.f32"
            with open(p, "wb") as f:
                f.write(struct.pack(f"<{len(sig)}f", *sig))
            print(f"  saved {p} ({len(sig)} samples, xinc={xinc:.3e})")


if __name__ == "__main__":
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    save = None
    if "--save" in sys.argv:
        i = sys.argv.index("--save")
        save = sys.argv[i+1] if i+1 < len(sys.argv) else "cross_eye_pe5"
    kw = {}
    if len(a) > 0: kw["timebase"] = a[0]
    kw["save"] = save
    analyze(**kw)
