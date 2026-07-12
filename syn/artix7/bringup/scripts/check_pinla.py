#!/usr/bin/env python3
"""Quick health-check for the trace_pin_la_top bitstream (proposal 32 P2b, pin-level).

Reads the status page at :5001 and prints live pin levels + write pointer + calib flag.
"""
import socket
import struct
import sys

IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.10.42"


def rd(s, base, n):
    s.sendto(struct.pack("<H", base & 0xFFFF) + bytes(n + 4), (IP, 5001))
    d, _ = s.recvfrom(2048)
    return d[2:2 + n]


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3.0)
    magic = bytes(rd(s, 0xFF70, 2))
    print(f"FF70..71 magic     = {magic!r}  (expect b'LA')")

    la_byte = rd(s, 0xFF08, 1)[0]
    clk = (la_byte >> 4) & 1
    d3 = (la_byte >> 3) & 1
    d2 = (la_byte >> 2) & 1
    d1 = (la_byte >> 1) & 1
    d0 = la_byte & 1
    print(f"FF08 la_byte       = 0x{la_byte:02x}  "
          f"[clk={clk} d3={d3} d2={d2} d1={d1} d0={d0}]")

    flags = rd(s, 0xFF09, 1)[0]
    print(f"FF09 calib/mig     = 0x{flags:02x}  "
          f"(bit0=mig_calib_raw={flags & 1}, bit1=calib_done={(flags >> 1) & 1})")

    ww = int.from_bytes(rd(s, 0xFF00, 4), "little")
    lost = int.from_bytes(rd(s, 0xFF04, 4), "little")
    print(f"FF00 words_written = {ww}  (128-bit words -> {ww * 16} bytes)")
    print(f"FF04 wr_lost_bytes = {lost}")


if __name__ == "__main__":
    main()
