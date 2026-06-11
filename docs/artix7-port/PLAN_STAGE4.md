# Orbtrace Artix-7 移植 · 第四阶段计划书（trace 数据通路端到端打通）

> 前置：第三阶段（上板 bring-up）已完成三道单元门——JTAG 点灯、STM32 ETM 自验（示波器确认 4-bit trace 出数据）、千兆网口 RGMII 链路（UDP 双向环回实测通过）。见 `stage3-bringup/`。
> 本阶段目标：**把三个已验证的孤岛连成一条链——`trace 引脚 → traceIF 采样/解帧 → OrbFlow/COBS 组帧 → UDP 出口 → PC Orbuculum 解码`——并端到端解出真实执行流。**
> 关键原则：**每一关只引入一个新的未知量**，每一关都有「已知输入 → 可观测输出 → 可证伪判据」。先摘数字段与工具链（仿真已覆盖、硬件没跑过），把物理命门单独拎出来用眼图判收，最后才放真实不可控输入进来。

---

## 0. 为什么这是一个独立 stage

```mermaid
graph LR
    S1[S1 仿真<br/>逻辑正确性 ✅] --> S2[S2 OOC综合<br/>资源/时序 ✅]
    S2 --> S3[S3 上板bring-up<br/>三个单元门 ✅]
    S3 --> S4[S4 数据通路端到端<br/>本阶段]
    S4 --> S5[S5 满速PoC<br/>命门收口]

    style S3 fill:#d6ffd6
    style S4 fill:#fff3cd
    style S5 fill:#ffd6d6
```

S3 验证的是**单元能力**（能烧、能配 ETM、网口能通），但三者各自孤立。S4 是第一次把它们**串成数据流**，它有自己独立的命门：

- **物理采样**：源同步采样相位、IDELAY 校准、眼图余量——这是红蓝博弈一贯认定的真命门，仿真不背书（见 `PLAN.md` §4 边界声明）。
- **UDP 鲁棒性**：丢包 / 乱序到底有多严重，要不要重传——之前一直是悬而未决的设计问题。
- **Orbuculum 真集成**：`PLAN.md` 的 S6 明确把「编译 C 上位机 + 网络源实时 ingest」**留到有真实数据流的硬件阶段**，就是现在。

所以它不是 S3 的延续，是一个新阶段。

---

## 1. 现状盘点

### 已验证的三个孤岛

| 孤岛 | 证据 | 文档 |
|------|------|------|
| STM32 ETM 发 4-bit trace | 示波器确认 TRACECLK + TRACED0..3 出数据 | `stage3-bringup/02-stm32-etm-enable.md` |
| FPGA RGMII ↔ PC UDP 链路 | `.42` UDP 1234 环回原样回显，因果开关实验闭环 | `stage3-bringup/03-rgmii-net-link.md` |
| trace 解帧/解码**逻辑** | `pytest tests/` 11 passed，真实 ITM TPIU 帧位级解出 | `PLAN.md` S1–S6 |

### 中间未验证的链（本阶段要打通）

```mermaid
graph LR
    PIN[trace 引脚<br/>双沿采样] --> TIF[traceIF<br/>128bit 帧组装]
    TIF --> CDC[AsyncFIFO<br/>trace域→sys域]
    CDC --> DMX[TPIUDemux→COBS→OrbFlow]
    DMX --> UDP[UDP 出口<br/>verilog-ethernet]
    UDP --> PC[PC Orbuculum<br/>解码执行流]

    style PIN fill:#ffd6d6
    style UDP fill:#d6ffd6
    style PC fill:#fff3cd
```

红色=物理命门（没在硬件上跑过），绿色=已验证（net_test），黄色=工具链待集成。

### 可复用资产

- **net_test 网络顶层**：已验证的 RGMII + UDP 出口（`syn/artix7/bringup/`），可作为出口骨架。
- **traceIF.v / trace/*.py**：解帧/组帧 RTL + Amaranth 逻辑，仿真已绿。
- **etm_enable.cfg**：STM32 ETM 使能序列，trace_clk 可调。
- **deskew 方案**：`proposals/12-deskew方案选型.md` 已定「FPGA 出原始采样 + PC 端扫 tap 算眼心」。

---

## 2. 验证阶梯（任务分解）

```mermaid
graph TD
    V0[V0 数字回环<br/>golden帧→UDP→PC] --> V1[V1 物理采样回环<br/>已知pattern绕板一圈]
    V1 --> V2[V2 接真实STM32 ETM<br/>低速]
    V2 --> V3[V3 Orbuculum 真集成]
    V3 --> V4[V4 升速逼命门<br/>+UDP鲁棒性]
    V4 --> GATE{端到端解出<br/>正确执行流?}
    GATE --> DONE[阶段完成]

    V0 -.可提前并行.-> V3
    style V0 fill:#e6f0ff
    style V1 fill:#ffd6d6
    style V4 fill:#ffd6d6
    style GATE fill:#fff3cd
    style DONE fill:#d6ffd6
```

阶梯顺序刻意为：**先摘数字段（V0）和工具链（V3 可提前），把物理命门（V1/V4）单独拎出来眼图判收，最后才让真实不可控输入（V2）进来。** 任何一关挂了，未知量唯一。

### V0 · 数字回环（不接 STM32，纯 FPGA 自产自销）✅
- **输入**：FPGA 内部一个 **golden TPIU 帧发生器**（常量 ROM：同步字 `0xFFFF_FFFF`/`0x7FFF_FFFF` + 已知 ITM 包），直接喂进 traceIF 下游，**绕过物理采样**。
- **出口**：走已验证的 UDP 把帧发到 PC。
- **判据**：PC 收到的字节 == 塞进去的 golden（逐字节）。
- **目的**：验证「组帧 → UDP 出口」这条 RTL 在真硅片上字节无误，把这段从未知里摘掉。纯数字，最稳，**为后面所有阶段打地基**。
- [x] golden 帧发生器 RTL + 接入 net_test 出口（端口 5000；端口 1234 echo 保留为网络回归）
- [x] PC 端收包比对脚本（golden 对拍，`v0_golden_check.py`）
- [x] **实测通过**：len 8/32/64/100/128/200，128B×500 迭代 0 mismatch / 0 lost；过程中 V0 抓到一个真实位置计数 bug（sync 前缀每 32B 重复）并修复。详见 `stage4-datapath/01-v0-golden-egress.md`

### V1 · 物理采样回环（自发自收，验时序不验内容）
- **输入**：不依赖 STM32——FPGA 自己用 IO 发已知 pattern 绕板一圈接回 trace 输入引脚（或用 STM32 GPIO toggle 已知慢速方波，配置已会）。
- **出口**：traceIF 解出的 word + **bad-sync 计数器**从 UDP 读出。
- **判据**：扫 IDELAY tap 0–31 × 4 lane，每点测「解出 == 已知 pattern」正确率，画眼图，找眼心，定最佳 tap。
- **目的**：把 deskew 方案（`proposals/12`）落地第一步，产出最佳 tap。**这是真命门的第一次正面接触**，低速先做。
- [ ] IDELAYE2 + tap 写入通道（VIO 或 UDP→CSR）
- [ ] PC 端眼图扫描脚本（tap × 正确率）
- [ ] 产出每 lane 眼心 tap

### V2 · 接真实 STM32 ETM（低速）
- **输入**：STM32 ETM 配**低 trace_clk**，跑可控执行流（如空 while 里 toggle 变量）。
- **出口**：TPIUDemux 解出的 payload 走 UDP；`trace_lost_cnt`（stage2 已规划，对标 Orbuculum `Monitor.lost`）一起带出。
- **判据**：① sync 建立稳定（isREsync 稳）② lost_cnt == 0 ③ PC 拿到的 ITM 包对得上已知程序行为。
- **前置**：V0/V1 必须先绿（这一阶第一次有真实不可控输入）。
- [ ] traceIF 采样前端接真实 trace 引脚（V1 的 tap 落地）
- [ ] trace_lost_cnt 接入 OrbFlow 并从 UDP 暴露
- [ ] 低速端到端解出可控 payload

### V3 · PC 端 Orbuculum 真集成（可与 V0/V1 并行）
- **背景**：`PLAN.md` S6 把 orbuculum（meson + libusb 的 C 项目）的完整集成明确留到本阶段，避免早期引入重依赖。
- **判据**：Orbuculum 从 UDP/网络源实时 ingest，解出**正确的函数跳转 / PC 流**，和 STM32 实际跑的代码对得上。
- [ ] 编译 orbuculum（meson + libusb）
- [ ] 接 UDP/网络源，解 OrbFlow over 网络
- [ ] 与 STM32 已知程序行为对拍

### V4 · 升速逼满速命门 + UDP 鲁棒性
- **升速**：逐步抬 trace_clk 到目标速率，看 V1 眼图余量、lost_cnt、UDP 丢包/乱序随速率的退化曲线。
- **UDP 鲁棒性**（回应「UDP 怎么防丢包/乱序」）：先**加 seq number 进 OrbFlow 帧**，PC 端统计丢失/乱序率，**用数据说话**该不该上重传 / FEC，而不是拍脑袋提前做。
- **判据**：在某个可量化的 trace_clk 上限内，lost_cnt==0 且 PC 解码无错；超过则记录退化点作为工具能力边界。
- [ ] OrbFlow 帧加 seq number
- [ ] PC 端丢包/乱序统计
- [ ] 升速退化曲线 + 工具能力边界数字

---

## 3. 贯穿手段：让 2-LED 板子「可观测」

板上只有 2 个用户可控 LED（M18/N18），所以可观测性要靠别的：

| 手段 | 用途 | 阶段 |
|------|------|------|
| **UDP status 端口** | `lost_cnt / bad_sync_cnt / 当前tap / sync状态` 做成可 query 的 UDP 端口（类比现 1234 echo） | 全程基础设施 |
| **VIO** | 在线改 IDELAY tap / 复位，不重综合 | V1 调相位 |
| **ILA** | 抓 RGMII / trace 波形、AXIS 流 | V1/V2 调试 |
| **LED 频率编码** | 慢闪=好/快闪=坏/灭=没发生，一眼区分 | 全程粗状态 |
| **CH340 串口** | 右边 Type-C，print 调试 / 触发 | 备用 |

**每一阶一个独立最小 bitstream**（像 net_test 一样），不一上来就全集成。

---

## 4. 完成判据

| 编号 | 判据 | 手段 |
|------|------|------|
| W-0 | golden 帧经 FPGA RTL → UDP → PC，逐字节一致 | V0 对拍脚本 |
| W-1 | IDELAY tap 扫描出每 lane 眼心，眼图窗口 ≥ 目标 UI | V1 眼图脚本 |
| W-2 | 低速真实 ETM：sync 稳、lost_cnt==0、payload 对得上 | V2 端到端 |
| W-3 | Orbuculum 实时解出正确函数跳转流 | V3 与 golden 程序对拍 |
| W-4 | 给出可量化的 trace_clk 无损上限 + UDP 丢包率曲线 | V4 升速测试 |

**只有 W-0~W-4 全绿，才算 trace 工具端到端 PoC 成立。** 其中 W-1/W-4 是平台命门，必须用眼图 / 实测数字判收，仿真绿不为其背书。

---

## 5. 明确边界（防误读）

```mermaid
graph TD
    S4[本阶段验证] --> YES[✅ 验证: 端到端字节正确<br/>低速采样眼图<br/>真实ETM解码<br/>UDP丢包实测]
    S4 --> NO[❌ 不保证: 任意满速无损<br/>—— 只在可量化trace_clk上限内]
    NO --> EDGE[工具能力边界=实测上限<br/>超限的退化如实记录]
    style YES fill:#d6ffd6
    style NO fill:#ffd6d6
    style EDGE fill:#fff3cd
```

- 工具的承诺不是「任意满速无损」，而是「在实测可量化的 trace_clk 上限内无损」（沿用 r04/r09 一贯定义）。
- V4 的产出是**一条退化曲线 + 一个边界数字**，不是「无限带宽」。

---

## 6. 工作流约定（沿用）

- 分支 `artix7-port`；提交 Conventional Commits，body 详述改动 + 验证。
- 每一阶 bitstream 综合后跑 DRC，RTL 改动跑 `pytest tests/` + iverilog 回归。
- 物理命门（V1/V4）结论必须附实测数据（眼图 / tap 表 / 丢包率），不靠估算。
- 文档：本阶段调试踩坑续写到 `stage3-bringup/`（或视量另起 `stage4-datapath/`），方案/评审归 `proposals/`、`reviews/`。

---

## 7. 建议起步

**先做 V0**——它复用已验证的 UDP 出口，只加一个 golden 帧发生器，风险最低，又能立刻验证「组帧 RTL 在真硅片上对不对」，为后续所有阶段打地基。V3（编 Orbuculum）不依赖硬件，可并行提前启动。
