#!/usr/bin/env python3
"""freq_sweep — batch DIV x EYE capture-quality matrix, zero reflash.

For each STM32 HCLK divider (TRACECLK rate) and each OVERSAMPLE EYE delay,
re-arm the capture, dump it, and measure decode quality (unknown%, flash
anchors). Repeats each point R times for statistics. All knobs are runtime:
  * frequency  : OpenOCD writes RCC_CFGR.HPRE (downclock.cfg), no reset
  * EYE delay  : UDP CSR :5002 (trace_ctrl set-eye)
  * re-arm     : UDP CSR :5002 (trace_ctrl rearm)  -- no FPGA reflash

Prereqs: ETM already enabled (etm_enable.sh), a trace_stream bitstream with the
runtime-CSR support flashed once, PHY link up.

Usage:
  python3 freq_sweep.py --ip 192.168.10.42 \
      --divs 512,256,128,64,16,8 --eyes 0,8,16,38,64 --repeat 5
"""
import argparse
import os
import subprocess
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DECODE = os.path.join(ROOT, "decode")
sys.path.insert(0, DECODE)


def set_div(div):
    """Set STM32 HCLK divider via OpenOCD (no reset). Returns True on success."""
    env = dict(os.environ, DIV=str(div))
    cfgdir = os.path.join(ROOT, "target")
    cmd = ["timeout", "10", "openocd",
           "-f", "interface/stlink.cfg",
           "-f", "target/stm32f4x.cfg",
           "-f", os.path.join(cfgdir, "downclock.cfg")]
    r = subprocess.run(cmd, cwd=ROOT, env=env,
                       capture_output=True, text=True)
    return "HCLK now" in (r.stdout + r.stderr)


def set_eye(ip, eye):
    subprocess.run(["python3", os.path.join(HERE, "trace_ctrl.py"),
                    "--ip", ip, "set-eye", str(eye)],
                   capture_output=True, text=True)


def read_gen(ip, depth=61440):
    """Read the current capture-generation counter (status-only)."""
    r = subprocess.run(["python3", os.path.join(HERE, "trace_dump.py"),
                        "--ip", ip, "--depth", str(depth), "--status-only"],
                       capture_output=True, text=True)
    for tok in r.stdout.split():
        if tok.startswith("gen="):
            return int(tok.split("=")[1])
    return None


def rearm(ip):
    subprocess.run(["python3", os.path.join(HERE, "trace_ctrl.py"),
                    "--ip", ip, "rearm"], capture_output=True, text=True)


def dump(ip, out, prev_gen, depth=61440):
    """Re-arm then dump a CONFIRMED-FRESH capture (gen advanced + full)."""
    subprocess.run(["python3", os.path.join(HERE, "trace_dump.py"),
                    "--ip", ip, "--depth", str(depth), "-o", out,
                    "--prev-gen", str(prev_gen)],
                   capture_output=True, text=True)


def measure(path):
    """Return (unknown_pct, flash_anchors, stray_pcs) for a raw dump."""
    import etm35lib as L
    import dsl_parse as D
    raw = open(path, "rb").read()
    nibs = bytearray()
    for b in raw:
        nibs.append((b >> 4) & 0xF)
        nibs.append(b & 0xF)
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
            if best is None or fl > best[0]:
                best = (fl, data)
    data = best[1]
    if L.has_tpiu_sync(data):
        ph, _ = L.find_tpiu_phase(data)
        data = L.tpiu_deframe_hsync(data, ph)
    syncs = L.find_isyncs(data)
    flash = [s for s in syncs if L.is_flash(s.addr)]
    unk = sum(1 for c in data if L._classify(c) == "unknown")
    pcs = set(s.addr for s in flash)
    stray = sum(1 for a in pcs if not (0x08000000 <= a < 0x08002000))
    return (100 * unk / max(1, len(data)), len(flash), stray)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--divs", default="512,256,128,64,16,8")
    ap.add_argument("--eyes", default="0,8,16,38,64")
    ap.add_argument("--repeat", type=int, default=5)
    ap.add_argument("--depth", type=int, default=61440)
    a = ap.parse_args()

    divs = [int(x) for x in a.divs.split(",")]
    eyes = [int(x) for x in a.eyes.split(",")]

    print(f"{'DIV':>5} {'EYE':>4} {'unk%(med)':>10} {'unk%(max)':>10} "
          f"{'anchors(med)':>12} {'stray':>6}")
    results = {}
    for div in divs:
        if not set_div(div):
            print(f"{div:>5}  -- failed to set DIV (openocd)")
            continue
        for eye in eyes:
            set_eye(a.ip, eye)
            unks, anchors, strays = [], [], []
            for r in range(a.repeat):
                prev_gen = read_gen(a.ip, a.depth)
                rearm(a.ip)
                out = f"/tmp/sweep_d{div}_e{eye}_r{r}.bin"
                dump(a.ip, out, prev_gen if prev_gen is not None else 0, a.depth)
                try:
                    u, fa, st = measure(out)
                except Exception as e:
                    u, fa, st = float("nan"), 0, -1
                unks.append(u)
                anchors.append(fa)
                strays.append(st)
            med_u = statistics.median(unks)
            max_u = max(unks)
            med_a = statistics.median(anchors)
            tot_stray = sum(s for s in strays if s > 0)
            results[(div, eye)] = (med_u, max_u, med_a, tot_stray)
            print(f"{div:>5} {eye:>4} {med_u:>10.3f} {max_u:>10.3f} "
                  f"{med_a:>12.0f} {tot_stray:>6}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
