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

    # Time-ordered edge nibbles (rising and falling), record edge type + nibble.
    # We defer pairing to the search below because which edge starts a byte
    # depends on where the trigger landed in the TRACECLK cycle.
    edges = []  # list of (edge_type, nibble); edge_type: 1=rising 0=falling
    for i in range(1, n):
        if clk[i - 1] == 0 and clk[i] == 1:
            j = min(i + off, n - 1); edges.append((1, nib(j)))
        elif clk[i - 1] == 1 and clk[i] == 0:
            j = min(i + off, n - 1); edges.append((0, nib(j)))
    print(f"edges captured: {len(edges)}", flush=True)

    # Search 4 pairing options: start parity {0,1} x swap {0,1}. rev is not
    # useful in practice (lanes are always LSB-first on this board), so we
    # skip it -- add it back if a board change ever requires bit-reversal.
    def build(start, swap):
        nseq = [n for _, n in edges][start:]
        out_ = bytearray()
        for k in range(0, len(nseq) - 1, 2):
            a, b = nseq[k], nseq[k + 1]
            out_.append((a << 4) | b if swap else (b << 4) | a)
        return bytes(out_)

    import trace_width as TW, etm35lib as L, tpiu_official as T
    def score(data):
        fsync = data.count(bytes([0xFF, 0xFF, 0xFF, 0x7F]))
        etm = b""
        if L.has_tpiu_sync(data):
            try:
                etm, _ = T.deframe(data, want_stream=2)
            except Exception:
                etm = b""
        a = zc = 0
        for c in etm:
            if c == 0: zc += 1
            elif c == 0x80 and zc >= 11: a += 1; zc = 0
            else: zc = 0
        return (a, len(etm), fsync)

    best = None
    for start in (0, 1):
        for swap in (0, 1):
            data = build(start, swap)
            sc = score(data)
            print(f"  try start={start} swap={swap}: bytes={len(data)} "
                  f"(A-sync,deframed,fsync)={sc}", flush=True)
            if best is None or sc > best[0]:
                best = (sc, start, swap, data)
    raw = best[3]
    open(out, "wb").write(raw)
    print(f"CAP_RAW bytes={len(raw)} start={best[1]} swap={best[2]} "
          f"(A-sync,deframed,fsync)={best[0]} -> {out}", flush=True)
    s.close()
    return out


if __name__ == "__main__":
    a = sys.argv[1:]
    kw = {}
    if len(a) > 0: kw["timebase"] = a[0]
    if len(a) > 1: kw["mdepth"] = a[1]
    if len(a) > 2: kw["out"] = a[2]
    if len(a) > 3: kw["maxpts"] = int(a[3])
    capture(**kw)
