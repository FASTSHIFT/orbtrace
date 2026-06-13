#!/usr/bin/env bash
# trace_run.sh — end-to-end trace capture + decode, the settled route.
#
# Route (docs/artix7-port/stage4-datapath/10-reuse-gap-audit.md §8):
#   STM32 ETM -> FPGA trace_stream_top (traceIF byte frames, NO tpiu_demux)
#   -> UDP dump -> etm_decode_cli.py (anchor on I-sync, addr2line) -> functions
#
# Correct ordering is enforced: enable ETM first, THEN (re)arm the FPGA
# one-shot capture, THEN dump+decode.
#
#   ./trace_run.sh                       # ETM -> reload trace_stream.bit -> dump -> decode
#   IP=192.168.10.42 DEPTH=61440 OUT=/tmp/trace.bin ELF=/tmp/axf/proj_new.axf ./trace_run.sh
#   ./trace_run.sh --no-program          # skip re-arm (decode last capture only)
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IP="${IP:-192.168.10.42}"
DEPTH="${DEPTH:-61440}"
OUT="${OUT:-/tmp/trace.bin}"
ELF="${ELF:-/tmp/axf/proj_new.axf}"
do_program=1
[ "${1:-}" = "--no-program" ] && do_program=0

if [ "$do_program" -eq 1 ]; then
    echo "==> [1/3] enable STM32 ETM"
    "$here/etm_enable.sh"
    echo "==> [2/3] re-arm FPGA capture (reload trace_stream.bit over JTAG)"
    "$here/program.sh" stream jtag
    sleep 3
    echo "==> [3/3] dump + decode"
    ( cd "$here" && python3 trace_dump.py --ip "$IP" --depth "$DEPTH" -o "$OUT" )
else
    echo "==> [decode only] using existing $OUT (no ETM/FPGA/dump)"
    [ -f "$OUT" ] || { echo "ERROR: $OUT not found"; exit 1; }
fi

echo
( cd "$here/../decode" && ELF="$ELF" python3 etm_decode_cli.py "$OUT" )
