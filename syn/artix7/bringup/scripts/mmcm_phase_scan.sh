#!/usr/bin/env bash
# Flash each phase-variant 42M bitstream, capture, decode, report anchors.
# OpenOCD must already have STM32 at HCLK 84M (TRACECLK 42M). Run from bringup/.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bringup="$(cd "$here/.." && pwd)"
ELF=/home/vifex/workpath/orbcode/proj_add.axf
IP=192.168.10.42
VIV="source ~/workpath/tools/xilinx/Vivado/2021.1/settings64.sh"

for bit in "$@"; do
    echo "================ $bit ================"
    # free JTAG (kills openocd; ETM regs persist, but HCLK resets -> re-set after)
    echo asd | sudo -S pkill -9 -f openocd 2>/dev/null
    sleep 1
    ( cd "$bringup/build" && bash -c "$VIV && BITFILE=$bit vivado -mode batch -source ../fpga_flow/program_bit.tcl" >/tmp/prog.log 2>&1 )
    grep -q PROGRAMMED /tmp/prog.log && echo "  flashed" || { echo "  FLASH FAIL"; continue; }
    # restart openocd + re-set HCLK 84M
    ( cd /home/vifex/workpath/orbcode/orbtrace && openocd -f interface/stlink.cfg -f target/stm32f4x.cfg -f syn/artix7/bringup/target/etm_enable.cfg >/tmp/ocd.log 2>&1 & )
    sleep 5
    echo asd | timeout 12 bash -c '{ echo "mww 0x40023808 [expr {([mrw 0x40023808] \& ~(0xF << 4)) | (0x8 << 4)}]"; sleep 1; echo "exit"; } | telnet 127.0.0.1 4444' >/dev/null 2>&1
    sleep 3
    python3 "$bringup/scripts/mmcm_status.py" "$IP" rearm
    python3 "$bringup/scripts/swo_dump_banked.py" --ip "$IP" --rearm --settle 1.5 -o /tmp/ph.bin >/dev/null 2>&1
    ELF=$ELF python3 "$bringup/decode/etm_decode_cli.py" /tmp/ph.bin --elf "$ELF" 2>&1 | grep -E "I-sync anchors|distinct functions|0x0800"
done
