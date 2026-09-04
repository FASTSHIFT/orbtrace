#!/usr/bin/env bash
# Build the P0-1 enhanced tb_ddr_ring_fixed with realistic MIG stalls.
# Usage: ./build_tb_fixed.sh            # fixed 0x42 source
#        ./build_tb_fixed.sh ramp       # ramp source
set -eu
cd "$(dirname "$0")"
DEFS=""
for a in "$@"; do
    case "$a" in
        ramp)     DEFS="$DEFS -DRAMP" ;;
        tag_seq)  DEFS="$DEFS -DSIM_TAG_SEQ" ;;      # r36 P0-2 H1 probe
        mem_11)   DEFS="$DEFS -DSIM_MEM_INIT_11" ;;  # r36 P0-2 H7 corroboration
        mem_00)   DEFS="$DEFS -DSIM_MEM_INIT_00" ;;  # r37 §1.3 cross-align
        mem_ff)   DEFS="$DEFS -DSIM_MEM_INIT_FF" ;;  # r37 §1.3 cross-align
        heavy)    DEFS="$DEFS -DHEAVY_STALL" ;;      # r37 corrective sweep
    esac
done
BRINGUP=..
VE=../../../external/verilog-ethernet
iverilog -g2012 $DEFS -o tb_ddr_ring_fixed.vvp \
    tb_ddr_ring_fixed.v \
    $BRINGUP/rtl/la_ddr_writer.v \
    $BRINGUP/rtl/la_ddr_ring_streamer.v \
    $BRINGUP/rtl/ddr3/ddr3_wr_ctrl.v \
    $BRINGUP/rtl/ddr3/ddr3_rd_ctrl.v \
    $BRINGUP/rtl/ddr3/ddr3_arbit.v \
    $VE/lib/axis/rtl/axis_async_fifo.v
echo "== compile ok =="
vvp tb_ddr_ring_fixed.vvp | tee /tmp/tb_fixed_out.txt
