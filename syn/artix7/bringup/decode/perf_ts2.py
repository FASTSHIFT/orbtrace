"""perf_ts2 — recursively walk a Perfetto protobuf trace and collect every
FtraceEvent.timestamp. We don't hard-code the nesting; instead we recurse into
every length-delimited field that parses cleanly as a submessage, and whenever
we are inside a message that looks like an FtraceEvent (has field 1 varint =
timestamp AND some known event submessage), record field 1.

Simpler heuristic actually used: collect ALL varints at field-number 1 that sit
directly beside a field-number 'pid' (3) or a print(6) — i.e. FtraceEvent. To
stay robust we just gather field-1 varints from any submessage that ALSO
contains field 3 (pid) as varint. Returns stats on those timestamps.
"""
import sys
import collections

data = open(sys.argv[1], 'rb').read()


def rv(b, i):
    s = 0
    r = 0
    while True:
        x = b[i]
        i += 1
        r |= (x & 0x7f) << s
        if not (x & 0x80):
            break
        s += 7
    return r, i


def parse(b):
    """return list of (field_num, wire_type, value) ; value is int or bytes."""
    out = []
    i = 0
    n = len(b)
    while i < n:
        try:
            key, i = rv(b, i)
        except IndexError:
            break
        fn = key >> 3
        wt = key & 7
        if wt == 0:
            v, i = rv(b, i)
            out.append((fn, wt, v))
        elif wt == 2:
            ln, i = rv(b, i)
            if i + ln > n:
                break
            out.append((fn, wt, b[i:i + ln]))
            i += ln
        elif wt == 5:
            out.append((fn, wt, b[i:i + 4]))
            i += 4
        elif wt == 1:
            out.append((fn, wt, b[i:i + 8]))
            i += 8
        else:
            break
    return out


timestamps = []


def looks_msg(bs):
    if len(bs) < 2:
        return False
    try:
        f = parse(bs)
        return len(f) > 0
    except Exception:
        return False


def walk(b, depth=0):
    flds = parse(b)
    # is this an FtraceEvent? has field1 varint (timestamp) + field3 varint (pid)
    has_ts = any(fn == 1 and wt == 0 for fn, wt, _ in flds)
    has_pid = any(fn == 3 and wt == 0 for fn, wt, _ in flds)
    if has_ts and has_pid:
        for fn, wt, v in flds:
            if fn == 1 and wt == 0:
                timestamps.append(v)
    if depth > 8:
        return
    for fn, wt, v in flds:
        if wt == 2 and isinstance(v, (bytes, bytearray)) and looks_msg(v):
            walk(v, depth + 1)


walk(data)
print("FtraceEvent timestamps found:", len(timestamps))
if timestamps:
    ts = timestamps
    span = max(ts) - min(ts)
    print("min ns:", min(ts), "max ns:", max(ts))
    print("span ns:", span, f"({span/1e9:.6f} s)")
    print("nonzero:", len([t for t in ts if t]), "/", len(ts))
    print("distinct values:", len(set(ts)))
    print("top 5:", collections.Counter(ts).most_common(5))
