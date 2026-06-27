#!/usr/bin/env bash
# 42M-TRACECLK phase quality sweep: flash, restart openocd, set HCLK /2 (84M ->
# TRACECLK 42M, literal RCC 0x948a), capture 2x, report unknown-rate via
# mmcm_decode. Usage: mmcm_q42.sh <bit1> <bit2> ...   (run from bringup/)
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
    # set HCLK /2 = 84M -> TRACECLK 42M (heredoc with sleeps; literal RCC value)
    echo asd | timeout 16 bash -c '{ echo halt; sleep 1; echo "mww 0x40023808 0x0000948a"; sleep 1; echo resume; sleep 1; echo exit; } | telnet 127.0.0.1 4444' >/dev/null 2>&1
    sleep 2
    for r in 1 2; do
        python3 "$bringup/scripts/swo_dump_banked.py" --ip "$IP" --rearm --settle 1.2 -o /tmp/q.bin >/dev/null 2>&1
        ( cd "$bringup/decode" && python3 -c "
import etm35lib as L, mmcm_decode as M
raw=open('/tmp/q.bin','rb').read()
etm,p,o,ph=M.decode(raw)
syncs=[s for s in L.find_isyncs(etm) if L.is_flash(s.addr)]
unk=sum(1 for c in etm if L._classify(c)=='unknown')
print(f'  run $r: anchors={len(syncs)} unknown {100*unk/max(1,len(etm)):.4f}%')
" )
    done
done
