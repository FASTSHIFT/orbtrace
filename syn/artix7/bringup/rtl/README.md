# rtl/ — bring-up FPGA sources (Verilog + constraints)

RTL tops and constraints for each bring-up stage, built by the TCL flows in
`../fpga_flow/`. The flow scripts read these via `$rtl_dir` (see each
`run_*.tcl`).

| Top | XDC | Stage / purpose |
|-----|-----|-----------------|
| `trace_ddr_stream_top.v` | `trace_ddr_stream.xdc` | **active**: IDDR capture -> DDR3 ring -> UDP :5555 |
| `blink.v` | `blink.xdc` | Stage-3 JTAG smoke-test (LED blink) |
| `net_test_top.v` | `net_test.xdc` | Stage-3 RGMII gigabit loopback |
| `fpga_core_net.v` | — | shared MAC/IP/UDP core wrapper |
| `ddr3_selftest_top.v` | `ddr3_selftest.xdc` | proposal 32 P1: DDR3 MIG write/readback self-loop (LED) |
| `trace_ddr_selftest_top.v` | `trace_ddr_selftest.xdc` | proposal 32 P2a: DDR3 MIG + Ethernet :5001 readout coexistence |
| `ddr_ring_selftest_top.v` | `trace_ddr_selftest.xdc` | DDR-ring drain self-test (ramp / fixed source) |
| `ddr3/` | — | vendor A7-Lite DDR3 abstraction layer + MIG/clock IP (reused) |

### DDR3 (MIG) notes — hard-won (proposal 32)
- **Cold boot required**: an openFPGALoader SRAM load leaves MIG mis-calibrated
  (calib ok but garbage reads). Always validate DDR3 bitstreams after a clean
  power cycle / flash boot.
- **Write data must be COMBINATIONAL**: the vendor `ddr3_wr_ctrl` samples
  `app_wdf_data = ddr3_wr_data` on the SAME cycle it raises `ddr3_wr_data_req`.
  A registered `wr_data <= f(cnt)` on the request is one cycle late and stores
  the previous word (readback looks shifted by one). Drive `wr_data`
  combinationally from the word counter.
- **BUILD_ID register (0xFF70)**:每个 build 打入 Unix 时间戳，:5001 读回可证明
  跑的 bitstream == 最新构建（排除烧录/冷启动没生效这类低级错误）。
- **Reset synchroniser domain**: generate the sys reset in clk125 (the MAC-FIFO
  domain), not clk100 — an async reset fanning clk100->clk125 with huge fanout
  fails the recovery check.
