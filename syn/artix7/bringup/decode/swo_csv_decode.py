#!/usr/bin/env python3
"""swo_csv_decode — decode ETM from a raw DSLogic/sigrok waveform CSV of the
single-wire SWO line (STM32 PB3, NRZ/UART).

The CSV is RAW samples (one level per row), not a UART-decoder export, so we do
the UART decode in software (the exact algorithm the Artix-7 swo_*.v front-end
does in hardware, 提案 15): find each bit centre at the configured baud, sample
8N1 LSB-first, assemble bytes. Then reuse our existing TPIU deframer + ETMv3.5
decoder (etm35lib) — the SAME downstream as the parallel path (red-team r17 Q2:
verify "下游零改动" on real bytes, not in theory).

Pipeline:  SWO column -> UART bytes -> TPIU deframe (stream 2) -> ETM I-sync PCs

Usage:
  swo_csv_decode.py <capture.csv> [--baud 2e6] [--rate 50e6] [--col 6]
                    [-o swo_etm.bin]
"""
import argparse
import collections
import sys

import etm35lib as L


def load_swo_column(path, col, max_rows=None):
    """Stream the CSV, returning the SWO bit column as a list of 0/1 ints and
    the sample rate parsed from the header (Hz)."""
    rate = None
    swo = []
    with open(path) as f:
        for line in f:
            if line.startswith(";"):
                # header lines; grab sample rate
                if "Sample rate" in line:
                    # "; Sample rate: 50 MHz"
                    tok = line.split(":", 1)[1].strip().split()
                    val = float(tok[0])
                    unit = tok[1].lower() if len(tok) > 1 else "hz"
                    mult = {"hz": 1, "khz": 1e3, "mhz": 1e6, "ghz": 1e9}.get(unit, 1)
                    rate = val * mult
                continue
            if line.startswith("Time") or line.startswith("time"):
                continue  # column header row
            p = line.split(",")
            if len(p) <= col:
                continue
            try:
                swo.append(int(p[col]))
            except ValueError:
                continue
            if max_rows and len(swo) >= max_rows:
                break
    return swo, rate


def uart_decode(swo, samples_per_bit):
    """Software 8N1 LSB-first UART decode of a raw oversampled line.
    Mirrors the HW chain: detect a falling edge (idle high -> start bit), then
    sample 8 data bits + stop bit at bit centres. Resyncs on each start bit so
    baud drift between bytes self-corrects (each frame re-locks to its own start
    edge)."""
    spb = float(samples_per_bit)
    n = len(swo)
    out = bytearray()
    i = 0
    # ensure we begin from an idle-high region
    while i < n and swo[i] == 0:
        i += 1
    while i < n:
        # find next start bit: a 1->0 transition
        while i < n and swo[i] == 1:
            i += 1
        if i >= n:
            break
        start = i  # index of the falling edge (start bit begins here)
        # sample bit k at start + (k+0.5)*spb ; k=0..8 (8 data + stop)
        # confirm it really is a start bit (low at its centre)
        c0 = start + int(spb // 2)
        if c0 >= n or swo[c0] != 0:
            i = start + 1
            continue
        byte = 0
        ok = True
        for k in range(8):
            c = start + int((k + 1.5) * spb)
            if c >= n:
                ok = False
                break
            byte |= (swo[c] & 1) << k          # LSB first
        stopc = start + int((9 + 0.5) * spb)
        if not ok or stopc >= n:
            break
        if swo[stopc] == 1:                    # valid stop bit
            out.append(byte)
            i = stopc                          # continue after stop bit
        else:
            # framing slip: skip past this start edge and resync
            i = start + 1
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--baud", type=float, default=2e6)
    ap.add_argument("--rate", type=float, default=None,
                    help="sample rate Hz (else parsed from CSV header)")
    ap.add_argument("--col", type=int, default=6,
                    help="0-based column index of the SWO channel (default 6)")
    ap.add_argument("--max-rows", type=int, default=None)
    ap.add_argument("-o", "--out", default="/tmp/swo_etm.bin")
    a = ap.parse_args()

    print(f"loading SWO column {a.col} from {a.csv} ...")
    swo, hdr_rate = load_swo_column(a.csv, a.col, a.max_rows)
    rate = a.rate or hdr_rate or 50e6
    spb = rate / a.baud
    print(f"  samples={len(swo)}  rate={rate/1e6:.1f}MHz  baud={a.baud/1e6:.3f}M "
          f"-> {spb:.2f} samples/bit")

    raw = uart_decode(swo, spb)
    print(f"UART-decoded bytes: {len(raw)}")
    print("  first 48:", " ".join(f"{x:02x}" for x in raw[:48]))

    # TPIU sync density (formatter-on stream)
    sync = raw.count(b"\xff\xff\xff\x7f")
    hsync = raw.count(b"\xff\x7f")
    print(f"  TPIU full-sync (ff ff ff 7f): {sync}   HSYNC (ff 7f): {hsync}")

    # Deframe (stream 2 = ETM) using the SAME downstream as the parallel path.
    if L.has_tpiu_sync(raw):
        etm = L.tpiu_deframe_walk(raw, want_stream=2)
        if len(etm) < 16:                       # maybe stream id differs
            etm = L.tpiu_deframe_walk(raw)
    else:
        print("  no TPIU sync found; trying raw as ETM directly")
        etm = raw

    unk = sum(1 for c in etm if L._classify(c) == "unknown")
    print(f"ETM bytes: {len(etm)}  unknown={100*unk/max(1,len(etm)):.3f}%")

    syncs = L.find_isyncs(etm)
    flash = [s for s in syncs if L.is_flash(s.addr)]
    hist = collections.Counter(s.addr for s in flash)
    print(f"flash I-sync anchors: {len(flash)}  distinct PCs: {len(hist)}")
    print("top anchor PCs:")
    for addr, c in hist.most_common(12):
        print(f"   0x{addr:08x} : {c}")

    with open(a.out, "wb") as f:
        f.write(etm)
    print(f"wrote {a.out} ({len(etm)} ETM bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
