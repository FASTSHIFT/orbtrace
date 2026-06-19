#!/usr/bin/env python3
"""swo_baud_sweep — sweep the SWO baud rate and report decode quality at each,
WITHOUT re-synthesising or restarting OpenOCD.

For each baud:
  1. set the STM32 TPIU ACPR live via the resident OpenOCD telnet (port 4444):
     ACPR = round(HCLK/baud) - 1   (must divide HCLK; we pick exact divisors)
  2. set the FPGA SWO front-end bitlen via UDP CSR :5002 (bitlen=200e6/baud)
  3. soft re-arm the capture, dump 60 KB, deframe + ETM-decode, report
     unknown% and flash anchors.

The FPGA bitlen is a runtime CSR (swo_stream_top), and ACPR is a live register
write, so the whole sweep runs against one resident OpenOCD session (SWO must
stay alive — debugger exit kills it).

Usage:
  swo_baud_sweep.py [--ip 192.168.10.42] [--hclk 168e6] [--bauds 2e6,4e6,6e6,8e6]
"""
import argparse
import socket
import subprocess
import sys
import time

sys.path.insert(0, ".")
import etm35lib as L  # noqa: E402

ACPR_ADDR = 0xE0040010


def ocd_telnet(cmd, host="localhost", port=4444, timeout=3.0):
    s = socket.create_connection((host, port), timeout)
    s.settimeout(timeout)
    time.sleep(0.1)
    s.recv(4096)  # banner
    s.sendall((cmd + "\n").encode())
    time.sleep(0.2)
    try:
        data = s.recv(4096).decode("utf-8", "replace")
    except socket.timeout:
        data = ""
    s.sendall(b"exit\n")
    s.close()
    return data


def set_csr(ip, addr, val, port=5002):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.0)
    s.sendto(bytes([addr & 0xFF, val & 0xFF, 0, 0]), (ip, port))
    try:
        s.recvfrom(2048)
    except socket.timeout:
        pass
    s.close()


def dump(ip, depth, out):
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    td = os.path.join(here, "..", "scripts", "trace_dump.py")
    subprocess.run(["python3", td, "--ip", ip,
                    "--depth", str(depth), "-o", out],
                   capture_output=True)


def decode(path):
    raw = open(path, "rb").read()
    etm = L.tpiu_deframe_walk(raw, want_stream=2) if L.has_tpiu_sync(raw) else raw
    if len(etm) < 16:
        etm = L.tpiu_deframe_walk(raw)
    unk = sum(1 for c in etm if L._classify(c) == "unknown")
    fl = [s for s in L.find_isyncs(etm) if L.is_flash(s.addr)]
    sync = raw.count(b"\xff\xff\xff\x7f")
    nz = sum(1 for b in raw if b)
    return sync, 100 * unk / max(1, len(etm)), len(fl), nz


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--hclk", type=float, default=168e6)
    ap.add_argument("--bauds", default="2e6,4e6,6e6,8e6,10.5e6,12e6")
    ap.add_argument("--depth", type=int, default=61440)
    a = ap.parse_args()

    bauds = [float(x) for x in a.bauds.split(",")]
    print(f"{'baud':>9} {'ACPR':>5} {'bitlen':>6} {'sync':>5} "
          f"{'unknown%':>9} {'anchors':>7} {'nonzero':>8}")
    for baud in bauds:
        div = round(a.hclk / baud)
        acpr = div - 1
        real_baud = a.hclk / div
        bitlen = round(200e6 / real_baud)
        # 1) STM32 ACPR live
        ocd_telnet(f"mww 0x{ACPR_ADDR:08x} 0x{acpr:x}")
        # 2) FPGA bitlen CSR
        set_csr(a.ip, 0x03, bitlen & 0xFF)
        set_csr(a.ip, 0x04, (bitlen >> 8) & 0xFF)
        # 3) re-arm + settle + dump
        set_csr(a.ip, 0x02, 1)
        time.sleep(1.0)
        out = f"/tmp/swo_b{int(real_baud/1e3)}k.bin"
        dump(a.ip, a.depth, out)
        sync, unk, anch, nz = decode(out)
        print(f"{real_baud/1e6:8.3f}M {acpr:5d} {bitlen:6d} {sync:5d} "
              f"{unk:8.3f}% {anch:7d} {nz:8d}   -> {out}")
    # restore 2M
    ocd_telnet(f"mww 0x{ACPR_ADDR:08x} 0x53")
    set_csr(a.ip, 0x03, 100)
    set_csr(a.ip, 0x04, 0)
    print("restored 2 MHz")
    return 0


if __name__ == "__main__":
    sys.exit(main())
