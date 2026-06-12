#!/usr/bin/env bash
# One-key program of a bring-up bitstream to the A7-Lite over JTAG (FT232H).
#
#   ./program.sh orbflow            # volatile JTAG load of trace_orbflow.bit  [default]
#   ./program.sh orbflow flash      # PERSISTENT QSPI flash of trace_orbflow.mcs
#   ./program.sh stream             # volatile JTAG load of trace_stream.bit
#
# Volatile load is fast and gone on power cycle (good for the
# configure-ETM-then-re-arm capture loop). Flash fixation persists across
# power cycles (use once the design is final).
#
# Requires: source $XILINX_VIVADO/settings64.sh, and hw_server running
# (this script starts one if absent).
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-orbflow}"
mode="${2:-jtag}"

case "$target" in
    orbflow) bit="trace_orbflow.bit"; mcs="trace_orbflow.mcs" ;;
    stream)  bit="trace_stream.bit";  mcs="trace_stream.mcs"  ;;
    *) echo "usage: $0 [orbflow|stream] [jtag|flash]"; exit 2 ;;
esac

if ! command -v vivado >/dev/null 2>&1; then
    echo "ERROR: vivado not on PATH. Run: source \$XILINX_VIVADO/settings64.sh"
    exit 1
fi

# Free OpenOCD (shares the FT232H with hw_server on FT232H boards is fine,
# but ST-Link OpenOCD for ETM must not hold the bus here).
pkill -9 -f openocd 2>/dev/null || true

# Ensure a hw_server is up.
if ! pgrep -x hw_server >/dev/null 2>&1; then
    echo "==> starting hw_server in background"
    ( hw_server >/tmp/hw_server.log 2>&1 & )
    sleep 2
fi

if [ "$mode" = "flash" ]; then
    if [ ! -f "$here/build/$mcs" ]; then echo "ERROR: build/$mcs missing (run build.sh first)"; exit 1; fi
    echo "==> FLASH fixation: build/$mcs -> QSPI (persists across power cycle)"
    ( cd "$here/build" && MCS="$mcs" vivado -mode batch -source ../flash_program.tcl )
else
    if [ ! -f "$here/build/$bit" ]; then echo "ERROR: build/$bit missing (run build.sh first)"; exit 1; fi
    echo "==> JTAG volatile load: build/$bit (gone on power cycle)"
    # reuse the generic net_test programmer, pointing it at our bit via env
    ( cd "$here/build" && BITFILE="$bit" vivado -mode batch -source ../program_bit.tcl )
fi
echo "==> program done."
