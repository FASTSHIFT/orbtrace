# 提案 22:Artix-7 采样方案的频率分工 —— IDELAY 移相范围决定的采集频率下限

> 触发:2-bit/4-bit 并口 trace 上板调试中,过采样(OVERSAMPLE)在 168MHz 主频下
> **过采样重复失锁**,降频到 1.3MHz 后**首次在 FPGA 通路上解出真实 PC**。本文把
> 三种采样方式的频率适用区间、以及核心约束 **"IDELAY 移相范围有限 → 用它对眼心
> 有一个采集频率下限"** 用准确物理 + 本地实测一次性钉清。
>
> 一句话:**IDELAY 最多把信号推迟 ~2.5ns,要靠它把采样点从数据边沿移到眼图中心,
> 需要移动 ~UI/2;频率越低 UI 越大,UI/2 越远,2.5ns 就够不到 —— 所以 IDELAY 移相
> 方案有一个 ~100MHz(TRACECLK)的采集频率下限,低于它必须改用"换边沿采"或过采样。**

---

## 1. Artix-7 IDELAYE2 的硬规格(已查证)

| 参数 | 值 | 来源 |
|------|----|------|
| 抽头数 | **32 tap**(0-31) | UG471 / UG953 |
| 每 tap 延迟 | **78 ps**(@ IDELAYCTRL REFCLK = 200MHz) | AMD/Xilinx 官方(MicroZed Chronicles、UG471);@300MHz refclk ≈ 52ps |
| **总移相范围** | **≈ 2.496 ns**(32 × 78ps) | 同上 |
| REFCLK 频率 | 必须 **190-210MHz**(或 290-310MHz)才保证 tap 标称值;Artix-7 IDELAY 工作频率窗口窄 | Xilinx 论坛/UG471(本项目用 200MHz) |

关键:**REFCLK 是给 IDELAYCTRL 校准 tap 用的参考钟(我们用 MMCM 出的 200MHz),与被采
信号 TRACECLK 的频率是两回事**。tap 的物理延迟由 REFCLK 定,移相总量 = 32×78ps = 2.496ns
封顶 —— 这个 2.496ns 才是下面频率下限的根源。

---

## 2. 核心约束:IDELAY 对眼心 → 采集频率下限 ~100MHz

ARM TPIU 并口是 **源同步 edge-aligned DDR**:数据在 TRACECLK 两个沿翻转,数据沿与时钟沿
对齐。IDDR 直接在时钟沿采 = **采在数据跳变点(眼最差)**。要采到眼心,必须用 IDELAY 把
数据(或时钟)推迟,使采样点落到数据稳定区中心。

- DDR 一个数据位(UI)= 半个 TRACECLK 周期 = **1/(2·f_TRACECLK)**。
- 从边沿移到眼心需要移动 **≈ UI/2 = 1/(4·f_TRACECLK)**。
- IDELAY 能提供的移相 ≤ **2.496 ns**。
- 能覆盖眼心 ⇔ 1/(4·f) ≤ 2.496ns ⇔ **f_TRACECLK ≥ ~100 MHz**。

| TRACECLK | UI(位宽) | 眼心距边沿(UI/2) | IDELAY 2.496ns 够不够 |
|----------|----------|------------------|----------------------|
| 1.3 MHz | 385 ns | **192 ns** | ❌ 差 ~77× |
| 10 MHz | 50 ns | **25 ns** | ❌ 差 ~10× |
| 25 MHz | 20 ns | **10 ns** | ❌ 差 ~4× |
| 50 MHz | 10 ns | **5 ns** | ❌ 差 ~2× |
| **~100 MHz** | 5 ns | **2.5 ns** | ✅ 刚好够 |

**结论:IDELAY 移相对眼心只在 TRACECLK ≳ 100MHz 才工作。** 低于此,IDELAY 移不到眼心 ——
这就是"频率不能太低"的准确含义(之前我含糊写成"最低频率下陷",机制讲错,在此更正)。

> 这也解释了 V1/V2 eyescan 在低速(~10M)"14 个 tap 都开眼"的怪象:IDELAY 总范围(2.5ns)
> 远小于 UI(50ns),32 个 tap 全落在眼内同一小区域,**都能解 → 无区分度**,并不是真在
> "扫眼"。低速下 eyescan 找的 best_tap 没有移相意义。

---

## 3. 本地实测证据(§22.4,`14-logic-analyzer-ground-truth.md`)

1.3MHz 下要把采样点移到半位中心(~190ns),逐一排查移相手段:

| 手段 | 1.3MHz 下可行? | 原因 |
|------|---------------|------|
| IDELAY 延数据/时钟 | ❌ | 最多 ~2.5ns,差 190ns **两个数量级** |
| MMCM/PLL 对 TRACECLK 移相 90° | ❌ | TRACECLK 1.3MHz < MMCM 最低输入(~10MHz),锁不住 |
| **换边沿采(IDDR 反相 / 换 a-b 边沿配对)** | ✅ | 用相反时钟沿,天然落在半位中心,**不需要绝对延时** |

→ 低速的正解不是 IDELAY,而是**换边沿**(免移相)或**过采样**(ref_200m 定位采样点)。

---

## 4. 三种采样方式的频率分工(代码里都有)

| 方式 | 原理 | 适用频率 | 我们的验证 |
|------|------|---------|-----------|
| **OVERSAMPLE**(trace_capture_a7 默认) | ref_200m(5ns)过采样 TRACECLK+数据,检测边沿后 mid-eye latch;采样点靠计数器定位,不靠 IDELAY | **低速,≤~10M**(再高过采样重复失锁,§5) | ✅ 降频 1.3M 解出真 PC |
| **IDDR(换边沿,无 IDELAY 移相)** | TRACECLK 当采样钟,用相反沿落半位中心 | **低/中速**,免移相所以无下限 | V1/V2 开眼吐帧(未端到端解 PC) |
| **IDDR + IDELAY 移相对眼心** | IDELAY 把采样推到眼心 | **高速,≳100MHz**(§2 下限);上限受 SI | 未触及该频段 |

**没有单一方式通吃全频段**:低速用过采样/换边沿,高速才用 IDELAY 移相。中间靠换边沿过渡。

---

## 5. 本轮实测(诚实标注)

- **OVERSAMPLE 降频首次解出真 PC**(✅):STM32 4-bit,HCLK /128(~1.3MHz),FPGA 解出
  `0x08000f8c add`/`0x08000fbc loop_sum`/`0x08000e90 TIM8 handler`(带 file:line)。
  **stage4 以来 FPGA 采样通路首次在板上解出真实函数**(§14 的真 PC 是逻辑分析仪抓的)。
- **OVERSAMPLE 高速失锁**(✅,168MHz):抓到字节**每个重复 3-5 次且不规整**
  (`83 83 83`、`c0 c0 c0 c0`)。根因:TRACECLK 半周期太短,边沿检测在一个真实周期内
  多触发(振铃被 LOCKOUT=4/20ns 压不住)。去重也解不出。
- **SELFTEST 恒完美**(✅):内部 +7 ramp 恒解出精确 ramp → OVERSAMPLE 采样/组装逻辑
  **零 bug**,高速失锁是真实信号边沿多检,非逻辑错。
- **boundary-scan 证接线对**(✅):TRACECLK(D17)/D0(F13)/D1(E14)均 toggle
  (balance .83/.52/.64),信号物理到达 FPGA。(此前我用 duty 统计误判"没进 FPGA",
  被此实验推翻 —— duty 在过采样多检下失真,不可用于判物理连通。)

---

## 6. 对函数级 trace 目标的路径

| 目标 | 方式 | TRACECLK | 状态 |
|------|------|----------|------|
| **现在就要函数级 trace** | OVERSAMPLE 降频 | 1.3-10M | ✅ 已通(4-bit 解真 PC) |
| 中速 + 函数级 | IDDR 换边沿(免移相) | 10-50M | 需做:换边沿采 + 端到端解码(V2 只到开眼) |
| 中速 + 函数级 | **MMCM 90° 移相** | **21M(HCLK 42M)** | **✅ 已通,板上解出真 PC(§7.2)** |
| 高速/满速 | IDDR + IDELAY 移相 | ≳100M(§2 下限)| 命门:此频段 SI + IDELAY 对眼,未触及 |

**最务实**:用 OVERSAMPLE 降频(已通)交付函数级 trace 能力,接 orbetto 出调用栈+时间轴;
中/高速作为独立 PoC,且要认清 **IDELAY 移相只在 ≳100MHz 才有意义**,中速段(10-50M)应走
"换边沿采"而非靠 IDELAY 对眼。

---

## 7. 频率扫描实测(本轮补,纠正旧估)

逐档扫 STM32 HCLK,测 OVERSAMPLE 4-bit 通路解出的 flash I-sync 锚点
(`scripts/freq_scan_oversample.sh`):

| HCLK | I-sync 锚点 | distinct PC | 状态 |
|------|------------|------------|------|
| 1.3 MHz (/128) | 16 | 3 | ✅ |
| 10.5 MHz (/16) | 15 | 3 | ✅ |
| 21 MHz (/8) | 18 | 5 | ✅ |
| **42 MHz (/4)** | **0** | **0** | ❌ 失锁 |
| 84 MHz (/2) | — | — | ❌(把 FPGA 网络搞挂,需重烧恢复) |

**OVERSAMPLE 实测可用上限 ≈ 21M HCLK,42M 崩。** 且 42M 下**扫遍 EYE_DELAY=1..12
(`scripts/eye_scan_42m.sh`)全部 0 锚点** —— 失锁**不是** mid-eye 点位置(改 EYE 救不活),
而是**过采样率根本不够**(42M 下每半位 ref_200m 采样点太少,边沿检测/配对失效)。

> duty 统计在真实信号 + 过采样多检下持续失真(测出 ms 级假"半周期"),**不可用于判
> TRACECLK 频率或物理连通**,本轮多次被它误导,改用锚点解码 + boundary-scan 判定。真实
> TRACECLK 频率待 LA 直接读数(HCLK↔TRACECLK 分频:etm_enable 注释 /16 prescale vs
> downclock.cfg "直接 HCLK 派生无独立分频",两处矛盾,需实测)。

### 7.1 中速(>21M)方案:MMCM 90° 移相(中速可行,低速不行)

要中速,§3 的"换边沿"在中速段有低速做不到的实现:**MMCM 对 TRACECLK 移相 90°**(=DDR
半位)落眼心,免 IDELAY 绝对延时。低速(<10M)TRACECLK < MMCM 最低输入锁不住;**中速
(TRACECLK 10-50M)MMCM 能锁** → 正好填 OVERSAMPLE(≤21M)与 IDELAY(≳100M)之间的空档。
前提:真实 TRACECLK ≥ ~10M(待实测)。若 TRACECLK=HCLK/16 则也锁不住,得提过采样钟或
IDDR 换边沿配对。**TRACECLK 实测频率是下一步 PoC 第一问。**

### 7.2 MMCM 90° 移相 —— 板上验证成功(✅ 实测,本轮)

`trace_capture_mmcm.v` + `trace_mmcm_top.v`(独立顶层,不动已验证的 OVERSAMPLE
`trace_stream_top`)在 **STM32 HCLK=42MHz(TRACECLK=21MHz)** 实测:

- **MMCM 锁定**:capture MMCM(`u_cap/u_mmcm`,CLKIN=21M,VCO=21M×40=840M)
  `locked=1`,buffer `rfull=1` —— 21MHz 远高于 MMCM 最低输入,稳定锁定。
- **解出真实函数级 trace**(`/tmp/mmcm_best.bin`,16 I-sync 锚点 / 44 branches):
  - `0x08000f8c _Z3addii` → main.cpp:54
  - `0x08000fb2 _Z8loop_sumi` → main.cpp:61
  - `0x08000e90 TIM8_UP_TIM13_IRQHandler` → timer.c:483
- **采集频率 = OVERSAMPLE 上限的 2×**:OVERSAMPLE 在 42M HCLK 失锁(§7),MMCM 90°
  在 42M HCLK / 21M TRACECLK **解出真 PC** —— stage4 以来第二个在 FPGA 通路解出真实
  函数的方案,且把可用频率从 21M HCLK 抬到 ≥42M HCLK。

#### 关键实测细节:半位配对偏移一拍
naive 打包 `{trace_b[k], trace_a[k]}`(同周期上/下半位)**解不出**(0 锚点)。板上暴力
搜索(`decode/mmcm_halfbit_search.py`,扫 offset×nibble序×lane序)得唯一可解组合:
**`cap_byte = {trace_a[k] (高nibble), trace_b[k-1] (低nibble)}`** —— 即字节边界比"同
周期两半位"偏移一个半位。根因:IDDR `SAME_EDGE_PIPELINED` 把当前上沿与**上一周期**下沿
配在一起(流水线相位)。已据此改 `trace_capture_mmcm.v`(`trace_b_q` 打一拍),使板上
直出字节即可解码(为后续 orbuculum 实时喂流准备)。

> 诚实标注:21M 已实测解出真 PC;更高(42M TRACECLK / 84M HCLK)MMCM 仍能锁(VCO 需
> 调 MULT,如 42M×20=840M),但 84M HCLK 曾把 FPGA 网络搞挂(§7),未在该频段验证解码。

---

## 8. 诚实边界(更新)

- OVERSAMPLE 上限 ~21M HCLK 已逐档实测(§7),非旧估。
- §2 的 ~100MHz 下限是 IDELAY 2.496ns + edge-aligned DDR 的物理推导,**未在板上撞到**
  (我们从没跑到 100MHz TRACECLK)。
- IDDR 换边沿在我们板上只验过"开眼吐帧",**未端到端解出真 PC**。
- tap=78ps 仅在 REFCLK=200MHz 时成立;若改 300MHz refclk,tap≈52ps、总范围更小,下限频率
  更高(约 150MHz)。
