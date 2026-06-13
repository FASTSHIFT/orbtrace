#!/usr/bin/env python3
"""dsl_to_stim — convert a DSView .dsl logic capture into an iverilog stimulus
memh file, so the EXACT real pin waveform the logic-analyser saw can be
replayed into the trace_capture_a7 RTL testbench.

This closes the loop: the same known-good samples that dsl_parse decodes to
818 flash anchors are driven, sample-for-sample, into the RTL. If the RTL
capture pipeline (OVERSAMPLE -> traceIF -> CAP_RAW byte) reproduces a
decodable stream, the RTL is correct and any on-board divergence is a real
hardware/SI issue. If it does NOT, the bug is in the RTL and is now observable
cycle-by-cycle in simulation instead of guessed at in the decoder.

Output: one hex byte per sample, MSB->LSB packed as
    bit4 = TRACECLK (ch0)
    bit3 = TRACED3  (ch4)
    bit2 = TRACED2  (ch3)
    bit1 = TRACED1  (ch2)
    bit0 = TRACED0  (ch1)
i.e. value = (clk<<4)|(d3<<3)|(d2<<2)|(d1<<1)|d0

Usage:
  python3 dsl_to_stim.py <capture.dsl> [nsamples] [out.memh]
"""
import sys
import dsl_parse as D


def main():
    path = sys.argv[1]
    nmax = int(sys.argv[2]) if len(sys.argv) > 2 else 300_000
    out = sys.argv[3] if len(sys.argv) > 3 else "/tmp/dsl_stim.memh"

    chans, srate, nprobes = D.load_channels(path)
    navail = min(len(v) for v in chans.values()) * 8
    n = min(navail, nmax)
    clk = D.unpack_bits(chans[0], n)
    d0 = D.unpack_bits(chans[1], n)
    d1 = D.unpack_bits(chans[2], n)
    d2 = D.unpack_bits(chans[3], n)
    d3 = D.unpack_bits(chans[4], n)

    with open(out, "w") as f:
        for i in range(n):
            v = (clk[i] << 4) | (d3[i] << 3) | (d2[i] << 2) | (d1[i] << 1) | d0[i]
            f.write(f"{v:02x}\n")

    # report edge stats so the TB / EYE_DELAY can be sanity-checked
    edges, half = D.find_edges(clk, n)
    print(f"samplerate={srate} probes={nprobes}")
    print(f"wrote {out}: {n} samples (of {navail} available)")
    print(f"TRACECLK edges={len(edges)} median half-period={half} samples "
          f"(={half*20} ns)")
    print(f"NSAMPLES={n}")


if __name__ == "__main__":
    main()
