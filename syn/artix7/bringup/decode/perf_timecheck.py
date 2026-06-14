"""perf_timecheck — parse a Perfetto .perf (protobuf) WITHOUT the perfetto libs,
using raw wire-format decoding, to extract ftrace event timestamps and the
'print' slice buffers, then sanity-check the time axis.

Why: orbetto/Mortrall derives timestamps from ETM cycle-count packets
(ts_ns = cycleCount * 1e9 / cps). Our ETMv3.5 stream has CYCACC off -> NO
cycle-count packets, so the time base may be degenerate. This script shows the
actual timestamps + inter-event deltas so we can confirm/deny.

Wire format we walk (perfetto schema field numbers):
  Trace.packet              = field 1 (len-delim)
  TracePacket.timestamp     = field 8 (varint)            [packet-level]
  TracePacket.ftrace_events = field 11 (len-delim) FtraceEventBundle
  FtraceEventBundle.event   = field 2 (len-delim) FtraceEvent
  FtraceEvent.timestamp     = field 1 (varint)            [ns]
  FtraceEvent.print         = field 18 (len-delim) PrintFtraceEvent
  PrintFtraceEvent.buf      = field 2 (len-delim) string
"""
import sys
import collections


def rd_varint(b, i):
    shift = 0
    val = 0
    while True:
        x = b[i]; i += 1
        val |= (x & 0x7F) << shift
        if not (x & 0x80):
            break
        shift += 7
    return val, i


def rd_tag(b, i):
    key, i = rd_varint(b, i)
    return key >> 3, key & 7, i


def skip_field(b, i, wt):
    if wt == 0:
        _, i = rd_varint(b, i)
    elif wt == 1:
        i += 8
    elif wt == 2:
        ln, i = rd_varint(b, i)
        i += ln
    elif wt == 5:
        i += 4
    return i


def parse_ftrace_event(b, off, ln):
    """Return (timestamp, print_buf_or_None)."""
    end = off + ln
    i = off
    ts = None
    buf = None
    while i < end:
        fn, wt, i = rd_tag(b, i)
        if fn == 1 and wt == 0:
            ts, i = rd_varint(b, i)
        elif fn == 3 and wt == 2:        # print (observed field 3)
            plen, i = rd_varint(b, i)
            pend = i + plen
            j = i
            while j < pend:
                pfn, pwt, j = rd_tag(b, j)
                if pfn == 2 and pwt == 2:  # buf string
                    blen, j = rd_varint(b, j)
                    buf = b[j:j + blen].decode("utf-8", "replace")
                    j += blen
                else:
                    j = skip_field(b, j, pwt)
            i = pend
        else:
            i = skip_field(b, i, wt)
    return ts, buf


def parse(path):
    b = open(path, "rb").read()
    n = len(b)
    i = 0
    events = []  # (ts, buf)
    while i < n:
        fn, wt, i = rd_tag(b, i)
        if fn == 1 and wt == 2:            # Trace.packet
            plen, i = rd_varint(b, i)
            pend = i + plen
            j = i
            while j < pend:
                pfn, pwt, j = rd_tag(b, j)
                if pfn == 1 and pwt == 2:   # ftrace_events bundle (observed field 1)
                    blen, j = rd_varint(b, j)
                    bend = j + blen
                    k = j
                    while k < bend:
                        efn, ewt, k = rd_tag(b, k)
                        if efn == 2 and ewt == 2:   # event
                            elen, k = rd_varint(b, k)
                            ts, buf = parse_ftrace_event(b, k, elen)
                            if ts is not None:
                                events.append((ts, buf))
                            k += elen
                        else:
                            k = skip_field(b, k, ewt)
                    j = bend
                else:
                    j = skip_field(b, j, pwt)
            i = pend
        else:
            i = skip_field(b, i, wt)
    return events


def main():
    events = parse(sys.argv[1])
    events_sorted = sorted(events, key=lambda e: e[0])
    ts = [e[0] for e in events_sorted]
    print(f"ftrace events with timestamp: {len(ts)}")
    if not ts:
        return
    print(f"timestamp range: {ts[0]} .. {ts[-1]} ns  span={ts[-1]-ts[0]} ns "
          f"({(ts[-1]-ts[0])/1e9:.6f} s)")
    distinct = sorted(set(ts))
    print(f"distinct timestamps: {len(distinct)} (of {len(ts)} events)")
    # inter-event deltas
    deltas = [ts[k+1]-ts[k] for k in range(len(ts)-1)]
    dh = collections.Counter(deltas)
    print("top inter-event deltas (ns:count):",
          [(d, c) for d, c in dh.most_common(8)])
    # how many events share timestamp 0 or are all-equal (degenerate)?
    zero = sum(1 for t in ts if t == 0)
    print(f"events at ts=0: {zero}; all-equal: {len(distinct)==1}")
    # sample a few print slices with their timestamps
    print("\nsample slices (ts_ns : buf):")
    shown = 0
    for t, buf in events_sorted:
        if buf and shown < 12:
            print(f"  {t:>14} : {buf}")
            shown += 1


if __name__ == "__main__":
    main()
