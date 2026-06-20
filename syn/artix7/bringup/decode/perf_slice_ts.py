"""perf_slice_ts — extract ALL FtraceEvent timestamps from an orbetto Perfetto
trace, using the structure verified by pb_dump:
  Trace.packet(1) -> TracePacketBundle field1 = FtraceEventBundle
    -> FtraceEventBundle.event(2) = repeated FtraceEvent
      -> FtraceEvent.timestamp(1, varint)
Also pulls the print/funcgraph name where present for a sanity sample.

Usage: perf_slice_ts.py <perf>
"""
import sys
import collections

data = open(sys.argv[1], "rb").read()


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


ts = []
names = []
top = parse(data)
for fn, wt, v in top:                      # Trace.packet
    if fn != 1 or wt != 2:
        continue
    for pfn, pwt, pv in parse(v):          # TracePacket fields
        if pfn == 1 and pwt == 2:          # ftrace_events bundle
            for bfn, bwt, bv in parse(pv):
                if bfn == 2 and bwt == 2:  # FtraceEvent
                    ev = parse(bv)
                    t = None
                    for efn, ewt, evv in ev:
                        if efn == 1 and ewt == 0:
                            t = evv
                    if t is not None:
                        ts.append(t)
                    # sample a print buf (field 6 -> print, has field 2 buf)
                    for efn, ewt, evv in ev:
                        if ewt == 2 and isinstance(evv, (bytes, bytearray)):
                            for sfn, swt, sv in parse(evv):
                                if swt == 2 and isinstance(sv, (bytes, bytearray)):
                                    s = bytes(sv)
                                    if s[:2] in (b"B|", b"E|", b"I|") or b"|0|" in s:
                                        names.append(s.decode("latin1", "replace"))

print("FtraceEvent count:", len(ts))
if ts:
    span = max(ts) - min(ts)
    print(f"min ns: {min(ts)}  max ns: {max(ts)}")
    print(f"span: {span} ns ({span/1e6:.3f} ms)")
    print(f"monotonic non-decreasing: {all(ts[k] <= ts[k+1] for k in range(len(ts)-1))}")
    print(f"distinct ts: {len(set(ts))} / {len(ts)}")
    # delta stats
    d = [ts[k+1]-ts[k] for k in range(len(ts)-1)]
    pos = [x for x in d if x > 0]
    if pos:
        pos.sort()
        print(f"positive deltas: {len(pos)}/{len(d)}  min/med/max ns: "
              f"{pos[0]} / {pos[len(pos)//2]} / {pos[-1]}")
if names:
    print("sample slice names:", collections.Counter(names).most_common(6))
