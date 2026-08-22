#!/usr/bin/env python3
"""stream_endurance — long-duration zero-loss stress for the full trace link:
STM32 ETM -> TPIU pins -> FPGA capture -> UDP self-TX -> PC.

Unlike stream_recv.py (which buffers the whole capture in RAM to reassemble a
decodable byte stream), this tool is built for HOURS: it discards the payload
by default and keeps only running statistics, so memory stays flat regardless of
duration. It reports both loss channels continuously:

  * wire-side seq-gap   : per-packet 32-bit sequence discontinuities (with
                          uint32 wrap handling) -- catches UDP/network drops.
  * capture-side lost   : the FPGA clk200 FIFO overrun counter at DEPTH+34..37,
                          polled periodically during the run (not just at the
                          end) -- catches capture-front-end overruns.

Per-interval (default 10 s) it prints rate + interval loss + cumulative loss, so
a slow leak or a burst at a particular time is visible. A final summary gives
total bytes, mean rate, total loss, and the worst interval.

The FPGA self-TX destination IP is HARDCODED to 192.168.10.245 in the bitstream
(see AGENT.md 2 -- the #1 trap). The host MUST hold .245 on the receiving NIC
or the kernel drops every packet before any socket. Bind to that NIC with
--iface and make sure `ip addr` shows .245 there.

Usage:
  sudo python3 stream_endurance.py --iface enxc8a36266dcae --seconds 3600
  sudo python3 stream_endurance.py --iface enxc8a36266dcae --hours 8 --sample /tmp/probe.bin
"""
import argparse
import socket
import struct
import sys
import time

SO_BINDTODEVICE = 25


def read_lost_cnt(ip, depth, iface=None, retries=6, timeout=0.5):
    """Read the capture-side clk200 FIFO overrun counter (DEPTH+34..37) over the
    :5001 request/reply path. Returns uint32 or None on timeout (the poll often
    times out while the self-TX stream is saturating the wire)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if iface:
        try:
            s.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, (iface + "\0").encode())
        except PermissionError:
            pass
    s.settimeout(timeout)
    payload = struct.pack("<H", depth + 34) + bytes(8)
    try:
        for _ in range(retries):
            try:
                s.sendto(payload, (ip, 5001))
                d, _ = s.recvfrom(2048)
                return d[2] | (d[3] << 8) | (d[4] << 16) | (d[5] << 24)
            except socket.timeout:
                continue
    finally:
        s.close()
    return None


def u32_delta(cur, prev):
    """cur - prev with 32-bit wraparound."""
    return (cur - prev) & 0xFFFFFFFF


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface", default=None, help="receiving NIC (must hold .245)")
    ap.add_argument("--bind", default="192.168.10.245", help="local addr to bind")
    ap.add_argument("--port", type=int, default=5555)
    ap.add_argument("--ip", default="192.168.10.42", help="FPGA IP for lost_cnt poll")
    ap.add_argument("--depth", type=int, default=61440, help="DEPTH for lost_cnt offset")
    ap.add_argument("--seconds", type=float, default=None)
    ap.add_argument("--hours", type=float, default=None)
    ap.add_argument("--interval", type=float, default=10.0, help="report interval (s)")
    ap.add_argument("--rcvbuf-mb", type=int, default=256)
    ap.add_argument("--sample", default=None,
                    help="optional: write the FIRST N MB of payload to this file "
                         "(for a decode sanity check); stream is otherwise discarded")
    ap.add_argument("--sample-mb", type=int, default=8)
    a = ap.parse_args()

    duration = a.seconds
    if a.hours is not None:
        duration = a.hours * 3600.0
    if duration is None:
        duration = 60.0

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, a.rcvbuf_mb * 1024 * 1024)
    actual = s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    if a.iface:
        try:
            s.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, (a.iface + "\0").encode())
        except PermissionError:
            print("[endurance] warning: not root, cannot SO_BINDTODEVICE", file=sys.stderr)
    if actual < (a.rcvbuf_mb * 1024 * 1024) // 2:
        print(f"[endurance] warning: SO_RCVBUF capped to {actual/1e6:.1f} MB; "
              f"raise net.core.rmem_max (sudo sysctl -w net.core.rmem_max={a.rcvbuf_mb<<20})",
              file=sys.stderr)
    s.bind((a.bind, a.port))
    s.settimeout(1.0)

    sample = bytearray() if a.sample else None
    sample_cap = a.sample_mb * 1024 * 1024

    # cumulative
    seq_prev = None
    tot_pkt = tot_bytes = tot_gaps = tot_lost_frames = 0
    lost_cnt_base = None
    lost_cnt_last = None
    t_start = time.time()
    t_interval = t_start
    iv_pkt = iv_bytes = iv_gaps = 0
    worst = {"gaps": 0, "at": 0.0}
    idle_intervals = 0

    print(f"[endurance] listening {a.bind}:{a.port} on {a.iface or 'kernel-route'} "
          f"for {duration:.0f}s, interval {a.interval:.0f}s, rcvbuf {actual/1e6:.0f}MB")
    print(f"[endurance] {'elapsed':>8} {'rate MB/s':>10} {'iv-gap':>8} {'cum-gap':>10} "
          f"{'cap-lost':>10} {'MB':>10}")

    try:
        while time.time() - t_start < duration:
            try:
                pkt, _ = s.recvfrom(4096)
            except socket.timeout:
                pkt = None
            if pkt is not None and len(pkt) >= 4:
                seq = struct.unpack(">I", pkt[:4])[0]
                if seq_prev is not None:
                    d = u32_delta(seq, seq_prev)
                    if d != 1:
                        miss = (d - 1) if d >= 1 else 0
                        tot_gaps += 1
                        iv_gaps += 1
                        tot_lost_frames += miss
                seq_prev = seq
                n = len(pkt) - 4
                tot_pkt += 1
                iv_pkt += 1
                tot_bytes += n
                iv_bytes += n
                if sample is not None and len(sample) < sample_cap:
                    sample.extend(pkt[4:4 + (sample_cap - len(sample))])

            now = time.time()
            if now - t_interval >= a.interval:
                iv_dt = now - t_interval
                rate = iv_bytes / iv_dt / 1e6
                if iv_pkt == 0:
                    idle_intervals += 1
                # poll capture-side lost_cnt (best-effort; may time out on busy wire)
                lc = read_lost_cnt(a.ip, a.depth, iface=a.iface)
                if lc is not None:
                    if lost_cnt_base is None:
                        lost_cnt_base = lc
                    lost_cnt_last = lc
                cap_lost = (u32_delta(lost_cnt_last, lost_cnt_base)
                            if lost_cnt_last is not None and lost_cnt_base is not None else -1)
                if iv_gaps > worst["gaps"]:
                    worst = {"gaps": iv_gaps, "at": now - t_start}
                print(f"[endurance] {now-t_start:8.0f} {rate:10.1f} {iv_gaps:8d} "
                      f"{tot_gaps:10d} {cap_lost:10d} {tot_bytes/1e6:10.1f}")
                t_interval = now
                iv_pkt = iv_bytes = iv_gaps = 0
    except KeyboardInterrupt:
        print("\n[endurance] interrupted", file=sys.stderr)
    finally:
        s.close()

    total_dt = time.time() - t_start
    print("\n=== endurance summary ===")
    print(f"  duration        : {total_dt:.0f} s")
    print(f"  total received  : {tot_bytes/1e6:.1f} MB ({tot_pkt} packets)")
    print(f"  mean rate       : {tot_bytes/total_dt/1e6:.1f} MB/s")
    print(f"  wire seq-gaps   : {tot_gaps} events, {tot_lost_frames} lost frames "
          f"({100*tot_lost_frames/max(1,tot_pkt+tot_lost_frames):.4f}%)")
    if lost_cnt_base is not None and lost_cnt_last is not None:
        print(f"  capture-side    : {u32_delta(lost_cnt_last, lost_cnt_base)} lost "
              f"(clk200 FIFO overrun, delta over run)")
    else:
        print("  capture-side    : (lost_cnt poll never succeeded -- wire too busy)")
    print(f"  worst interval  : {worst['gaps']} gaps at t={worst['at']:.0f}s")
    if idle_intervals:
        print(f"  idle intervals  : {idle_intervals} (no packets -- stream stalled?)")
    verdict = "ZERO LOSS" if tot_gaps == 0 else f"{tot_gaps} gap-events"
    print(f"  VERDICT         : {verdict}")
    if sample is not None and sample:
        open(a.sample, "wb").write(sample)
        print(f"  sample          : wrote {len(sample)} bytes -> {a.sample}")
    return 0 if tot_gaps == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
