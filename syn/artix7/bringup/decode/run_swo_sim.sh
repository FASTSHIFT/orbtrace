#!/usr/bin/env bash
# run_swo_sim — SWO front-end RTL regression (提案 15).
# Compiles and runs the three SWO testbenches with iverilog and asserts PASS:
#   1. swo_chain_tb   : synthetic UART bytes round-trip through pulse->nrz->uart
#   2. swo_baud_tb    : NRZ baud tolerance (+/-5% must recover all bytes)
#   3. swo_replay_tb  : REAL LA-captured SWO waveform -> RTL bytes, then checks
#                       the RTL output byte-for-byte equals the software model
#                       (decode/swo_csv_decode pulse->nrz->uart) on the same data.
#
# Usage:  ./run_swo_sim.sh [path-to-swo.csv]
# The replay test is skipped (with a notice) if no CSV is given/found.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bringup="$(cd "$here/.." && pwd)"
rtl="$bringup/rtl"
sim="$rtl/sim"
csv="${1:-}"

pass=0; fail=0
run_tb() {  # name, sources..., (reads $expect)
    local name="$1"; shift
    local bin="/tmp/${name}"
    if ! iverilog -g2012 -o "$bin" "$@" 2>/tmp/${name}.ivl; then
        echo "[$name] COMPILE FAIL"; cat /tmp/${name}.ivl; fail=$((fail+1)); return
    fi
    local out; out="$(vvp "$bin" 2>&1)"
    echo "$out" | sed 's/^/    /'
    if echo "$out" | grep -q "^PASS\|PASS:"; then
        echo "[$name] PASS"; pass=$((pass+1))
    else
        echo "[$name] FAIL"; fail=$((fail+1))
    fi
}

echo "=== 1/3 swo_chain_tb (synthetic round-trip) ==="
run_tb swo_chain_tb \
    "$sim/swo_chain_tb.v" "$rtl/swo_pulse_capture.v" \
    "$rtl/swo_nrz_decode.v" "$rtl/swo_uart_decode.v"

echo "=== 2/3 swo_baud_tb (baud tolerance) ==="
run_tb swo_baud_tb \
    "$sim/swo_baud_tb.v" "$rtl/swo_pulse_capture.v" \
    "$rtl/swo_nrz_decode.v" "$rtl/swo_uart_decode.v"

echo "=== 3/3 swo_replay_tb (real LA waveform vs software model) ==="
if [ -z "$csv" ] || [ ! -f "$csv" ]; then
    echo "    SKIP: no CSV given (usage: $0 <swo.csv>)"
else
    # export vector (400k LA samples) + software-model golden bytes
    python3 "$here/swo_csv_to_simvec.py" "$csv" /tmp/swo_vec.mem --max-samples 400000 >/dev/null
    nbits=$(wc -l < /tmp/swo_vec.mem)
    python3 "$here/swo_model_bytes.py" "$csv" --max-samples 400000 -o /tmp/swo_model.hex >/dev/null
    if iverilog -g2012 -DVEC='"/tmp/swo_vec.mem"' -DNBITS="$nbits" \
         -DOUTHEX='"/tmp/swo_rtl_bytes.hex"' -o /tmp/swo_replay_tb \
         "$sim/swo_replay_tb.v" "$rtl/swo_pulse_capture.v" \
         "$rtl/swo_nrz_decode.v" "$rtl/swo_uart_decode.v" 2>/tmp/replay.ivl; then
        vvp /tmp/swo_replay_tb 2>&1 | sed 's/^/    /'
        if python3 "$here/swo_cmp_bytes.py" /tmp/swo_rtl_bytes.hex /tmp/swo_model.hex; then
            echo "[swo_replay_tb] PASS"; pass=$((pass+1))
        else
            echo "[swo_replay_tb] FAIL"; fail=$((fail+1))
        fi
    else
        echo "    COMPILE FAIL"; cat /tmp/replay.ivl; fail=$((fail+1))
    fi
fi

echo "==================================================="
echo "SWO sim regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
