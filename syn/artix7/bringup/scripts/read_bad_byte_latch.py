#!/usr/bin/env python3
"""r38 P0-4 diagnostic latches — read the FPGA-side view of the bad byte
event.

Programs required: ddr_ring_selftest.bit (with r38 diag-latch changes at
addresses 0xFF80..0xFF94).

Usage:
    read_bad_byte_latch.py            # one-shot read
    read_bad_byte_latch.py --clear    # clear latches first, then wait+read
    read_bad_byte_latch.py --watch    # poll every 500ms until Ctrl-C

Assumes .245 is on the trace NIC and FPGA IP is 192.168.10.42.
"""
import argparse
import socket
import struct
import sys
import time

FPGA_IP = "192.168.10.42"
CTRL_PORT = 5002
DATA_PORT = 5001
IFACE = None  # optional bind


def try_bind(sk, iface):
    if not iface:
        return
    try:
        sk.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE,
                      (iface + "\0").encode())
    except PermissionError:
        pass


def csr_write(addr, value, iface=None):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try_bind(s, iface)
    s.sendto(bytes([addr & 0xFF, value & 0xFF, 0, 0]), (FPGA_IP, CTRL_PORT))
    s.close()


def read_page(base, length, iface=None, retries=6, timeout=0.5):
    """Read `length` bytes starting at 16-bit `base` using the fpga_core_net
    :5001 CSR protocol (matches ddr_selftest_status / fpga_health)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try_bind(s, iface)
    req = struct.pack("<H", base & 0xFFFF) + bytes(length + 4)
    for _ in range(retries):
        try:
            s.sendto(req, (FPGA_IP, DATA_PORT))
            s.settimeout(timeout)
            data, _ = s.recvfrom(2048)
            s.close()
            return data[2:2 + length]
        except socket.timeout:
            continue
    s.close()
    raise RuntimeError(f"CSR read timeout at 0x{base:04x}")


def dump(iface="enxc8a36266dcae"):
    raw = read_page(0xFF80, 0x15, iface)
    magic = raw[0x00]
    if magic != 0xD2:
        print(f"ERROR: expected magic 0xD2 at 0xFF80, got 0x{magic:02x}")
        return None
    flags   = raw[0x01]
    latched = bool(flags & 1)
    srcfix  = bool(flags & 2)
    bad_val    = raw[0x02]
    bad_stream = raw[0x03]
    bad_pos    = raw[0x04]
    bad_seq    = int.from_bytes(raw[0x05:0x09], "little")
    bad_cnt    = int.from_bytes(raw[0x09:0x0D], "little")
    stream_p   = int.from_bytes(raw[0x0D:0x11], "little")
    pkt_p      = int.from_bytes(raw[0x11:0x15], "little")
    return dict(
        magic=magic, src_fixed=srcfix, latched=latched,
        bad_byte_val=bad_val,       # pkt_tdata at bad event
        bad_stream_td=bad_stream,   # stream_tdata (pre-mux) at same tick
        bad_pos=bad_pos,            # byte offset in packet
        bad_seq=bad_seq,            # latched_seq (packet index)
        bad_count=bad_cnt,          # running counter
        stream_pulses=stream_p,     # (stream_tvalid & tready) count
        pkt_active_pulses=pkt_p,    # rising edges of pkt_active
    )


def fmt(d):
    if d is None:
        return "no data"
    return (
        f"src_fixed={int(d['src_fixed'])}  latched={int(d['latched'])}  "
        f"bad_count={d['bad_count']}  pkts={d['pkt_active_pulses']}  "
        f"stream_pulses={d['stream_pulses']}\n"
        f"    first bad: pkt_tdata=0x{d['bad_byte_val']:02x} "
        f"stream_tdata=0x{d['bad_stream_td']:02x} "
        f"pos={d['bad_pos']} seq={d['bad_seq']}"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface", default="enxc8a36266dcae")
    ap.add_argument("--clear", action="store_true",
                    help="clear the diag latches (CSR 0x0C=1) first")
    ap.add_argument("--enable-fixed", action="store_true",
                    help="assert src_fixed_125=1 (CSR 0x0B=1) first")
    ap.add_argument("--watch", action="store_true",
                    help="poll every 500 ms")
    args = ap.parse_args()

    if args.enable_fixed:
        csr_write(0x0B, 0x01, args.iface)
        print("CSR 0x0B <- 0x01  (src_fixed=1)")
        time.sleep(0.1)
    if args.clear:
        csr_write(0x0C, 0x01, args.iface)
        print("CSR 0x0C <- 0x01  (clear diag latches)")
        time.sleep(0.1)

    def read_once():
        # Pause the stream so :5001 CSR reads can go through (the streamer
        # otherwise floods the ethernet path). CSR 0x0A=1 => stream_pause_125.
        csr_write(0x0A, 0x01, args.iface)
        time.sleep(0.05)
        d = dump(args.iface)
        csr_write(0x0A, 0x00, args.iface)
        return d

    try:
        if args.watch:
            while True:
                d = read_once()
                print(fmt(d))
                print("---")
                time.sleep(0.5)
        else:
            print(fmt(read_once()))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
