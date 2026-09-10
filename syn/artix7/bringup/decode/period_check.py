#!/usr/bin/env python3
"""period_check — test whether the ETM byte stream is strictly periodic.

Rationale (no decode, no golden, no spec): interrupts are masked (PRIMASK=1)
and the workload is a fixed data-independent loop (det_iter -> 8x node -> leaf),
so every det_iter() MUST emit an identical ETM byte sequence. Therefore the
ETM byte stream must be strictly periodic with some period T. If it is, the
capture + deframe are clean (the fixed loop round-trips byte-for-byte). If the
periodicity is broken (period drifts, or the period unit doesn't repeat byte-
exact), that break IS the corruption -- and where it breaks localises it,
independent of any decoder.

Method:
  1. deframe raw -> stream-2 ETM bytes (that's the only assumption; validated
     separately by the TPIU golden-pattern test).
  2. find candidate period T by autocorrelation (byte-equality score vs lag).
  3. at the best T, fold the stream into rows of length T and check how many
     columns are byte-identical across all rows == strict periodicity.
"""
import sys
import numpy as np

sys.path.insert(0, ".")
import opencsd_etm4_run as R

raw = open(sys.argv[1] if len(sys.argv) > 1 else
           "/media/vifextech/huge/hwtrace/captures/period.bin", "rb").read()
raw = raw[:4_000_000]
_, par, order, data, _, _, fs = R.recover_assemble(raw, stream=2)
etm, _ = R.T.deframe(data, want_stream=2)
etm = np.frombuffer(etm, dtype=np.uint8)
print(f"deframed ETM bytes={len(etm)} (parity={par} order={order} fsync={fs})")

# --- autocorrelation by byte-equality over a range of lags ---
# Use a window in the middle to avoid capture edges.
N = min(len(etm), 200000)
seg = etm[:N].astype(np.int16)
# search lags up to 20000 bytes (one det_iter is tens of KB at most)
maxlag = min(40000, N // 2)
best = []
# coarse scan step 1; equality fraction between seg[:-lag] and seg[lag:]
a = seg
scores = np.zeros(maxlag)
for lag in range(1, maxlag):
    m = N - lag
    scores[lag] = np.count_nonzero(a[:m] == a[lag:lag + m]) / m
# report top lags (ignore tiny lags < 8)
order_idx = np.argsort(-scores[8:]) + 8
print("top periodicity lags (byte-equality fraction at that shift):")
seen = 0
for lag in order_idx:
    if seen >= 10:
        break
    # skip near-duplicates of already-listed lags
    print(f"   lag={lag:6d}  match={scores[lag]*100:.2f}%")
    seen += 1

# --- fold at the single best lag and check column-wise constancy ---
T = int(order_idx[0])
print(f"\nbest period T={T} bytes")
rows = N // T
M = rows * T
grid = etm[:M].reshape(rows, T)
col_const = np.count_nonzero((grid == grid[0]).all(axis=0))
print(f"folded {rows} rows of {T} bytes; columns byte-identical across ALL "
      f"rows: {col_const}/{T} = {100*col_const/T:.1f}%")
# how many rows exactly equal the first row
row_eq = np.count_nonzero((grid == grid[0]).all(axis=1))
print(f"rows exactly equal to row 0: {row_eq}/{rows}")
