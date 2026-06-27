#!/usr/bin/env bash
# Sweep STM32 HCLK (and thus TRACECLK) across mid-speed bands and measure how
# many real flash I-sync anchors the OVERSAMPLE FPGA path decodes at each, to
# pin the practical upper frequency of oversampling (proposal 22 §7 unmeasured).
#
# Assumes: OpenOCD resident on :4444 (4-bit etm_enable), FPGA = trace4_raw.bit
# (TRACE_WIDTH=4 CAP_RAW=1). Each band: set HPRE -> reflash (one-shot re-arm)
# -> dump -> etm_decode_cli anchor count.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bringup="$(cd "$here/.." && pwd)"
ELF=/home/vifex/workpath/orbcode/proj_add.axf
BIT=trace4_raw.bit
VIV="source ~/workpath/tools/xilinx/Vivado/2021.1/settings64.sh"

# band: name  RCC_CFGR  HCLK_MHz
bands=(
  "div16 0x000094ba 10.5"
  "div8  0x000094aa 21"
  "div4  0x0000949a 42"
  "div2  0x0000948a 84"
)

for b in "${bands[@]}"; do
  set -- $b; name=$1; cfgr=$2; mhz=$3
  echo "==================== $name  HCLK=${mhz}MHz  RCC_CFGR=$cfgr ===================="
  printf 'halt\nmww 0x40023808 %s\nresume\n' "$cfgr" | timeout 8 nc localhost 4444 >/dev/null 2>&1
  sleep 0.3
  bash -c "$VIV && cd $bringup/build && BITFILE=$BIT vivado -mode batch -source ../fpga_flow/program_bit.tcl >/tmp/prog.log 2>&1"
  sleep 2
  out=/tmp/fscan_$name.bin
  python3 "$bringup/scripts/trace_dump.py" --ip 192.168.10.42 --depth 61440 -o "$out" --timeout 8 2>&1 | grep -E "full|wrote"
  python3 "$bringup/decode/etm_decode_cli.py" "$out" --elf "$ELF" 2>&1 | grep -E "I-sync anchors|distinct absolute|distinct functions"
done
echo "==================== scan done ===================="
