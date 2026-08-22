# 20 — 采集误码率：Part A 纯 RTL 仿真（离线，iverilog）

> **问题起点**：真实 ETM 数据解码盲区率 63%（cm100 slice，doc 附 §），但之前 ramp
> 压测说"物理链路零丢包"。用户质疑：ramp 压测和 TPIU AA/55 压测到底测了什么？为什么
> 一上真实数据就坏？要求**用单测证明采集误码率**，别再拿"传输零丢包"当"链路没问题"。

**结论（Part A）**：**数字 CDC 采集架构本身在理想信号下误码率 = 0%**（跨 12–198 MHz
TRACECLK、跨相位、异步独立时钟拍频，稳态坏字节 = 0，仅 2 字节固定上电瞬态）。
误码只在**注入 per-bit skew（模拟 SI/走线偏斜）且特定相位**时出现。这把"坏包"来源从
"数字架构 bug"收窄到"模拟层（IDDR setup/hold、走线 skew、SI、duty 失真）"——但 Part A
用的是**行为级 IDDR + 理想数据**，**证不了真实模拟采样的误码率**，那要 Part B 上板。

---

## 1. 先厘清：三种"压测"各测链路的哪一段（RTL 实锤）

真实 ETM 通路：

```
STM32 TPIU 引脚 ─▶ [IDDR 采样 + 相位/眼图/SI] ─▶ cap_byte ─▶ 异步FIFO ─▶ 打包 ─▶ UDP ─▶ PC
                  └────────── 模拟采样层 ──────────┘└──────────── 数字传输层 ────────────┘
                        坏包在这一层产生                    ramp 压测覆盖这一层
```

| 压测 | 注入点（RTL） | 覆盖 | **不覆盖** |
|---|---|---|---|
| **ramp**（CSR 0x09 `STREAM_SELFTEST`）| `src_data = selftest_active ? bw_cnt : cap_byte`（clk200 计数器，**cap_byte 之后**）| FIFO→打包→UDP→网卡→内核 **传输层** | **整个模拟采样层 + IDDR CDC** |
| **TPIU AA/55**（CURTPM 0x00020004）| 真实引脚，走 IDDR | 引脚+IDDR（但低频方波、眼极宽）| 高熵真实流的 SI/skew/相位抖动（坑点 17）|
| **RTL 仿真**（本文 Part A）| 行为级 IDDR 输入 | **数字 CDC 架构**（tclk_byte/tgl 跨时钟）| 真实模拟采样（setup/hold、duty、SI）|

**关键澄清（纠正之前的过度断言）**：ramp 压测"573MB 零丢零错"是**真的**，但它证的是
**传输层**零丢包，**从 RTL 注入点看就是从 `cap_byte` 之后开始的**（`trace_stream_top.v`
`g_stream`：`selftest_active` 时 `src_data=bw_cnt`，完全 bypass `trace_capture_a7`）。
把"传输层零丢包"讲成"物理链路没问题"是错的——采样层从没被 ramp 覆盖过。

---

## 2. Part A 实测（`sim/`，iverilog 12.0，全部离线）

### 2.1 纯数字 CDC，理想信号，扫 TRACECLK（`tb_iddr_cdc_sweep`，SKEW=0）

行为级 IDDR、理想 50% duty、干净 walking-1s 数据、零注入 skew：

| TRACECLK | 12M | 48M | 75M | 100M | 125M | 150M | 198M |
|---|---|---|---|---|---|---|---|
| 坏字节率 | 0% | 0% | 0% | **0%** | 0% | 0% | 0% |

**数字 CDC 架构在所有频率零误码。** 100M（=ref/2，toggle-CDC 理论最恶点）也 0%。

### 2.2 异步独立时钟拍频（`tb_iddr_cdc_async`，无注入 skew）

trace_clk 与 ref_200m 当独立振荡器（连续相位漂移），98–102 MHz、多相位、
run 10–160 µs：

- 稳态坏字节 **= 0**；报告的 2 个坏字节是**固定上电瞬态**（run 拉长坏率 0.20%→0.05%→
  0.01%→…，绝对数恒为 2）。
- 结论：**异步拍频本身不产生稳态误码**（早期怀疑的 toggle-CDC undersample 在
  behavioural 模型下不炸）。

### 2.3 相位扫描（`tb_iddr_cdc_phase`，edge-aligned 真实数据，100M）

PH0 = 0…4500 ps 全扫：**恒 2 坏字节（上电瞬态），0% 稳态**。

### 2.4 注入 per-bit skew（`tb_iddr_cdc_sweep`，SKEW>0）= SI/skew 代理

- **100M 固定相位**：SKEW 0→500 ps 全 **0%**（该相位对 skew 免疫）。
- **跨频固定相位 SKEW=300 ps**：12M 32% / 48M 17% / 75M 33% / **100M 0%** / 125M 20% /
  150M 4% / 198M 17%——**skew×频率×相位交互**才撕裂，且强烈相位相关。

**误码只在"注入走线偏斜 + 特定相位"下出现**，无 skew 时任何频率/相位都 0%。这与坑点 17
"半-nibble 字节边界错位"、坑点 21"相位整体偏一字节"自洽——那些是模拟/相位现象，不是
数字架构。

---

## 3. 诚实边界（Part A 证不了什么）

- 所有 tb 的 IDDR 是**行为级理想采样器**（`always @(posedge/negedge)` 直接锁 data），
  **没有真实 flip-flop 的 setup/hold 窗口、亚稳态、时钟 duty 失真、引脚 SI**。
- 所以 Part A 只能断言 **"数字 CDC 架构在理想输入下零误码"**，把真凶从"数字 bug"排除。
- **真实采集误码率必须 Part B 上板测**：已知图案走**真实引脚 + 真实 IDDR + 真实
  TRACECLK**，主机逐字节比对。见 §4。

---

## 4. Part B 设计（上板，需连设备，下一步）

**目的**：量真实模拟采样层的误码率，是本项目"坏包 0.75%–10% 时变"的直接测量。

- **图案**：TPIU walking-1s（`CURTPM_VAL=0x00020001`，`target/arm_walking_h743.cfg`），
  走真实 4-bit 引脚 + 真实 TRACECLK（PLL 决定，不动固件）。单 lane one-hot 旋转，
  严格旋转判据能抓 lane skew + drop/extra nibble。
- **抓取**：`td capture stream`（stream bit）或 one-shot，抓 known-pattern 输出。
- **判据（误码率单测）**：主机逐字节验 walking 旋转，坏字节数 / 总字节数 = **采集误码率**。
  再扫：位宽 4/2/1（单 lane 无 SSN 应更低）、TRACECLK 100M→50M（时序裕度）、
  IDELAY tap（眼位）。
- **交叉**：同一图案的误码率应与真实 ETM 的 opencsd 坏包率（RESERVED+BAD_SEQUENCE）
  同数量级、同随位宽/频率的趋势——若是，�down锁定模拟采样层。

---

## 5. 复现命令（离线）

```bash
cd orbtrace/syn/artix7/bringup/sim
# 纯数字 CDC 扫频（SKEW=0 → 全 0%）
for TH in 41667 10417 6667 5000 4000 3333 2525; do
  iverilog -g2012 -Ptb_iddr_cdc_sweep.THALF=$TH -Ptb_iddr_cdc_sweep.BITSKEW=0 \
    -o /tmp/s.vvp tb_iddr_cdc_sweep.v && vvp /tmp/s.vvp; done
# 异步拍频（稳态 0，仅上电瞬态 2 字节）
iverilog -g2012 -Ptb_iddr_cdc_async.TCLK_HALF=5050 -Ptb_iddr_cdc_async.RUN_NS=160000 \
  -o /tmp/a.vvp tb_iddr_cdc_async.v && vvp /tmp/a.vvp
# skew×频率交互（注入 300ps skew → 特定相位/频率撕裂）
bash run_sweep.sh
```


---

## 6. Part B 实测：真实引脚 + 真实 IDDR 采集误码率（2026-08-22，上板）

**目的**：Part A 只证了数字 CDC 架构零误码（行为级 IDDR）。Part B 用 TPIU 内建测试图案
走**真实引脚 → 真实 IDDR 采样 → 真实 stream 通路**（与真实 ETM 完全同一条采集链），
逐字节量采集误码率。

### 6.1 方法

- **图案源**：TPIU CURTPM（`target/arm_walking_h743.cfg`），CPU halt、PLL 不动。
  绕开 M7/ETM/CSTF/ETF/formatter，直接从 TPIU 驱动 4 lane。
- **采集通路**：**stream bit（与真实 ETM 抓取同一个 bit、同一 IDDR、同一 tap=17）**，
  `stream_recv.py` 收 :5555。**不是** pin_la bit——刻意用真实抓取通路。
- **TRACECLK = 112.5 MHz**（固件 PLL：HSE25/M2×N36/R2/2；比多数真实 ETM 抓取的 100M 还高，
  不是更宽松的工作点）。
- **判据**：每字节 = `{falling_nibble, rising_nibble}`（一个 TRACECLK 周期两条边）。
  - walking-1s：每 nibble 必是 one-hot ∈ {1,2,4,8}；且整流严格旋转（抓 drop/extra nibble）。
  - FF00：每 nibble 必是 0x0 或 0xF（4 lane 同步翻转，最大 SSN）。

### 6.2 结果

| 图案 | SSN | TRACECLK | 抓取量 | 判据 | **误码率** |
|---|---|---|---|---|---|
| walking-1s | 低（单 lane 轮转）| 112.5M | **223 MB** | nibble one-hot + 严格旋转 | **0.000000%**（0 / 223797248）|
| FF00 | **最大**（4 lane 齐翻）| 112.5M | **225 MB** | nibble ∈ {0x0,0xF} | **0.0000%**（0 / 224928768）|

- **walking-1s**：整条 223 MB 只有两个字节值 `0x42`/`0x18` 严格交替，**0 次偏离**——
  零 bit 错、零 lane skew、零丢/重 nibble、零相位滑移。
- **FF00**：224 MB 全 `0x0F`，**0 个坏 nibble**——最大同步开关噪声下仍零误码。

### 6.3 关键推论

- **真实引脚 + 真实 IDDR 采集通路，在 112.5M、含最大 SSN 图案下，误码率 = 0%。**
  Part A（数字架构 0%）+ Part B（真实模拟采集对**周期图案** 0%）都指向：**采集硬件对
  可预测/周期性码流是零误码的**。
- 这**收窄**了真实 ETM 那 0.75%–10% 坏包的来源：不是"引脚/IDDR/走线在 112.5M 采不动"
  的普遍能力问题（能，且零误码），而是**与真实 ETM 码流的某种特性相关**（见 §6.4）。

### 6.4 诚实边界：Part B 证不了什么（关键，别过度解读）

**TPIU 测试图案是低熵、周期、静态的**——walking-1s 就两个字节无限重复，FF00 就一个字节。
一旦 IDDR 锁上一个稳定采样相位，周期码流会**永远命中同一相位**，自然零误码。
**它没有复现真实 ETM 的两个特性**：

1. **高熵、任意 nibble 跳变**：真实 ETM 每周期 4 lane 独立、任意组合跳变（0x0→0xF、
   0x3→0xC 等大摆幅 + 任意小摆幅混合），data-dependent jitter / ISI / 串扰只在这种
   随机跳变下暴露；周期图案的固定跳变模式测不到。
2. **数据相关的边沿位置抖动**：不同 nibble pattern 的上升/下降沿因串扰/负载被推前/拖后
   不同量，采样窗口在高熵流里被动态压缩——这正是坑点 17/21"半-nibble 相位错位"的物理
   来源，周期图案里边沿位置固定，测不出。

**所以 Part B 的正确结论是**：采集通路对**周期/低熵码流** 0% 误码（排除了"硬件根本采不动
112.5M"），但**真实 ETM 的坏包大概率来自高熵码流特有的 data-dependent 采样裕度问题**，
Part B 的静态图案无法复现，也就无法用它测出真实 ETM 的坏包率。

### 6.5 下一步（Part C，若要坐实高熵假设）

要真正量"高熵码流下的采集误码率"，图案本身必须高熵且可预测。选项：
1. **TPIU 不提供伪随机图案**（只有 AA55/FF00/W1/W0 四种低熵）——此路不通。
2. **ETM 已知固定程序**：让 M7 跑一段**确定性、无数据依赖分支**的紧循环，ETM 输出可由
   ELF 静态预测，再逐包比对——但这又回到"解码器是否忠实"的耦合，不纯。
3. **位宽/降频对照（最实际）**：真实 ETM 抓取时扫 4/2/1-bit 与 100M/50M，看坏包率是否
   随 SSN（位宽）/时序裕度（频率）单调下降。若是 → 坐实 data-dependent 采样裕度；
   这不需要新图案，直接在真实 ETM 抓取上测（AGENT.md §21.4 第 3、4 条）。

**建议**：Part B 已排除"硬件采不动"，Part C 用**真实 ETM 抓取的位宽/降频扫描**（坏包率
vs 位宽 vs 频率）最省事且直接对准高熵假设——留待下次连设备批量抓。

### 6.6 复现命令

```bash
# 1) arm walking-1s on real pins (CPU halted, firmware PLL => 112.5M TRACECLK)
CURTPM_VAL=0x00020001 openocd -f interface/cmsis-dap.cfg -f target/stm32h7x.cfg \
  -f syn/artix7/bringup/target/arm_walking_h743.cfg
# 2) FPGA real-trace path (NOT selftest), rearm, capture via the real stream bit
sudo python3 syn/artix7/bringup/scripts/trace_ctrl.py --ip 192.168.10.42 stream-selftest 0
sudo python3 syn/artix7/bringup/scripts/trace_ctrl.py rearm
sudo python3 syn/artix7/bringup/scripts/stream_recv.py --seconds 2 --out /tmp/w1_4bit.bin
# 3) per-byte check: every nibble one-hot {1,2,4,8}, strict 0x42/0x18 rotation
python3 -c "import numpy as np;d=np.fromfile('/tmp/w1_4bit.bin',np.uint8);\
lo=d&0xF;hi=(d>>4)&0xF;ok=np.isin(lo,[1,2,4,8])&np.isin(hi,[1,2,4,8]);\
print('err%%',100*(~ok).mean(),'distinct',[hex(x) for x in np.unique(d)])"
# FF00: CURTPM_VAL=0x00020008 ; check nibbles in {0x0,0xF}
```
