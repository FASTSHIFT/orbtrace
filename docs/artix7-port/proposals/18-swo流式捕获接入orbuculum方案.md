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
  占用率监控。

### 5b. 丢包压测（r19 Q3 — 已实测，结论比预期乐观 ✅）

r19 Q3 担心"实时丢包不可重读 + 高 baud sync 稀疏 → 丢一包长时间失锁丢大段"。
按 r19 建议做了零 FPGA 压测（`decode/swo_losstest.py` / `swo_losstest_sparse.py`）：把干净
TPIU 流按概率删 1 KB 块（模拟丢 UDP 包），喂 `orbuculum -s -T -N -t 2`，量化 :3443 输出锚点。

| 场景 | 0% 丢包锚点 | 10% 丢包锚点 | 退化 |
|------|------------|-------------|------|
| sync 密（30 个/流） | 40288 | 36259 | **-10%（=丢包率，线性）** |
| sync 稀疏（4 个） | 18010 | 16430 | **-9%** |
| sync 极稀疏（1 个） | 18010 | 16272 | **-10%** |
| sync 密、20% 丢包 | 6713 | 4890 | -27%（≈丢包率，线性） |

**两个结论**：
1. **丢包退化始终线性 ≈ 丢包率，无雪崩失锁** —— 即使全流只 1 个 full-sync，10% 丢包也只掉
   10% 锚点。**r19 Q3 的"丢包→长时间失锁"未发生**：orbuculum 的 `-N keep-sync` 锁定后靠
   **每帧 HSYNC（ff 7f）维持帧对齐**，丢包后下一个 HSYNC 即续上，不必等稀疏的 full-sync。
2. **稀疏 sync 本身砍半锚点**（密 40288 → 稀 18010）—— 但这是已知的 sync 密度问题（高 baud
   现象），与丢包正交，不是丢包引入。

**对 FPGA 设计的影响**：**不需要可靠传输（TCP/重传）**。UDP 丢包代价 = 线性损失 ≈ 丢包率，
而千兆下 56M SWO 仅占 4.5% 带宽，实际丢包率应 <<1%。方案 A 的 UDP 推流足够，只需 overflow
计数可观测。这把"自发 UDP TX"的设计大大简化（无需 ARQ/序号/重传）。

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

---

## 8. 上板实测：live bridge 路径打通（✅ 已实现 — 重启后复现）

r20 的 STREAM=0 判别实验把自发 TX 零包根因钉到了 **FSM/header（B/C），不是 link（A）**
（见 §9）。在自发 TX 修复之前，按 r19/r20 一致推荐的**更稳路径**先把用户目标
（"流式捕获接入 ./orbuculum"）**真正落地**了——零 FPGA 改动，复用已知网络正常的
`swo_stream.bit`：

**`scripts/swo_live_bridge.py`**：PC 端 TCP server（:5555）。orbuculum 连上后循环
`re-arm → 等 full → 分 bank 读出 → sendall`，把一次性 BRAM 捕获拼成**连续字节流**。
re-arm 之间有小间隙，但 §5b 丢包压测已证 orbuculum `-N` keep-sync 靠每帧 HSYNC 平滑越过
间隙（退化线性、无雪崩），所以这条在**未改 FPGA**的前提下就能实时解。

```
Terminal A: python3 scripts/swo_live_bridge.py --ip 192.168.10.42 --port 5555 --bitlen 200
Terminal B: orbuculum -s localhost:5555 -T -N -t 2
Terminal C: orbcat -s localhost:3402 -T -t 2   (或 orbtop / orbmortem)
```

**实测结果（设备重启 → 重烧 swo_stream.bit + 重配 ETM 2M dense-sync 后）**：
- live bridge 连续推流 **~100 KB/s**，每次捕获 90624 B，含 **4–5 个 TPIU full-sync**，
  gen 单调递增（确认每次都是 fresh capture）。
- 从 orbuculum legacy :3443 抓到 309 KB，etm35lib 解出 **298 个 flash 锚点，全是 proj_add
  真实 PC**（0x8000fae loop_sum / 0x8000fc0 / 0x8000f96 setup / 0x8000f8c add / TIM handlers）。
- orbflow :3402 与 legacy :3443 同时 listening；`orbcat -s localhost:3402` 收到 live 数据
  （标准 orbuculum 客户端路径打通）。

**结论**：**方案 A 的"实时接入 orbuculum"目标已用 PC-poll bridge 达成**，无需先攻克自发 TX。
自发 TX（§9 的 FSM/header bug）是"FPGA 主动推流"的优化项，可在主线（并口 SI / SWO baud）
之后再修；它不再阻塞"流式接入 orbuculum"这个用户目标。

## 8b. 实时工具链深化：reframe 让 orbuculum 原生锁定（✅ 已实现）

§8 的 live bridge 直推原始拼接 TPIU 流时，**orbuculum 自带 TPIU decoder 锁不住**——
verbose 日志刷 `No handler for tag N`（tag 分布散乱：27/14/64...），因为我们的 sync 太稀疏
（每 90KB 才 4–5 个 full-sync）且多个一次性 capture 拼接破坏 16 字节帧对齐。orbuculum 的标准
TPIU 解帧没有我们 etm35lib 的自适应重锁能力。

**解法（不造轮子，复用已验证工具）**：bridge 加 `--reframe` 模式：
1. 用 `etm35lib.tpiu_deframe_walk(want_stream=2)` 自适应重锁去帧 → 纯 ETM stream 2 字节；
2. 用 `etm_to_tpiu.reframe()` 重新封装成**标准 TPIU 帧（16 字节对齐 + 每 16 帧一个 FSYNC）**；
3. 喂 `orbuculum -s ... -T -N -t 2`。

**实测（实时链路，FPGA→bridge→orbuculum）**：
- orbuculum **0 个 `No handler`**（之前是数万个）→ TPIU **原生锁定**，按 tag 2 路由。
- legacy :3443 实时持续解出真实 PC（连续多轮 307 / 321 / 224 锚点，全 proj_add）。
- `--deframe`（只去帧不重封装，喂 orbuculum 不带 `-T`）也能让 0 no-handler，但 reframe
  版让 orbuculum 走完整 TPIU→tag 路由，更接近原生用法。

bridge 三种模式：默认（原始 TPIU，orbuculum 锁不住，仅 etm35lib 旁路能解）；`--deframe`
（纯 ETM）；`--reframe`（重封装 TPIU，orbuculum 原生锁）。**推荐 `--reframe`。**

## 8c. orbmortem 实时反汇编：卡在 orbuculum OFLOW 输出缺陷（⚠️ 受阻，已定位）

实时反汇编 orbmortem **只支持从 OFLOW :3402 取 tag**（源码 `orbmortem.c` 第 467-469：
`PROT_ETM` 直连 legacy 的分支 `return false`，未实现）。所以必须让 OFLOW :3402 的 tag 2
有合法数据。

reframe 让 orbuculum 锁定后，OFLOW :3402 **裸 socket 能收到字节**（channel header = 2，
确认 tag 路由对），但：
- 抓到的字节流 **没有任何 COBS 0x00 帧分隔符**（开头 `25 02 a8 37...`），**不是合法 OFLOW
  COBS 帧**。
- orbmortem 连上、配置正确（日志 "Decoding OFLOW with ETM in stream 2"），但**永远 "Waiting"**，
  verbose 无 RXED——它的 OFLOW 解析器认不出这些非 COBS 字节。

**定位**：这个 orbuculum 版本（`3de6b9b-dirty`）在 **`-T` legacy → OFLOW 重编码路径
（`_purgeBlock` createOFLOW 分支 / `OFLOWEncode`）上输出的不是合法 COBS 帧**，导致下游 OFLOW
客户端（orbmortem/orbtop）收不到可解帧。这是 **orbuculum 自身在该模式的缺陷**，不是我们链路
的问题——我们的 ETM 数据本身正确（legacy :3443 旁路实时解出真实 PC 已证）。

**下一步选项（待定方向，停下讨论）**：
1. **换/升级 orbuculum**：拉上游最新版，看 OFLOW 重编码是否修了；或用原生 OFLOW 源（不走
   `-T` legacy）。
2. **bridge 直接产 OFLOW**：PC 端用 COBS+OFLOW（带 `%%ORBFLOW1.0.0%%` 签名）把去帧后的纯
   ETM 封成 tag 2，当 OFLOW 源喂 orbuculum（绕开有缺陷的 `-T`→OFLOW 重编码）。中等工作量。
3. **接受现状**：实时"解出真实 PC 流"已达成（legacy :3443），orbtop/orbmortem 的 TUI 实时
   呈现作为后续 nice-to-have；离线 orbmortem/Perfetto 已能给完整反汇编+调用栈。
4. **orbtop 对 ETM 本就弱**：orbtop 基于 ITM PC-sampling，对纯 ETM 指令流支持有限，即使
   OFLOW 修好也未必出热点——实时反汇编应以 orbmortem 为主。

## 9. 自发 UDP TX 零包：STREAM=0 判别实验结论（r20 闭环）

r20 指定的单一 next action：把 `selftx_test_top` 设 STREAM=0（摘掉自发 TX FSM，选
`fpga_core_net` 的 `g_echo_only` 纯 RX echo），重综合后只测 :5001/:1234 echo，干净区分
根因 A（新顶层 link 没起）vs B/C（FSM/header）。

- 为此给 `selftx_test_top` 加了 `STREAM` 参数（默认 1），`run_selftx.tcl` 认 `STREAM` 环境
  变量。STREAM=0 重综合 → 烧板 → `decode/echo_probe.py` 测 :1234 loopback。
- **板上结果：echo 5/5 全回**（64B 原样返回）。
- **判定：根因 A（link/时钟/复位/RGMII 没起）排除**——新顶层 `selftx_test_top` 的
  link/RGMII/复位完全健康。零包 bug 在**自发 TX FSM / header mux（B/C）**，由排除法确认。

**已板上验证的事实（只列这些）**：
1. STREAM=0（无自发 FSM，纯 echo）→ :1234 echo 5/5 → **link 健康**。
2. STREAM=1（自发 FSM）→ 零包（含零 ARP，前次实测）。
3. ∴ bug 在 `g_stream` FSM/header 路径，**不在 link**。

**待查候选（推测，未钉死，留主线后处理）**：`udp_complete` 的
`UDP_CHECKSUM_GEN_ENABLE=1` 是 **store-and-forward checksum**——它先收 header、再吸完整包
payload（STATE_SUM_PAYLOAD），最后才把 header 下传触发 ARP。我的 FSM 顺序（ST_HDR 等
hdr_ready → ST_SEND 发 payload）在纸面上与之相容（header 会先被接受、payload 随后流入），
所以"FSM 与 checksum 互等"的死锁**经复查并不成立**——不要把它当成已确认根因。零 ARP 的真正
机制仍需**在板上**用 ILA / tcpdump 抓 `tx_udp_hdr_valid`/`tx_udp_hdr_ready`/payload 握手
钉死，而不是再做代码审查。修复前必须先有这个板上证据。这条整体排在主线（并口 SI / SWO
baud）之后；**且它已不阻塞"流式接入 orbuculum"**（§8 的 live bridge 已达成用户目标）。
