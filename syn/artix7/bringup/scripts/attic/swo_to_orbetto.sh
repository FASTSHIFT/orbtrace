#!/usr/bin/env bash
# swo_to_orbetto.sh — turn an FPGA SWO capture into a Perfetto trace via orbetto.
#
# orbetto (embedded-debug-tools/ext/orbetto) decodes the ETM instruction stream
# with Mortrall and emits a Perfetto trace with a FUNCTION-LEVEL call stack.
# It is an OFFLINE file tool (-f), it does NOT connect to a live orbuculum.
#
# Pipeline:
#   FPGA capture (TPIU, sparse sync)
#     -> etm35lib.tpiu_deframe_walk  (adaptive re-lock -> pure ETM stream 2)
#     -> etm_to_tpiu.reframe         (re-wrap as dense-FSYNC TPIU so orbetto's
#                                     TPIUPump locks; it needs FSYNC)
#     -> orbetto -t 2 -f <tpiu> -e <elf>  -> orbetto.perf  (drag into ui.perfetto.dev)
#
# orbetto's Device() is identified from the ELF FILENAME; a bare app ELF is not
# recognised, so we symlink it to a name containing 'nuttx' (orbetto's pure-ETM
# test device). The CPU clock is overridden with -C anyway.
#
# Usage:
#   scripts/swo_to_orbetto.sh [capture.bin] [elf] [cpufreq_khz] [orbetto_bin]
# Defaults: fresh capture from FPGA, proj_add.axf, 168000 kHz.
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bringup="$(cd "$here/.." && pwd)"
repo_root="$(cd "$bringup/../../../.." && pwd)"

cap="${1:-}"
elf="${2:-$repo_root/proj_add.axf}"
cpufreq_khz="${3:-168000}"
orbetto="${4:-$repo_root/embedded-debug-tools/ext/orbetto/build/orbetto}"
ip="${IP:-192.168.10.42}"
bitlen="${BITLEN:-200}"

tpiu=/tmp/orbetto_in.tpiu

if [ -z "$cap" ]; then
    cap=/tmp/orbetto_cap.bin
    echo "==> capturing fresh SWO from FPGA $ip"
    python3 "$bringup/scripts/trace_ctrl.py" --ip "$ip" set-bitlen "$bitlen" >/dev/null || true
    python3 "$bringup/scripts/swo_dump_banked.py" --ip "$ip" --rearm -o "$cap"
fi

echo "==> deframe + reframe (adaptive re-lock -> pure ETM -> dense-FSYNC TPIU)"
python3 - "$cap" "$tpiu" "$bringup/decode" <<'PY'
import sys
sys.path.insert(0, sys.argv[3])
import etm35lib as L
from etm_to_tpiu import reframe
raw = open(sys.argv[1], "rb").read()
etm = L.tpiu_deframe_walk(raw, want_stream=2)
tp = reframe(etm)
open(sys.argv[2], "wb").write(tp)
fl = [x for x in L.find_isyncs(etm) if L.is_flash(x.addr)]
print(f"   raw {len(raw)} -> etm {len(etm)} -> reframed TPIU {len(tp)}; "
      f"etm35lib flash anchors (ground truth) = {len(fl)}")
PY

# orbetto identifies the device from the ELF filename; alias to a 'nuttx' name.
elf_alias=/tmp/$(basename "${elf%.*}")_nuttx.${elf##*.}
ln -sf "$(readlink -f "$elf")" "$elf_alias"

echo "==> orbetto: ETM -> Perfetto (function-level call stack)"
out_dir="$(dirname "$orbetto")/.."
( cd "$out_dir" && "$orbetto" -C "$cpufreq_khz" -t 2 -f "$tpiu" -e "$elf_alias" )

perf="$out_dir/orbetto.perf"
echo "==> done. Perfetto trace: $perf"
echo "    drag it into https://ui.perfetto.dev"
