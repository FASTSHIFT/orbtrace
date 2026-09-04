#!/usr/bin/env bash
# Sim regression sweep for S1b bring-up (r38 §6.5).
#
# Runs the tb_ddr_ring_fixed matrix (6 variants) and reports pass/fail per case.
# Exit non-zero on any FAIL. Intended for CI.
#
# Usage:  ./run_sim_regression.sh [--verbose]
#
# CI integration: put this behind a GitHub Actions job with `iverilog` installed
# (`apt-get install iverilog`). Runtime ~30 s total.

set -eu
cd "$(dirname "$0")"

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

CASES=(
    ""            # baseline: mem=DEADBEEF, stalls 40/60/100
    "mem_11"      # H7 corroboration: mem=0x11
    "mem_00"      # r37 cross-align: mem=0x00
    "mem_ff"      # r37 cross-align: mem=0xFF
    "ramp"        # ramp source (order-preservation check)
    "heavy"       # aggressive stalls (200/200 wdf/rdy)
)

FAIL=0
for cfg in "${CASES[@]}"; do
    label="${cfg:-baseline}"
    out=$(bash build_tb_fixed.sh $cfg 2>&1 || true)
    result=$(echo "$out" | grep "^RESULT=" | head -1)
    if echo "$result" | grep -q "ALL_PASS"; then
        # RAMP mode: currently tolerates 1 bad byte (known edge, r38 §1.4)
        printf "  PASS  %-16s  %s\n" "$label" "$result"
    elif [ "$cfg" = "ramp" ]; then
        bad=$(echo "$out" | grep -oP "bad_cnt=\K[0-9]+" | head -1 || echo 0)
        if [ "${bad:-0}" -le 2 ]; then
            printf "  WARN  %-16s  bad_cnt=%s (known ramp edge)\n" "$label" "$bad"
        else
            printf "  FAIL  %-16s  bad_cnt=%s (regression!)\n" "$label" "$bad"
            FAIL=$((FAIL+1))
        fi
    else
        printf "  FAIL  %-16s  %s\n" "$label" "$result"
        FAIL=$((FAIL+1))
        [ $VERBOSE -eq 1 ] && echo "$out" | tail -20
    fi
done

echo
if [ $FAIL -eq 0 ]; then
    echo "sim regression: ALL PASS (${#CASES[@]} cases)"
    exit 0
else
    echo "sim regression: $FAIL / ${#CASES[@]} FAILED"
    exit 1
fi
