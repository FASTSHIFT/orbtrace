<!--
  Bilingual README. English first, 中文在后.
  Use the language links below to jump between sections.
-->

# ORBTrace · Artix-7 Port

**Language / 语言**:&nbsp; **English** &nbsp;|&nbsp; [中文](#orbtrace--artix-7-移植版)

> A fork of [orbcode/orbtrace](https://github.com/orbcode/orbtrace) that ports the
> ARM Cortex-M parallel-TRACE pipeline from the ECP5 + USB + HyperRAM ORBTrace mini
> hardware onto a commodity **Xilinx Artix-7** board (MicroPhase A7-Lite, XC7A35T)
> with a **Gigabit-Ethernet** export path.
>
> The upstream README is preserved verbatim at **[`README.upstream.md`](README.upstream.md)**.

---

## Why this fork

The original ORBTrace is excellent but hard to obtain: the mini board's PCB is not
open-sourced, and the gateware is tied to three Lattice/board-specific dependencies
— ECP5 clocking primitives, a ULPI USB 2.0 PHY, and HyperRAM. This fork keeps the
**platform-independent trace decode core untouched** and rebuilds everything around
it for parts you can actually buy off the shelf.

| Aspect | Upstream ORBTrace mini | This fork (Artix-7) |
|--------|------------------------|---------------------|
| FPGA | Lattice ECP5 (LFE5U-25F) | Xilinx Artix-7 (XC7A35T-2FGG484I) |
| Capture front-end | ECP5 `IDDRX1F` + `DELAYG` | 7-series `IDDR` + `IDELAYE2` + `IDELAYCTRL` |
| Clocking | `ECP5PLL` | `MMCME2_BASE` |
| Host link | USB 2.0 HS via ULPI PHY | **Gigabit Ethernet (RGMII, RTL8211E)** |
| Trace buffer | 8 MB HyperRAM | on-chip BRAM AsyncFIFO (DDR3 spill is Stage-3) |
| Target board | ORBTrace mini (PCB not open) | MicroPhase A7-Lite (off-the-shelf, ~¥375) |

What is **reused unchanged**: the Amaranth trace decode core
(`orbtrace/trace/*.py` — TPIUDemux / COBS / ChecksumAppender / SuperFramer) and the
hand-written `verilog/traceIF.v` TPIU framer. We deliberately layered the port on
top rather than rewriting the core, so upstream improvements can still be merged.

---

## Project status

Hardware-free bring-up is complete through **Stage-2 (OOC synthesis & board
selection)**. A three-round red/blue review (r09 → r10 → r11) converged to a
**GO for the 35T** once four buy-decision hard gates were closed:

| Gate | Question | Result |
|------|----------|--------|
| HG-1 | Is the trace pipeline really in the routed netlist? | ✅ paths end at `u_sf/data_reg[*]` |
| HG-2 | Does BUFG eat the sampling window? | ✅ BUFR/BUFIO is **1.34 ns** wider → use it on board |
| HG-3 | Does the optional RGMII-RX IDELAY fit (2nd IDELAYCTRL, cross-bank)? | ✅ both IDELAYCTRLs place & route |
| HG-4 | Are 35T and 100T pin-compatible on FGG484? | ✅ **0 mismatches** across 40 used pins |

**Post-implementation (xc7a35tfgg484-2):** 2,320 LUT (11.15%), 11 BRAM (22%),
WNS = +1.254 ns, WHS = +0.034 ns, TNS = THS = 0, DRC 0 errors.

Real hardware risks (eye-scan margin, PHY strap, metastability MTBF) are
explicitly carried into **Stage-3 (on-board PoC)**.

**Stage-3 status:** the board has arrived and first-light is done — a
2-LED blink bitstream builds, programs over JTAG, and runs
(`End of startup status: HIGH`), proving the PC → JTAG → FPGA-config
chain. Getting there hit two environment-only snags (Linux `ftdi_sio`
grabbing the FT232H, and VMware's EHCI USB passthrough failing to open
the FTDI MPSSE endpoint); both are written up in
**[`docs/artix7-port/stage3-bringup/01-board-bringup-troubleshooting.md`](docs/artix7-port/stage3-bringup/01-board-bringup-troubleshooting.md)**.
Bring-up sources live in [`syn/artix7/bringup/`](syn/artix7/bringup/).

**Target self-test:** the STM32F429 (DISC1) ETM → TPIU → 4-bit parallel
trace port has been enabled over ST-Link/OpenOCD and verified on a scope
(TRACECLK + TRACED0..3 carry data) — so the "does the target emit trace?"
question is settled before wiring it to the FPGA. The exact register
sequence and the gotchas (GPIO must be hand-muxed to AF0; ETM must be
enabled, not just the TPIU) are in
**[`docs/artix7-port/stage3-bringup/02-stm32-etm-enable.md`](docs/artix7-port/stage3-bringup/02-stm32-etm-enable.md)**.

**Gigabit link up:** the on-board RGMII + RTL8211E gigabit Ethernet path
is working both directions — the FPGA answers ARP and a UDP loopback on
port 1234 echoes back end-to-end. The fix was removing the FPGA-side
double-delay on both RX (bypass IDELAY) and TX (`USE_CLK90="FALSE"`),
since the RTL8211E straps its own RX/TX delays on. The debugging journey
(including the dead ends) is in
**[`docs/artix7-port/stage3-bringup/03-rgmii-net-link.md`](docs/artix7-port/stage3-bringup/03-rgmii-net-link.md)**.

**Next (Stage-4):** with those three islands proven, the remaining work
is to wire them into one stream — `trace pins → traceIF → OrbFlow → UDP →
Orbuculum` — and decode a real instruction flow end-to-end. The plan,
structured as a falsifiable ladder (V0 digital loopback → V1 sampling
eye-scan → V2 real ETM → V3 Orbuculum → V4 speed/UDP robustness), is in
**[`PLAN_STAGE4.md`](docs/artix7-port/PLAN_STAGE4.md)**.

Full plan and evidence: **[`docs/artix7-port/`](docs/artix7-port/)**
(see [`PLAN.md`](docs/artix7-port/PLAN.md), [`PLAN_STAGE2.md`](docs/artix7-port/PLAN_STAGE2.md),
[`PLAN_STAGE4.md`](docs/artix7-port/PLAN_STAGE4.md),
the `proposals/` and `reviews/` directories).

---

## What changed vs upstream

Highly localized — only **2 upstream files touched**, everything else is additive.

- **`verilog/traceIF.v`** (29 lines): fixed two genuine upstream bugs that surfaced
  under Vivado/iverilog — a stray port-list comma + missing explicit `wire`
  declarations, and a **missing reset branch** (`FrAvail` etc. stayed `X` in
  simulation and never produced a frame-ready edge).
- **`verilog/testbeds/traceIF_tb.v`** (5 lines): port-name alignment.
- **Everything under [`syn/`](syn/)** is new: the Artix-7 capture front-end
  (`rtl/trace_capture_a7.v`), the integration top (`rtl/trace_probe_top.v`), board
  constraints, OOC/impl Tcl flows, the Amaranth→Verilog exporter, and the
  simulation regressions.
- **`syn/external/verilog-ethernet`** is a new submodule (Alex Forencich's gigabit
  stack) providing the Ethernet export path.
- New tests (`tests/test_*.py`, `verilog/testbeds/*_tb.v`) and CI tweaks.

---

## Building

### Upstream ORBTrace mini gateware

Unchanged — see **[`README.upstream.md`](README.upstream.md)**.

### Artix-7 OOC synthesis / implementation (this fork)

Requires Vivado (validated on **2021.1**). Source the settings first:

```bash
source /path/to/Xilinx/Vivado/2021.1/settings64.sh

# Full design: synth + place + route + utilization/timing + survival checks
vivado -mode batch -source syn/artix7/run_top_impl.tcl

# Optionally prove the RGMII-RX-IDELAY variant (HG-3)
PHY_RX_DELAY_INTERNAL=1 vivado -mode batch -source syn/artix7/run_top_impl.tcl

# BUFG vs BUFR/BUFIO sampling-window study (HG-2)
vivado -mode batch -source syn/artix7/run_capture_bufr.tcl

# 35T vs 100T pin compatibility (HG-4)
vivado -mode batch -source syn/artix7/check_pincompat.tcl
```

### Simulation / regression

```bash
# Logic-layer unit tests (Amaranth)
python3 -m pytest tests/

# traceIF physical-layer regressions (iverilog)
iverilog -g2012 -o /tmp/tb verilog/traceIF.v verilog/testbeds/traceIF_tb.v && vvp /tmp/tb

# Dual-clock CDC regression: frame128 trace_clk→clk100 + overflow accounting (iverilog)
./syn/artix7/sim/run_frame_cdc.sh

# Artix-7 capture front-end end-to-end (Vivado xsim; iverilog can't do unisims)
source /path/to/Vivado/2021.1/settings64.sh
./syn/artix7/sim/run_xsim.sh
```

---

## Repository layout (fork additions)

```
syn/artix7/
  rtl/trace_capture_a7.v     7-series capture front-end (IDDR+IDELAY, BUFG|BUFR_IO)
  rtl/trace_probe_top.v      integration top (capture + traceIF + AsyncFIFO + GbE)
  constraints/trace_probe.xdc A7-Lite pins / clocks / source-sync input delays
  export_trace_modules.py    Amaranth trace core → Verilog for Vivado
  run_*.tcl                  OOC / full-impl / BUFR study / pin-compat flows
  sim/                       xsim front-end + iverilog dual-clock CDC regressions
syn/external/verilog-ethernet  gigabit Ethernet stack (submodule)
docs/artix7-port/            plans, proposals, red/blue reviews (r01–r11)
```

---

## Acknowledgements

This fork stands entirely on [orbcode/orbtrace](https://github.com/orbcode/orbtrace)
by Vegard Storheil Eriksen and Dave Marples, and on
[Orbuculum](https://github.com/orbcode/orbuculum) for host-side decode. The Ethernet
path uses [alexforencich/verilog-ethernet](https://github.com/alexforencich/verilog-ethernet).
Please honour the Open Source ethos as the upstream authors ask — pay it forward.

License: BSD-3-Clause (same as upstream).

---
---

# ORBTrace · Artix-7 移植版

**Language / 语言**:&nbsp; [English](#orbtrace--artix-7-port) &nbsp;|&nbsp; **中文**

> 这是 [orbcode/orbtrace](https://github.com/orbcode/orbtrace) 的一个 fork，把
> ARM Cortex-M 并行 TRACE 流水线从 ORBTrace mini 的 ECP5 + USB + HyperRAM 硬件，
> 移植到一块随手能买到的 **Xilinx Artix-7** 开发板（微相 A7-Lite，XC7A35T）上，
> 并改用 **千兆以太网** 作为数据出口。
>
> 上游原始 README 原文保留于 **[`README.upstream.md`](README.upstream.md)**。

---

## 为什么做这个 fork

原版 ORBTrace 很优秀，但难买：mini 主板的 PCB 未开源，gateware 又绑死了三个
Lattice/板级专属依赖——ECP5 时钟原语、ULPI USB 2.0 PHY、HyperRAM。本 fork
**完全不动平台无关的 trace 解码核心**，只把它周围的东西全部换成市面上买得到的器件。

| 维度 | 上游 ORBTrace mini | 本 fork（Artix-7） |
|------|--------------------|--------------------|
| FPGA | Lattice ECP5（LFE5U-25F） | Xilinx Artix-7（XC7A35T-2FGG484I） |
| 采样前端 | ECP5 `IDDRX1F` + `DELAYG` | 7 系 `IDDR` + `IDELAYE2` + `IDELAYCTRL` |
| 时钟 | `ECP5PLL` | `MMCME2_BASE` |
| 主机链路 | 经 ULPI PHY 的 USB 2.0 高速 | **千兆以太网（RGMII，RTL8211E）** |
| Trace 缓冲 | 8 MB HyperRAM | 片内 BRAM AsyncFIFO（DDR3 深缓冲留第三阶段） |
| 目标板 | ORBTrace mini（PCB 未开源） | 微相 A7-Lite（市售，约 ¥375） |

**原样复用、一行没改的部分**：Amaranth 写的 trace 解码核心
（`orbtrace/trace/*.py` — TPIUDemux / COBS / ChecksumAppender / SuperFramer）
和手写的 `verilog/traceIF.v` TPIU 组帧模块。移植是"叠加"而非"重写核心"，
所以上游对 trace 核心的改进随时还能 merge 进来。

---

## 项目状态

无硬件阶段已完成到 **第二阶段（OOC 综合与选板）**。经过三轮红蓝对抗评审
（r09 → r10 → r11）收敛，在关闭四个"下单前硬门"后判定 **可下单 35T**：

| 硬门 | 问题 | 结果 |
|------|------|------|
| HG-1 | trace 流水线是否真在 routed 网表里？ | ✅ 路径起点为 `u_sf/data_reg[*]` |
| HG-2 | BUFG 是否吃掉采样窗口？ | ✅ BUFR/BUFIO 宽 **1.34 ns** → 上板用它 |
| HG-3 | 可选的 RGMII-RX IDELAY 能否放下（跨 bank 第二个 IDELAYCTRL）？ | ✅ 两个 IDELAYCTRL 都能布局布线 |
| HG-4 | 35T 与 100T 在 FGG484 上引脚兼容吗？ | ✅ 40 个用脚 **0 处不一致** |

**实现后实测（xc7a35tfgg484-2）：** 2,320 LUT（11.15%）、11 BRAM（22%）、
WNS = +1.254 ns、WHS = +0.034 ns、TNS = THS = 0、DRC 0 错误。

真实硬件风险（眼图余量、PHY strap 配置、亚稳态 MTBF）已明确带入
**第三阶段（上板 PoC）**。

**第三阶段进展：** 板子已到货并完成首次点灯——2-LED blink bitstream
综合、JTAG 烧录、上板运行（`End of startup status: HIGH`），证明
PC → JTAG → FPGA 配置链路打通。过程中踩了两个纯环境坑（Linux `ftdi_sio`
抢占 FT232H、VMware EHCI USB 透传打不开 FTDI MPSSE 端点），完整记录见
**[`docs/artix7-port/stage3-bringup/01-board-bringup-troubleshooting.md`](docs/artix7-port/stage3-bringup/01-board-bringup-troubleshooting.md)**。
Bring-up 源码在 [`syn/artix7/bringup/`](syn/artix7/bringup/)。

**被测对象自验：** STM32F429（DISC1）的 ETM → TPIU → 4-bit 并行 trace 端口
已通过 ST-Link/OpenOCD 使能，并用示波器确认（TRACECLK + TRACED0..3 有数据）——
"被测对象会不会发 trace"这个问题在接 FPGA 之前就已坐实。完整寄存器序列和
踩坑（GPIO 必须手动切到 AF0 复用；要使能 ETM 而不只是 TPIU）见
**[`docs/artix7-port/stage3-bringup/02-stm32-etm-enable.md`](docs/artix7-port/stage3-bringup/02-stm32-etm-enable.md)**。

**千兆网口打通：** 板载 RGMII + RTL8211E 千兆以太网收发双向已通——FPGA 正常
应答 ARP，UDP 1234 端口环回端到端原样回显。修复关键是去掉 FPGA 端在 RX
（旁路 IDELAY）和 TX（`USE_CLK90="FALSE"`）两侧的双重延迟，因为 RTL8211E 的
strap 默认已经把自己的 RX/TX delay 打开了。完整调试过程（含走过的弯路）见
**[`docs/artix7-port/stage3-bringup/03-rgmii-net-link.md`](docs/artix7-port/stage3-bringup/03-rgmii-net-link.md)**。

**下一步（第四阶段）：** 三个孤岛验证完毕后，剩下的活是把它们连成一条流——
`trace 引脚 → traceIF → OrbFlow → UDP → Orbuculum`——端到端解出真实执行流。
计划按「可证伪的阶梯」组织（V0 数字回环 → V1 采样眼图 → V2 真实 ETM →
V3 Orbuculum → V4 升速/UDP 鲁棒性），见
**[`PLAN_STAGE4.md`](docs/artix7-port/PLAN_STAGE4.md)**。

完整计划与证据见 **[`docs/artix7-port/`](docs/artix7-port/)**
（[`PLAN.md`](docs/artix7-port/PLAN.md)、[`PLAN_STAGE2.md`](docs/artix7-port/PLAN_STAGE2.md)、
[`PLAN_STAGE4.md`](docs/artix7-port/PLAN_STAGE4.md)，
以及 `proposals/` 和 `reviews/` 目录）。

---

## 相对上游改了什么

改动高度集中——**只动了上游 2 个文件**，其余全是新增。

- **`verilog/traceIF.v`**（29 行）：修了两个在 Vivado/iverilog 下暴露的上游真 bug——
  端口表多余逗号 + 缺显式 `wire` 声明，以及**缺复位分支**（`FrAvail` 等寄存器
  在仿真里一直是 `X`，永远不产生帧就绪沿）。
- **`verilog/testbeds/traceIF_tb.v`**（5 行）：端口名对齐。
- **[`syn/`](syn/) 下全部是新增**：Artix-7 采样前端（`rtl/trace_capture_a7.v`）、
  集成顶层（`rtl/trace_probe_top.v`）、板级约束、OOC/实现 Tcl 流程、
  Amaranth→Verilog 导出脚本、仿真回归。
- **`syn/external/verilog-ethernet`** 是新增 submodule（Alex Forencich 的千兆栈），
  提供以太网出口。
- 新增测试（`tests/test_*.py`、`verilog/testbeds/*_tb.v`）与 CI 调整。

---

## 构建

### 上游 ORBTrace mini gateware

未改动——见 **[`README.upstream.md`](README.upstream.md)**。

### Artix-7 OOC 综合 / 实现（本 fork）

需要 Vivado（在 **2021.1** 上验证）。先 source 环境：

```bash
source /path/to/Xilinx/Vivado/2021.1/settings64.sh

# 全设计：综合 + 布局布线 + 资源/时序 + 流水线存活检查
vivado -mode batch -source syn/artix7/run_top_impl.tcl

# 可选：验证启用 RGMII-RX-IDELAY 的变体（HG-3）
PHY_RX_DELAY_INTERNAL=1 vivado -mode batch -source syn/artix7/run_top_impl.tcl

# BUFG vs BUFR/BUFIO 采样窗口对比（HG-2）
vivado -mode batch -source syn/artix7/run_capture_bufr.tcl

# 35T vs 100T 引脚兼容（HG-4）
vivado -mode batch -source syn/artix7/check_pincompat.tcl
```

### 仿真 / 回归

```bash
# 逻辑层单元测试（Amaranth）
python3 -m pytest tests/

# traceIF 物理层回归（iverilog）
iverilog -g2012 -o /tmp/tb verilog/traceIF.v verilog/testbeds/traceIF_tb.v && vvp /tmp/tb

# 双时钟 CDC 回归：frame128 trace_clk→clk100 + 溢出计数（iverilog）
./syn/artix7/sim/run_frame_cdc.sh

# Artix-7 采样前端端到端（Vivado xsim；iverilog 跑不了 unisims）
source /path/to/Vivado/2021.1/settings64.sh
./syn/artix7/sim/run_xsim.sh
```

---

## 目录结构（fork 新增部分）

```
syn/artix7/
  rtl/trace_capture_a7.v     7 系采样前端（IDDR+IDELAY，BUFG|BUFR_IO 可选）
  rtl/trace_probe_top.v      集成顶层（采样 + traceIF + AsyncFIFO + 千兆网）
  constraints/trace_probe.xdc A7-Lite 引脚 / 时钟 / 源同步 input delay
  export_trace_modules.py    Amaranth trace 核心 → Verilog 供 Vivado 综合
  run_*.tcl                  OOC / 全实现 / BUFR 研究 / 引脚兼容 流程
  sim/                       xsim 前端 + iverilog 双时钟 CDC 回归
syn/external/verilog-ethernet  千兆以太网栈（submodule）
docs/artix7-port/            计划、提案、红蓝评审（r01–r11）
```

---

## 致谢

本 fork 完全建立在 Vegard Storheil Eriksen 与 Dave Marples 的
[orbcode/orbtrace](https://github.com/orbcode/orbtrace) 之上，主机侧解码依赖
[Orbuculum](https://github.com/orbcode/orbuculum)，以太网路径使用
[alexforencich/verilog-ethernet](https://github.com/alexforencich/verilog-ethernet)。
请如上游作者所愿，尊重开源精神，把善意传递下去。

许可证：BSD-3-Clause（与上游一致）。
