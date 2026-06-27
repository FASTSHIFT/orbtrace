#!/usr/bin/env bash
# For each 84M phase-variant bitstream: flash, restart openocd (HCLK resets to
# full-speed 168M = TRACECLK 84M, which is what 84M variants need), capture 2x,
# report unknown-byte rate + anchors via mmcm_decode (the reliable pipeline).
# Usage: mmcm_phase_quality.sh <bit1> <bit2> ...   (run from bringup/)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bringup="$(cd "$here/.." && pwd)"
root=/home/vifex/workpath/orbcode/orbtrace
IP=192.168.10.42
VIV="source ~/workpath/tools/xilinx/Vivado/2021.1/settings64.sh"

for bit in "$@"; do
    echo "================ $bit ================"
    echo asd | sudo -S pkill -9 -f openocd 2>/dev/null; sleep 1
    ( cd "$bringup/build" && bash -c "$VIV && BITFILE=$bit vivado -mode batch -source ../fpga_flow/program_bit.tcl" >/tmp/prog.log 2>&1 )
    grep -q PROGRAMMED /tmp/prog.log || { echo "  FLASH FAIL"; continue; }
    ( cd "$root" && openocd -f interface/stlink.cfg -f target/stm32f4x.cfg -f syn/artix7/bringup/target/etm_enable.cfg >/tmp/ocd.log 2>&1 & )
    sleep 6
    for r in 1 2; do
        python3 "$bringup/scripts/swo_dump_banked.py" --ip "$IP" --rearm --settle 1.2 -o /tmp/pq.bin >/dev/null 2>&1
        ( cd "$bringup/decode" && python3 -c "
import etm35lib as L, mmcm_decode as M
raw=open('/tmp/pq.bin','rb').read()
etm,p,o,ph=M.decode(raw)
syncs=[s for s in L.find_isyncs(etm) if L.is_flash(s.addr)]
unk=sum(1 for c in etm if L._classify(c)=='unknown')
print(f'  run $r: parity={p} anchors={len(syncs)} unknown {100*unk/max(1,len(etm)):.3f}%')
" )
    done
done
