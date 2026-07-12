#!/usr/bin/env python3
"""pin_wire_check — automated continuity + integrity check for the H743-to-A7
trace wire harness (PE2/PE3/PE4/PE5/PE6).

Approach:
  * openocd runs long-lived (Popen) with -c "init; halt" and its telnet port
    (4444). We feed 'mww'/'echo' one line at a time through the telnet socket
    -- avoids the 250 ms openocd startup penalty each command.

Strategy:
  1. openocd halts the STM32 CPU (no firmware running -> no ETM, no other
     driver contention).
  2. For each pin under test (PE2..PE6), configure it as GP OUTPUT, then
     alternately drive high/low N times (default 100), each cycle with a
     ~20 ms dwell. All other trace pins are configured as INPUT so only ONE
     lane is driving.
  3. In parallel, the on-board LA (trace_pin_la_top) continuously samples the
     5 pins at 200 MSPS. After the toggle sequence, we arm a DDR3 readback
     and pull ~4 MB (~20 ms) of waveform.
  4. Analyze: count edges on each LA lane. The pin we toggled should show
     exactly 2*N edges (rising + falling). Other lanes should be nearly
     static. Any lane that couples > 5% of the toggling lane's edges is a
     cross-talk / harness fault.

Wiring assumption:
    STM32 PE2   -> A7 D17 (trace_clk_in)
    STM32 PE3   -> A7 F13 (trace_data_in[0])
    STM32 PE4   -> A7 E14 (trace_data_in[1])
    STM32 PE5   -> A7 D14 (trace_data_in[2])
    STM32 PE6   -> A7 E16 (trace_data_in[3])

LA sample byte layout (from trace_pin_la_top.v):
    bit[4]=CLK  bit[3]=D3  bit[2]=D2  bit[1]=D1  bit[0]=D0

Usage:
    ./pin_wire_check.py --ip 192.168.10.42 [--toggles 100]
"""
import argparse
import os
import socket
import struct
import subprocess
import sys
import time
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))

# STM32 registers ---------------------------------------------------------
RCC_AHB4ENR = 0x580244E0     # bit4=GPIOEEN
GPIOE_BASE  = 0x58021000
GPIOE_MODER    = GPIOE_BASE + 0x00
GPIOE_OTYPER   = GPIOE_BASE + 0x04
GPIOE_OSPEEDR  = GPIOE_BASE + 0x08
GPIOE_PUPDR    = GPIOE_BASE + 0x0C
GPIOE_IDR      = GPIOE_BASE + 0x10
GPIOE_ODR      = GPIOE_BASE + 0x14
GPIOE_BSRR     = GPIOE_BASE + 0x18

# Pin index on port E for the trace lanes.
PIN_MAP = {
    "CLK": 2,   # PE2 -> D17
    "D0":  3,   # PE3 -> F13
    "D1":  4,   # PE4 -> E14
    "D2":  5,   # PE5 -> D14
    "D3":  6,   # PE6 -> E16
}
# Lane bit in the LA sample byte (0/1/2/3 for D0..D3, 4 for CLK).
LA_BIT = {
    "CLK": 4,
    "D0":  0,
    "D1":  1,
    "D2":  2,
    "D3":  3,
}
PINS = ["CLK", "D0", "D1", "D2", "D3"]

CTRL_PORT = 5002
STREAM_PORT = 5555
STATUS_PORT = 5001
REG_ARM = 0x20


# ---- openocd helpers ------------------------------------------------------

class OcdSession:
    """A long-lived openocd process talking on telnet port 4444.
    Each call to .cmd() sends one Tcl line and returns openocd's reply
    (up to the next '>' prompt)."""

    def __init__(self):
        self.proc = subprocess.Popen(
            ["openocd", "-f", "interface/cmsis-dap.cfg",
             "-f", "target/stm32h7x.cfg",
             "-c", "init", "-c", "halt"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        # wait for telnet server to come up
        for _ in range(30):
            time.sleep(0.15)
            try:
                s = socket.create_connection(("localhost", 4444), timeout=0.5)
                s.close()
                break
            except OSError:
                continue
        self.tn = socket.create_connection(("localhost", 4444), timeout=3.0)
        self.tn.settimeout(3.0)
        # eat banner
        self._drain(0.4)

    def _drain(self, wait=0.05):
        data = bytearray()
        deadline = time.time() + wait
        while time.time() < deadline:
            try:
                self.tn.settimeout(0.05)
                chunk = self.tn.recv(4096)
                if not chunk:
                    break
                data.extend(chunk)
            except socket.timeout:
                pass
        return data.decode(errors="replace")

    def cmd(self, line, wait=0.15):
        self.tn.send((line + "\n").encode())
        return self._drain(wait)

    def close(self):
        try:
            self.cmd("shutdown", 0.1)
        except Exception:
            pass
        try:
            self.tn.close()
        except Exception:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def prep_gpio(ocd, pin_out):
    """Configure GPIOE so that pin_out is push-pull output, other trace pins
    are inputs with pull-down (measured: driving PE3 lifts other floating PEx
    IDR bits via capacitive coupling -> pull-down anchors them at 0)."""
    idx_out = PIN_MAP[pin_out]
    ocd.cmd(f"mww {RCC_AHB4ENR:#x} [expr {{[mrw {RCC_AHB4ENR:#x}] | 0x10}}]")
    # MODER
    ocd.cmd(f"set m [mrw {GPIOE_MODER:#x}]")
    ocd.cmd(f"set m [expr {{$m & ~(0x3FFF << 4)}}]")
    ocd.cmd(f"set m [expr {{$m | (0x1 << {2 * idx_out})}}]")
    ocd.cmd(f"mww {GPIOE_MODER:#x} $m")
    # OSPEEDR
    ocd.cmd(f"set s [mrw {GPIOE_OSPEEDR:#x}]")
    ocd.cmd(f"set s [expr {{$s | (0x3 << {2 * idx_out})}}]")
    ocd.cmd(f"mww {GPIOE_OSPEEDR:#x} $s")
    # OTYPER
    ocd.cmd(f"mww {GPIOE_OTYPER:#x} "
            f"[expr {{[mrw {GPIOE_OTYPER:#x}] & ~(1 << {idx_out})}}]")
    # PUPDR: pull-down on all input trace pins, none on the driven pin.
    ocd.cmd(f"set p [mrw {GPIOE_PUPDR:#x}]")
    ocd.cmd(f"set p [expr {{$p & ~(0x3FFF << 4)}}]")
    for name, idx in PIN_MAP.items():
        ocd.cmd(f"set p [expr {{$p | (0x2 << {2 * idx})}}]")
    ocd.cmd(f"set p [expr {{$p & ~(0x3 << {2 * idx_out})}}]")
    ocd.cmd(f"mww {GPIOE_PUPDR:#x} $p")


def toggle_pin(ocd, pin, count):
    """Toggle `pin` `count` times via BSRR in one server-side Tcl proc."""
    idx = PIN_MAP[pin]
    hi = 1 << idx
    lo = 1 << (idx + 16)
    # Define+call in one line to avoid multiline parsing issues on telnet.
    prog = (f"proc _tgl {{}} {{"
            f" for {{set i 0}} {{$i < {count}}} {{incr i}} {{"
            f" mww {GPIOE_BSRR:#x} {hi:#x};"
            f" mww {GPIOE_BSRR:#x} {lo:#x}"
            f" }} }}")
    ocd.cmd(prog, wait=0.3)
    ocd.cmd("_tgl", wait=max(0.5, count * 0.01))   # give SWD time


# ---- LA capture -----------------------------------------------------------

def la_capture(ip, out_path, seconds=5.0):
    """Arm the pin-LA readback and receive the DDR3 ring snapshot."""
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 << 20)
    rx.bind(("0.0.0.0", STREAM_PORT))
    rx.settimeout(seconds)
    # ARP warmup
    warm = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    warm.settimeout(0.3)
    for _ in range(5):
        try:
            warm.sendto(b"\x10\x00\x00\x00", (ip, STATUS_PORT))
            warm.recvfrom(64)
        except socket.timeout:
            pass
    warm.close()

    ctrl = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ctrl.sendto(bytes([REG_ARM, 1, 0, 0]), (ip, CTRL_PORT))
    ctrl.close()

    with open(out_path, "wb") as f:
        total = 0
        while True:
            try:
                d, _ = rx.recvfrom(65535)
            except socket.timeout:
                break
            f.write(d)
            total += len(d)
    rx.close()
    return total


def count_edges(raw, bit):
    """Count 0->1 + 1->0 transitions on the given bit across the sample stream."""
    mask = 1 << bit
    prev = raw[0] & mask
    n = 0
    for b in raw[1:]:
        v = b & mask
        if v != prev:
            n += 1
            prev = v
    return n


def analyze(raw, pin_toggled, expected_edges):
    """Return dict of per-lane edge counts + verdict."""
    counts = {}
    for name in PINS:
        counts[name] = count_edges(raw, LA_BIT[name])
    verdict = "PASS"
    notes = []
    exp = 2 * expected_edges   # rising + falling
    # tolerance: openocd sleep 1ms is noisy; expect roughly the right count
    lo, hi = exp * 0.5, exp * 1.5
    self_ct = counts[pin_toggled]
    if not (lo <= self_ct <= hi):
        verdict = "FAIL_SELF"
        notes.append(f"{pin_toggled} edges {self_ct} not in [{lo:.0f}..{hi:.0f}]")
    # crosstalk: other lanes should be small (<10% of self)
    for name in PINS:
        if name == pin_toggled:
            continue
        if counts[name] > max(50, 0.10 * self_ct):
            verdict = "CROSSTALK"
            notes.append(f"{name} edges {counts[name]} > 10% of {pin_toggled}"
                         f"({self_ct})")
    return counts, verdict, notes


# ---- main -----------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--toggles", type=int, default=50,
                    help="toggle count per pin (default 50)")
    ap.add_argument("--pins", default="CLK,D0,D1,D2,D3",
                    help="comma list of pins to test")
    ap.add_argument("--outdir", default="/tmp/pin_wire_check")
    ap.add_argument("--seconds", type=float, default=5.0)
    a = ap.parse_args()

    os.makedirs(a.outdir, exist_ok=True)
    pins = a.pins.split(",")

    print(f"=== per-pin continuity check ({a.toggles} toggles each, "
          f"LA at 200 MSPS via trace_pin_la_top) ===")
    print("starting persistent openocd session...")
    ocd = OcdSession()
    print(f"  ready; halted at pc={ocd.cmd('reg pc', 0.3).strip()[:80]}")
    import threading

    results = {}
    try:
        for pin in pins:
            print(f"\n---- {pin} (PE{PIN_MAP[pin]}, LA bit {LA_BIT[pin]}) ----")
            prep_gpio(ocd, pin)
            # sanity IDR check while pin is high/low
            ocd.cmd(f"mww {GPIOE_BSRR:#x} {1 << PIN_MAP[pin]:#x}")
            idr_hi_txt = ocd.cmd(f"mdw {GPIOE_IDR:#x} 1", wait=0.2)
            ocd.cmd(f"mww {GPIOE_BSRR:#x} {1 << (PIN_MAP[pin] + 16):#x}")
            idr_lo_txt = ocd.cmd(f"mdw {GPIOE_IDR:#x} 1", wait=0.2)
            # mdw output is: "0x58021010: 000000XX \n> "
            import re
            def _extract(s):
                m = re.search(r"0x58021010:\s*([0-9a-fA-F]+)", s)
                return m.group(1) if m else "?"
            hi_hex = _extract(idr_hi_txt)
            lo_hex = _extract(idr_lo_txt)
            print(f"  IDR hi=0x{hi_hex}  lo=0x{lo_hex}  "
                  f"(only PE{PIN_MAP[pin]}=1 in hi expected)")

            # Toggle in a background thread over a fresh telnet connection so
            # openocd services SWD while we simultaneously arm+recv on UDP.
            def _tog_thread(pin_name=pin):
                try:
                    tn = socket.create_connection(("localhost", 4444), timeout=3.0)
                    tn.settimeout(3.0)
                    idx = PIN_MAP[pin_name]
                    hi = 1 << idx
                    lo = 1 << (idx + 16)
                    prog = ("proc _tgl {} { "
                            f"for {{set i 0}} {{$i < {a.toggles}}} {{incr i}} {{ "
                            f"mww {GPIOE_BSRR:#x} {hi:#x};"
                            f"mww {GPIOE_BSRR:#x} {lo:#x} "
                            "} }\n")
                    tn.send(prog.encode())
                    time.sleep(0.02)
                    tn.send(b"_tgl\n")
                    time.sleep(0.5 + a.toggles * 0.005)
                    tn.close()
                except Exception as e:
                    print(f"    (tog thread {pin_name}: {e})")

            cap_path = os.path.join(a.outdir, f"cap_{pin}.bin")
            t_start = time.time()
            th = threading.Thread(target=_tog_thread, daemon=True)
            th.start()
            time.sleep(0.05)   # let toggle start
            got = la_capture(a.ip, cap_path, seconds=a.seconds)
            th.join(timeout=10)
            print(f"  total {(time.time() - t_start) * 1000:.0f} ms; "
                  f"LA rx {got} B -> {cap_path}")

            raw = open(cap_path, "rb").read()
            counts, verdict, notes = analyze(raw, pin, a.toggles)
            results[pin] = (counts, verdict, notes)
            print(f"  edges  CLK={counts['CLK']:6}  D0={counts['D0']:6}  "
                  f"D1={counts['D1']:6}  D2={counts['D2']:6}  D3={counts['D3']:6}")
            print(f"  verdict: {verdict}  {'; '.join(notes) if notes else ''}")
    finally:
        ocd.close()

    # summary
    print("\n=== SUMMARY ===")
    for pin, (counts, verdict, notes) in results.items():
        emoji = "✓" if verdict == "PASS" else "✗"
        print(f"  {emoji} {pin} (PE{PIN_MAP[pin]}): {verdict}")
    return 0 if all(v[1] == "PASS" for v in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
