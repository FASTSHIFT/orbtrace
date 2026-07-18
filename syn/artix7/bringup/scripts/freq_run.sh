#!/usr/bin/env bash
# freq_run — flash a firmware variant, verify it runs (no fault), enable ETM
# BB=1, clear CURTPM, re-arm the FPGA capture, dump raw, decode + order-check.
# One-key higher-frequency real-ETM validation.
#
#   freq_run.sh <fw_tag>      e.g. freq_run.sh tclk66
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"     # orbtrace/
fwroot="$(cd "$root/.." && pwd)"            # orbcode/
TAG="${1:-tclk100}"
HEX="$fwroot/perf/firmware/$TAG/H743_Blink.hex"
ELF="$fwroot/perf/firmware/$TAG/H743_Blink.axf"
IP="${IP:-192.168.10.42}"
OUT="/tmp/etm_$TAG.bin"

cd "$root"

echo "==> [1/6] flash $TAG"
pkill -9 -f openocd 2>/dev/null; sleep 1
timeout 60 openocd -f interface/cmsis-dap.cfg \
    -c "adapter speed 1000" \
    -c "reset_config srst_only srst_nogate connect_assert_srst" \
    -f target/stm32h7x.cfg \
    -c "init" -c "reset halt" \
    -c "program $HEX verify" -c "reset run" -c "shutdown" \
    >/tmp/fr_flash.log 2>&1
grep -qi "Verified OK" /tmp/fr_flash.log && echo "    verified OK" || { echo "    FLASH FAIL"; tail -5 /tmp/fr_flash.log; exit 1; }

echo "==> [2/6] verify stable (no fault)"
pkill -9 -f openocd 2>/dev/null; sleep 1
timeout 20 openocd -f interface/cmsis-dap.cfg -f target/stm32h7x.cfg \
    -c "init" -c "halt" -c "resume" \
    -c "sleep 60" -c "halt" -c "set c \[mrw 0xE000ED28\]" \
    -c "echo CFSR=\[format 0x%08x \$c\]" -c "echo PC=\[reg pc\]" \
    -c "resume" -c "shutdown" 2>&1 | grep -iE "CFSR=|PC=pc"

echo "==> [3/6] enable ETM BB=1"
pkill -9 -f openocd 2>/dev/null; sleep 1
TRACE_BB=1 timeout 12 openocd -f interface/cmsis-dap.cfg -f target/stm32h7x.cfg \
    -f syn/artix7/bringup/target/etm_enable_h743.cfg >/tmp/fr_etm.log 2>&1

echo "==> [4/6] clear CURTPM"
pkill -9 -f openocd 2>/dev/null; sleep 1
timeout 10 openocd -f interface/cmsis-dap.cfg -f target/stm32h7x.cfg \
    -c "init" -c "halt" -c "mww 0x5C015204 0" -c "resume" -c "shutdown" >/dev/null 2>&1

echo "==> [5/6] re-arm + dump"
python3 "$here/trace_ctrl.py" --ip "$IP" rearm >/dev/null
sleep 1
python3 "$here/trace_dump.py" --ip "$IP" --depth 61440 -o "$OUT" --timebase 2>&1 | tail -3

echo "==> [6/6] measured TRACECLK + decode + order check"
python3 - "$OUT" <<'PY'
import json,sys,re
b=sys.argv[1]
try:
    tb=json.load(open(b+".ts.json"))
    f=tb['depth']/(tb['last_tick']*tb['tick_ns']*1e-9)/1e6
    print("    TRACECLK = %.1f MHz (FPGA timebase)"%f)
except Exception as e:
    print("    (no timebase:",e,")")
PY
python3 "$here/../decode/opencsd_etm4_run.py" "$OUT" "$ELF" --period-ns 15.0 \
    --dump-lister "/tmp/l_$TAG.txt" 2>&1 | grep -iE "deframed|A-sync|unique|flash|func_test|missing"
echo "--- strict byte error + order ---"
python3 -c "
import re
t=open('/tmp/l_$TAG.txt').read()
ir=len(re.findall(r'INSTR_RANGE',t));res=len(re.findall(r'I_RESERVED',t));bad=len(re.findall(r'BAD_SEQUENCE',t))
print('INSTR_RANGE=%d RESERVED=%d BAD_SEQ=%d  byte-err=%.3f%%'%(ir,res,bad,100*(res+bad)/max(1,ir+res+bad)))
"
python3 "$here/../decode/verify_order.py" "/tmp/l_$TAG.txt" "$ELF" 2>&1 | grep -iE "PASS|PARTIAL"
