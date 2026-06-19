#!/usr/bin/env python3
"""swo_oversample_limit — find the pulse-measurement decode floor as a function
of SAMPLES-PER-BIT, the true figure of merit for SWO (red-team r18 Q1).

r18's key point: the limit of pulse-length SWO decoding is set by *samples per
symbol*, not absolute sample rate. ORBTrace's 62M @ 500MSa/s = 8.06 samp/bit;
our 21M @ 200MSa/s = 9.52 samp/bit (clean), 28M @ 200MSa/s = 7.14 samp/bit
(starts to break). So the break point is somewhere in 7..9.5 samp/bit. If it is
~7, then IDDR 500MSa/s @ 56M (8.9 samp/bit) is still clean and r18's "62M must
break" is wrong; if ~9, r18 is right.

This answers it with ZERO hardware: take a known-good clean TPIU byte stream,
re-modulate it as an IDEAL NRZ SWO line at S samples/bit (with a RANDOM
sub-sample start phase, the real async-capture error — the FPGA's ref clock is
not aligned to the SWO bit grid), then decode it back through the SAME software
model as the FPGA front-end (pulse-length -> NRZ -> UART) and re-deframe.
Sweep S and report unknown% + recovered anchors. Pure quantisation/phase error,
no SI (that is a separate, additive penalty).

Usage: swo_oversample_limit.py [clean_tpiu.bin]
"""
import random
import sys

sys.path.insert(0, ".")
import etm35lib as L
from swo_model_bytes import pulse_capture, nrz_decode, uart_decode


def modulate_nrz(tpiu_bytes, samples_per_bit, phase_frac=0.0):
    """Render TPIU bytes as an ideal NRZ UART line (8N1, LSB first), at a
    fractional samples_per_bit. phase_frac in [0,1) shifts the bit grid relative
    to the sample grid (the async-capture phase). Returns a list of 0/1 samples
    (one per ref-clock tick)."""
    spb = samples_per_bit
    # build the ideal bit sequence: idle high, then per byte start(0) d0..d7 stop(1)
    bits = []
    # lead-in idle
    bits += [1] * 1
    for b in tpiu_bytes:
        bits.append(0)                      # start
        for k in range(8):
            bits.append((b >> k) & 1)       # LSB first
        bits.append(1)                      # stop
    bits += [1] * 1
    # sample the bit waveform at tick t -> bit index floor((t - phase)/spb)
    nsamp = int(len(bits) * spb) + 2
    out = bytearray(nsamp)
    for t in range(nsamp):
        bi = int((t - phase_frac * spb) / spb)
        out[t] = bits[bi] & 1 if 0 <= bi < len(bits) else 1
    return out


def decode_chain(samples, bitlen_cycles):
    """Run the FPGA-equivalent pulse->nrz->uart software model on a sample list,
    return recovered bytes. bitlen_cycles = samples_per_bit (the configured
    bitlen the front-end would use)."""
    pulses = pulse_capture(list(samples))
    bits = nrz_decode(pulses, max(2, round(bitlen_cycles)))
    return uart_decode(bits)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "/tmp/big2m.bin"
    tpiu = open(src, "rb").read()
    # use a manageable slice so the sweep is fast but still has several anchors
    tpiu = tpiu[:30000]
    base_etm = L.tpiu_deframe_walk(tpiu, want_stream=2)
    base_anchors = len([s for s in L.find_isyncs(base_etm) if L.is_flash(s.addr)])
    print(f"source {src}: {len(tpiu)}B, baseline anchors={base_anchors}")
    print(f"{'samp/bit':>8} {'unk%(avg)':>10} {'anchors(avg)':>13} {'worst unk%':>11}")

    for spb in [12, 11, 10, 9.5, 9, 8.5, 8, 7.5, 7, 6.5, 6, 5.5, 5]:
        unks = []
        anchs = []
        for trial in range(5):                  # average over random phases
            ph = random.random()
            samples = modulate_nrz(tpiu, spb, ph)
            rx = decode_chain(samples, spb)
            etm = L.tpiu_deframe_walk(rx, want_stream=2)
            if len(etm) < 16:
                etm = rx
            unk = sum(1 for c in etm if L._classify(c) == "unknown")
            unks.append(100 * unk / max(1, len(etm)))
            anchs.append(len([s for s in L.find_isyncs(etm) if L.is_flash(s.addr)]))
        avg = sum(unks) / len(unks)
        worst = max(unks)
        aavg = sum(anchs) / len(anchs)
        mark = "  <-- clean" if avg < 1.0 else ("  <-- BREAK" if avg > 5 else "")
        print(f"{spb:8.1f} {avg:10.3f} {aavg:13.1f} {worst:11.3f}{mark}")

    print("\nReference points:")
    print("  ORBTrace 62M @500MSa/s = 8.06 samp/bit")
    print("  ours     21M @200MSa/s = 9.52 samp/bit (measured clean)")
    print("  ours     28M @200MSa/s = 7.14 samp/bit (measured starts to break)")
    print("  IDDR 56M @500MSa/s     = 8.93 samp/bit")
    print("  IDDR 62M @500MSa/s     = 8.06 samp/bit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
