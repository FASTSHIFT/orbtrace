#!/usr/bin/env bash
# One-key end-to-end trace capture in the CORRECT ORDER:
#   1) enable STM32 ETM (trace source live)
#   2) (re)load the FPGA bitstream so its one-shot capture re-arms on live data
#   3) dump the captured OrbFlow stream over UDP to a file
#   4) (optional) decode with orbcat/orbmortem
#
# Why this order: the FPGA capture is one-shot and freezes when full. If you
# burn the FPGA before the ETM is emitting, it captures power-on idle. Always
# configure the trace source FIRST, then re-arm the FPGA. (See
# docs/artix7-port/stage4-datapath/06-v3-orbuculum-decode.md "真根因".)
#
#   ./capture.sh                       # ETM -> reload orbflow.bit -> dump 60KB
#   IP=192.168.10.42 DEPTH=61440 OUT=/tmp/oflow.bin ./capture.sh
#   ./capture.sh --decode              # also run orbcat on the result
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IP="${IP:-192.168.10.42}"
DEPTH="${DEPTH:-61440}"
OUT="${OUT:-/tmp/oflow.bin}"
TARGET="${TARGET:-orbflow}"
decode=0
[ "${1:-}" = "--decode" ] && decode=1

echo "==> [1/3] enable STM32 ETM"
"$here/etm_enable.sh"

echo "==> [2/3] re-arm FPGA capture (reload $TARGET bitstream over JTAG)"
"$here/program.sh" "$TARGET" jtag
# give the PHY link + capture a moment to fill
sleep 3

echo "==> [3/3] dump captured stream -> $OUT"
( cd "$here" && python3 trace_dump.py --ip "$IP" --depth "$DEPTH" -o "$OUT" )

if [ "$decode" -eq 1 ]; then
    echo "==> decoding $OUT with orbcat (OFLOW, tag 1)"
    "$here/decode.sh" "$OUT" || true
fi
echo "==> capture done: $OUT"
