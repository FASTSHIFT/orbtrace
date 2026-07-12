#!/usr/bin/env python3
"""pin_speed_scan — sweep the STM32 GPIO OSPEEDR (output slew) for each trace
pin and quantify per-lane crosstalk with the on-board pin LA.

Depends on: pin_wire_check_isolated pipeline (ETM disabled, only mww ODR
drives the pins).

For every (pin, speed) combination we:
  1. configure pin as GP OUTPUT push-pull with the target OSPEEDR value
     (00 = low, 01 = medium, 10 = high, 11 = very-high).
  2. toggle 200 times via BSRR.
  3. arm the LA, receive 4 MB (~20 ms), classify bytes:
       - 0x00 or (1<<lane_bit) : "clean"
       - else                  : "dirty" (crosstalk-induced)

Result: dirty% per (pin,speed). If lowering speed drops the dirty% on
neighbours, the culprit is edge-rate SI/crosstalk. If dirty% stays constant,
the pin is coupled by something other than edge rate (long trace / near
oscillator / etc).

Usage:
  ./pin_speed_scan.py --pins CLK,D0,D1,D2,D3 --speeds 0,1,2,3
"""
import argparse
import os
import socket
import sys
import time
import threading
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from pin_wire_check import (   # noqa: E402
    OcdSession, la_capture, PIN_MAP, LA_BIT, PINS,
    RCC_AHB4ENR, GPIOE_BASE, GPIOE_MODER, GPIOE_OTYPER,
    GPIOE_OSPEEDR, GPIOE_PUPDR, GPIOE_IDR, GPIOE_ODR, GPIOE_BSRR,
)


def isolate_and_prep(ocd, pin_out, speed):
    """Disable ETM/ETF, then configure pin_out as output at `speed`, others
    as input with pull-down."""
    idx_out = PIN_MAP[pin_out]

    # Disable ETM + ETF + TPIU so nothing else drives the pins.
    ocd.cmd("mww 0xE0041FB0 0xC5ACCE55", 0.03)
    ocd.cmd("mww 0xE0041004 0x00000000", 0.03)
    ocd.cmd("mww 0x5C014FB0 0xC5ACCE55", 0.03)
    ocd.cmd("mww 0x5C014020 0x00000000", 0.03)

    # Enable GPIOE clock
    ocd.cmd(f"mww {RCC_AHB4ENR:#x} [expr {{[mrw {RCC_AHB4ENR:#x}] | 0x10}}]", 0.03)

    # MODER: PE2..PE6 input, pin_out output (01)
    ocd.cmd(f"set m [mrw {GPIOE_MODER:#x}]", 0.03)
    ocd.cmd(f"set m [expr {{$m & ~(0x3FFF << 4)}}]", 0.03)
    ocd.cmd(f"set m [expr {{$m | (0x1 << {2 * idx_out})}}]", 0.03)
    ocd.cmd(f"mww {GPIOE_MODER:#x} $m", 0.03)

    # OSPEEDR for pin_out; leave other trace pins at 00 (irrelevant since inputs)
    ocd.cmd(f"set s [mrw {GPIOE_OSPEEDR:#x}]", 0.03)
    ocd.cmd(f"set s [expr {{$s & ~(0x3 << {2 * idx_out})}}]", 0.03)
    ocd.cmd(f"set s [expr {{$s | ({speed} << {2 * idx_out})}}]", 0.03)
    ocd.cmd(f"mww {GPIOE_OSPEEDR:#x} $s", 0.03)

    # OTYPER push-pull (clear bit)
    ocd.cmd(f"mww {GPIOE_OTYPER:#x} "
            f"[expr {{[mrw {GPIOE_OTYPER:#x}] & ~(1 << {idx_out})}}]", 0.03)

    # PUPDR: pull-down on all trace input pins, none on driven pin
    ocd.cmd(f"set p [mrw {GPIOE_PUPDR:#x}]", 0.03)
    ocd.cmd(f"set p [expr {{$p & ~(0x3FFF << 4)}}]", 0.03)
    for name, idx in PIN_MAP.items():
        ocd.cmd(f"set p [expr {{$p | (0x2 << {2 * idx})}}]", 0.03)
    ocd.cmd(f"set p [expr {{$p & ~(0x3 << {2 * idx_out})}}]", 0.03)
    ocd.cmd(f"mww {GPIOE_PUPDR:#x} $p", 0.03)


def classify(cap_path, pin):
    """Return (total, clean_lo, clean_hi, dirty, per_lane_dirty_dict)."""
    d = open(cap_path, "rb").read()
    bit = LA_BIT[pin]
    mask = 1 << bit
    clean_lo = clean_hi = dirty = 0
    per_lane = {name: 0 for name in PINS if name != pin}
    for b in d:
        if b == 0:
            clean_lo += 1
        elif b == mask:
            clean_hi += 1
        else:
            dirty += 1
            for name in per_lane:
                other_mask = 1 << LA_BIT[name]
                if b & other_mask:
                    per_lane[name] += 1
    return len(d), clean_lo, clean_hi, dirty, per_lane


def toggle_thread(pin, toggles):
    """Background thread: define + run the toggle proc via a second telnet."""
    try:
        tn = socket.create_connection(("localhost", 4444), timeout=3.0)
        tn.settimeout(3.0)
        idx = PIN_MAP[pin]
        hi = 1 << idx
        lo = 1 << (idx + 16)
        prog = ("proc _tgl {} { "
                f"for {{set i 0}} {{$i < {toggles}}} {{incr i}} {{ "
                f"mww {GPIOE_BSRR:#x} {hi:#x};"
                f"mww {GPIOE_BSRR:#x} {lo:#x} "
                "} }\n")
        tn.send(prog.encode())
        time.sleep(0.02)
        tn.send(b"_tgl\n")
        time.sleep(0.5 + toggles * 0.005)
        tn.close()
    except Exception as e:
        print(f"    (toggle thread: {e})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--toggles", type=int, default=200)
    ap.add_argument("--pins", default="CLK,D0,D1,D2,D3")
    ap.add_argument("--speeds", default="0,1,2,3",
                    help="OSPEEDR values 0=low, 1=medium, 2=high, 3=very-high")
    ap.add_argument("--outdir", default="/tmp/pin_speed_scan")
    ap.add_argument("--seconds", type=float, default=5.0)
    a = ap.parse_args()

    os.makedirs(a.outdir, exist_ok=True)
    pins = a.pins.split(",")
    speeds = [int(x) for x in a.speeds.split(",")]

    print(f"=== speed sweep ({a.toggles} toggles/pt, ETM off, only mww driver) ===")
    ocd = OcdSession()
    speed_names = {0: "low", 1: "medium", 2: "high", 3: "veryhigh"}

    results = {}
    try:
        for pin in pins:
            print(f"\n---- {pin} (PE{PIN_MAP[pin]}) ----")
            for sp in speeds:
                isolate_and_prep(ocd, pin, sp)
                cap_path = os.path.join(a.outdir, f"{pin}_speed{sp}.bin")
                th = threading.Thread(target=toggle_thread,
                                      args=(pin, a.toggles), daemon=True)
                th.start()
                time.sleep(0.05)
                got = la_capture(a.ip, cap_path, seconds=a.seconds)
                th.join(timeout=10)

                total, lo, hi, dirty, per_lane = classify(cap_path, pin)
                # top crosstalk lane
                top_leak_lane = max(per_lane, key=per_lane.get) if per_lane else "-"
                top_leak_ct = per_lane.get(top_leak_lane, 0) if per_lane else 0
                dirty_pct = 100 * dirty / total
                leak_pct = 100 * top_leak_ct / total
                print(f"  speed={sp} ({speed_names[sp]:8}) "
                      f"clean={100*(lo+hi)/total:5.1f}%  "
                      f"DIRTY={dirty_pct:5.2f}%  "
                      f"worst-leak-lane={top_leak_lane} {leak_pct:5.2f}%")
                results.setdefault(pin, []).append(
                    (sp, dirty, dirty_pct, per_lane))
    finally:
        ocd.close()

    print("\n=== SUMMARY (dirty% per speed) ===")
    header = "pin   " + "  ".join(f"speed{s}" for s in speeds)
    print(header)
    for pin, rows in results.items():
        cells = "  ".join(f"{r[2]:6.2f}%" for r in rows)
        print(f"{pin:5} {cells}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
