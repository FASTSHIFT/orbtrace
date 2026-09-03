# Scope cross-check (RIGOL MSO8304A) — localise TRACE byte loss

An independent **golden observation point at the TPIU pins** (the source),
used to break the long-standing "loses a little, keeps losing" question into a
single answerable layer: **SI / FPGA-sampling / network-transport**.

The FPGA capture is at the *end* of a serial chain (STM32 TPIU pins → 47R +
flylead SI → FPGA IDDR sampling → FIFO → UDP → NIC → host). Every host-side
metric only sees the end. The scope taps the **front** (the pins), so diffing
scope-source bytes against FPGA-captured bytes tells you where bytes vanish.

## Wiring
Scope LA pod, ST side of the series resistors (the source):

| LA line | signal   |
|---------|----------|
| D0      | TRACECK  |
| D1      | TRACED0  |
| D2      | TRACED1  |
| D3      | TRACED2  |
| D4      | TRACED3  |

(CH1 analog on TRACECK is handy for an eye / frequency sanity check.)

## Setup (once)
```bash
pip3 install pyvisa pyvisa-py pyusb
sudo cp 60-rigol-usbtmc.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
# be in the 'plugdev' group; re-login if needed
python3 scope_visa.py "*IDN?"   # -> RIGOL TECHNOLOGIES,MSO8304A,...
```

## Run a cross-check
```bash
# 1) scope side: deep LA capture -> CAP_RAW bytes (same format as the FPGA)
python3 la_capture.py 1e-5 10M /tmp/scope_capraw.bin 4000000

# 2) FPGA side: capture the live stream (from bringup root)
python3 scripts/trace_ctrl.py rearm && sleep 2
python3 scripts/trace_dump.py --depth 61440 -o /tmp/fpga_base.bin

# 3) diff
python3 scope/scope_fpga_diff.py /tmp/scope_capraw.bin /tmp/fpga_base.bin
```

## Reading the result
`scope_fpga_diff.py` strips TPIU idle/halfsync and reports the longest verbatim
common run + the fraction of FPGA byte-windows found verbatim in the scope
stream. Because the two captures are independent time slices of the periodic
selftrace loop, expect **partial-but-high** agreement when the chain is clean.

| observation | verdict |
|-------------|---------|
| high agreement (>~70%) + long identical run | source == FPGA bytes → **SI & FPGA sampling OK**; loss is downstream (FIFO/UDP/**AX88179 NIC**, see AGENT.md §2) |
| low agreement, scope stream clean | **FPGA sampling** (IDDR phase / tap) — re-check tap=2 eye centre |
| scope stream itself dirty/idle | **SI / source** at the pins |

## 2026-09-03 baseline (selftrace-O0, 112.5 MHz TRACECLK)
Longest common run **17 bytes identical**
(`f696304af6962cf79613f696fad3f6969a`), **71.4%** of FPGA 8-byte windows found
verbatim in the scope source. → **source and FPGA saw the same bytes**: SI and
FPGA sampling are not the fault; the residual ~0.1% real-trace loss is the
AX88179 USB NIC dropping frames at line rate (AGENT.md §2), not the pins or the
sampler.

## Files
| file | role |
|------|------|
| `scope_visa.py` | pyvisa (USB) SCPI wrapper — **never** raw /dev/usbtmc (wedges the scope) |
| `la_capture.py` | deep LA capture → CAP_RAW bytes (feeds decode/ tools like an FPGA capture) |
| `scope_fpga_diff.py` | content cross-check → SI vs sampling vs transport verdict |
| `60-rigol-usbtmc.rules` | udev rule for no-sudo USBTMC access (plugdev) |

## Notes / gotchas
- **Always use pyvisa**, never hand-rolled `/dev/usbtmc` reads: the raw path
  omits the USBTMC bulk-IN/bTag handshake, desyncs after the first query, and
  wedges the scope's remote interface (only a power-cycle recovers it).
- Each digital line reads back with its level in **bit0** of every byte; read
  each `Dn` via its own `:WAVeform:SOURce`.
- `:ACQuire:MDEPth` only takes effect while **RUNNING**; RAW readback needs
  `:STOP` first.
- 10:1 probes with a long ground lead show huge (±1–2 V) overshoot on the
  analog channels at 50–112 MHz — that is ground-loop ringing, a measurement
  artifact, not the real signal. Trust the LA logic decision (1.65 V) and the
  byte-level diff, not the analog Vmax/Vmin.
