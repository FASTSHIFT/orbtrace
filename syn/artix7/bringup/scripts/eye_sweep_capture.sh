#!/usr/bin/env bash
# eye_sweep_capture — program a given (EYE-variant) bitstream, re-arm the
# one-shot capture on the live ETM trace, dump it, and report the error rate.
# Assumes ETM is already enabled + downclocked (etm_enable.sh + downclock /64
# already run and the target left RUNNING).
#
#   ./eye_sweep_capture.sh <build/trace_stream_eyeNN.bit> <out_tag>
#
# e.g. ./eye_sweep_capture.sh build/trace_stream_eye38.bit eye38
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
bit="${1:?usage: eye_sweep_capture.sh <bitfile> <tag>}"
tag="${2:?usage: eye_sweep_capture.sh <bitfile> <tag>}"
ip="${IP:-192.168.10.42}"
out="/tmp/fpga_${tag}.bin"

if [ ! -f "$root/$bit" ] && [ ! -f "$bit" ]; then
    echo "ERROR: bitfile not found: $bit"; exit 1
fi
[ -f "$bit" ] || bit="$root/$bit"

echo "==> [1/3] program $bit (JTAG, re-arm one-shot)"
pkill -9 -f openocd 2>/dev/null || true
# program_bit.tcl takes BITFILE relative to build/, so pass an absolute path.
abs_bit="$(cd "$(dirname "$bit")" && pwd)/$(basename "$bit")"
( cd "$root/build" && BITFILE="$abs_bit" vivado -mode batch -source ../fpga_flow/program_bit.tcl >/tmp/prog_${tag}.log 2>&1 ) \
    && echo "    programmed" || { echo "    PROGRAM FAILED (see /tmp/prog_${tag}.log)"; exit 1; }

echo "==> [2/3] free JTAG + dump capture"
pkill -9 -f hw_server 2>/dev/null || true
sleep 3
python3 "$here/trace_dump.py" --ip "$ip" --depth 61440 -o "$out"

echo "==> [3/3] error rate"
python3 "$root/decode/fpga_errrate.py" "$out"
