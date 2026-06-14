#!/usr/bin/env python3
"""Stage-4 V3: dump the FPGA's captured raw trace byte stream to a file.

trace_stream_top captures a contiguous block (DEPTH bytes) of the raw TPIU
byte stream off the STM32 ETM into BRAM, one-shot, then serves it on UDP
:5001 with a paged readout:
  request payload: byte0/1 = 16-bit base offset (LE), rest = don't-care pad
  reply:           byte0/1 = echo of base (discard), byte2.. = source[base..]

We page through DEPTH bytes in CHUNK-sized requests and write the assembled
stream to a file for offline decode:
  orbmortem -f trace.bin -e proj.axf -P ETM3.5

Usage: python3 trace_dump.py [--ip 192.168.10.42] [--depth 16384] [-o trace.bin]
"""
import argparse
import socket
import struct
import sys

CHUNK = 1024  # data bytes per request (reply = CHUNK+2)


def req(sock, ip, port, base, n, timeout):
    # payload: 2-byte LE base + n+2 pad (reply length mirrors request length)
    payload = struct.pack("<H", base) + bytes(n)
    sock.sendto(payload, (ip, port))
    data, _ = sock.recvfrom(2048)
    # reply[2:] = source[base : base+n]
    return data[2:2 + n]


def read_status(s, ip, port, depth, timeout):
    """Read (dev_depth, full, gen) from the status region at addr=depth.
    The status bytes come from a combinational mux (NOT the BRAM `rrd`), so
    unlike the data region they have NO leading-duplicate latency artifact —
    read them directly."""
    st = req(s, ip, port, depth, 4, timeout)
    dev_depth = st[0] | (st[1] << 8)
    full = st[2] & 1
    gen = st[3]
    return dev_depth, full, gen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--port", type=int, default=5001)
    ap.add_argument("--depth", type=int, default=16384)
    ap.add_argument("-o", "--out", default="trace.bin")
    ap.add_argument("--timeout", type=float, default=2.0)
    ap.add_argument("--prev-gen", type=int, default=None,
                    help="wait until capture generation != PREV_GEN and full=1 "
                         "(confirms a FRESH capture after a soft re-arm)")
    ap.add_argument("--wait", type=float, default=3.0,
                    help="max seconds to wait for a fresh full capture")
    ap.add_argument("--status-only", action="store_true",
                    help="print DEPTH/full/gen and exit (no data read)")
    ap.add_argument("--skip", type=int, default=0,
                    help="drop the first SKIP bytes (capture-start transient "
                         "lead-in; the first ~7.5KB after re-arm can be garbage "
                         "until TPIU framing locks — doc 15 §14)")
    a = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(a.timeout)

    # read status (DEPTH, full, gen) at addr depth..depth+3
    try:
        dev_depth, full, gen = read_status(s, a.ip, a.port, a.depth, a.timeout)
        # If asked, wait for a FRESH capture: generation advanced AND full.
        if a.prev_gen is not None:
            import time
            t0 = time.time()
            while time.time() - t0 < a.wait:
                if gen != (a.prev_gen & 0xFF) and full:
                    break
                time.sleep(0.02)
                dev_depth, full, gen = read_status(s, a.ip, a.port,
                                                   a.depth, a.timeout)
        print(f"  device DEPTH={dev_depth}  full={full}  gen={gen}")
    except (socket.timeout, OSError) as e:
        print(f"ERROR reading status: {e}")
        return 2
    if a.status_only:
        return 0
    if not full:
        print("  WARNING: capture buffer not full yet (still filling or no sync).")

    out = bytearray()
    base = 0
    while base < a.depth:
        n = min(CHUNK, a.depth - base)
        try:
            # Readout off-by-one fix (deterministic, doc 14 §31): the CAP_RAW
            # BRAM read has 1 cycle latency, so the FIRST data byte of every
            # reply repeats source[base] (stale read). Request n+1 bytes and
            # drop the leading duplicate -> contiguous, correct stream.
            # (Verified 0.000% unknown on real trace; an RTL-side fix did not
            # reliably remove it due to a first-beat AXI stall.)
            chunk = req(s, a.ip, a.port, base, n + 1, a.timeout)
            chunk = chunk[1:1 + n]
        except (socket.timeout, OSError) as e:
            print(f"ERROR at base {base}: {e}")
            return 2
        if len(chunk) < n:
            print(f"  short chunk @{base}: {len(chunk)}<{n}")
        out.extend(chunk[:n])
        base += n

    if a.skip > 0:
        out = out[a.skip:]

    with open(a.out, "wb") as f:
        f.write(out)
    print(f"  wrote {len(out)} bytes -> {a.out}"
          + (f" (skipped first {a.skip})" if a.skip else ""))
    # quick content sanity: TPIU sync 0xFFFFFF7F frequency
    sync = out.count(b"\xff\xff\xff\x7f")
    print(f"  TPIU full-sync (ff ff ff 7f) occurrences: {sync}")
    nonzero = sum(1 for b in out if b != 0)
    print(f"  non-zero bytes: {nonzero}/{len(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
