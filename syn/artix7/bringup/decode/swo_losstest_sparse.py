#!/usr/bin/env python3
"""swo_losstest_sparse — r19 Q3's real danger zone: packet loss on a SPARSE-SYNC
stream (high baud). At high baud the TPIU full-sync period (time-fixed) spans
far more bytes, so after a dropped packet orbuculum may wait a long time for the
next sync to re-lock. Simulate by stripping most full-syncs from the stream,
then apply loss, and compare anchor recovery vs the sync-dense case.

Usage: swo_losstest_sparse.py [raw.bin]
"""
import sys
import re

sys.path.insert(0, "decode")
sys.path.insert(0, ".")
from swo_losstest import hole, run_once
import etm35lib as L

RAW = sys.argv[1] if len(sys.argv) > 1 else "/tmp/raw.bin"
SIG = bytes([0xFF, 0xFF, 0xFF, 0x7F])


def make_sparse(data, keep_every):
    """Concatenate the data and remove all but every `keep_every`-th full-sync,
    to emulate a high-baud stream where syncs are far apart in bytes."""
    # tile to a longer stream first so removing syncs leaves long gaps
    big = data * 6
    out = bytearray(big)
    # find syncs, blank out (replace with a benign data byte) all but kept ones
    pos = [m.start() for m in re.finditer(re.escape(SIG), bytes(big))]
    removed = 0
    for k, p in enumerate(pos):
        if k % keep_every != 0:
            out[p:p + 4] = b"\x00\x00\x00\x00"   # destroy this sync
            removed += 1
    return bytes(out), len(pos), len(pos) - removed


def main():
    data = open(RAW, "rb").read()
    print(f"{'variant':>22} {'syncs':>6} {'loss%':>6} {'anchors':>8} {'distinctPC':>10}")
    # dense (all syncs kept), tiled
    for keep, name in [(1, "dense(all syncs)"), (8, "sparse(1/8 syncs)"),
                       (9999, "very-sparse(1 sync)")]:
        sparse, total, kept = make_sparse(data, keep)
        for loss in (0.0, 0.10):
            holed = hole(sparse, loss)
            res = run_once(holed, port=5562)
            if res is None:
                print(f"{name:>22} {kept:6d} {loss*100:5.0f}%   link failed")
                continue
            _, anch, pcs = res
            print(f"{name:>22} {kept:6d} {loss*100:5.0f}% {anch:8d} {pcs:10d}")


if __name__ == "__main__":
    main()
