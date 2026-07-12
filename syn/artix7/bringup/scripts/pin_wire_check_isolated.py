#!/usr/bin/env python3
"""pin_wire_check_isolated — same as pin_wire_check.py but explicitly halts
the STM32 CPU AND fully de-configures GPIOE trace pins before probing, so
the only signal source in the ring is our own mww ODR toggle. This isolates
the LA truth check from any residual TPIU/ETM output.

If the LA capture is CLEAN (only 0x00 and mask bit) throughout, the LA is
trustworthy. If dirty bytes still show up (top-3-bits != 0), the LA itself
has a bug.
"""
import argparse
import os
import socket
import subprocess
import sys
import time
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from pin_wire_check import (   # noqa: E402
    OcdSession, prep_gpio, la_capture, PIN_MAP, LA_BIT, PINS,
    GPIOE_BSRR, GPIOE_MODER, GPIOE_IDR, RCC_AHB4ENR,
)


def isolate_gpio(ocd):
    """Set all PE2..PE6 to analog input (MODER=11) with pull-down. Also
    disable ETM (TRCPRGCTLR.EN=0) so nothing feeds TRACE anymore."""
    # Disable ETM first so it stops driving anything
    ocd.cmd("mww 0xE0041FB0 0xC5ACCE55", 0.05)
    ocd.cmd("mww 0xE0041004 0x00000000", 0.05)
    # Also break TPIU->pin path by disabling the ETF (belt+braces)
    ocd.cmd("mww 0x5C014FB0 0xC5ACCE55", 0.05)
    ocd.cmd("mww 0x5C014020 0x00000000", 0.05)
    # Set PE2..PE6 back to analog input (default reset state) with pull-down
    ocd.cmd(f"mww {RCC_AHB4ENR:#x} [expr {{[mrw {RCC_AHB4ENR:#x}] | 0x10}}]", 0.05)
    ocd.cmd(f"set m [mrw {GPIOE_MODER:#x}]", 0.05)
    ocd.cmd(f"set m [expr {{$m | (0x3FFF << 4)}}]", 0.05)   # PE2..PE6 = 11 analog
    ocd.cmd(f"mww {GPIOE_MODER:#x} $m", 0.05)


def check_capture(cap_path, pin):
    """Return (n_clean, n_dirty, n_expected_pattern) counts."""
    d = open(cap_path, "rb").read()
    bit = LA_BIT[pin]
    mask = 1 << bit
    clean_lo = 0    # byte == 0x00
    clean_hi = 0    # byte == mask (only our bit set)
    dirty = 0
    for b in d:
        if b == 0:
            clean_lo += 1
        elif b == mask:
            clean_hi += 1
        else:
            dirty += 1
    return len(d), clean_lo, clean_hi, dirty


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--toggles", type=int, default=200)
    ap.add_argument("--pins", default="CLK,D0,D1,D2,D3")
    ap.add_argument("--outdir", default="/tmp/pin_wire_isolated")
    ap.add_argument("--seconds", type=float, default=5.0)
    a = ap.parse_args()

    os.makedirs(a.outdir, exist_ok=True)
    pins = a.pins.split(",")

    print("=== ISOLATED per-pin check: disable ETM/ETF/TPIU first ===")
    print("starting persistent openocd session (halted)...")
    ocd = OcdSession()
    isolate_gpio(ocd)
    # confirm ETM is off
    r = ocd.cmd("mdw 0xE0041004 1", 0.2)
    print(f"  TRCPRGCTLR after disable: {r.strip().splitlines()[-2:] if r else ''}")
    r = ocd.cmd("mdw 0x5C014020 1", 0.2)
    print(f"  ETF_CTL after disable:    {r.strip().splitlines()[-2:] if r else ''}")

    import threading
    results = {}
    try:
        for pin in pins:
            print(f"\n---- {pin} (PE{PIN_MAP[pin]}, LA bit {LA_BIT[pin]}) ----")
            prep_gpio(ocd, pin)

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
            time.sleep(0.05)
            got = la_capture(a.ip, cap_path, seconds=a.seconds)
            th.join(timeout=10)

            total, lo, hi, dirty = check_capture(cap_path, pin)
            print(f"  bytes={total}  clean(=0)={lo}({100*lo/total:.1f}%)  "
                  f"clean(=mask)={hi}({100*hi/total:.1f}%)  "
                  f"DIRTY={dirty}({100*dirty/total:.1f}%)")
            verdict = "LA_CLEAN" if dirty == 0 else "LA_BUG_or_LEAK"
            print(f"  verdict: {verdict}")
            results[pin] = (total, lo, hi, dirty)
    finally:
        ocd.close()

    print("\n=== SUMMARY ===")
    for pin, (total, lo, hi, dirty) in results.items():
        emoji = "✓" if dirty == 0 else "✗"
        print(f"  {emoji} {pin}: dirty={dirty}/{total} ({100*dirty/total:.2f}%)")


if __name__ == "__main__":
    sys.exit(main())
