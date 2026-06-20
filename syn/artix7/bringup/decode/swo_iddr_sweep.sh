#!/usr/bin/env bash
# swo_iddr_sweep — sweep SWO baud on the IDDR (400 MSa/s) bitstream and report
# decode quality per baud (proposal 17 §4.3). Requires:
#   - swo_stream.bit built with SWO_MODE=1 (IDDR) and programmed
#   - the resident OpenOCD ETM-SWO session (etm_swo_openocd.cfg) alive
#     (SWO dies on debugger exit), with dense sync
#
# IDDR is 400 MSa/s, so bitlen (sample ticks/UART bit) = 400e6 / baud, and the
# STM32 TPIU ACPR = 168e6/baud - 1. Run from the bringup dir:
#   bash decode/swo_iddr_sweep.sh
set -u
IP="${IP:-192.168.10.42}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bringup="$(cd "$here/.." && pwd)"

# baud(MHz) -> "ACPR(hex) bitlen(400e6/baud)"
declare -A A=( [8]="0x14 50" [14]="0x0B 29" [21]="0x07 19" \
               [28]="0x05 14" [42]="0x03 10" [56]="0x02 7" )

printf "%6s %6s %7s %9s %8s %8s\n" baud acpr bitlen samp/bit "best_unk%" anchors
for b in 8 14 21 28 42 56; do
    set -- ${A[$b]}; acpr=$1; bl=$2
    printf "mww 0xE0040010 $acpr\nexit\n" | timeout 5 nc localhost 4444 >/dev/null 2>&1
    python3 "$bringup/scripts/trace_ctrl.py" --ip "$IP" set-bitlen "$bl" >/dev/null
    best=100; bestf=0
    for t in 1 2 3; do
        python3 "$bringup/scripts/swo_dump_banked.py" --ip "$IP" --rearm --settle 0.5 \
            -o /tmp/id_$b.bin >/dev/null 2>&1
        read u f <<<$(python3 - "$b" <<'PYEOF'
import sys; sys.path.insert(0, "decode")
import etm35lib as L
raw = open(f"/tmp/id_{sys.argv[1]}.bin", "rb").read()
etm = L.tpiu_deframe_walk(raw, want_stream=2)
unk = sum(1 for c in etm if L._classify(c) == "unknown")
fl = len([s for s in L.find_isyncs(etm) if L.is_flash(s.addr)])
print(f"{100*unk/max(1,len(etm)):.3f} {fl}")
PYEOF
)
        awk "BEGIN{exit !($u<$best)}" && { best=$u; bestf=$f; }
    done
    sb=$(python3 -c "print(f'{400/$b:.2f}')")
    printf "%5sM %6s %7s %9s %8s %8s\n" "$b" "$acpr" "$bl" "$sb" "$best" "$bestf"
done

# restore 2M
printf 'mww 0xE0040010 0x53\nexit\n' | timeout 5 nc localhost 4444 >/dev/null 2>&1
python3 "$bringup/scripts/trace_ctrl.py" --ip "$IP" set-bitlen 200 >/dev/null
echo "restored 2 MHz"
