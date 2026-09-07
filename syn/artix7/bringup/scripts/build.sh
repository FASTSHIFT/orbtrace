#!/usr/bin/env bash
# One-key build of the active trace bitstream. Wraps the Vivado batch flow so
# you don't retype the vivado invocation or manage the build/ dir.
#
#   ./build.sh                  # trace_ddr_stream_top, USE_IDELAY=0 (direct)
#   USE_IDELAY=1 ./build.sh     # per-lane IDELAYE2 deskew variant (retired path)
#   OUTBIT=foo.bit ./build.sh   # override output bit name
#
# The direct (USE_IDELAY=0) build is the shipped path: IBUF->IDDR edge capture,
# frequency-independent, no per-lane tap sweep (see docs 23/24/25).
#
# Requires: source $XILINX_VIVADO/settings64.sh  (Vivado 2021.1) beforehand.
# Output bit lands in build/.
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

tcl="run_trace_ddr_stream.tcl"
outbit="${OUTBIT:-trace_ddr_stream_direct.bit}"
export USE_IDELAY="${USE_IDELAY:-0}"
export OUTBIT="$outbit"

if ! command -v vivado >/dev/null 2>&1; then
    echo "ERROR: vivado not on PATH. Run: source \$XILINX_VIVADO/settings64.sh"
    exit 1
fi

mkdir -p "$root/build"
echo "==> building trace_ddr_stream (USE_IDELAY=$USE_IDELAY) -> build/$outbit"
rm -f "$root/build/$outbit"
( cd "$root/build" && vivado -mode batch -source "../fpga_flow/$tcl" )

if [ -f "$root/build/$outbit" ]; then
    echo "==> BUILD OK: build/$outbit"
else
    echo "==> BUILD FAILED: build/$outbit not produced (see build/vivado.log)"
    exit 1
fi
