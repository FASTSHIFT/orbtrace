"""perf_ts — extract FtraceEvent timestamps from a Perfetto trace (orbetto.perf)
to check whether the time axis is real or collapsed. Minimal protobuf walk:
Trace.packet(1) -> TracePacket.ftrace_events(11) -> FtraceEventBundle.event(2)
-> FtraceEvent.timestamp(1, varint ns)."""
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


def fields(b):
    i = 0
    n = len(b)
    while i < n:
        key, i = rv(b, i)
        fn = key >> 3
        wt = key & 7
        if wt == 0:
            v, i = rv(b, i)
            yield fn, wt, v
        elif wt == 2:
            ln, i = rv(b, i)
            yield fn, wt, b[i:i + ln]
            i += ln
        elif wt == 5:
            yield fn, wt, b[i:i + 4]
            i += 4
        elif wt == 1:
            yield fn, wt, b[i:i + 8]
            i += 8
        else:
            break


ts = []
for fn, wt, val in fields(data):
    if fn == 1 and wt == 2:
        for pfn, pwt, pval in fields(val):
            if pfn == 11 and pwt == 2:
                for bfn, bwt, bval in fields(pval):
                    if bfn == 2 and bwt == 2:
                        for efn, ewt, ev in fields(bval):
                            if efn == 1 and ewt == 0:
                                ts.append(ev)

print("events with timestamp:", len(ts))
if ts:
    span = max(ts) - min(ts)
    print("min ns:", min(ts), " max ns:", max(ts))
    print("span ns:", span, f"({span/1e9:.6f} s)")
    print("nonzero ts:", len([t for t in ts if t != 0]), "/", len(ts))
    print("distinct ts values:", len(set(ts)))
    print("top 5 ts:", collections.Counter(ts).most_common(5))
