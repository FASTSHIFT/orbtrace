"""glitch_corr (E3b) — per capture, correlate the FPGA's mid-glitch counter
(half-periods 2..31 ref cycles that slipped past the edge LOCKOUT) with the
capture's decode quality (unknown%). If BAD captures consistently show many
more glitches than GOOD ones, the root cause of the intermittent ~7-10% is
pinned to 'glitches passing the lockout'.

Reads glitch_cnt from status reg NB+24/25 (combinational; read right after dump,
before re-arm clears it).

Usage: python3 glitch_corr.py [ip] [N]
"""
import os
import sys
import socket
import struct
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
SCR = os.path.join(os.path.dirname(HERE), "scripts")
sys.path.insert(0, HERE)
import etm35lib as L
import dsl_parse as D

IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.10.42"
N = int(sys.argv[2]) if len(sys.argv) > 2 else 30
DEPTH = 61440

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2.0)


def req(base, n):
    s.sendto(struct.pack("<H", base) + bytes(n), (IP, 5001))
    d, _ = s.recvfrom(2048)
    return d[2:2 + n]


def status():
    r = req(DEPTH, 26)
    full = r[2] & 1
    gen = r[3]
    glitch = r[24] | (r[25] << 8)
    return full, gen, glitch


def rearm():
    subprocess.run(["python3", os.path.join(SCR, "trace_ctrl.py"),
                    "--ip", IP, "rearm"], capture_output=True, text=True)


def dump(out, pg):
    subprocess.run(["python3", os.path.join(SCR, "trace_dump.py"),
                    "--ip", IP, "--depth", str(DEPTH), "-o", out,
                    "--prev-gen", str(pg)], capture_output=True, text=True)


def measure(path):
    raw = open(path, "rb").read()
    nibs = bytearray()
    for b in raw:
        nibs.append((b >> 4) & 0xF)
        nibs.append(b & 0xF)
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for x in L.find_isyncs(data) if L.is_flash(x.addr))
            if best is None or fl > best[0]:
                best = (fl, data)
    data = best[1]
    if L.has_tpiu_sync(data):
        ph, _ = L.find_tpiu_phase(data)
        data = L.tpiu_deframe_hsync(data, ph)
    unk = sum(1 for c in data if L._classify(c) == "unknown")
    return 100 * unk / max(1, len(data))


good_g, bad_g = [], []
print(f"{'cap':>4} {'unk%':>8} {'glitch':>7} {'verdict':>8}")
for i in range(N):
    _, pg, _ = status()
    rearm()
    out = f"/tmp/gc{i}.bin"
    dump(out, pg)
    _, _, glitch = status()   # read glitch AFTER dump, BEFORE next re-arm
    try:
        u = measure(out)
    except Exception:
        u = float("nan")
    good = u < 0.1
    (good_g if good else bad_g).append(glitch)
    print(f"{i:>4} {u:>8.3f} {glitch:>7} {'GOOD' if good else 'BAD':>8}")


def stat(xs):
    if not xs:
        return "n/a"
    xs = sorted(xs)
    return f"n={len(xs)} median={xs[len(xs)//2]} min={xs[0]} max={xs[-1]}"


print(f"\nGOOD glitch: {stat(good_g)}")
print(f"BAD  glitch: {stat(bad_g)}")
