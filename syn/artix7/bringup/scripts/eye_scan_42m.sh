#!/usr/bin/env bash
# At HCLK=42MHz (where OVERSAMPLE failed with default EYE), sweep the runtime
# EYE_DELAY CSR (mid-eye sample offset) WITHOUT re-synthesis, to test whether
# the 42M failure is "EYE_DELAY too large for the shorter half-bit" (fixable by
# a smaller mid-eye offset) or a fundamental oversample-rate limit.
#
# Assumes FPGA=trace4_raw at 42M, OpenOCD resident.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bringup="$(cd "$here/.." && pwd)"
ELF=/home/vifex/workpath/orbcode/proj_add.axf
IP=192.168.10.42

for eye in 1 2 3 4 6 8 12; do
  python3 "$bringup/scripts/trace_ctrl.py" --ip $IP set-eye $eye >/dev/null 2>&1
  python3 "$bringup/scripts/trace_ctrl.py" --ip $IP rearm >/dev/null 2>&1
  sleep 1.0
  out=/tmp/eye_$eye.bin
  python3 "$bringup/scripts/trace_dump.py" --ip $IP --depth 61440 -o "$out" --timeout 6 >/dev/null 2>&1
  anc=$(python3 "$bringup/decode/etm_decode_cli.py" "$out" --elf "$ELF" 2>&1 | grep -oE "I-sync anchors=[0-9]+")
  fn=$(python3 "$bringup/decode/etm_decode_cli.py" "$out" --elf "$ELF" 2>&1 | grep -oE "distinct functions executed: [0-9]+")
  echo "EYE=$eye : $anc  $fn"
done
