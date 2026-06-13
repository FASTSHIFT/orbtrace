#!/usr/bin/env bash
# One-key STM32F429 ETM 4-bit parallel trace enable.
# Wraps etm_enable.cfg so you don't memorise the OpenOCD invocation.
#
#   ./etm_enable.sh
#
# Runs the full GPIO-AF + DEMCR + DBGMCU + TPIU + ETM sequence, prints a
# register readback, then resumes the target. OpenOCD stays resident to keep
# trace running; it is killed after TIMEOUT seconds (the resume has already
# taken effect, so exit code 124 from `timeout` is expected and harmless).
#
# Correct ordering for a capture: run THIS first, THEN (re)burn the FPGA so
# its one-shot capture arms on live trace (see flash_and_capture.sh).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cfg="$root/target/etm_enable.cfg"
TIMEOUT="${TIMEOUT:-6}"

# Free any resident OpenOCD that would hold the ST-Link.
pkill -9 -f openocd 2>/dev/null || true
sleep 0.3

echo "==> enabling STM32 ETM (4-bit parallel trace) via $cfg"
timeout "$TIMEOUT" openocd \
    -f interface/stlink.cfg \
    -f target/stm32f4x.cfg \
    -f "$cfg"
rc=$?
if [ "$rc" -eq 124 ]; then
    echo "==> OpenOCD timed out and was killed (expected); resume already applied."
    rc=0
fi
echo "==> ETM enable done (rc=$rc). STM32 is RUNNING and emitting trace."
exit "$rc"
