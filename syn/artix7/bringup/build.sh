#!/usr/bin/env bash
# One-key build of a bring-up bitstream. Wraps the Vivado batch flow so you
# don't retype the vivado invocation or manage the build/ dir.
#
#   ./build.sh orbflow      # trace_orbflow_top  (A route, native OFLOW)  [default]
#   ./build.sh stream       # trace_stream_top   (raw traceIF-frame capture)
#   TAP=24 ./build.sh orbflow   # override IDELAY tap (default 28)
#
# Requires: source $XILINX_VIVADO/settings64.sh  (Vivado 2021.1) beforehand.
# Output bit/mcs/bin land in build/.
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-orbflow}"

case "$target" in
    orbflow) tcl="run_trace_orbflow.tcl"; bit="trace_orbflow.bit" ;;
    stream)  tcl="run_trace_stream.tcl";  bit="trace_stream.bit"  ;;
    *) echo "usage: $0 [orbflow|stream]"; exit 2 ;;
esac

if ! command -v vivado >/dev/null 2>&1; then
    echo "ERROR: vivado not on PATH. Run: source \$XILINX_VIVADO/settings64.sh"
    exit 1
fi

mkdir -p "$here/build"
echo "==> building $target (tap=${TAP:-28}) -> build/$bit"
rm -f "$here/build/$bit"
( cd "$here/build" && vivado -mode batch -source "../$tcl" )

if [ -f "$here/build/$bit" ]; then
    echo "==> BUILD OK: build/$bit"
else
    echo "==> BUILD FAILED: build/$bit not produced (see build/vivado.log)"
    exit 1
fi
