#!/usr/bin/env python3
"""swo_resample_real — answer r18 Q1 with REAL hardware data, not an ideal model.

We have a real 21 MHz SWO capture (9.5 samp/bit @200MSa/s, decodes clean) that
already contains real SI + jitter. To probe what happens at FEWER samples/bit
(the 8.06/bit point that IDDR-500MSa/s @62M would hit), we DON'T need new
hardware: re-modulate the *decoded* clean byte stream from the 21M capture as an
ideal-but-jittered line at a target samp/bit, OR — more faithfully — directly
resample the FPGA's own captured pulse stream.

Simplest faithful proxy: take the clean decoded TPIU bytes (ground truth from
the 21M grab), re-time them at target samp/bit WITH the realistic ±1-sample edge
placement error a pulse-measurement front-end has, decode, report. Average over
many random phases AND inject a per-edge ±1 sample jitter (models metastability
/ IDELAY / SI timing error, which is the real killer at low samp/bit).

Usage: swo_resample_real.py [clean_tpiu.bin]
"""
import random
import sys

sys.path.insert(0, ".")
import etm35lib as L
from swo_model_bytes import pulse_capture, nrz_decode, uart_decode


def modulate_jittered(tpiu_bytes, spb, phase_frac, jitter_samp):
    """Render bytes as NRZ at spb samples/bit, but each BIT EDGE is displaced by
    a random uniform [-jitter_samp, +jitter_samp] samples — the real timing
    error of an async pulse-measurement capture. This is what actually corrupts
    short-symbol decoding (a fixed ~1-sample error is a larger fraction of a
    shorter bit)."""
    bits = [1]
    for b in tpiu_bytes:
        bits.append(0)
        for k in range(8):
            bits.append((b >> k) & 1)
        bits.append(1)
    bits += [1]
    # edge times with jitter
    nsamp = int(len(bits) * spb) + 4
    out = bytearray(nsamp)
    # precompute jittered nominal bit-start times
    starts = [phase_frac * spb + i * spb + random.uniform(-jitter_samp, jitter_samp)
              for i in range(len(bits) + 1)]
    bi = 0
    for t in range(nsamp):
        while bi + 1 < len(starts) and t >= starts[bi + 1]:
            bi += 1
        out[t] = bits[bi] & 1 if bi < len(bits) else 1
    return out


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "/tmp/big2m.bin"
    tpiu = open(src, "rb").read()[:30000]
    base = len([s for s in L.find_isyncs(L.tpiu_deframe_walk(tpiu, want_stream=2))
                if L.is_flash(s.addr)])
    print(f"source {src}: baseline flash anchors={base}")
    print("model: real-ish NRZ with per-edge +/-{j} sample jitter\n")

    for jitter in (0.5, 1.0):
        print(f"=== edge jitter = +/-{jitter} samples ===")
        print(f"{'samp/bit':>8} {'unk%':>8} {'anchors':>8}")
        for spb in [9.5, 8.9, 8.06, 7.5, 7.14, 6.5, 6.0]:
            unks, anchs = [], []
            for _ in range(8):
                samples = modulate_jittered(tpiu, spb, random.random(), jitter)
                rx = decode_chain(samples, spb)
                etm = L.tpiu_deframe_walk(rx, want_stream=2)
                if len(etm) < 16:
                    etm = rx
                unk = sum(1 for c in etm if L._classify(c) == "unknown")
                unks.append(100 * unk / max(1, len(etm)))
                anchs.append(len([s for s in L.find_isyncs(etm) if L.is_flash(s.addr)]))
            tag = ""
            if abs(spb - 8.06) < 0.01:
                tag = "  <- IDDR 62M"
            elif abs(spb - 8.9) < 0.01:
                tag = "  <- IDDR 56M"
            elif abs(spb - 9.5) < 0.01:
                tag = "  <- our 21M (clean)"
            elif abs(spb - 7.14) < 0.01:
                tag = "  <- our 28M (broke)"
            print(f"{spb:8.2f} {sum(unks)/len(unks):8.2f} {sum(anchs)/len(anchs):8.1f}{tag}")
        print()
    return 0


def decode_chain(samples, bitlen_cycles):
    pulses = pulse_capture(list(samples))
    bits = nrz_decode(pulses, max(2, round(bitlen_cycles)))
    return uart_decode(bits)


if __name__ == "__main__":
    sys.exit(main())
