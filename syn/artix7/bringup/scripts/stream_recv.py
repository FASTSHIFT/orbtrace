#!/usr/bin/env python3
"""stream_recv — receive the continuous UDP trace stream from trace_stream_top
(STREAM=1) and dump it to a file, checking the packet sequence numbers.

Wire format matches the packetiser in trace_stream_top.v:
  UDP payload = <32-bit BE seq><PAYLOAD trace bytes>   per packet
so a lost UDP frame shows up as a gap in seq. The FPGA also exposes a
capture-side drop count at status offsets DEPTH+34..37 (little endian), which is
the *other* way to lose data (clk200 -> clk125 async FIFO overrun); we poll it
before and after so the two numbers can be reconciled.

Usage:
  python3 stream_recv.py [--port 5555] [--out /tmp/stream.bin] [--seconds 3]
"""
import argparse
import socket
import struct
import sys
import time


def read_lost_cnt(ip, depth, port=5001, retries=8, timeout=1.0):
    """Read the four DEPTH+34..37 status bytes via the request/reply :5001 path.

    Retries because while STREAM is saturating the TX path (self_busy always
    high in fpga_core_net's FSM), a :5001 echo request must wait for a gap
    between UDP packets on our side. On a busy stream the gap is small, and the
    first few polls typically time out."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    payload = struct.pack("<H", depth + 34) + bytes(8)
    for _ in range(retries):
        try:
            s.sendto(payload, (ip, port))
            d, _ = s.recvfrom(2048)
            s.close()
            return d[2] | (d[3] << 8) | (d[4] << 16) | (d[5] << 24)
        except socket.timeout:
            continue
    s.close()
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5555,
                    help="UDP port the FPGA streams to (STREAM_DEST_PORT)")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--out", default="/tmp/stream.bin")
    ap.add_argument("--seconds", type=float, default=3.0)
    ap.add_argument("--ip", default="192.168.10.42",
                    help="FPGA IP for polling status (DEPTH+34..37 lost count)")
    ap.add_argument("--depth", type=int, default=61440,
                    help="DEPTH parameter (for lost_cnt readback offset)")
    a = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    s.bind((a.bind, a.port))
    s.settimeout(0.5)

    lost_before = read_lost_cnt(a.ip, a.depth)
    print(f"capture-side lost_cnt before: {lost_before}")

    trace = bytearray()
    seq_prev = None
    gaps = 0
    npkt = 0
    nbytes = 0
    t0 = time.time()
    while time.time() - t0 < a.seconds:
        try:
            pkt, _ = s.recvfrom(2048)
        except socket.timeout:
            continue
        if len(pkt) < 4:
            continue
        seq = struct.unpack(">I", pkt[:4])[0]
        payload = pkt[4:]
        # NB: fpga_core_net promises exactly STREAM_PKT_BYTES; if underrun, the
        # FSM pads with 0x00 to complete the packet. The seq check catches lost
        # UDP frames on the wire (the capture-drop counter catches capture-side
        # loss); combined they cover both failure modes.
        if seq_prev is not None and seq != (seq_prev + 1) & 0xFFFFFFFF:
            missing = (seq - seq_prev - 1) & 0xFFFFFFFF
            gaps += missing
        seq_prev = seq
        trace.extend(payload)
        npkt += 1
        nbytes += len(payload)
    s.close()

    lost_after = read_lost_cnt(a.ip, a.depth)
    lost_delta = None
    if lost_before is not None and lost_after is not None:
        lost_delta = (lost_after - lost_before) & 0xFFFFFFFF

    open(a.out, "wb").write(trace)
    elapsed = time.time() - t0
    print(f"packets={npkt}  bytes={nbytes} ({nbytes/1e6:.2f} MB) "
          f"in {elapsed:.2f}s  -> {nbytes/elapsed/1e6:.2f} MB/s")
    print(f"seq-gap lost frames: {gaps}")
    if lost_delta is not None:
        print(f"capture-side lost bytes (clk200 FIFO overrun): {lost_delta}")
    print(f"wrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
