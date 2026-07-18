#!/usr/bin/env bash
# Sweep TRACECLK across the CDC and print bad-byte rate. All-digital, ideal 50%
# duty clock, clean walking data -> isolates the CDC from SI/duty.
set -u
# THALF (ps) for a set of TRACECLK freqs. f = 1/(2*THALF).
# 12M=41667  48M=10417  75M=6667  100M=5000  125M=4000  150M=3333  198M=2525
for TH in 41667 10417 6667 5000 4000 3333 2525; do
  iverilog -g2012 -Ptb_iddr_cdc_sweep.THALF=$TH \
    -o /tmp/s.vvp tb_iddr_cdc_sweep.v 2>/dev/null
  vvp /tmp/s.vvp 2>/dev/null
done
