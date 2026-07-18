#!/usr/bin/env bash
# Compile + run the la_ddr_writer stress testbench with iverilog.
#   ./run_tb.sh          # run
#   ./run_tb.sh vcd      # run + dump waveform
set -eu
cd "$(dirname "$0")"

BRINGUP=..
VE=../../../external/verilog-ethernet

SRC=(
    tb_la_ddr_writer.v
    $BRINGUP/rtl/la_ddr_writer.v
    $VE/lib/axis/rtl/axis_async_fifo.v
)

echo "== iverilog compile =="
iverilog -g2012 -Wall -o tb_la_ddr_writer.vvp "${SRC[@]}"

echo "== run =="
if [ "${1:-}" = "vcd" ]; then
    vvp tb_la_ddr_writer.vvp +vcd | tee /tmp/tb_la_out.txt
else
    vvp tb_la_ddr_writer.vvp | tee /tmp/tb_la_out.txt
fi

# CI gate: require the ALL_PASS verdict. ($fatal already returns non-zero, but
# vvp's exit code is masked by the pipe; assert on the printed verdict too.)
if grep -q 'RESULT=ALL_PASS' /tmp/tb_la_out.txt; then
    echo "== la_ddr_writer stress test: ALL_PASS =="
    exit 0
else
    echo "== la_ddr_writer stress test: FAILED ==" >&2
    exit 1
fi
