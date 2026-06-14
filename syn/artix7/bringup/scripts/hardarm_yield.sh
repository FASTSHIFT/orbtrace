#!/usr/bin/env bash
# hardarm_yield — measure capture yield under HARD re-arm (full bitstream
# reprogram each time), to test the re-arm-race hypothesis (r16 E1): hard-arm
# re-establishes the whole capture pipeline from reset, so if hard-arm is
# consistently clean while soft-arm is 7-10% bad, the soft re-arm is implicated.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
bit="${1:-trace_stream_sr.bit}"
n="${2:-6}"
ip="${IP:-192.168.10.42}"

for i in $(seq 1 "$n"); do
    pkill -9 -f hw_server 2>/dev/null || true
    ( cd "$root/build" && BITFILE="$root/build/$bit" \
        vivado -mode batch -source ../fpga_flow/program_bit.tcl >/tmp/ha_prog.log 2>&1 )
    pkill -9 -f hw_server 2>/dev/null || true
    sleep 1
    python3 "$here/trace_dump.py" --ip "$ip" --depth 61440 -o "/tmp/ha$i.bin" >/dev/null 2>&1
    v=$(python3 "$root/decode/fpga_errrate.py" "/tmp/ha$i.bin" 2>/dev/null \
        | grep -oP '\(\K[0-9.]+(?=%\))')
    echo "hardarm $i: ${v}%"
done
