#!/usr/bin/env python3
"""pin_multi_toggle — drive MULTIPLE trace pins simultaneously via BSRR and
watch whether the un-driven pin (default D3) picks up ghost activity.

Purpose: quantify SSN (simultaneous switching noise) on the GPIOE bank.
Compares single-pin baseline to multi-pin (all-but-observed) case.

Usage:
    ./pin_multi_toggle.py --observe D3 --toggles 200
    ./pin_multi_toggle.py --observe D3 --observe D2 --toggles 200
"""
import argparse
import os
import socket
import sys
import time
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from pin_wire_check import (   # noqa: E402
    OcdSession, la_capture, PIN_MAP, LA_BIT, PINS,
    RCC_AHB4ENR, GPIOE_MODER, GPIOE_OTYPER, GPIOE_OSPEEDR,
    GPIOE_PUPDR, GPIOE_ODR, GPIOE_BSRR,
)


def prep_multi(ocd, driven_pins, observed_pins, speed=3):
    """Configure driven_pins as push-pull output OSPEEDR=speed,
    observed_pins as input pull-down."""
    # Disable ETM/ETF
    ocd.cmd("mww 0xE0041FB0 0xC5ACCE55", 0.03)
    ocd.cmd("mww 0xE0041004 0x00000000", 0.03)
    ocd.cmd("mww 0x5C014FB0 0xC5ACCE55", 0.03)
    ocd.cmd("mww 0x5C014020 0x00000000", 0.03)
    ocd.cmd(f"mww {RCC_AHB4ENR:#x} [expr {{[mrw {RCC_AHB4ENR:#x}] | 0x10}}]", 0.03)

    # MODER: driven=01 output, observed=00 input, other unchanged (but we
    # zero all trace pin nibbles first for a clean slate)
    ocd.cmd(f"set m [mrw {GPIOE_MODER:#x}]", 0.03)
    ocd.cmd(f"set m [expr {{$m & ~(0x3FFF << 4)}}]", 0.03)
    for pin in driven_pins:
        idx = PIN_MAP[pin]
        ocd.cmd(f"set m [expr {{$m | (0x1 << {2 * idx})}}]", 0.03)
    ocd.cmd(f"mww {GPIOE_MODER:#x} $m", 0.03)

    # OSPEEDR for driven pins
    ocd.cmd(f"set s [mrw {GPIOE_OSPEEDR:#x}]", 0.03)
    ocd.cmd(f"set s [expr {{$s & ~(0x3FFF << 4)}}]", 0.03)
    for pin in driven_pins:
        idx = PIN_MAP[pin]
        ocd.cmd(f"set s [expr {{$s | ({speed} << {2 * idx})}}]", 0.03)
    ocd.cmd(f"mww {GPIOE_OSPEEDR:#x} $s", 0.03)

    # OTYPER push-pull (clear all trace pin bits)
    ocd.cmd(f"mww {GPIOE_OTYPER:#x} "
            f"[expr {{[mrw {GPIOE_OTYPER:#x}] & ~(0x7C)}}]", 0.03)

    # PUPDR: pull-down on observed pins, none on driven
    ocd.cmd(f"set p [mrw {GPIOE_PUPDR:#x}]", 0.03)
    ocd.cmd(f"set p [expr {{$p & ~(0x3FFF << 4)}}]", 0.03)
    for pin in observed_pins:
        idx = PIN_MAP[pin]
        ocd.cmd(f"set p [expr {{$p | (0x2 << {2 * idx})}}]", 0.03)
    ocd.cmd(f"mww {GPIOE_PUPDR:#x} $p", 0.03)


def toggle_thread(pins, toggles):
    """Toggle multiple pins simultaneously in a background telnet session."""
    try:
        tn = socket.create_connection(("localhost", 4444), timeout=3.0)
        tn.settimeout(3.0)
        hi = sum(1 << PIN_MAP[p] for p in pins)
        lo = sum(1 << (PIN_MAP[p] + 16) for p in pins)
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
        print(f"    toggle: {e}")


def analyze(cap_path, driven_pins, observed_pins):
    """Return dict: for each observed pin, count edges."""
    d = open(cap_path, "rb").read()
    result = {}
    for pin in PINS:
        bit = LA_BIT[pin]
        mask = 1 << bit
        prev = d[0] & mask
        edges = 0
        ones = 0
        for b in d:
            v = b & mask
            if v != prev:
                edges += 1
                prev = v
            if v:
                ones += 1
        result[pin] = {"edges": edges, "duty%": 100 * ones / len(d)}
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--toggles", type=int, default=200)
    ap.add_argument("--observe", action="append", default=[],
                    help="pin to leave as input (repeat for multi)")
    ap.add_argument("--outdir", default="/tmp/pin_multi_toggle")
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--speed", type=int, default=3,
                    help="OSPEEDR value 0..3 for driven pins")
    a = ap.parse_args()

    if not a.observe:
        a.observe = ["D3"]

    observed = a.observe
    driven = [p for p in PINS if p not in observed]

    os.makedirs(a.outdir, exist_ok=True)
    print(f"driven: {driven}   observed: {observed}   OSPEEDR={a.speed}")

    ocd = OcdSession()
    try:
        # Step 1: single-driver baseline (drive only one pin -- pick first driven)
        baseline_pin = driven[0]
        print(f"\n--- baseline: only {baseline_pin} driven ---")
        prep_multi(ocd, [baseline_pin], [p for p in PINS if p != baseline_pin], a.speed)
        cap_bl = os.path.join(a.outdir, "baseline.bin")
        th = threading.Thread(target=toggle_thread,
                              args=([baseline_pin], a.toggles), daemon=True)
        th.start(); time.sleep(0.05)
        got = la_capture(a.ip, cap_bl, seconds=a.seconds)
        th.join(timeout=10)
        bl = analyze(cap_bl, [baseline_pin], observed)
        for pin in PINS:
            r = bl[pin]
            marker = "(driven)" if pin == baseline_pin else ("(observed)" if pin in observed else "")
            print(f"  {pin:4} edges={r['edges']:>7}  duty={r['duty%']:5.1f}%  {marker}")

        # Step 2: multi-driver (all driven pins toggle together)
        print(f"\n--- multi-drive: {driven} together, observing {observed} ---")
        prep_multi(ocd, driven, observed, a.speed)
        cap_multi = os.path.join(a.outdir, "multi.bin")
        th = threading.Thread(target=toggle_thread,
                              args=(driven, a.toggles), daemon=True)
        th.start(); time.sleep(0.05)
        got = la_capture(a.ip, cap_multi, seconds=a.seconds)
        th.join(timeout=10)
        mu = analyze(cap_multi, driven, observed)
        for pin in PINS:
            r = mu[pin]
            marker = "(driven)" if pin in driven else "(observed)"
            print(f"  {pin:4} edges={r['edges']:>7}  duty={r['duty%']:5.1f}%  {marker}")

        # Delta on observed pins
        print(f"\n--- crosstalk on observed pins ---")
        for pin in observed:
            d0 = bl[pin]["edges"]
            d1 = mu[pin]["edges"]
            print(f"  {pin}: baseline={d0}  multi-drive={d1}  "
                  f"delta={d1 - d0}")
    finally:
        ocd.close()


if __name__ == "__main__":
    sys.exit(main())
