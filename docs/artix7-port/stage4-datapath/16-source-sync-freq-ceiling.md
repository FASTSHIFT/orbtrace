# Stage-4 · 源同步 IDDR 采集频率上限实测

> 日期：2026-07-18
> 方法：CURTPM AA/55 已知图案 + IDDR 源同步捕获（CAP_METHOD=IDDR, CAP_RAW=1）
> 频率控制：CPU halt + runtime 改 PLL1 DIVN1/DIVR1（`target/set_pll_n.cfg`，
>           不重烧 firmware）。频率用 FPGA 200MHz timebase 数字节率实测（无混叠）。

## ⚠️ 结论修正（红方自我证伪后）

**初版结论"197.8MHz @ 0.002% 干净"是 AA/55 图案下的乐观假象，已被 walking-bit
图案证伪。诚实结论见 §红方证伪。**

### 初版（AA/55，乐观下界）

用 CURTPM AA/55（4 条 data lane 同步翻转 → 字节恒为 0xA5/0x5A）测得：181-198MHz
全程 0.002% 误码。频率随 DIVN1 到 N=31（197.8MHz）达峰后回落 = STM32 PLL VCO 撞顶。

**但 AA/55 是最宽松的图案**：4 lane 同步，无 lane 间差异；且丢一对 nibble 后仍读
作 0xA5，误码判据根本测不出丢字节。所以 0.002% 只证明"物理链路能在 198MHz 传输
*同步方波*"，不证明能可靠采多-lane 高熵数据。

## 红方证伪：walking-bit 图案（lane 不同步，严格判据）

改用 CURTPM walking-1s（单 bit 在 4 lane 上循环右移 → 理想 nibble 序列
4,2,1,8,...，每个 nibble 单 bit、有方向）。判据：nibble 必须是单 bit 且严格遵循
旋转，能抓 lane skew（多 bit nibble）和丢/多 nibble（旋转断裂）。

| TRACECLK | AA/55 err | **walking-1s err** |
|---------:|----------:|-------------------:|
|  75 MHz | 0.002% | **2.40%** |
| 100 MHz | — | **2.70%** |
| 125 MHz | — | **2.55%** |
| 150 MHz | 0.002% | **2.64%** |
| 175 MHz | 0.002% | **2.81%** |
| 198 MHz | 0.002% | **2.87%** |

**walking 误码比 AA/55 高 ~1000 倍**，且从 75→198MHz 几乎平坦在 ~2.5%——**不随
频率上升**。这个平坦性很关键：如果是 SI/带宽到极限，误码应随频率陡升；平坦说明
这 2.5% 是**结构性固定误差**，不是频率相关的 SI 墙。

### 2.5% 的根因（诚实定位）

细分 75MHz walking 样本：
- 4 条 lane 单 bit 计数几乎完全均等（1/2/4/8 各 ~7900-8120）→ **无 stuck lane、
  无单 lane 偏弱，4 lane 物理都健康**
- multi-bit nibble 只有两种：`0xa`(lane 1,3) 和 `0x5`(lane 0,2)，各 ~370 次 →
  **结构化的隔-lane 混叠**，不是随机 skew
- 即"walking bit 跨 lane 移动的过渡瞬间，采样偶尔把相邻两个 nibble 的 bit 混进
  一个采样点"——是**跳变附近的采样相位/眼过渡问题**，所有全局 tap 下都残留 ~2.5%

### 诚实的采集能力结论

- **AA/55（同步方波）**：198MHz 干净 —— 物理链路带宽够
- **walking（每边沿换 lane 的高活跃图案）**：全频段 ~2.5% 结构性误差 —— 当前
  **单一全局 IDELAY tap + 这套 CDC** 对高活跃多-lane 图案有固定的过渡态采样误差
- 真实 ETM 数据介于两者之间（高熵但非每边沿全换），实测（doc 07 §9.2）也是
  "inter-sync 段零星 bit 错"——与这里的 2.5% 结构性误差一致

**所以采集频率上限不能只报 AA/55 的 198MHz。诚实说法：物理带宽 ≥198MHz，但
多-lane 逐字节零错还没解决（~2.5% 结构性误差），需要 per-lane IDELAY 校准或
改进过渡态采样。终极判据仍是真 ETM + orbmortem 解码正确率。**

## 数据

频率扫描（DIVR1=0，VCO=TRACECLK，每档扫 IDELAY tap 取最佳）：

| DIVN1 | TRACECLK | best-tap err | 眼宽(#good tap) |
|------:|---------:|-------------:|:---------------:|
| 28 | 181.3 MHz | 0.002% | 7/9 |
| 29 | 187.5 MHz | 0.002% | 6/9 |
| 30 | 193.8 MHz | 0.002% | 7/9 |
| **31** | **197.8 MHz** | **0.002%** | **7/9** ← 峰值 |
| 32 | 193.7 MHz | 0.002% | 5/9 | ← 频率回落=VCO撞顶 |
| 33 | 187.5 MHz | 0.002% | 5/9 |
| 34 | 181.2 MHz | 0.002% | 5/9 |

眼图闭合观测（更早的粗扫，150MHz 时 tap 0-16 干净、tap 20+ 崩）：随频率升高
可用 tap 数减少，是眼在收窄的物理指纹；但即便到 198MHz 仍有 7/9 tap 干净，说明
眼还没闭到危险程度。

## 方法学要点

1. **频率测量用 FPGA timebase 字节率，不用边沿计数**：IDDR raw 每 TRACECLK
   周期产 1 字节，200MHz 计数器数字节数 / 时间 = TRACECLK，无混叠。早先 pin-LA
   400MSPS 把 75MHz 误测成 66.67MHz、把 150MHz 误测成 100MHz —— 那是异步过采样
   的混叠假象，timebase 法根治。
2. **runtime 改频靠 CPU halt**：之前 runtime 改 DIVR1 不可靠是因为 func_test
   firmware 的 SysTick/HAL 会重配 RCC。CURTPM 图案由 TPIU 硬件发，CPU halt 照发，
   halt 下 firmware 不干预 RCC，改频稳定可复现。
3. **误码判据用已知图案**：CURTPM AA/55 每字节必为 0xA5/0x5A，不依赖 TPIU sync
   帧（避开 r23 Q3/Q5 满载失效死穴）。

## 工具

- `target/set_pll_n.cfg` / `set_divr1.cfg`：CPU halt 下改 VCO/分频 + 重启 CURTPM
- `scripts/freq_ceiling_sweep.py`：扫 N × tap，测频率+误码+眼宽，报上限
- `scripts/iddr_tap_sweep.py`：单频率下扫 tap 找眼心

## 后续（如需突破 198MHz）

要测更高频率需重配 PLL1 输入分频 M / RGE 让 VCO 能上更高（>198MHz），或换更快
的 PLL 源。但这属于"造更快的信号源"，不是"测采集上限"——采集侧已证明 198MHz
仍游刃有余。真正要压 FPGA 采集极限，需要一个能发 >200MHz 干净 DDR 的信号源。
