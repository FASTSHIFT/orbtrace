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

## ⚠️ 严格判据修正：字节流 NOT 100% 匹配（逐指令核对）

"13/14 函数 / 781 PC / 100% 落 flash" 是**虚荣指标**（红方 r25 批过）：函数覆盖是
集合去重、"落 flash"只说明地址在范围内，都不能证明执行流逐条正确。

按严格判据（每个解码事件是否合法）重新量化同一份 BB=1 / 12MHz 解码：

| 信号 | 数量 |
|------|-----:|
| INSTR_RANGE（执行区间） | 1852 |
| **RESERVED（非法包头）** | **547** |
| BAD_SEQUENCE | 27 |
| NOT_SYNC | 19 |
| TRACE_ON（重锁次数） | 141 |

- **非法解码事件 = 24.3%**（593 错误事件 / 2445 总事件）。**绝非 100%。**
- 模式：长段正确 + 周期性脱轨。最长连续 123 条指令区间无错，中位数 28 条，
  之后撞上一个字节错误 → 脱轨 → 靠下一个 A-sync 重锁（141 次 TRACE_ON）。
- 这与物理层 walking 测得的 ~2.5% nibble 结构误差自洽：一个 ETMv4 包几字节，
  2.5% 字节错 ≈ 每 30-40 条指令区间遇一次错 → 正好对上 clean-run 中位数 28。

### 最终瓶颈定位

字节流不到 100% 的根因**不是解码链**（那已修好），是**采集侧那 ~2.5% 的 nibble
结构误差**——walking 图案测出的、与频率无关的 `0xa(lane1,3)/0x5(lane0,2)` 隔-lane
混叠，发生在数据跨 lane 跳变的过渡瞬间。**当前 4 条 data lane 共用一个全局
IDELAY tap，补不掉 lane 间的相对偏斜**。

要逼近 100% 逐指令匹配，下一步是 **per-lane 独立 IDELAY tap 校准**（每条 lane 单独
扫眼心），而非共用一个 tap。这是采集侧的收尾工作。

## 2.5% 的谜底：架构级根因 = TRACECLK 占空比 + IDDR 下降沿采样窗口

用户直觉"2.5% 顽固、反复出现、可能是架构问题"完全正确。逐层逼近后锁死根因：

### 决定性证据链（全部实测，walking-1s @12MHz）

1. **误差全在下降沿**：FALL nibble 错误 3.4-3.9%，RISE nibble 只 0.6% —— **fall 比
   rise 差 ~5.5×**。完全的边沿不对称。
2. **错误值 100% 确定**：FALL 错误恒为 `0x5`，RISE 错误恒为 `0xa`。非随机。
3. **对 IDELAY tap 完全不敏感**：全 32 tap 扫，FALL 错误纹丝不动在 ~3.4%（移数据
   ±2.4ns 毫无影响）→ **排除采样相位/眼图/SI/飞线 skew**（那些必随 tap 变）。
4. **周期性**：错误每 6 字节一次（walking 周期 2 字节的 3 倍）。
5. **上下文叠加**：时间序 `R8 F5 R2`，此处 fall 应为 `F1`，实测 `F5 = F1|F4` ——
   **fall 采样抓到了当前 fall 值与相邻 fall 值的 OR 叠加**（采到正在切换的中间态）。

### 根因

TPIU 是 **edge-aligned**（数据在 TRACECLK 边沿翻转）。我们的 IDDR 直接在 TRACECLK
双沿采 = **采在数据跳变点**。上升沿采样(Q1)勉强够 setup；但**下降沿采样(Q2)的
半位窗口被 TRACECLK 占空比失真压窄**（STM32 出来经飞线+IBUF，占空比非精确 50%，
fall 沿离 rise 沿更近），fall 数据还没稳定就被采 → 系统性抓到过渡态叠加。

这不是模拟 SI（对 tap 不敏感证明），是**数字采样窗口 + 时钟占空比**的架构矛盾：
- **IDDR 源同步**：能上高频，但只能边沿采（=跳变点），fall 窗口受占空比压缩 →
  ~2.5-3.4% floor，与频率/tap 无关。
- **OVERSAMPLE 眼中心采**：采样点对，但边沿检测在高频失效（LOCKOUT）→ 只能低频。
- 两条现有路各有死穴，这就是 2.5% 跨 pin-LA / walking / 真 ETM 都顽固的本质。
- 历史印证（doc 14 §21-22）：早就发现"falling 值系统性偏向 rising、falling 采样
  踩在跳变沿采到过渡/上一拍数据"，且 §21.5 单 lane 下降沿采样率只有上升沿的 1/3。

### 解法（架构级，按可行性）

1. **移数据 1/4 UI 而非移边沿**：IDELAY 只能移整体延迟，改变不了 fall 相对 rise 的
   半位不对称（实测 tap 无效）。真正要的是让 **rise/fall 采样点各自落在自己半位
   中心**。IDDR 单一延迟做不到（rise/fall 共享 IDELAY），需要：
2. **MMCM 生成相移采样时钟**（proposal 22/26 的方向）：用一个相对 TRACECLK 移相
   90° 的时钟驱动 IDDR C，把双沿采样点整体挪到两个半位中心。这才是 Xilinx 源同步
   edge-aligned 接收的标准解（对应 ECP5 IDDRX1F 的固有偏移）。代价：MMCM 要锁
   TRACECLK，gap 时会失锁（与"停走时钟"需求冲突，需权衡）。
3. **ISERDES 过采样**：IOB 内 1.2-1.4GSPS 过采，软件挑眼中心，彻底绕开占空比。
   工程量最大。

**结论**：2.5% 是 edge-aligned DDR 在"边沿采 + 占空比失真"下的架构下限，IDELAY tap
治不了。要清零需相移采样时钟(MMCM)或过采样(ISERDES)。这是采集架构的下一个大改，
不是参数调整。


## ⚠️⚠️ 撤回"占空比根因"（红方 r26 证伪 + 我的仿真复核）

红方 `reviews/r26-源同步IDDR占空比根因-红方证伪.md` 把上一节的"占空比根因"证伪，
我复核后**接受，并撤回"锁死根因"的措辞**。诚实把握度：占空比根因 ~30%。

**红方成立的三条**：
- R1：IDDR 分支 duty 统计硬置 0，**占空比从未被实测**，纯推断。
- R2：把 g_iddr 的 CDC verbatim 抄进 iverilog，理想 50% 占空比 + 干净数据，12MHz
  误码 0.00% → 占空比不是复现 2.5% 的必要条件。
- R3：`0x5=0x1|0x4` 是两值按位 OR（位撕裂签名，非模拟边沿抖动）；"对 tap 不敏感"
  指向 IDELAY 下游的数字 CDC，不是占空比。我把反证读成了正证。

**但我的进一步仿真也未坐实红方的 CDC 撕裂假设（R4）**：
- 写了 `tb_iddr_cdc_phase.v`：忠实建模 edge-aligned 数据 + 真实双沿 IDDR
  (SAME_EDGE_PIPELINED 流水) + verbatim CDC，扫 trace_clk 相位 0-5000ps。
- 结果：理想 50% 占空比下 **lo5=0 hia=0，不复现 0x5/0xa**（仅 2/48 启动瞬态）。
- → R4 的"CDC 数据/选通差一拍"在理想模型下也不产生 0x5/0xa。

**真实数据的最硬实测（/tmp/wt.bin，IDDR 路径 walking @12M）**：
- 错误字节形如 `18 42 [58] 42 18`：正常 `0x18` 处变 `0x58`，**rise nibble(8) 完全
  正确、前后字节(42)完全正确，只有该 fall nibble 从 1 变 5 = 1|4**。
- 即**单个 fall 采样点多亮了一条 lane（lane2 泄漏）**，= 当前 fall 值 OR 前一个 fall
  值。不是整字节撕裂（前后字节都对），是**单 nibble 单沿的 lane 泄漏**。

**诚实现状**：现象是硬的（fall-only、0x1|0x4 OR、rise/相邻字节都对、tap 无关），但
**占空比假设和 CDC 撕裂假设都未能在仿真复现它**。真实机制未定。停止猜测。

### 采纳红方 P0，下一步（先测再断）

1. **实测 TRACECLK 占空比**：编 OVERSAMPLE 版 trace_stream（该分支自带 duty 统计），
   同一 CURTPM walking 抓，读 duty_hi/lo，直接算占空比。同时得到**完全不同采集
   路径（眼中心采）的 walking 误码**做对照——若 OVERSAMPLE 也出 0x5/0xa，则排除
   IDDR 边沿采样；若不出，才支持边沿采样类假设。
2. **fall 误码率 vs 频率曲线**（R5）：平坦→证伪窗口压窄；单调恶化→支持。
3. 只有实测确认后才谈 MMCM/ISERDES（R7 成本倒挂）。


## 高频(100MHz)重测 + 统计严谨化：tap 无效是抓样噪声，误码随机抖动

按 r26/护栏要求，在 IDELAY 有分辨力的频率(100MHz，half-bit 5ns，authority 48%)
重做 tap 扫描（低频扫 tap 全程无意义，已被护栏拦截）。

**第一轮（单次抓样，每 tap 一次）**：错误随 tap 剧烈变化 0.51%-3.67%，且**fall/rise
不再是低频的 5.5× 不对称，而是几乎相等**（fall 略低于 rise）。一度以为"tap 有效
→ 相位/眼图问题"。

**但统计复核推翻了它**：固定 tap 各重复抓 8 次：

| tap | 8 次 multibit% |
|----:|----------------|
| 8  | 2.80 2.46 0.90 1.70 2.55 2.38 2.66 0.69 |
| 10 | 1.08 2.92 2.16 3.05 1.95 2.51 2.74 3.31 |
| 18 | 1.46 1.78 1.76 1.04 1.50 3.17 1.70 2.80 |

**三个 tap 的分布完全重叠，同一 tap 的方差(0.69↔2.80)比 tap 之间的差异还大。**
第一轮那个"随 tap 变化"根本是**单次抓样噪声**——同 tap 重抓就能从 0.7% 跳到 2.8%。

### 修正后的诚实观测（统计严谨）

100MHz 下误码是：**均值 ~2%、每次 rearm 剧烈随机抖动、与 IDELAY tap 无关、
fall/rise 对称**。

这个特征组合：
- **随机 + 每次 rearm 不同** → 不是稳态相位偏移（那样同 tap 应稳定重复）
- **与 tap 无关**（这次 IDELAY 有 authority，无关才有意义）→ 故障在 IDELAY 下游
- **fall/rise 对称**（不同于低频的 fall 独坏）→ 不是占空比
- → **重新指向 CDC 亚稳态 / 字节撕裂 / arm 时刻随机相位锁定**（红方 R4 方向，在这个
  随机性特征下重新变强）

### 方法学教训（已固化为护栏）

我反复在少量抓样上过早下结论。"tap 随位置变化"两次都被单次噪声骗了。**必须每点
多次重复取统计**才能区分真效应与噪声。低频扫 tap 更是双重无效（IDELAY 无 authority
+ 单次噪声）。sampling_guard.py 已拦低频；统计复核纪律需贯彻。

### 下一步：SELFTEST 一锤定音

要把"随机 2% 抖动"定位到 FPGA 内部(CDC) vs 物理层，用 `SELFTEST=1`（trace_capture_a7
内部生成已知图案，绕开物理引脚/IDELAY/SI）。若 SELFTEST 下仍有此随机抖动 →
纯 FPGA 内部(CDC)，与 TRACECLK/飞线/SI 全无关，彻底定位到 R4 的 CDC 交接。


## CDC 仿真定位：纯逻辑零 skew 不复现，但当前 CDC 设计本就不严谨

现有 SELFTEST 注入点**只在 OVERSAMPLE 分支**（`os_clk_src/os_data_src`），IDDR 分支
没接，且生成器仅 ~1MHz——无法直接测 IDDR CDC。改走 iverilog 离线定位。

**tb_iddr_cdc_async.v（零人为 skew + 真异步 + 真实双沿 IDDR + edge-aligned data）**：
- 100MHz(=ref/2, toggle CDC 最坏情况)扫遍初始相位：**bad≈0，0x5=0 0xa=0**。
- 93MHz(非 ref/2 真异步)扫相位：同样不复现。
- → **纯 CDC 逻辑在零 skew 下不产生 0x5/0xa**，即使最坏 ref/2。

**tb_iddr_cdc_sweep.v（红方版，注入 per-bit skew）**：撕裂**高度依赖精确频率比/相位**
——红方报告的 48MHz 撕裂在 100MHz 整除 ref/2 时反而消失（相位锁定）。skew 0-300ps @
100MHz 全 0%。说明"CDC+skew 撕裂"存在但对工况极敏感，不是普遍解释。

### 诚实的把握度与判断

- 占空比根因：**基本排除**（100M fall/rise 对称）。
- 纯 CDC 逻辑撕裂：**零 skew 仿真不复现**；靠真实布线 bit-skew 可能在特定工况撕裂。
- 把握度：CDC 字节交接不严谨是**最可能方向(~55%)**，但**尚无稳定复现硬件 2% 的仿真**。

**关键工程判断（不必等 100% 坐实机制）**：当前 IDDR 导出 CDC = `tclk_byte` 组合更新
的 8-bit 裸总线，被 ref_200m 域用"数据链 2 级 / 选通链 3 级"直接采——**没有任何原子性
保证**（红方 R4）。无论撕裂机制细节如何，这都是不严谨设计。正确做法是用**已验证的
异步 FIFO（格雷码指针，la_ddr_writer 里 CI 测过的 axis_async_fifo）做原子字节交接**。

### 下一步：修 CDC 再上板（"修了再看"胜过继续猜）

把 IDDR 分支的裸总线 toggle-CDC 换成 axis_async_fifo 原子交接，重编上板测 100M walking：
- 若 2% 随机错**消失** → 机制坐实为 CDC 字节交接，问题解决。
- 若**仍在** → 排除 CDC，指向物理层（真实 SI / IDDR Q2 建立时间），再上 MMCM 相移/ISERDES。
这比继续在仿真参数空间穷举更有产出。


## ✅ 根因坐实 + 修复：2.5% = 我的裸总线 CDC 撕裂，换 async FIFO 后 walking 归零

把 IDDR 分支的裸总线 toggle-CDC 换成经 CI 验证的 **axis_async_fifo（格雷码指针原子
交接）**，100MHz walking，关键 tap 各重复 8 次：

| tap | 旧裸总线 CDC（8次） | **新 async FIFO（8次）** |
|----:|--------------------|--------------------------|
| 8  | 0.69–2.80% 随机 | **0.00 ×8** |
| 10 | 1.08–3.31% 随机 | **0.00 ×8** |
| 18 | 1.04–3.17% 随机 | **0.00 ×8** |

严格 walk_score（rotation 判据）：**0.0000%**，零 multibit、零 rotation break。

**根因一锤定音**：那顽固的 2.5% **是我自己写的 CDC bug**——`tclk_byte` 8-bit 裸总线
跨 trace_clk→ref_200m 非原子交接，ref 采样撞在发射窗口就把相邻周期的 bit 混进一个
字节（`0x5=0x1|0x4` OR 撕裂）。**不是占空比、不是 SI、不是飞线、不是 IDDR 采样相位**
——全是我之前的错误猜测。红方 r26 R4 方向完全正确。所有诡异现象都被解释：tap 无关
（CDC 在 IDELAY 下游）、随机每次不同（异步交接相位随机）、0x5/0xa OR 叠加（撕裂签名）、
跨场景顽固（只要用这 CDC 就有）。

### 遗留：FIFO 版真 ETM 出现 nibble-顺序偏移（标定中）

FIFO 版抓真 ETM，raw 的 HSYNC 从 `ff 7f` 变成 `f7 ff`——**字节 nibble 顺序相对旧版
变了**（FIFO 的 valid/data 对齐与旧 toggle-CDC 的多级延迟不同）。walking 对称看不出，
但真 ETM 的 TPIU 结构暴露了。host 端 nibble-swap 是错解（凑出假 FSYNC）。正解：用
**不对称已知图案（CURTPM F0/00 → 字节 0x0F 或 0xF0）标定正确 nibble 顺序**，在 RTL 里
把 `{iddr_b,iddr_a}` 打包顺序改对，重编译。walking 完美已证 FIFO 本身零错，只差这个
确定性的字节对齐。
