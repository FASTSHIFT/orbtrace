"""duty_probe (E3) — read the FPGA's own measurement of the real TRACECLK duty
cycle AT ITS INPUT PIN (not the LA probe point). Tests the unverified premise
'FPGA-pin duty != 50%'. Reads the status registers NB+4..NB+23 (high/low dwell
min/max/sum/cnt in ref_200m cycles, 5ns each).

Usage: python3 duty_probe.py [ip] [depth]
"""
import socket
import struct
import sys

IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.10.42"
DEPTH = int(sys.argv[2]) if len(sys.argv) > 2 else 61440
PORT = 5001

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2.0)


def req(base, n):
    s.sendto(struct.pack("<H", base) + bytes(n), (IP, PORT))
    d, _ = s.recvfrom(2048)
    return d[2:2 + n]


# status region (combinational mux, no read-latency duplicate)
raw = req(DEPTH, 24)
hi_min = raw[4] | (raw[5] << 8)
hi_max = raw[6] | (raw[7] << 8)
lo_min = raw[8] | (raw[9] << 8)
lo_max = raw[10] | (raw[11] << 8)
hi_sum = raw[12] | (raw[13] << 8) | (raw[14] << 16) | (raw[15] << 24)
hi_cnt = raw[16] | (raw[17] << 8)
lo_sum = raw[18] | (raw[19] << 8) | (raw[20] << 16) | (raw[21] << 24)
lo_cnt = raw[22] | (raw[23] << 8)

NS = 5.0  # ref_200m cycle = 5 ns
hi_avg = hi_sum / hi_cnt if hi_cnt else 0
lo_avg = lo_sum / lo_cnt if lo_cnt else 0
print(f"HIGH dwell: min={hi_min} max={hi_max} avg={hi_avg:.2f} cyc "
      f"({hi_avg*NS:.1f} ns)  n={hi_cnt}")
print(f"LOW  dwell: min={lo_min} max={lo_max} avg={lo_avg:.2f} cyc "
      f"({lo_avg*NS:.1f} ns)  n={lo_cnt}")
if hi_avg + lo_avg > 0:
    duty = 100 * hi_avg / (hi_avg + lo_avg)
    period_ns = (hi_avg + lo_avg) * NS
    print(f"==> duty(high) = {duty:.1f}%   period = {period_ns:.1f} ns "
          f"(TRACECLK ~ {1e3/period_ns:.2f} MHz)")
    print(f"    half-bit spread: HIGH {hi_min*NS:.0f}-{hi_max*NS:.0f}ns, "
          f"LOW {lo_min*NS:.0f}-{lo_max*NS:.0f}ns")
