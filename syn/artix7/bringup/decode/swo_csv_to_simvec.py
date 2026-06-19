#!/usr/bin/env python3
"""swo_csv_to_simvec — export the SWO column of a DSLogic raw-waveform CSV into
a 1-bit-per-line $readmemb file for the RTL testbench (swo_replay_tb.v).

The LA samples at 50 MHz; the FPGA SWO front-end runs in ref_200m (200 MHz). To
replay the real line into the RTL at the correct relative timing, each LA sample
is repeated UPS = ref_rate / la_rate times (200/50 = 4) so one LA sample lasts
the right number of ref cycles. We also expand RLE-free (one bit per ref cycle)
so the testbench just reads one bit per clock.

Usage:
  swo_csv_to_simvec.py <csv> <out.mem> [--col 6] [--ups 4] [--max-bits N]
"""
import argparse
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("out")
    ap.add_argument("--col", type=int, default=6)
    ap.add_argument("--ups", type=int, default=4,
                    help="ref cycles per LA sample (200MHz/50MHz=4)")
    ap.add_argument("--max-samples", type=int, default=400000,
                    help="LA samples to export (keep sim tractable)")
    a = ap.parse_args()

    n = 0
    with open(a.csv) as f, open(a.out, "w") as o:
        for line in f:
            if line.startswith(";") or line[:4].lower() == "time":
                continue
            p = line.split(",")
            if len(p) <= a.col:
                continue
            try:
                bit = int(p[a.col]) & 1
            except ValueError:
                continue
            o.write((str(bit) + "\n") * a.ups)
            n += 1
            if n >= a.max_samples:
                break
    print(f"wrote {a.out}: {n} LA samples x{a.ups} = {n*a.ups} ref-cycle bits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
