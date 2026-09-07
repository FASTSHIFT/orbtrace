# fpga_flow/ — Vivado build / program / flash TCL

Batch TCL run by the `../scripts/*.sh` wrappers (or directly). RTL is read from
`../rtl/`, the verilog-ethernet submodule, and the shared `../../rtl` /
`../../../verilog` trees. Builds land in `../build/`.

## Build (synth+impl+bit)
- `run_trace_ddr_stream.tcl` — **active** real-trace path: IDDR capture ->
  DDR3 ring -> UDP :5555 (`trace_ddr_stream_top`). `USE_IDELAY=0` (default in
  `../scripts/build.sh`) is the shipped direct capture.
- `run_blink.tcl` — Stage-3 LED blink
- `run_net_test.tcl` — Stage-3 RGMII loopback
- `run_ddr_ring_selftest.tcl` / `run_trace_ddr_selftest.tcl` — DDR-ring / trace
  DDR diagnostic self-tests (ramp / fixed source, no trace pins)

## Program / flash
- `program_jtag.tcl` — volatile JTAG `.bit` load (blink)
- `program_bit.tcl` — generic volatile `.bit` load (env `BITFILE`)
- `program_net_test.tcl` — per-design loader
- `flash_program.tcl` — QSPI flash fixation of a `.mcs` (persists power cycle)

Most scripts are run from `../build/`, e.g.
`cd build && vivado -mode batch -source ../fpga_flow/run_trace_ddr_stream.tcl`.
