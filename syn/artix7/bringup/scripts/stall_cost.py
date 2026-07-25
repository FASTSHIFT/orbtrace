#!/usr/bin/env python3
"""stall_cost — measure the CPU cost of ETM trace at each TPIU port width.

TRCSTALLCTLR (DDI0494D 3.4.7) lets the ETM stall the processor when its trace
buffer runs low, which is what keeps our captures lossless. The narrower the
parallel port, the slower the trace drains, so the stall pressure -- and the
CPU slowdown -- should grow as the port shrinks. This quantifies that.

The metric is the CoreMark score printed on USART1, which needs no trace
decoding at all, so it works even when the capture side is unhappy. For each
configuration we set TPIU_CURPSIZE (and TRCSTALLCTLR), let the benchmark settle,
then average several reported Iterations/Sec.

Configurations swept: trace off (baseline), then {4,2,1}-bit x {stall on, off}.

Usage:
  python3 stall_cost.py [--samples 4] [--port /dev/ttyACM0]
"""
import argparse
import re
import subprocess
import sys
import time

try:
    import serial
except ImportError:
    print("needs pyserial")
    sys.exit(2)

# CoreSight / TPIU registers (H743, system-bus addresses -- RM0433 ROM table 2)
TPIU_CURPSIZE = 0x5C015004
TRCPRGCTLR    = 0xE0041004
TRCCONFIGR    = 0xE0041010     # bit3 = BB (branch broadcast)
TRCSTALLCTLR  = 0xE004102C

PSIZE = {4: 0x08, 2: 0x02, 1: 0x01}
# ISTALL=1 (bit8) + LEVEL=11 (bits[3:2]) = maximum stall / lossless trace
STALL_ON = 0x0000010C
STALL_OFF = 0x00000000

RE_SCORE = re.compile(rb"Iterations/Sec\s*:\s*([0-9.]+)")


def openocd(cmds, cwd):
    """Run a list of openocd -c commands against the target and return stdout."""
    argv = ["openocd", "-f", "interface/cmsis-dap.cfg", "-f", "target/stm32h7x.cfg",
            "-c", "init", "-c", "halt"]
    for c in cmds:
        argv += ["-c", c]
    argv += ["-c", "resume", "-c", "shutdown"]
    r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=120)
    return r.stdout + r.stderr


def read_scores(port, n, drop=2, timeout=300):
    """Collect n CoreMark scores from the serial banner stream.

    DROP the first `drop` scores: a 2000-iteration run takes ~1.6 s, so the run
    in flight when we changed the ETM config straddles both settings and the one
    after it can still be affected by the openocd halt/resume. Reading too eagerly
    was what made an earlier version of this script report byte-identical scores
    for every configuration -- it was always reporting the previous state."""
    s = serial.Serial(port, 115200, timeout=3)
    s.reset_input_buffer()
    out = []
    t0 = time.time()
    while len(out) < n + drop and time.time() - t0 < timeout:
        line = s.readline()
        m = RE_SCORE.search(line)
        if m:
            out.append(float(m.group(1)))
    s.close()
    return out[drop:] if len(out) > drop else out


def capture_and_measure_loss(width, tag):
    """Capture at this width and report what the trace looks like, so the CPU
    cost can be read against the actual data volume that reached us.

    A stall-vs-overflow tradeoff is only meaningful if the ETM is really
    saturating the port: if the workload never fills the ETF there is nothing to
    stall for, and a 0% CPU cost is real but says nothing about narrow ports.
    A-sync count is the honest activity signal (BB=1 gives ~150 per capture at
    300 MHz, BB=0 only ~11)."""
    import subprocess as sp
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    dec = os.path.join(os.path.dirname(here), "decode")
    raw = f"/tmp/stallcost_{tag}.bin"
    sp.run([sys.executable, os.path.join(here, "trace_ctrl.py"),
            "set-width", str(width)], capture_output=True)
    time.sleep(3)
    sp.run([sys.executable, os.path.join(here, "trace_doctor.py"),
            "capture", "snapshot", "--out", raw], capture_output=True)
    r = sp.run([sys.executable, os.path.join(dec, "trace_width.py"), raw,
                str(width)], capture_output=True, text=True, cwd=dec)
    best = [l for l in r.stdout.splitlines() if "A-sync" in l]
    top = max(best, key=lambda l: int(l.split("score=")[1])) if best else ""
    return top.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=4)
    ap.add_argument("--port", default="/dev/ttyACM0")
    ap.add_argument("--cwd", default=".",
                    help="dir containing interface/ + target/ for openocd")
    ap.add_argument("--with-capture", action="store_true",
                    help="also capture at each width and report A-sync/deframed "
                         "volume, to prove the port is actually saturated")
    a = ap.parse_args()

    results = []

    def measure(label, cmds):
        openocd(cmds, a.cwd)
        sc = read_scores(a.port, a.samples)
        if not sc:
            print(f"  {label}: NO SCORES (serial silent?)")
            return None
        avg = sum(sc) / len(sc)
        print(f"  {label}: {avg:8.1f} Iter/s  (n={len(sc)}, "
              f"spread {max(sc)-min(sc):.1f})")
        results.append((label, avg))
        return avg

    print("=== baseline: ETM disabled (no trace at all) ===")
    base = measure("trace off", [f"mww 0x{TRCPRGCTLR:08x} 0"])

    # Sweep both branch-broadcast settings: BB dominates the trace byte rate, so
    # BB=0 may never fill the ETF and thus never stall, while BB=1 emits an
    # address for every taken branch and is where narrow ports should hurt.
    for bb, bbname in ((0x00, "BB0"), (0x08, "BB1")):
        for w in (4, 2, 1):
            for stall, sname in ((STALL_ON, "stall on "), (STALL_OFF, "stall off")):
                print(f"=== {bbname} {w}-bit, {sname} ===")
                measure(f"{bbname} {w}-bit {sname}", [
                    f"mww 0x{TRCPRGCTLR:08x} 0",          # stop ETM to reconfigure
                    f"mww {hex(TRCCONFIGR)} 0x{bb:08x}",
                    f"mww 0x{TRCSTALLCTLR:08x} 0x{stall:08x}",
                    f"mww 0x{TPIU_CURPSIZE:08x} 0x{PSIZE[w]:08x}",
                    f"mww 0x{TRCPRGCTLR:08x} 1",          # restart ETM
                ])
                if a.with_capture:
                    print("      trace volume:",
                          capture_and_measure_loss(w, f"{bbname}_{w}b"))

    # restore: BB=0, 4-bit, stall on (our normal lossless config)
    openocd([f"mww 0x{TRCPRGCTLR:08x} 0",
             f"mww {hex(TRCCONFIGR)} 0",
             f"mww 0x{TRCSTALLCTLR:08x} 0x{STALL_ON:08x}",
             f"mww 0x{TPIU_CURPSIZE:08x} 0x{PSIZE[4]:08x}",
             f"mww 0x{TRCPRGCTLR:08x} 1"], a.cwd)

    print("\n=== summary (cost relative to trace off) ===")
    if base:
        for label, avg in results:
            print(f"  {label:18} {avg:8.1f} Iter/s   "
                  f"{100*(base-avg)/base:6.2f}% slower")
    return 0


if __name__ == "__main__":
    sys.exit(main())
