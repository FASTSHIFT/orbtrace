#!/usr/bin/env python3
"""trace_ctrl — write runtime CSRs to trace_stream_top over UDP :5002.

CSR map (fpga_core_net control port, doc 15):
  0x01  EYE delay   : ref_200m cycles for OVERSAMPLE mid-eye sampling (0=default)
  0x02  soft re-arm : any write re-arms the one-shot capture (no reflash)

Request payload = {reg_addr(1B), reg_value(1B)} (+pad); the FPGA latches both
and pulses csr_we at end-of-frame.

Usage:
  python3 trace_ctrl.py --ip 192.168.10.42 set-eye 38
  python3 trace_ctrl.py --ip 192.168.10.42 rearm
"""
import argparse
import socket
import sys

CTRL_PORT = 5002
REG_EYE = 0x01
REG_REARM = 0x02
REG_BITLEN_LO = 0x03
REG_BITLEN_HI = 0x04
REG_TAP = 0x05     # IDDR IDELAY deskew tap (0..31) for ALL lanes; loads it
REG_TAP_LANE = 0x06  # per-lane tap: value = {lane[6:5], tap[4:0]}
REG_TAP_CLK = 0x07   # clock-lane IDELAY tap (0..31); >100MHz eye reach


def write_csr(ip, addr, value, timeout=1.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    # payload: addr, value, then a few pad bytes so the frame has a clear tlast
    payload = bytes([addr & 0xFF, value & 0xFF, 0, 0])
    s.sendto(payload, (ip, CTRL_PORT))
    try:
        s.recvfrom(2048)   # reply is echoed; ignore content
    except socket.timeout:
        pass               # write is fire-and-forget; reply optional
    s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    sub = ap.add_subparsers(dest="cmd", required=True)
    pe = sub.add_parser("set-eye")
    pe.add_argument("value", type=int)
    pb = sub.add_parser("set-bitlen",
                        help="SWO NRZ bit length in ref_200m cycles (=200e6/baud)")
    pb.add_argument("value", type=int)
    pt = sub.add_parser("set-tap",
                        help="IDDR IDELAY deskew tap 0..31, ALL lanes (loads now)")
    pt.add_argument("value", type=int)
    ptl = sub.add_parser("set-tap-lane",
                         help="per-lane IDELAY tap: lane 0..3, tap 0..31")
    ptl.add_argument("lane", type=int)
    ptl.add_argument("value", type=int)
    ptc = sub.add_parser("set-tap-clk",
                         help="clock-lane IDELAY tap 0..31 (>100MHz eye reach)")
    ptc.add_argument("value", type=int)
    sub.add_parser("rearm")
    a = ap.parse_args()

    if a.cmd == "set-eye":
        write_csr(a.ip, REG_EYE, a.value)
        print(f"set EYE delay = {a.value}")
    elif a.cmd == "set-bitlen":
        write_csr(a.ip, REG_BITLEN_LO, a.value & 0xFF)
        write_csr(a.ip, REG_BITLEN_HI, (a.value >> 8) & 0xFF)
        print(f"set SWO bitlen = {a.value} ref cycles (~{200e6/a.value/1e6:.3f} Mbaud)")
    elif a.cmd == "set-tap":
        write_csr(a.ip, REG_TAP, a.value & 0x1F)
        print(f"set IDELAY tap = {a.value & 0x1F} (all lanes)")
    elif a.cmd == "set-tap-lane":
        val = ((a.lane & 0x3) << 5) | (a.value & 0x1F)
        write_csr(a.ip, REG_TAP_LANE, val)
        print(f"set IDELAY lane {a.lane & 0x3} tap = {a.value & 0x1F}")
    elif a.cmd == "set-tap-clk":
        write_csr(a.ip, REG_TAP_CLK, a.value & 0x1F)
        print(f"set clock IDELAY tap = {a.value & 0x1F}")
    elif a.cmd == "rearm":
        write_csr(a.ip, REG_REARM, 1)
        print("soft re-arm pulsed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
