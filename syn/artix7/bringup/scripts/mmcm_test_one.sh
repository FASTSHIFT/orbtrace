#!/usr/bin/env bash
# Flash ONE bitstream, restart openocd, set HCLK via literal RCC_CFGR, capture,
# full pairing search. Usage: mmcm_test_one.sh <bit> <rcc_cfgr_hex>
#   rcc: 0x948a=HCLK84/TC42  0x940a=HCLK168/TC84  0x949a=HCLK42/TC21
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bringup="$(cd "$here/.." && pwd)"
root=/home/vifex/workpath/orbcode/orbtrace
ELF=/home/vifex/workpath/orbcode/proj_add.axf
IP=192.168.10.42
VIV="source ~/workpath/tools/xilinx/Vivado/2021.1/settings64.sh"
bit="$1"; rcc="$2"

echo asd | sudo -S pkill -9 -f openocd 2>/dev/null; sleep 1
( cd "$bringup/build" && bash -c "$VIV && BITFILE=$bit vivado -mode batch -source ../fpga_flow/program_bit.tcl" >/tmp/prog.log 2>&1 )
grep -q PROGRAMMED /tmp/prog.log && echo "  flashed $bit" || { echo "  FLASH FAIL"; exit 1; }
( cd "$root" && openocd -f interface/stlink.cfg -f target/stm32f4x.cfg -f syn/artix7/bringup/target/etm_enable.cfg >/tmp/ocd.log 2>&1 & )
sleep 5
printf 'mww 0x40023808 %s\nmdw 0x40023808\nexit\n' "$rcc" | timeout 12 telnet 127.0.0.1 4444 >/tmp/tel.log 2>&1
sleep 2
echo -n "  RCC_CFGR="; strings /tmp/tel.log | grep -o '0x40023808: [0-9a-f]*' | tail -1
python3 "$bringup/scripts/mmcm_status.py" "$IP" rearm
python3 "$bringup/scripts/swo_dump_banked.py" --ip "$IP" --rearm --settle 1.5 -o /tmp/one.bin >/dev/null 2>&1
ELF=$ELF python3 "$bringup/decode/mmcm_halfbit_search.py" /tmp/one.bin 2>&1 | grep -E "BEST|anchors_in_text=[1-9]"
