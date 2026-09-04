#!/usr/bin/env python3
"""ddr_selftest_status — read the DDR3 selftest status registers exposed by
trace_ddr_selftest_top at 0xFF50..0xFF73 over the :5001 CSR path, decode them,
and print a verdict.

MAGIC 0xD3 at FF50 confirms the running bitstream is trace_ddr_selftest_top.
FF51:  bit0=calib_done, bit1=err_sticky, bit2=mig_calib_raw
FF52-55: errc (32-bit total mismatch count, running)
FF56-59: passb (32-bit total bytes that passed compare, running)
FF5A:  fsm state (0=ARBIT, 1=WRITE, 2=READ)
FF5B-62: first-mismatch capture (word idx, expected/got bytes)
FF70-73: BUILD_ID
"""
import argparse
import socket
import struct
import sys
import time


def read_bytes(sock, ip, port, addr, n, retries=6, timeout=0.5):
    # fpga_core_net CSR protocol (matches fpga_health.rd()):
    #   req  = <u16 base LE> + padding of (n+4) bytes
    #   reply= [2 echo bytes] [ ext_data[base], ext_data[base+1], ... ]
    # The value for `base` is at index 2, base+k at index 2+k.
    req = struct.pack("<H", addr & 0xFFFF) + bytes(n + 4)
    for _ in range(retries):
        try:
            sock.sendto(req, (ip, port))
            sock.settimeout(timeout)
            data, _ = sock.recvfrom(2048)
            return data[2:2 + n]
        except socket.timeout:
            continue
    raise RuntimeError(f"CSR read timeout at 0x{addr:04x}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--port", type=int, default=5001)
    ap.add_argument("--iface", default="enxc8a36266dcae")
    ap.add_argument("--loop", type=float, default=0,
                    help="loop this many seconds, poll every 1s")
    a = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, 25, (a.iface + "\0").encode())
    except PermissionError:
        print("note: run as root to bind interface", file=sys.stderr)

    def dump():
        raw = read_bytes(sock, a.ip, a.port, 0xFF50, 0x24)
        magic = raw[0x00]
        flags = raw[0x01]
        errc  = int.from_bytes(raw[0x02:0x06], "little")
        passb = int.from_bytes(raw[0x06:0x0A], "little")
        fsm   = raw[0x0A]
        bad_word = raw[0x0B] | ((raw[0x0C] & 0x3) << 8)
        exp_lo = raw[0x0D]
        got_lo = raw[0x0E]
        exp_hi = int.from_bytes(raw[0x0F:0x11], "little")
        got_hi = int.from_bytes(raw[0x11:0x13], "little")
        build_id = int.from_bytes(raw[0x20:0x24], "little")

        calib_done = flags & 1
        err_sticky = (flags >> 1) & 1
        mig_calib  = (flags >> 2) & 1

        print(f"magic       : 0x{magic:02x} {'OK' if magic == 0xD3 else 'MISMATCH (not ddr_selftest bit?)'}")
        print(f"MIG calib   : {'OK' if mig_calib else 'NOT DONE'}   (init_calib_complete)")
        print(f"local calib : {'OK' if calib_done else 'NOT DONE'}")
        print(f"error sticky: {'!!! LATCHED' if err_sticky else 'clean'}")
        print(f"errc (total): {errc}")
        print(f"pass bytes  : {passb}   ({passb/1e6:.1f} MB compared OK)")
        print(f"fsm         : {['ARBIT','WRITE','READ','?'][min(fsm,3)]}")
        if err_sticky:
            print(f"1st bad word: 0x{bad_word:03x}")
            print(f"  expected  : 0x{exp_hi:04x}{exp_lo:02x}")
            print(f"  got       : 0x{got_hi:04x}{got_lo:02x}")
        print(f"BUILD_ID    : 0x{build_id:08x}  ({time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(build_id))})")

    if a.loop == 0:
        dump()
    else:
        t0 = time.time()
        while time.time() - t0 < a.loop:
            print("---", time.strftime("%H:%M:%S"), "---")
            dump()
            time.sleep(1.0)
    sock.close()


if __name__ == "__main__":
    main()
