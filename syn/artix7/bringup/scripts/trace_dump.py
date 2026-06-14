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


def read_timebase(s, ip, port, depth, timeout):
    """Read the FPGA capture-time base (doc 15 §24.2).

    Metadata lives just past the status region; the per-stride snapshot table
    starts at depth+64. Returns a dict:
      stride      : captured-byte interval between snapshots (1<<stride_log2)
      n           : number of table entries
      tick_ns     : ns per ref_200m tick (5.0)
      last_tick   : ref tick at the last captured byte (for the tail)
      ticks       : list[n] of ref_200m counter snapshots (one per stride bytes)

    The table read uses the SAME 1-cycle BRAM latency as the data region, so we
    request +1 leading byte per chunk and drop it (mirrors the data path)."""
    meta = req(s, ip, port, depth + 26, 7, timeout)
    stride_log2 = meta[0]
    n = meta[1] | (meta[2] << 8)
    last_tick = meta[3] | (meta[4] << 8) | (meta[5] << 16) | (meta[6] << 24)
    base = depth + 64
    nbytes = 4 * n
    raw = bytearray()
    off = 0
    while off < nbytes:
        m = min(CHUNK, nbytes - off)
        chunk = req(s, ip, port, base + off, m + 1, timeout)
        raw.extend(chunk[1:1 + m])
        off += m
    ticks = [raw[4*k] | (raw[4*k+1] << 8) | (raw[4*k+2] << 16) | (raw[4*k+3] << 24)
             for k in range(n)]
    return {
        "stride": 1 << stride_log2,
        "n": n,
        "tick_ns": 5.0,           # ref_200m = 200 MHz
        "last_tick": last_tick,
        "ticks": ticks,
    }


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
    ap.add_argument("--timebase", action="store_true",
                    help="also read the FPGA capture-time base table and write "
                         "a sidecar <out>.ts.json (byte-index -> wall-clock ns). "
                         "Adapts to any TRACECLK frequency (doc 15 §24.2).")
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

    if a.timebase:
        import json
        try:
            tb = read_timebase(s, a.ip, a.port, a.depth, a.timeout)
        except (socket.timeout, OSError) as e:
            print(f"  WARNING: time base read failed: {e} (old bitstream?)")
        else:
            tb["skip"] = a.skip          # bytes dropped from the front of out
            tb["depth"] = a.depth
            side = a.out + ".ts.json"
            with open(side, "w") as f:
                json.dump(tb, f)
            ticks = tb["ticks"]
            span_ns = (tb["last_tick"]) * tb["tick_ns"]
            print(f"  time base: {tb['n']} snapshots @ every {tb['stride']} B, "
                  f"span {span_ns/1e3:.1f} us -> {side}")
            # quick monotonic sanity (ticks may wrap if capture > ~21s @200MHz)
            nonmono = sum(1 for k in range(1, len(ticks)) if ticks[k] < ticks[k-1])
            if nonmono:
                print(f"  NOTE: {nonmono} tick wrap/non-monotonic points "
                      f"(capture longer than counter range)")
    # quick content sanity: TPIU sync 0xFFFFFF7F frequency
    sync = out.count(b"\xff\xff\xff\x7f")
    print(f"  TPIU full-sync (ff ff ff 7f) occurrences: {sync}")
    nonzero = sum(1 for b in out if b != 0)
    print(f"  non-zero bytes: {nonzero}/{len(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
