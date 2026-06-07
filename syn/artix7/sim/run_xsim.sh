#!/usr/bin/env bash
# Stage-2 T2 simulation: end-to-end Artix-7 trace capture front-end test
# using Vivado xsim (iverilog can't simulate Xilinx unisims/secureip).
#
# Usage:
#   source ~/workpath/tools/xilinx/Vivado/2021.1/settings64.sh
#   ./syn/artix7/sim/run_xsim.sh
#
# Verifies that trace_capture_a7 (IBUF + IDELAYE2 + IDDR + IDELAYCTRL)
# chained to traceIF.v produces the expected frame
#   FRAME[0] = 123402030405060708090a0b0c0d0e0f
# from the same TPIU sync + 16-byte payload sendByte sequence used by
# verilog/testbeds/traceIF_tb.v. This is the Artix-7-specific equivalent
# of the traceIF iverilog regression.

set -euo pipefail

if [[ -z "${XILINX_VIVADO:-}" ]]; then
    echo "ERROR: XILINX_VIVADO not set. source the Vivado settings64.sh first." >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")"/../../.. && pwd)"
WORK="${TMPDIR:-/tmp}/orbtrace_xsim"
mkdir -p "$WORK"
cd "$WORK"
rm -rf xsim.dir

xvlog -L unisims_ver -L secureip \
    "$ROOT/verilog/traceIF.v" \
    "$ROOT/syn/artix7/rtl/trace_capture_a7.v" \
    "$ROOT/syn/artix7/sim/trace_capture_a7_tb.v" \
    "$XILINX_VIVADO/data/verilog/src/glbl.v"

xelab --debug typical --timescale 1ns/1ps -L unisims_ver -L secureip \
    work.trace_capture_a7_tb work.glbl -s tb_sim

cat > run_xsim.tcl <<'TCL'
run all
exit
TCL

LOG="$(mktemp)"
xsim tb_sim -t run_xsim.tcl 2>&1 | tee "$LOG"

if grep -q "PASS: Artix-7 capture front-end produced a frame" "$LOG" \
    && grep -q "FRAME\[0\] = 123402030405060708090a0b0c0d0e0f" "$LOG"; then
    echo "OK"
    rm -f "$LOG"
    exit 0
else
    echo "FAIL: expected frame not produced"
    exit 1
fi
