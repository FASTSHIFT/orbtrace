# 提案 18：SWO 流式捕获 + 接入 orbuculum

> 目标：把当前"一次性抓满 BRAM → UDP 分页读出 → 离线解码"的 SWO 采集，升级为
> **连续流式捕获**，并直接喂给 `./orbuculum`（实时 mux/解码/分发），实现 ORBTrace
> 那样的实时 trace 体验（orbmortem 实时反汇编、orbtop 实时 profiling）。
>
> 一句话结论：**推荐"UDP 流式推送 + PC 端 udp2tcp 小桥 → orbuculum -s"** —— FPGA 侧改动
> 适中（复用现有 UDP/MMCM/SWO 前端，加一个主动推流的 UDP TX），PC 侧零 FPGA 风险，且
> orbuculum 原生支持 "SWO over TCP"。TCP 直接在 FPGA 实现代价过高（verilog-ethernet 无
> TCP 栈），不推荐。

---

## 1. orbuculum 的接入点（已查证）

orbuculum 支持十种采集源，其中两种对我们可用（README + `Src/orbuculum.c` 实测确认）：

| orbuculum 源 | 命令行 | 适配我们 |
|------|--------|---------|
| **SWO over TCP** | `orbuculum -s <host>:<port>` | ✅ 最自然：FPGA/桥当 TCP server 吐原始 SWO 字节 |
| 文件 | `orbuculum -f <file>` | 仅离线回放 |

关键参数（我们 SWO 场景必用）：
- `-T`：剥 TPIU framing（我们 formatter-on，ETM 在 stream 2）
- `-N`：保持 TPIU 锁定（稀疏 sync 源，正是 STM32 SWO，sidetrack §10.4 实测必加）
- `-t 2`：路由 ETM stream 2
- `-a <baud>`：仅用于占用率计算，不影响功能

下游：`orbuculum`（mux，:3402 orbflow / :3443+ legacy TCP per stream）→ `orbmortem -P ETM3.5
-e proj_add.axf`（实时反汇编）/ `orbtop`（实时热点）。**这条链 sidetrack 已用 CH343 串口源
实测跑通（~133 万指令/秒）**，我们只是把"串口源"换成"FPGA 网络源"。

**orbuculum 吃的就是原始 SWO 字节流**（UART 解码它自己做 / 或我们已解的 TPIU 帧字节）。
注意：orbuculum 的 SWO-over-TCP 期望的是 **NRZ bit 之上的字节流**，而我们 FPGA 已经做了
UART 解码（pulse→nrz→uart 出字节）。所以我们喂给 orbuculum 的应是 **已解出的 TPIU 帧字节**，
配 `-T` 让它剥 TPIU、`-t 2` 取 ETM —— 等价于我们现在 `etm35lib` 做的事，改由 orbuculum 实时做。

---

## 2. 现状与差距

| 环节 | 现状 | 流式需要 |
|------|------|---------|
| SWO 前端 | pulse→nrz→uart 出字节（cap_byte/cap_valid），clk200/clk250 域 | ✅ 不变，直接复用 |
| 缓冲 | one-shot 写满 96 KB BRAM 即停 | 改为**连续**：环形/直通，不停 |
| 出口 | UDP :5001 **请求-应答**分页读出（PC 发 base，FPGA 回 BRAM 段） | 改为 FPGA **主动连续推送** |
| 网络栈 | verilog-ethernet：UDP/IP/ARP，**无 TCP** | TCP 需自己实现（重）或 PC 端桥接 |
| 解码 | 离线 `etm35lib` | 改 orbuculum 实时（-T -N -t 2） |

**核心差距 = 出口从"被动应答"变"主动推流"，且 orbuculum 要 TCP 而我们只有 UDP。**

---

## 3. 三个候选方案

### 方案 A：FPGA 主动 UDP 推流 + PC 端 udp2tcp 桥（推荐）

```
SWO前端→字节 → 连续FIFO → FPGA 主动 UDP 发包(:5003) → 网络
   → PC: udp2tcp.py (收UDP, 开TCP server :5555) → orbuculum -s localhost:5555 -T -N -t 2
   → orbmortem / orbtop 实时
```

- **FPGA 改动（中等）**：
  1. SWO 字节进一个连续 FIFO（AsyncFIFO，跨 cap_clk→clk125），不再 one-shot。
  2. 新增**主动 UDP 发送器**：FIFO 攒够一包（如 1024 B）或超时，就发一个 UDP 包到固定
     PC IP:port。复用 verilog-ethernet 的 `udp_complete` TX 路径，但 TX 头要**自发**
     （现有 `fpga_core_net` 的 TX 头是 RX 触发的 echo，需改成定时器/FIFO-阈值触发，
     dest IP/MAC 用固定常量或一次 ARP）。
  3. 背压：FIFO 满则丢并置 overflow 标志（SWO 本就可 stall 节流，但流式下 PC/网络是新
     瓶颈，要有可观测的丢包计数）。
- **PC 改动（小、零 FPGA 风险）**：~30 行 `udp2tcp.py`：recvfrom UDP → 累积 → 任何 TCP
  client 连上就转发。orbuculum `-s` 连这个 TCP。
- **优点**：复用现有 UDP/IP/ARP 栈（已验证）；TCP 复杂度全在 PC（可丢可重启）；FPGA 只加
  一个"自发 UDP TX"，是现有 echo TX 的小变体。
- **缺点**：UDP 无重传，丢包靠 overflow 计数观测（但 SWO+stall 下码率远低于千兆，实测
  56M SWO = 7 MB/s << 千兆，丢包概率低）；多一跳 PC 桥（本机 localhost，延迟可忽略）。

### 方案 B：FPGA 直接实现 TCP server（不推荐）

orbuculum `-s` 直连 FPGA。**但 verilog-ethernet 没有 TCP 栈**，要自己实现
握手/重传/窗口/重排 —— 在 FPGA 上是数千行、数周工作量、且易错。**性价比极低，否决。**

### 方案 C：保持 UDP 应答式，PC 高频轮询拼流（过渡/最省）

PC 端循环 `swo_dump_banked --rearm` 拼接成长流喂 orbuculum -f（或管道）。
- **优点**：FPGA 零改动。
- **缺点**：每次 re-arm 清零、有间隙，**不是真流式**（§之前实测：21M 下 re-arm 间隙会漏
  sync）；不能实时连续。仅作 A 落地前的临时验证。

---

## 4. 推荐：方案 A，分阶段落地

### 阶段 1：PC 桥 + 现有 UDP（验证 orbuculum 链路，零 FPGA 改动）
- 写 `udp2tcp.py`，先用方案 C 的轮询 UDP 数据喂它 → orbuculum → orbmortem，**验证
  orbuculum 能实时解我们的字节流**（-T -N -t 2 + proj_add.axf）。这步把"orbuculum 接入"
  和"FPGA 流式"解耦，先确认下游通。

### 阶段 2：FPGA 连续 FIFO + 自发 UDP 推流（真流式）
- `swo_stream_top` 加连续 AsyncFIFO（cap_clk→clk125）替代 one-shot BRAM。
- `fpga_core_net` 加自发 UDP TX：FIFO 阈值/定时触发，固定 dest（PC IP:5555），复用
  TX FIFO + udp_complete。保留现有 :5001 应答口作调试。
- overflow 计数寄存器（:5001 状态区或 CSR 读回），量化丢包。

### 阶段 3：实测对接
- `orbuculum -s localhost:5555 -T -N -t 2 -a 2000000`
- `orbmortem -s localhost:3402 -P ETM3.5 -e ./proj_add.axf -t 2` → 看 'Capturing' + KIps
- 与离线 `etm35lib` 解码逐函数对拍（proj_add 已知 PC：0x08000f8c add / fae loop_sum）。

---

## 4b. 地基实测验证（r19 Q1 — 已通过 ✅）

红方 r19 Q1 质疑"orbuculum 能吃我们的字节格式"是未验证的对冲假设，可能 OFLOW 自动判别
导致裸 TPIU 字节全 COBS error。**按 r19 建议用零 FPGA、干净数据钉死了这条地基：**

实验（`decode/feed_tcp.py` + `decode/probe_orbuculum_out.py`）：
1. 拿一段 etm35lib 已验证 0.535% / 93 锚点的干净 UART-decoded TPIU 字节流（`/tmp/raw.bin`，
   含 5 个 TPIU full-sync）。
2. `feed_tcp.py` 当 TCP server（:5555）循环吐这段字节。
3. `orbuculum -s localhost:5555 -T -N -t 2` 连它。
4. `probe_orbuculum_out.py` 连 orbuculum 的 legacy tag-2 口 :3443，抓它**剥 TPIU 后转发**
   的字节，用 etm35lib 验证。

**结果**：
- orbuculum 收下字节，**进 legacy 模式**（不是 OFLOW），日志 "Will decode tag 2, exported
  Legacy interface on port 3443"、持续 "RXED Packet"、**无 COBS/OFLOW error**。
- 从 :3443 抓到 335 KB，etm35lib 解出 **308 个 flash 锚点，PC 全是 proj_add 真实地址**
  （0x8000fae loop_sum / 0x8000f8c add / 0x8000f96 setup / 0x8000fc0）。

**结论**：地基成立。`orbuculum -s` 网络源**接受我们 UART-decoded 的 TPIU formatter 字节**，
`-T -N -t 2` 正确剥 TPIU + 路由 ETM stream 2。r19 Q1 担心的"OFLOW 判别拦路"未发生。
§1 之前的"/或"对冲假设现已坐实为：**legacy 模式 + -T 吃裸 TPIU 字节**。剩余风险（自发 TX
复杂度 Q2、丢包 Q3）不影响地基，按 r19 顺序在阶段 2 前单独处理。

---

## 5. 带宽与背压（诚实评估）

| baud | SWO 字节率 | vs 千兆 | vs orbuculum |
|------|-----------|--------|-------------|
| 2M | 0.2 MB/s | 0.16% | 轻松 |
| 21M | 2.1 MB/s | 1.7% | 轻松 |
| 56M（本机上限） | 5.6 MB/s | 4.5% | sidetrack 实测 orbmortem ~133万指令/s 时 ~0.6MB/s，余量足 |

- **网络不是瓶颈**：千兆 125 MB/s，56M SWO 才 5.6 MB/s。
- **真瓶颈在 stall**（SWO 本质）：CPU 被 trace 拖慢，码率自然受限，FIFO 不易满。
- **新风险点**：PC 端 orbuculum/udp2tcp 处理速度 + UDP 丢包。用 overflow 计数 + orbuculum
  占用率监控。丢包不致命（trace 本就允许 unknown%，且我们有重锁 walk）。

---

## 6. 工作量与风险

| 项 | 工作量 | 风险 |
|----|--------|------|
| 阶段1 udp2tcp.py + orbuculum 链路验证 | 小（~30 行 + 调参） | 低 |
| 阶段2 连续 FIFO | 中（AsyncFIFO + 替换 one-shot） | 中（CDC 要对） |
| 阶段2 自发 UDP TX | 中（改 echo TX 为自发触发 + 固定 dest/ARP） | 中（TX 头时序） |
| 阶段3 实测对拍 | 小 | 低 |

**最大风险**：自发 UDP TX（现有 TX 是 RX-echo 触发，改自发要正确生成 UDP 头 + dest MAC
（ARP 或硬编码）+ 不破坏现有 :5001/:5002）。建议先在仿真/网络回归里验 TX 自发，再上板。

---

## 7. 结论

- **推荐方案 A**（UDP 推流 + PC udp2tcp 桥 → orbuculum -s），分 3 阶段。
- **先做阶段 1**（零 FPGA 风险）验证 orbuculum 能实时解我们的字节——这步成本最低、解耦
  下游，且能立刻看到 orbmortem 实时反汇编（项目里程碑式的体验提升）。
- TCP 直实现（方案 B）否决：verilog-ethernet 无 TCP，代价远超收益。
- 方案 C 仅作阶段1的临时数据源，不是终态。

> 落地顺序：udp2tcp.py + orbuculum 链路（阶段1）→ 连续 FIFO + 自发 UDP TX（阶段2）→
> 实时对拍（阶段3）。每阶段独立可验，风险隔离。
