#!/usr/bin/env python3
"""perfproto — shared Perfetto `.perf` (protobuf wire-format) reader.

Several decode-side tools (anomaly, perf_dump_tree, diag_deepstack, exc_audit,
verify_functest, ...) each re-implemented the same minimal protobuf varint
reader + a walk that digs Trace.packet -> ftrace_events bundle -> FtraceEvent ->
the "B|0|name" / "E|0" / "I|..." print buffer. This module is the single copy.

Public API:
  read_varint(buf, i)      -> (value, next_index)     [alias: rv]
  parse_fields(buf)        -> list[(field_no, wire_type, value)]   [alias: parse]
  iter_ftrace_prints(data) -> list[(ts_ns, pid, buf_str)]
        every ftrace print slice in stream order (UNSORTED); buf_str is the
        decoded "B|..|name" / "E|.." / "I|.." payload. Callers sort/filter.
  load_ftrace_prints(path) -> same, sorted by timestamp.
"""
from __future__ import annotations


def read_varint(buf, i):
    shift = result = 0
    while True:
        x = buf[i]
        i += 1
        result |= (x & 0x7F) << shift
        if not x & 0x80:
            break
        shift += 7
    return result, i


def parse_fields(buf):
    out = []
    i = 0
    n = len(buf)
    while i < n:
        try:
            key, i = read_varint(buf, i)
        except IndexError:
            break
        fn = key >> 3
        wt = key & 7
        if wt == 0:
            v, i = read_varint(buf, i)
            out.append((fn, wt, v))
        elif wt == 2:
            ln, i = read_varint(buf, i)
            out.append((fn, wt, buf[i:i + ln]))
            i += ln
        elif wt == 5:
            out.append((fn, wt, buf[i:i + 4]))
            i += 4
        elif wt == 1:
            out.append((fn, wt, buf[i:i + 8]))
            i += 8
        else:
            break
    return out


# Back-compat short aliases matching the original inlined names.
rv = read_varint
parse = parse_fields


def iter_ftrace_prints(data):
    """Walk a Perfetto trace blob and yield (ts_ns, pid, buf_str) for every
    ftrace print event (B|/E|/I| payload), in stream order (not sorted)."""
    events = []
    for fn, wt, v in parse_fields(data):
        if fn != 1 or wt != 2:                       # Trace.packet
            continue
        for pfn, pwt, pv in parse_fields(v):
            if pfn != 1 or pwt != 2:                 # ftrace_events bundle
                continue
            for bfn, bwt, bv in parse_fields(pv):
                if bfn != 2 or bwt != 2:             # FtraceEvent
                    continue
                ts = pid = buf = None
                for efn, ewt, evv in parse_fields(bv):
                    if efn == 1 and ewt == 0:
                        ts = evv
                    elif ewt == 0 and pid is None and efn in (2, 3, 4):
                        pid = evv
                    elif ewt == 2 and isinstance(evv, (bytes, bytearray)):
                        for sfn, swt, sv in parse_fields(evv):
                            if swt == 2 and isinstance(sv, (bytes, bytearray)):
                                s = bytes(sv)
                                if s[:2] in (b"B|", b"E|", b"I|"):
                                    buf = s
                if buf is not None and ts is not None:
                    events.append((ts, pid, buf.decode("latin1", "replace")))
    return events


def load_ftrace_prints(path):
    """Read a .perf file and return ftrace prints sorted by timestamp."""
    with open(path, "rb") as f:
        data = f.read()
    events = iter_ftrace_prints(data)
    events.sort(key=lambda x: x[0])
    return events
