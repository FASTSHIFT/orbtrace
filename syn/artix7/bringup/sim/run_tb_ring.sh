#!/usr/bin/env bash
# doc 19 P1 + P0e: compile + run the CONCURRENT read/write DDR ring testbench.
# Exercises la_ddr_writer + la_ddr_ring_streamer sharing one ring through the
# REAL vendor ddr3_wr_ctrl/ddr3_rd_ctrl/ddr3_arbit + a behavioural MIG memory.
#   ./run_tb_ring.sh          # run
#   ./run_tb_ring.sh vcd      # run + dump waveform
set -eu
cd "$(dirname "$0")"

BRINGUP=..
VE=../../../external/verilog-ethernet

SRC=(
    tb_la_ddr_ring.v
    $BRINGUP/rtl/la_ddr_writer.v
    $BRINGUP/rtl/la_ddr_ring_streamer.v
    $BRINGUP/rtl/ddr3/ddr3_wr_ctrl.v
    $BRINGUP/rtl/ddr3/ddr3_rd_ctrl.v
    $BRINGUP/rtl/ddr3/ddr3_arbit.v
    $VE/lib/axis/rtl/axis_async_fifo.v
)

echo "== iverilog compile =="
iverilog -g2012 -Wall -o tb_la_ddr_ring.vvp "${SRC[@]}"

echo "== run =="
if [ "${1:-}" = "vcd" ]; then
    vvp tb_la_ddr_ring.vvp +vcd | tee /tmp/tb_ring_out.txt
else
    vvp tb_la_ddr_ring.vvp | tee /tmp/tb_ring_out.txt
fi

if grep -q 'RESULT=ALL_PASS' /tmp/tb_ring_out.txt; then
    echo "== la_ddr_ring concurrent R/W test: ALL_PASS =="
    exit 0
else
    echo "== la_ddr_ring concurrent R/W test: FAILED ==" >&2
    exit 1
fi
