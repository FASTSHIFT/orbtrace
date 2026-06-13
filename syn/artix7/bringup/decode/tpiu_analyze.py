#!/usr/bin/env python3
"""Offline TPIU demux analysis on raw traceIF 16-byte frames.

Replicates orbtrace's Unmangle + TrackStream (tpiu.py) to see how the ETM
data distributes across TPIU channels, and tests byte-order hypotheses to
find which (if any) collapses the stream to a single TraceID.
"""
import sys
from collections import Counter

data = open(sys.argv[1] if len(sys.argv) > 1 else "/tmp/frames.bin", "rb").read()

# split into 16-byte frames (traceIF emits frames back to back; the dump is
# frame-major already from trace_stream_top)
frames = [data[i:i+16] for i in range(0, len(data) - 15, 16)]
print(f"frames: {len(frames)}")


def demux(frames, rev=False):
    """orbtrace Unmangle + TrackStream. rev=reverse each frame's byte order."""
    channel = 0
    chan_bytes = Counter()
    next_channel = None
    for fr in frames:
        if rev:
            fr = fr[::-1]
        # Unmangle: 15 usable bytes; byte15 (aux) supplies bit0 of even bytes
        aux = fr[15]
        for i in range(15):
            if i & 1 == 0:
                is_id = fr[i] & 1
                d = (fr[i] & 0xFE) | ((aux >> (i // 2)) & 1)
                if is_id:
                    # channel id byte
                    if d & 1:
                        next_channel = d >> 1
                    else:
                        channel = d >> 1
                    continue
                else:
                    chan_bytes[channel] += 1
                    if next_channel is not None:
                        channel = next_channel
                        next_channel = None
            else:
                # odd byte: always data
                chan_bytes[channel] += 1
                if next_channel is not None:
                    channel = next_channel
                    next_channel = None
    return chan_bytes


for rev in (False, True):
    cb = demux(frames, rev=rev)
    tot = sum(cb.values()) or 1
    top = cb.most_common(8)
    print(f"\n--- rev={rev}: {len(cb)} channels, top:")
    for ch, n in top:
        print(f"    ch {ch:3d}: {n:6d}  ({100*n/tot:.1f}%)")
