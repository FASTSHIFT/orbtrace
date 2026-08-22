#!/usr/bin/env python3
"""_seqdiag — characterise :5555 stream gaps: distinguish frame LOSS (forward
seq jumps) from REORDER (backward deltas) and record the size distribution of
gaps. Also checks payload length consistency (short/oversized frames). Pure
diagnostic, discards payload."""
import socket
import struct
import sys
import time
from collections import Counter

IFACE = sys.argv[1] if len(sys.argv) > 1 else "enxc8a36266dcae"
SECS = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 256 << 20)
s.setsockopt(socket.SOL_SOCKET, 25, (IFACE + "\0").encode())
s.bind(("192.168.10.245", 5555))
s.settimeout(1.0)

seq_prev = None
npkt = 0
fwd_jumps = 0        # seq jumped forward by >1  -> frame loss
lost_frames = 0
back_jumps = 0       # seq went backward         -> reorder (or wrap)
gap_sizes = Counter()
lens = Counter()
t0 = time.time()
while time.time() - t0 < SECS:
    try:
        pkt, _ = s.recvfrom(4096)
    except socket.timeout:
        continue
    if len(pkt) < 4:
        continue
    seq = struct.unpack(">I", pkt[:4])[0]
    lens[len(pkt)] += 1
    if seq_prev is not None:
        d = (seq - seq_prev) & 0xFFFFFFFF
        if d == 1:
            pass
        elif d < 0x80000000:          # forward jump = loss
            fwd_jumps += 1
            lost_frames += d - 1
            gap_sizes[d - 1] += 1
        else:                          # backward = reorder (small) or wrap
            back_jumps += 1
    seq_prev = seq
    npkt += 1
s.close()

print(f"packets={npkt}")
print(f"forward-jumps (frame LOSS): {fwd_jumps} events, {lost_frames} lost frames")
print(f"backward-jumps (REORDER):   {back_jumps}")
print(f"payload length distribution: {dict(lens)}")
print(f"gap-size distribution (missing frames per event): "
      f"{dict(sorted(gap_sizes.items()))}")
if fwd_jumps and back_jumps == 0:
    print("=> pure FRAME LOSS (no reorder); frames that arrive are contiguous")
elif back_jumps:
    print("=> REORDER present; some 'loss' may be out-of-order delivery")
