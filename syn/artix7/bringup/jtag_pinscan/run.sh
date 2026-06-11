#!/usr/bin/env bash
# One-shot pure-JTAG connectivity scan (NO bitstream).
#   ./run.sh [GPIO net ...]      e.g. ./run.sh GPIO1_4P GPIO1_0P ...
#   ./run.sh                     scans the default trace+loopback pool
# Requires: Vivado settings64.sh sourced or at the default path; hw_server
# running; openocd not holding the FTDI.
set -e
cd "$(dirname "$0")"

VIV=${VIVADO_SETTINGS:-~/workpath/tools/xilinx/Vivado/2021.1/settings64.sh}
# shellcheck disable=SC1090
source "$VIV"

# default pool: the 5 trace input pins + 5 loopback output pins (GPIO1)
DEFAULT_POOL="GPIO1_4P GPIO1_0P GPIO1_1P GPIO1_2P GPIO1_3P GPIO1_5P GPIO1_6P GPIO1_7P"
POOL=${*:-$DEFAULT_POOL}

# 0. ensure pinmap.json exists
[ -f pinmap.json ] || python3 parse_bsdl.py

# 1. generate EXTEST vectors
python3 pinscan.py gen $POOL

# 2. shift them over JTAG (clears config via JPROGRAM, then EXTEST)
pkill -9 -f openocd 2>/dev/null || true
vivado -mode batch -source run_scan.tcl > scan.log 2>&1
grep -E "ran .* vectors|ERROR" scan.log || true

# 3. decode -> jumper list
python3 pinscan.py decode
