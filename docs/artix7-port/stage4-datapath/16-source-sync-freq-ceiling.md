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

## 终极判据：真 ETM + OpenCSD 解码（进行中）

按红方建议上真 ETM 做无法自欺的验证。用 `build_h743.sh` 自编译 firmware（ELF
与 flash 严格匹配，避免地址错配），`etm_enable_h743.cfg` 启 ETMv4 + 清 CURTPM，
IDDR raw 抓 → `opencsd_etm4_run.py`（OpenCSD trc_pkt_lister）解码。

### 现状（诚实）

- **真 ETM 数据确实抓到**：201-224 个不同字节值，大量 TPIU HSYNC(0xFF/0x7F) +
  高熵 ETMv4 包；assemble 后有 FSYNC(0xFFFFFF7F)（48M ~10 个，12M ~36 个）。
- **解码器能起步**：锁到 A-sync，解出 I_ATOM_F1/F2/F3、I_ADDR_S_IS1、I_EXCEPT
  等合法 ETMv4 包，48M 有 318 个 I_ADDR 包、12M 有 2724 个。
- **但 unique PC = 0**：解出的地址被污染（如 0xF71D0472，高位是流里的高熵字节），
  没有一个落在 flash（0x080xxxxx）。

### 根因定位：字节/nibble 对齐滑移（不是 SI，不是频率）

- **降频到 12MHz（SI 余量极大）表现和 48M 一样烂** → 排除高速 SI / bit 错为主因。
- deframe 流里真 A-sync（11零+0x80）后**本该紧跟 Trace-Info(0x01)，实测中间隔着
  一个 stray byte**（0xf7/0xf6/0xdb），且滑移不一致（有的缺 0x80、有的多字节）。
  这正是 `opencsd_etm4_run.fix_async_alignment` 注释描述的"1 字节相位滑移"，但该
  函数是死代码（主流程未调用）且模式匹配太窄，只能修 1 个。
- **IDDR raw 字节边界其实是对的**（一度误判）：TPIU HSYNC 在 raw 里表现为
  `ff 7f ff 7f...` 交替（这是 TPIU 半同步字的正常字节形态，不是连续 0xFF），
  且 raw 直接 `has_tpiu_sync=True`、含 36 个 FSYNC(0xFFFFFF7F)。所以 **不该再做
  nibble assemble**——`recover_assemble` 把已对的字节又拆 nibble 重组反而搞乱。
  直接把 raw 当 TPIU 字节流 deframe 才对。
- 但**直接 deframe 后 A-sync 仍不跟 0x01**（trace-info-after=0）。字节边界对了，
  问题下沉到 **TPIU formatter 帧解析**（`tpiu_deframe_walk`）：16 字节帧的
  stream-ID / aux-bit 交织提取有偏移，导致 deframe 后的 ETM 字节流错位。那 2 个
  A-sync 很可能是数据里的巧合零串，非真同步点。

### 结论与下一步

真 ETM 端到端**尚未跑通**，但逐层排除后定位清楚：
- 采集/SI/频率：**排除**（12M 与 48M 同样表现；raw 有 FSYNC；字节边界正确）
- firmware/ELF 匹配：**已解决**（自编译，flash 与 ELF 严格一致）
- **TPIU formatter deframe 错位**：`tpiu_deframe_walk` 对这个 16-字节帧流的
  stream-ID/aux 提取有偏移，是当前唯一未通的环节。

下一步（独立的解码链工程）：
1. 核对 TPIU formatter 帧格式（IHI0029 §D4：16 字节 = 交织的数据字节 + 每偶字节
   LSB 的 ID/data 标志 + 末字节 aux）与 `tpiu_deframe_walk` 实现，修正帧内提取偏移。
2. deframe 正确后 A-sync 应自然紧跟 0x01，解码器落出 flash PC。
3. 再谈"真 ETM 在多高 TRACECLK 下解码正确率达标"——那才是有意义的采集上限。

**可复现资产**：`perf/firmware/{etmtest,tclk12}/`（自编译，ELF 匹配 flash），
`/tmp/etm12.bin`（12M 真 ETM raw，raw 直接 deframe：36 FSYNC / 20218 ETM 字节）。

## 更新：真 ETM 端到端跑通（BB=1，解出真实 func_test PC）

### 先证 CPU 真在跑 func_test（排除"程序没起来"）

DAPLink 多次 halt 采 PC：0x08000442→444→4d0→4ec→504，全部精确命中 func_test
用户函数（level_b / dispatch_callback / callback_test / factorial）。**CPU 正常
执行 func_test**，ETM trace 的是真实执行流。附带发现：func_test 代码极紧凑
（0x08000414-0x08000578，160 字节），几乎全是短距离直接调用/分支。

### 关键：BB（Branch Broadcast）决定能否解码

- **BB=0**（低 TRACECLK 默认）：直接分支不发地址包，紧凑代码下地址锚点极稀疏，
  OpenCSD 无法定位 → unique PC=0（之前一直卡这）。
- **BB=1**（每分支发地址）：地址锚点大增，**端到端跑通**：
  - deframed 27206 B, A-sync=9, INSTR_RANGE=3, **unique PC=6, 6/6 落 flash(100%)**
  - **解出真实函数**：`factorial`（func_test 用户函数）、HAL_RCC_OscConfig
  - Idx:7599 `exec range=0x8000512:[0x8000516] ISA=T32 iBR ret` = factorial 递归
    返回的真实 Thumb 指令流 —— **内容真实且正确**。

**这是整条链第一次端到端跑通**：源同步 IDDR 采集 → IDDR raw → TPIU deframe →
OpenCSD → 真实落 flash 的 PC + 命中 func_test 函数。之前的 0 PC 不是链路坏，是
BB=0 锚点太稀疏。

### 仍存在的限制（诚实）

- 解码率低（6 PC / 2 函数，远非全覆盖）：那个字节滑移（A-sync 后 0x80/0x01 时多
  时少一字节，trace-info-after 仍 0）仍在拖累，且偶有误解码（如 ISA=A32，M7 上
  不存在 → 假范围）。
- 根因仍是 PC 端 `tpiu_deframe_walk` 在高 HSYNC 密度流（30%）上的帧对齐滑移，
  或 IDDR raw 导出 CDC 的偶发字节滑移 —— 需进一步用 orbuculum 官方 tpiuDecoder
  对照区分。

**结论**：真 ETM 端到端**已跑通并解出真实 PC**（推翻"没跑通"），但解码率受字节滑移
限制。这是 PC 端解码链的完善问题，不是采集/SI/频率问题。

## 真 ETM 彻底跑通：官方 TPIU deframer 修好 → 781 PC / 13-14 func_test 函数

低解码率的根因找到了：**我们自写的 Python `tpiu_deframe_walk` 逐字节扫 HSYNC
(0xFF 0x7F)，在本流 ~30% HSYNC 密度下、当 HSYNC 落在奇字节偏移时会丢 16-bit 帧
相位**。对比 orbuculum 官方 `Src/tpiuDecoder.c`：它按 **16-bit 对（got_lowbits）**
收集字节、只在对边界过滤 HSYNC，永不丢帧相位；并正确处理 padding(stream 0 丢弃)
和 delayed-stream-change。

把官方逻辑忠实移植为 `decode/tpiu_official.py`，同一份 BB=1 抓样：

| 指标 | 自写 walk | **官方移植** |
|------|----------:|-------------:|
| A-sync | 9 | **72** |
| trace-info-after(0x01) | 0 | **57** |
| unique PC | 6 | **781** |
| PC 落 flash | 6/6 | **781/781 (100%)** |
| 覆盖函数 | 2 | **46** |
| func_test 用户函数 | 1/14 | **13/14**（仅缺 conditional）|

**真 ETM 端到端彻底跑通**：STM32 源同步采集 → IDDR raw → 官方 TPIU deframe →
OpenCSD → 重建真实 func_test 执行流（main_loop/callback_test/indirect_caller/
mixed_test/factorial... 13/14）。缺的 conditional 很可能只是该 trace 窗口未执行到。

已把官方 deframer 接入 `opencsd_etm4_run.py`（`--deframer official` 默认），从 raw
一步出 781 PC。

### 最终定位（全链诚实结论）

真 ETM 解码失败的根因**从来不是 FPGA 采集 / SI / 频率**，逐层证明：
1. CPU 确在跑 func_test（DAPLink PC 采样命中用户函数）
2. 采集/SI/频率排除（12M=48M；raw 有 FSYNC；字节边界对；walking 证 SI 结构误差
   与频率无关）
3. BB=0 锚点饥饿（紧凑代码直接分支不发地址）→ BB=1 解决
4. **PC 端 Python deframe 的 HSYNC 相位 bug** → 官方 16-bit 对齐移植解决

采集侧结论不变：源同步 IDDR 物理带宽 ≥198MHz（AA/55），多-lane 有 ~2.5% 结构
误差；而**真实 ETM 在 12MHz + BB=1 下已能重建 13/14 func_test 函数**。下一步可
在更高 TRACECLK 下复测真 ETM 解码正确率，得到"有意义的采集上限"。
