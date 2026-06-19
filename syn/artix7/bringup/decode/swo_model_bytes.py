#!/usr/bin/env python3
"""swo_model_bytes — software bit-exact model of the FPGA SWO front-end RTL
(swo_pulse_capture -> swo_nrz_decode -> swo_uart_decode), used as the golden
reference for the RTL replay regression (run_swo_sim.sh step 3).

This deliberately mirrors the HARDWARE algorithm (pulse-length -> NRZ bit
spreading with +bitlen/2 bias and a 12-bit cap -> 8N1 UART), NOT the mid-eye
decoder in swo_csv_decode.py. Same input (LA samples upsampled x UPS to the ref
domain) must yield the same bytes the RTL emits, byte for byte.

Usage:
  swo_model_bytes.py <csv> [--col 6] [--ups 4] [--bitlen 100]
                     [--max-samples N] -o out.hex
"""
import argparse
import sys


def load_swo_column(path, col, max_rows):
    swo = []
    with open(path) as f:
        for line in f:
            if line.startswith(";") or line[:4].lower() == "time":
                continue
            p = line.split(",")
            if len(p) <= col:
                continue
            try:
                swo.append(int(p[col]) & 1)
            except ValueError:
                continue
            if max_rows and len(swo) >= max_rows:
                break
    return swo


def pulse_capture(ref):
    """Mirror swo_pulse_capture: emit (level, count) when the level changes."""
    pulses = []
    prev = ref[0]
    cnt = 0
    for s in ref[1:]:
        if s != prev:
            pulses.append((prev, cnt + 1))
            prev = s
            cnt = 0
        else:
            cnt += 1
    pulses.append((prev, cnt + 1))
    return pulses


def nrz_decode(pulses, bitlen):
    """Mirror swo_nrz_decode: each pulse -> round(count/bitlen) bits of level,
    with +bitlen/2 bias and a 12-bit-per-pulse cap."""
    bits = []
    for level, count in pulses:
        acc = count + bitlen // 2
        c = 0
        while acc >= bitlen and c < 12:
            bits.append(level)
            acc -= bitlen
            c += 1
    return bits


def uart_decode(bits):
    """Mirror swo_uart_decode: 8N1 LSB-first, resync on start bit."""
    out = bytearray()
    i = 0
    n = len(bits)
    state = 0  # 0=WAITSTART, 1=GETBITS
    frame = []
    nb = 0
    while i < n:
        if state == 0:
            if bits[i] == 0:
                frame = []
                nb = 0
                state = 1
            i += 1
        else:
            if nb < 8:
                frame.append(bits[i])
                nb += 1
                i += 1
            else:
                # stop bit
                if bits[i] == 1:
                    b = 0
                    for k in range(8):
                        b |= frame[k] << k
                    out.append(b)
                state = 0
                i += 1
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--col", type=int, default=6)
    ap.add_argument("--ups", type=int, default=4)
    ap.add_argument("--bitlen", type=int, default=100)
    ap.add_argument("--max-samples", type=int, default=400000)
    ap.add_argument("-o", "--out", default="/tmp/swo_model.hex")
    a = ap.parse_args()

    swo = load_swo_column(a.csv, a.col, a.max_samples)
    ref = []
    for s in swo:
        ref.extend([s] * a.ups)
    pulses = pulse_capture(ref)
    bits = nrz_decode(pulses, a.bitlen)
    data = uart_decode(bits)
    with open(a.out, "w") as f:
        for x in data:
            f.write(f"{x:02x}\n")
    print(f"model bytes: {len(data)} -> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
