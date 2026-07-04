#!/usr/bin/env python3
"""period_find — find the loop period (in deframed-ETM bytes) by autocorrelation.

func_test's main_loop is deterministic, so the deframed ETM stream is periodic.
We find the period WITHOUT any decode: byte-equality autocorrelation over a
range of candidate lags; the lag that maximises the byte-match fraction (well
above the 1/256 chance floor) is the loop period. This is the prerequisite for
period_vote.py, which uses cross-iteration majority voting as a self-supplied
ground truth (no logic analyser needed).

Usage: period_find.py <fpga_raw.bin> [min_lag] [max_lag]
"""
import sys
import numpy as np
import etm35lib as L
import dsl_parse as D


def deframe_raw(raw):
    nibs = bytearray()
    for byte in raw:
        nibs.append((byte >> 4) & 0xF)
        nibs.append(byte & 0xF)
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
            if best is None or fl > best[0]:
                best = (fl, data)
    data = best[1]
    if L.has_tpiu_sync(data):
        data = L.tpiu_deframe_walk(data)
    return data


def main():
    raw = open(sys.argv[1], "rb").read()
    etm = deframe_raw(raw)
    a = np.frombuffer(etm, dtype=np.uint8)
    n = len(a)
    print(f"deframed ETM = {n} bytes")

    min_lag = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
    max_lag = int(sys.argv[3]) if len(sys.argv) > 3 else 40000

    # byte-equality match fraction at each lag, over a fixed comparison window
    win = min(400000, n - max_lag - 1)
    base = a[:win].astype(np.int16)
    best = []
    step = 1
    for lag in range(min_lag, max_lag, step):
        seg = a[lag:lag+win].astype(np.int16)
        match = np.count_nonzero(base == seg) / win
        best.append((match, lag))
    best.sort(reverse=True)
    print(f"chance floor ~= {1/256:.4f}")
    print("top lags by byte-match fraction:")
    for m, lag in best[:12]:
        print(f"  lag={lag:7d}  match={m:.4f}")


if __name__ == "__main__":
    main()
