#!/usr/bin/env bash
# freq_push — flash a firmware tag, bring up ETM (BB=1, no stall), sweep the
# global IDELAY tap scored by real-ETM A-sync (the eye narrows as freq rises,
# so the eye centre moves), pick the best tap, then full-decode + order-check
# at that tap. Ends with trace_off so the debug AP never stalls.
#
#   freq_push.sh <fw_tag>
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"     # orbtrace/
fwroot="$(cd "$root/.." && pwd)"
TAG="${1:?usage: freq_push.sh <fw_tag>}"
HEX="$fwroot/perf/firmware/$TAG/H743_Blink.hex"
ELF="$fwroot/perf/firmware/$TAG/H743_Blink.axf"
IP="${IP:-192.168.10.42}"
TAPS="${TAPS:-0,2,4,6,8,10,12,16,20,24}"
cd "$root"

echo "==> flash $TAG"
pkill -9 -f openocd 2>/dev/null; sleep 1
timeout 60 openocd -f interface/cmsis-dap.cfg \
  -c "adapter speed 1000" \
  -c "reset_config srst_only srst_nogate connect_assert_srst" \
  -f target/stm32h7x.cfg -c "init" -c "reset halt" \
  -c "program $HEX verify" -c "reset run" -c "shutdown" >/tmp/fp_flash.log 2>&1
grep -qi "Verified OK" /tmp/fp_flash.log && echo "   verified" || { echo "   FLASH FAIL"; tail -5 /tmp/fp_flash.log; exit 1; }

echo "==> enable ETM BB=1, no stall; clear CURTPM"
pkill -9 -f openocd 2>/dev/null; sleep 1
TRACE_BB=1 TRACE_STALL=0 timeout 12 openocd -f interface/cmsis-dap.cfg -f target/stm32h7x.cfg \
  -f syn/artix7/bringup/target/etm_enable_h743.cfg >/tmp/fp_etm.log 2>&1
pkill -9 -f openocd 2>/dev/null; sleep 1
timeout 10 openocd -f interface/cmsis-dap.cfg -f target/stm32h7x.cfg \
  -c "init" -c "halt" -c "mww 0x5C015204 0" -c "resume" -c "shutdown" >/dev/null 2>&1

echo "==> measure TRACECLK"
python3 "$here/trace_ctrl.py" --ip "$IP" rearm >/dev/null; sleep 0.5
python3 "$here/trace_dump.py" --ip "$IP" --depth 61440 -o /tmp/fp.bin --timebase >/dev/null 2>&1
python3 - <<PY
import json
try:
    tb=json.load(open("/tmp/fp.bin.ts.json"))
    print("   TRACECLK = %.1f MHz"%(tb['depth']/(tb['last_tick']*tb['tick_ns']*1e-9)/1e6))
except Exception as e: print("   (no timebase)",e)
PY

echo "==> global tap sweep (A-sync metric)"
best_tap=-1; best_a=-1
IFS=',' read -ra TA <<< "$TAPS"
for t in "${TA[@]}"; do
  python3 "$here/trace_ctrl.py" --ip "$IP" set-tap "$t" >/dev/null
  python3 "$here/trace_ctrl.py" --ip "$IP" rearm >/dev/null; sleep 0.4
  python3 "$here/trace_dump.py" --ip "$IP" --depth 61440 -o /tmp/fp.bin >/dev/null 2>&1
  a=$(python3 - <<PY
import sys; sys.path.insert(0,"$here/../decode")
import tpiu_official as T
d=open("/tmp/fp.bin","rb").read()
etm,st=T.deframe(d,want_stream=2)
a=z=0
for c in etm:
    if c==0:z+=1
    elif c==0x80 and z>=11:a+=1;z=0
    else:z=0
print(a)
PY
)
  echo "   tap=$t  A-sync=$a"
  if [ "$a" -gt "$best_a" ]; then best_a=$a; best_tap=$t; fi
done
echo "   -> best tap = $best_tap (A-sync=$best_a)"

echo "==> full decode + order at best tap"
python3 "$here/trace_ctrl.py" --ip "$IP" set-tap "$best_tap" >/dev/null
python3 "$here/trace_ctrl.py" --ip "$IP" rearm >/dev/null; sleep 0.5
python3 "$here/trace_dump.py" --ip "$IP" --depth 61440 -o "/tmp/etm_$TAG.bin" >/dev/null 2>&1
python3 "$here/../decode/opencsd_etm4_run.py" "/tmp/etm_$TAG.bin" "$ELF" \
  --period-ns 8.0 --dump-lister "/tmp/l_$TAG.txt" 2>&1 | grep -iE "deframed|unique|flash|func_test|missing"
python3 -c "
import re;t=open('/tmp/l_$TAG.txt').read()
ir=len(re.findall(r'INSTR_RANGE',t));res=len(re.findall(r'I_RESERVED',t));bad=len(re.findall(r'BAD_SEQUENCE',t))
print('   INSTR_RANGE=%d RESERVED=%d BAD_SEQ=%d byte-err=%.3f%%'%(ir,res,bad,100*(res+bad)/max(1,ir+res+bad)))"
python3 "$here/../decode/verify_order.py" "/tmp/l_$TAG.txt" "$ELF" 2>&1 | grep -iE "PASS|PARTIAL"

echo "==> trace off (avoid AP stall)"
pkill -9 -f openocd 2>/dev/null; sleep 1
timeout 12 openocd -f interface/cmsis-dap.cfg -f target/stm32h7x.cfg \
  -f syn/artix7/bringup/target/trace_off_h743.cfg >/dev/null 2>&1
echo "== done $TAG =="
