#!/usr/bin/env bash
# r10 B2 / NEW-1 regression: dual-clock-domain CDC test of the frame128
# trace_clk -> clk100 crossing (axis_async_fifo) + overflow accounting.
#
# Uses iverilog (axis_async_fifo is plain RTL, no Xilinx primitives), so
# this runs without Vivado. This is the test r10 demanded: trace_clk and
# clk100 at unequal periods + jitter, 200 frames, FIFO driven to full,
# proving (1) no corruption/reorder across the CDC and (2) every dropped
# frame is counted by trace_lost_cnt (loss visible, never silent).
#
# Usage:  ./syn/artix7/sim/run_frame_cdc.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")"/../../.. && pwd)"
SIM="${TMPDIR:-/tmp}/orbtrace_frame_cdc"

iverilog -g2012 -o "$SIM" \
    "$ROOT/syn/external/verilog-ethernet/lib/axis/rtl/axis_async_fifo.v" \
    "$ROOT/syn/artix7/sim/frame_cdc_tb.v"

LOG="$(mktemp)"
vvp "$SIM" 2>&1 | tee "$LOG"

if grep -q "PASS: CDC integrity (no corruption, no reorder, no silent loss)" "$LOG"; then
    echo "OK"
    rm -f "$LOG"
    exit 0
else
    echo "FAIL: CDC regression did not pass"
    rm -f "$LOG"
    exit 1
fi
