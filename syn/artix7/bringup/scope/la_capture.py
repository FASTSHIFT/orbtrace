#!/usr/bin/env python3
"""Capture the TRACE parallel port with the MSO8304A logic analyzer and build a
CAP_RAW-format byte stream identical to what the FPGA stores, for cross-check.

Wiring (ST side of the 47R series R, i.e. the source):
    D0 = TRACECK   D1 = TRACED0   D2 = TRACED1   D3 = TRACED2   D4 = TRACED3

Key gotchas learned the hard way:
  * Each digital line is read via its OWN :WAVeform:SOURce Dn, and the level is
    in BIT0 of every returned byte (NOT packed bit0=D0,bit1=D1 in one source).
  * :ACQuire:MDEPth must be set while RUNNING; setting it while stopped is
    silently ignored.
  * RAW waveform read requires :STOP first.

CAP_RAW format (matches rtl/trace_stream_top.v, CAP_RAW=1):
    one byte per TRACECLK period = {trace_b[3:0], trace_a[3:0]}
    trace_a = TRACED nibble sampled on the RISING edge  (low nibble)
    trace_b = TRACED nibble sampled on the FALLING edge (high nibble)
The empirically-correct scope reconstruction is: pair consecutive edges
starting at the first FALLING->RISING boundary (start parity 1), nibble order
{falling<<4 | rising}, no bit reversal (see scope_fpga_diff.py which searches
these if a board/probe change invalidates it).

Usage:
    python3 la_capture.py [timebase_s_per_div] [mdepth] [out.bin] [maxpts]
    e.g. python3 la_capture.py 1e-5 10M /tmp/scope_capraw.bin 4000000
Output: CAP_RAW .bin (feed to opencsd_etm4_run.py / trace_width.py just like an
FPGA capture) + prints a deframe self-check.
"""
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, "..", "decode"))
from scope_visa import Scope

TRACECLK_HZ = 112.5e6  # nominal; only used to pick a mid-eye sample offset


def read_line(s, src, n, q):
    s.w(f":WAVeform:SOURce {src}")
    s.w(":WAVeform:MODE RAW")
    s.w(":WAVeform:FORMat BYTE")
    avail = int(float(q(":WAVeform:POINts?")))
    m = min(avail, n)
    out = []
    start, CH = 1, 1_000_000
    while start <= m:
        stop = min(start + CH - 1, m)
        s.w(f":WAVeform:STARt {start}")
        s.w(f":WAVeform:STOP {stop}")
        out.extend(b & 1 for b in s.read_block(":WAVeform:DATA?", timeout_ms=60000))
        start = stop + 1
    return out, avail


def capture(timebase="1e-5", mdepth="10M", out="/tmp/scope_capraw.bin",
            maxpts=4_000_000):
    s = Scope(timeout_ms=10000)

    def q(c, t=8000):
        try:
            return s.q(c, t)
        except Exception as e:
            return f"ERR {e!r}"

    s.w(":LA:STATe ON")
    s.w(":LA:POD1:THReshold 1.65")            # 3.3V IO decision point
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
    s.w(f":ACQuire:MDEPth {mdepth}")          # MUST be while running
    time.sleep(1.2)
    s.w(":STOP")
    time.sleep(0.5)

    srate = float(q(":ACQuire:SRATe?"))
    spp = srate / TRACECLK_HZ
    off = max(1, int(spp * 0.25))             # sample ~1/4 period after edge
    print(f"srate={srate:.3e} mdepth={q(':ACQuire:MDEPth?')} ~{spp:.1f} samp/period",
          flush=True)

    clk, avail = read_line(s, "D0", maxpts, q)
    d0, _ = read_line(s, "D1", maxpts, q)
    d1, _ = read_line(s, "D2", maxpts, q)
    d2, _ = read_line(s, "D3", maxpts, q)
    d3, _ = read_line(s, "D4", maxpts, q)
    n = min(len(clk), len(d0), len(d1), len(d2), len(d3))
    print(f"points_available={avail} aligned={n}", flush=True)

    def nib(i):
        return (d3[i] << 3) | (d2[i] << 2) | (d1[i] << 1) | d0[i]

    raw = bytearray()
    rising = None
    for i in range(1, n):
        if clk[i - 1] == 0 and clk[i] == 1:            # rising
            j = min(i + off, n - 1)
            rising = nib(j)
        elif clk[i - 1] == 1 and clk[i] == 0 and rising is not None:  # falling
            j = min(i + off, n - 1)
            raw.append((nib(j) << 4) | rising)         # {trace_b, trace_a}
            rising = None
    open(out, "wb").write(raw)
    print(f"CAP_RAW bytes={len(raw)} -> {out}", flush=True)

    # deframe self-check
    try:
        import trace_width as TW, etm35lib as L, tpiu_official as T
        best = None
        for ph, bo, data in TW.candidates(bytes(raw), 4):
            fsync = data.count(bytes([0xFF, 0xFF, 0xFF, 0x7F]))
            etm = b""
            if L.has_tpiu_sync(data):
                etm, _ = T.deframe(data, want_stream=2)
            a = zc = 0
            for c in etm:
                if c == 0:
                    zc += 1
                elif c == 0x80 and zc >= 11:
                    a += 1; zc = 0
                else:
                    zc = 0
            key = (a, len(etm), fsync)
            if best is None or key > best[0]:
                best = (key, ph, bo)
        print(f"deframe best: phase={best[1]} order={best[2]} "
              f"(A-sync,deframed,fsync)={best[0]}", flush=True)
    except Exception as e:
        print("deframe self-check skipped:", e, flush=True)
    s.close()
    return out


if __name__ == "__main__":
    a = sys.argv[1:]
    capture(*(a + [])[:4]) if a else capture()
