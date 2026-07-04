#!/usr/bin/env python3
"""period_vote — self-supervised channel error rate via cross-iteration majority
voting on a deterministic program, NO logic analyser required.

Idea: func_test (SysTick disabled) emits a byte-exact periodic trace. Using the
correct nibble->byte alignment (max HSYNC), we:
  1. find the loop period P by autocorrelation on the aligned byte stream,
  2. fold the stream into rows of length P,
  3. at each column take the majority byte = the program's true byte,
  4. error rate = fraction of cells deviating from their column majority.

This isolates ENVIRONMENT B (sampling correctness): the program guarantees the
true repeating content, so deviations are channel/sampling bit errors. Reported
per nibble half (rising a vs falling b) and per data lane to localise skew.

Usage: period_vote.py <fpga_raw.bin> [min_lag] [max_lag]
"""
import sys
import numpy as np
from nibble_align import best_align


def aligned_bytes(raw):
    _h, ph, order, ab = best_align(raw)
    return ab, ph, order


def find_period(a, min_lag, max_lag):
    win = min(300000, len(a) - max_lag - 1)
    base = a[:win].astype(np.int16)
    best = (-1, 0)
    for lag in range(min_lag, max_lag):
        seg = a[lag:lag+win].astype(np.int16)
        m = np.count_nonzero(base == seg)
        if m > best[0]:
            best = (m, lag)
    return best[1], best[0] / win


def main():
    raw = open(sys.argv[1], "rb").read()
    ab, ph, order = aligned_bytes(raw)
    a = np.frombuffer(ab, dtype=np.uint8)
    print(f"{sys.argv[1]}: aligned bytes={len(a)} (nibble phase={ph} order={order})")

    min_lag = int(sys.argv[2]) if len(sys.argv) > 2 else 50
    max_lag = int(sys.argv[3]) if len(sys.argv) > 3 else 8000
    P, frac = find_period(a, min_lag, max_lag)
    print(f"loop period P={P} bytes  (autocorr match={frac:.4f})")
    if P <= 0:
        return

    # fold into rows of length P
    nrows = len(a) // P
    M = a[:nrows*P].reshape(nrows, P)
    print(f"folded {nrows} iterations x {P} bytes")

    # column majority via bincount
    maj = np.zeros(P, dtype=np.uint8)
    for col in range(P):
        maj[col] = np.bincount(M[:, col], minlength=256).argmax()

    # error = cells deviating from column majority
    dev = M != maj[None, :]
    total = M.size
    errs = int(dev.sum())
    print(f"\ncross-iteration byte error rate = {errs}/{total} "
          f"= {100*errs/total:.4f}%")

    # per-column error rate distribution (how many columns are clean)
    col_err = dev.mean(axis=0)
    clean_cols = int((col_err == 0).sum())
    print(f"clean columns (0 errors across all iters): {clean_cols}/{P} "
          f"({100*clean_cols/P:.1f}%)")
    print(f"worst columns (col: err_rate):")
    worst = np.argsort(col_err)[::-1][:10]
    for c in worst:
        print(f"  col {c}: {100*col_err[c]:.2f}%  majority=0x{maj[c]:02x}")

    # per-nibble-half error: even byte index in original time order = ?
    # Each aligned byte = {hi_nibble, lo_nibble}. Split error by which nibble
    # differs from majority to localise rising(a) vs falling(b) half.
    hi_err = ((M >> 4) != (maj[None, :] >> 4)) & dev
    lo_err = ((M & 0xF) != (maj[None, :] & 0xF)) & dev
    print(f"\nhigh-nibble errors: {int(hi_err.sum())}  "
          f"low-nibble errors: {int(lo_err.sum())}")

    # per data-lane (bit) error: XOR majority, count bit flips per lane
    xor = M ^ maj[None, :]
    print("per-bit(lane) flip counts [bit0..bit7]:")
    counts = [int(((xor >> b) & 1).sum()) for b in range(8)]
    for b in range(8):
        print(f"  bit{b}: {counts[b]} ({100*counts[b]/total:.4f}%)")


if __name__ == "__main__":
    main()
