#!/usr/bin/env bash
# run_sim_equiv — end-to-end "prove the OVERSAMPLE RTL is LA-equivalent in
# simulation" flow. Generates a stimulus from a golden .dsl, replays it through
# trace_capture_a7 (OVERSAMPLE) in iverilog, and checks the recovered ETM byte
# stream is BYTE-IDENTICAL to the logic-analyser software path.
#
#   ./run_sim_equiv.sh <golden.dsl> [nsamples]
#
# Exit 0 only if byte-identical. No hardware required.
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rtl="$(cd "$here/../../rtl" && pwd)"
dsl="${1:?usage: run_sim_equiv.sh <golden.dsl> [nsamples]}"
nsamp="${2:-2000000}"

stim="/tmp/dsl_stim_${nsamp}.memh"
simout="/tmp/sim_raw_${nsamp}.hex"
vvp="/tmp/tb_replay_${nsamp}.vvp"

echo "==> [1/4] .dsl -> stimulus ($nsamp samples)"
python3 "$here/dsl_to_stim.py" "$dsl" "$nsamp" "$stim"

echo "==> [2/4] compile iverilog testbench"
iverilog -g2012 -o "$vvp" \
    "$rtl/sim/tb_dsl_replay.v" "$rtl/sim/xil_stubs.v" "$rtl/trace_capture_a7.v"

echo "==> [3/4] replay golden waveform through OVERSAMPLE RTL"
vvp "$vvp" +stim="$stim" +nsamp="$nsamp" +out="$simout"

echo "==> [4/4] strict byte-identical check vs LA software path"
python3 "$here/sim_la_equiv.py" "$simout" "$dsl" "$nsamp"
