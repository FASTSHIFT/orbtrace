# rtl/ — bring-up FPGA sources (Verilog + constraints)

RTL tops and constraints for each bring-up stage, built by the TCL flows in
`../fpga_flow/`. The flow scripts read these via `$rtl_dir` (see each
`run_*.tcl`).

| Top | XDC | Stage / purpose |
|-----|-----|-----------------|
| `blink.v` | `blink.xdc` | Stage-3 JTAG smoke-test (LED blink) |
| `net_test_top.v` | `net_test.xdc` | Stage-3 RGMII gigabit loopback |
| `eyescan_top.v` / `trace_eyescan.v` | `eyescan.xdc` | V1 IDELAY eye-scan |
| `trace_stream_top.v` | `trace_stream.xdc` | V3 raw traceIF-frame capture |
| `trace_orbflow_top.v` | `trace_orbflow.xdc` | V3 "A route" native OFLOW egress |
| `fpga_core_net.v` | — | shared MAC/IP/UDP core wrapper |
| `sim/eyescan_pattern_tb.v` | — | eye-scan pattern testbench |
