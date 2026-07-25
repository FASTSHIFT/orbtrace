#!/usr/bin/env python3
"""synth_stream_timebase — write a synthetic .ts.json for a streaming capture.

The one-shot BRAM path snapshots a free-running ref_200m tick every 256 captured
bytes and hands the PC the resulting table -- accurate wall-clock, tolerates
TRACECLK idle gaps. The streaming path doesn't have that (bytes flow straight
into the async FIFO and out over UDP), but for a saturated capture the byte rate
IS the trace-clock rate: 1 cap_byte per TRACECLK period. So a purely linear
timebase (t = byte_index * period_ns) reconstructs the wall-clock exactly
whenever the port is fed continuously, which is our regime.

Caveat: any TRACECLK idle in the middle of the capture is missed -- the linear
model attributes those bytes real elapsed time. In practice at 300 MHz sysclk
running CoreMark with BB=0 there is no idle window long enough to matter, but
it's why we prefer the one-shot's real timebase when both fit.

Usage:
  python3 synth_stream_timebase.py <cap.bin> [--traceclk-mhz 100]
"""
import argparse
import json
import os
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cap")
    ap.add_argument("--traceclk-mhz", type=float, default=100.0,
                    help="TRACECLK frequency (100 MHz for our 300 MHz sysclk build)")
    ap.add_argument("--stride", type=int, default=256,
                    help="snapshots every N cap bytes (mirrors the one-shot path)")
    a = ap.parse_args()

    n_bytes = os.path.getsize(a.cap)
    period_ns = 1000.0 / a.traceclk_mhz             # 10 ns @ 100 MHz
    tick_ns = 5.0                                    # ref_200m tick (5 ns)
    ticks_per_stride = int(round(a.stride * period_ns / tick_ns))

    n_snap = n_bytes // a.stride + 1
    ticks = [k * ticks_per_stride for k in range(n_snap)]
    last_tick = int(round(n_bytes * period_ns / tick_ns))

    out = a.cap + ".ts.json"
    with open(out, "w") as f:
        json.dump({
            "stride":   a.stride,
            "n":        n_snap,
            "tick_ns":  tick_ns,
            "last_tick": last_tick,
            "ticks":    ticks,
            "skip":     0,
            "depth":    n_bytes,
        }, f)
    print(f"wrote {out}: {n_snap} snapshots, span "
          f"{last_tick * tick_ns / 1e6:.1f} ms for {n_bytes/1e6:.1f} MB")


if __name__ == "__main__":
    sys.exit(main())
