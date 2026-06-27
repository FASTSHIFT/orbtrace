#!/usr/bin/env python3
"""mmcm_stream_timeline — anchor-level function timeline (Perfetto/Chrome JSON)
straight from a streamed MMCM capture, with a uniform FPGA wall-clock.

Reliable by construction: uses only I-sync ANCHORS (absolute PC + byte offset),
which are ground truth (doc 14 §14). Each anchor -> (function, wall-clock ns).
The uniform time base is exact for the streaming top (1 byte per TRACECLK
period at constant rate). Emits:
  - <out>.etm        : clean ETM bytes
  - <out>.time.json  : {times_ns:[...]} per ETM byte (what etm_to_perfetto wants)
then calls etm_to_perfetto.build_stack_events to produce <out>.json.

This is NOT full per-instruction nesting (that needs Mortrall return-stack work,
doc 14 §11); it is a trustworthy function-change timeline anchored at I-syncs.

Usage: mmcm_stream_timeline.py <stream.bin> <elf> <out_prefix> [--period-ns 47.6]
"""
import argparse
import json
import sys

import etm35lib as L
import dsl_parse as D
import etm_to_perfetto as P


def recover_assemble(raw):
    nibs = bytearray()
    for k in range(len(raw) - 1):
        nibs.append((raw[k] >> 4) & 0xF)
        nibs.append(raw[k + 1] & 0xF)
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
            if best is None or fl > best[0]:
                best = (fl, parity, order, data)
    return best[3], best[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("elf")
    ap.add_argument("out_prefix")
    ap.add_argument("--period-ns", type=float, default=47.6)
    a = ap.parse_args()

    raw = open(a.stream, "rb").read()
    data, parity = recover_assemble(raw)

    # deframe with per-ETM-byte source offset; ns = offset * period (uniform)
    if L.has_tpiu_sync(data):
        etm, offs = L.tpiu_deframe_walk_offsets(data, want_stream=2)
    else:
        etm = data
        offs = list(range(len(data)))
    times_ns = [int(round(o * a.period_ns)) for o in offs]

    open(a.out_prefix + ".etm", "wb").write(etm)
    json.dump({"times_ns": times_ns}, open(a.out_prefix + ".time.json", "w"))

    # build anchor-level function timeline (reuse etm_to_perfetto internals)
    starts, funcs = P.load_symbols(a.elf)
    isyncs = [s for s in L.find_isyncs(etm) if L.is_flash(s.addr)]
    if not isyncs:
        print("no flash I-sync anchors; abort")
        return 1
    anchors = []
    for s in isyncs:
        off = min(s.offset, len(times_ns) - 1)
        anchors.append((times_ns[off], s.addr & ~1))
    anchors.sort()
    named = [(t, P.func_for_pc(pc, starts, funcs)) for t, pc in anchors]

    # Two views:
    # (a) flat anchor timeline (RELIABLE): each anchor occupies [t, next_t) on a
    #     single track, labelled with its function. No nesting heuristic -> an
    #     honest "which function was running when" view (PC-sample style).
    # (b) nested call-stack (heuristic, best-effort): build_stack_events.
    flat = [
        {"name": "process_name", "ph": "M", "pid": 1, "tid": 1,
         "args": {"name": "LVGL ETM (FPGA wall-clock)"}},
        {"name": "thread_name", "ph": "M", "pid": 1, "tid": 1,
         "args": {"name": "function @ I-sync anchor"}},
    ]
    for i, (t, name) in enumerate(named):
        t_end = named[i + 1][0] if i + 1 < len(named) else times_ns[-1]
        if t_end <= t:
            t_end = t + int(a.period_ns)        # ensure non-zero duration
        flat.append({"name": name, "ph": "X", "pid": 1, "tid": 1,
                     "ts": t / 1000.0, "dur": (t_end - t) / 1000.0})
    out_flat = a.out_prefix + "_flat.json"
    json.dump({"traceEvents": flat, "displayTimeUnit": "ns"}, open(out_flat, "w"))

    events, calls = P.build_stack_events(named, times_ns[-1])
    out_json = a.out_prefix + ".json"
    json.dump({"traceEvents": events, "displayTimeUnit": "ns"}, open(out_json, "w"))

    span = anchors[-1][0] - anchors[0][0]
    from collections import Counter
    hist = Counter(n for _, n in named)
    print(f"parity={parity} ETM={len(etm)}B anchors={len(anchors)} "
          f"calls={calls} span={span/1e6:.3f}ms")
    print("top functions by anchor count:")
    for n, c in hist.most_common(12):
        print(f"  {c:6d}  {n}")
    print(f"wrote {out_json} (nested heuristic) + {out_flat} (flat anchors)")
    print(f"  -> drag either into https://ui.perfetto.dev")
    return 0


if __name__ == "__main__":
    sys.exit(main())
