# Stage-4 · 频率扫描与采样策略测试方案

> 目标:在低速 100% 正确(§30,unknown ~0.003%)基础上,系统测出本采集系统的**频率承压上限**,
> 并确定不同频率档位的采样策略切换点。原则:**动态 + 批量 + 多次重复,尽量零重新编译烧录。**

## 0. 前置:任务 1(读出 off-by-one)RTL 修正已并入

`fpga_core_net.v` 的 `ext_pos` 提前 1 拍补偿 BRAM 读延迟;trace_dump 恢复朴素分页读。用 SELFTEST ramp
ground truth 验证读出干净后,频率扫描的所有误码数才可信(否则又是测量假象)。

## 1. 频率怎么变(零烧录)

TRACECLK = STM32 HCLK,由 `downclock.cfg` 改 `RCC_CFGR.HPRE` 分频决定,**与 FPGA 位流无关**:

| DIV | HPRE | HCLK≈ | TRACECLK(DDR 半位) | 备注 |
|-----|------|-------|-----|------|
| /512 | 0xF | 0.33 MHz | 1.5 µs | 极慢,基线 |
| /256 | 0xE | 0.66 MHz | 760 ns | |
| /128 | 0xD | 1.3 MHz | 380 ns | |
| /64 | 0xC | 2.6 MHz | 190 ns | **当前 100% 基线** |
| /16 | 0xB | 10.5 MHz | 48 ns | |
| /8 | 0xA | 21 MHz | 24 ns | 过采开始吃力区 |
| /4 | 0x9 | 42 MHz | 12 ns | |
| /2 | 0x8 | 84 MHz | 6 ns | ref=200M 仅 1.2 拍/半位,过采失效 |
| /1 | 0x0 | 168 MHz | 3 ns | 必须 IDDR |

> 注:HCLK 实际值取决于固件 SystemClock_Config 设的 PLL;上表按 168MHz 系统时钟估算,实测以读 RCC 为准。
> 改频率只需跑一条 OpenOCD(`DIV=n ... downclock.cfg`),不 reset、不重烧 FPGA。

## 2. 采样策略随频率分三档(关键)

| 档 | 条件(半位 vs ref 周期 5ns) | 策略 | RTL |
|----|------|------|-----|
| 低频 | 半位 ≫ 5ns(≥ ~40ns,DIV≥/16) | **OVERSAMPLE**,EYE_DELAY 落眼内即可 | 现有 |
| 中频 | 半位 ~ 15–40ns(DIV /8–/4) | OVERSAMPLE,**EYE_DELAY 必须 = 半位/2 自适应**;边沿检测 ±1 拍抖动开始占比变大 | 现有 + 自适应 EYE |
| 高频 | 半位 < ~3 个 ref 周期(DIV≤/2) | 过采失效 → **IDDR + IDELAY per-lane deskew**(TRACECLK 当采样时钟) | 需另写(§5) |

**本次扫描的核心产出 = 实测出 OVERSAMPLE 的频率上限,以及必须切 IDDR 的临界点。**

## 3. 零烧录的可调旋钮设计

为了"一次烧录扫完整个矩阵",把编译期参数改成**运行时 CSR**(通过 UDP 控制端口写):

- **EYE_DELAY** → 运行时寄存器(替代 `EYE` generic)。一次烧录即可扫所有 EYE 值。
- **(可选)CAP_METHOD** → 若想在同一位流里切 OVERSAMPLE/IDDR,做成运行时 mux + 两条采集路径并存,
  由 CSR 选。代价是面积翻倍但省去重烧。先不做,IDDR 档单独烧一次。

控制通道:复用现有 UDP readout 框架,新增一个写寄存器端口(如 :5002),payload = {reg_addr, value}。

## 4. 测试编排(软件循环,批量 + 重复)

一次烧录后,PC 端脚本 `freq_sweep.py` 跑双重循环:

```
for DIV in [512,256,128,64,16,8,4,2,1]:
    openocd 设 HPRE=DIV               # 改频率,不 reset
    for EYE in [auto, 一组候选]:
        写 EYE CSR                     # 运行时设采样点
        repeat R 次:
            重 arm FPGA(reload bit 或 soft-rearm CSR)
            trace_dump
            fpga_errrate → 记录 unknown%、锚点数、杂散PC数
    汇总该 DIV 的 中位数/最差/方差
输出:误码-频率曲线 + 每频率最优 EYE + OVERSAMPLE 上限拐点
```

重复 R 次(如 10)取统计,排除单次偶发;记录 median 和 worst-case。

**soft re-arm**:目前 re-arm 靠重烧位流(慢)。应加一个 CSR 复位 capture FSM 的位,让 re-arm = 写寄存器
(快、可批量)。这是省时间的关键改动。

## 5. 高频档(IDDR)预案

当 OVERSAMPLE 在某频率开始劣化,切 IDDR 路线:
- TRACECLK 经 BUFG/BUFR 当采样时钟,IDDR 双沿采;
- IDELAYE2 per-lane 扫 tap 找眼心(eye-scan 训练,FPGA 内做或 PC 辅助);
- 这是源同步标准做法,高频下 IDELAY 的 ~2.5ns 范围相对几 ns 的半位足够。
- 单独烧一个 IDDR 位流,跑同样的 freq_sweep 对比。

## 6. 验收指标

- 每个 (DIV, EYE, 重复) 点:unknown%、flash 锚点数、杂散 bit-flip PC 数。
- **频率上限定义**:unknown 持续 < 0.1%(或锚点稳定全中)的最高 TRACECLK。
- 产出曲线:unknown% vs TRACECLK(每档最优 EYE),标出 OVERSAMPLE→IDDR 切换点。
- SELFTEST(固定内部频)全程当常驻探针:任一频率出问题时,先跑 SELFTEST 确认采集链+读出仍干净,
  从而把"物理层/频率相关"与"采集链 bug"分开(避免再被测量假象误导)。
```


## 7. 实测进展(运行时 CSR 已通,频率标定存疑)

### 7.1 已完成

- **运行时 CSR 打通**:UDP :5002 写 EYE(0x01)/ 软 re-arm(0x02);`trace_ctrl.py` + `freq_sweep.py`。
  一次烧录、零 reflash 跑 DIV×EYE 矩阵已验证可用。
- **读出 off-by-one 终修**:RTL ext_pos 提前一拍的尝试在真实读出下**不可靠**(首拍 AXI stall,SELFTEST
  ramp 看着干净但真实流仍有每页重复字节)。改回 trace_dump 端**每页多读 1 字节丢首字节**的确定性修法,
  实测真实 trace **0.000% unknown**。教训:别用一个数据集(ramp)的干净就推断修复对所有数据成立。
- **板上验证**:CSR set-eye + 软 re-arm + drop-first 读出 = unknown 0.000%、38 锚点、0 杂散,可复现。

### 7.2 存疑:DIV 是否真的改变了 TRACECLK(必须用 LA/示波器证实)

freq_sweep 在 DIV=/64../1 全部得到 **0.000% unknown + 完全相同的 38 锚点**。这有两种可能:
1. 过采样在所有这些频率下都完美(乐观);
2. **DIV 实际没怎么改变 TRACECLK 速率**(存疑)。

旁证指向需要警惕:
- 锚点数在所有 DIV 完全相同(38)——锚点由 ETM 1024 字节同步周期驱动,是字节域量,**与时钟速率无关**,
  所以"锚点相同"既不能证明也不能否定速率变了。
- 用"buffer 填满时间"当速率探针**失败**:/512 和 /1 填充都是几百 ms 级缓慢。原因:tight while 循环里
  ETM 只在分支/同步时**稀疏突发**地出 trace,填充时间被**trace 数据产生率**门控,不是 TRACECLK 速率。
- RCC_CFGR 确实被写入(HPRE 字段在变),但 F429 并口 TRACECLK 与 HCLK 的实际关系、以及 TPIU 是否对并口
  也有自己的分频,**没有用 LA/示波器实测确认过**。

**结论(诚实标注)**:字节域测量**在结构上无法**给出绝对 TRACECLK 频率。"0% 跨所有 DIV"是真实的解码质量
结果,但**不能据此声称达到了某个频率上限**。要标定频率,必须:
- 用 LA(50MSa/s)直接量不同 DIV 下 TRACECLK 的周期,或
- 跑一段已知指令数/已知时长的程序,用 trace 的时间戳/字节量反推速率。

### 7.3 下一步

1. 用 LA 实测 DIV=/64 vs /16 vs /1 下 TRACECLK 的真实周期(几分钟,直接定标)。
2. 标定后,才能在"已知真实频率"轴上画 unknown%-频率曲线、找过采样上限、确定 IDDR 切换点。
3. 在那之前不对"频率承压上限"下任何结论。


## 8. 过采样频率上限分析(从 RTL 算法约束推导)

实标定:SYSCLK=168MHz(实读 RCC_PLLCFGR=0x07405408:HSE8/M8×N336/P2),TRACECLK = HCLK/2。
当前 `ref_200m` = 200MHz(5ns/拍)。当前算法:TRACECLK 边沿后等 EYE_DELAY 拍 latch,每边沿产一 nibble。

约束逐条(f = TRACECLK,半位 = 1/(2f)):

| 约束 | 每半位需 ref 周期数 | 半位下限 | TRACECLK 上限 |
|------|------|------|------|
| 边沿可分辨(2-FF 边沿检测,绝对极限) | 2 | 10ns | 50MHz(危险) |
| 眼内采样 + 容 ±1 拍抖动(**实际可用**) | 4 | 20ns | **25MHz** |
| 远离跳变、舒适裕量(**已验证安全**) | 8 | 40ns | **12.5MHz** |

**结论(ref=200MHz 当前实现)**:
- 舒适可靠 ≤ **12.5MHz** TRACECLK(覆盖 DIV/16=5.25MHz、/8=10.5MHz)。
- 可用有余量 ≤ **25MHz**(DIV/4=21MHz 贴边,需实测确认)。
- 50MHz 理论极限,不可靠。
- DIV/1 = TRACECLK **84MHz** → 半位 6ns,每半位仅 ~1.2 个 ref 点,**过采样物理上不可能工作**。
  → 之前 freq_sweep 在 /1 报 0.000% + 38 个完全相同锚点 = **soft re-arm 高速竞态读到旧 buffer 的假象**,
    不是真采到 84MHz。(又一例字节域指标骗人,被 LA 抓不上当场戳破。)

**上限正比于 ref 频率**。要往高推:
1. 提 ref 过采时钟(MMCM 出 400MHz → 上限翻倍);再高用 ISERDESE2 1:4/1:8 串并等效过采到 ~GHz,
   把过采样路线推到 100MHz+ TRACECLK。
2. >25MHz 切源同步 IDDR + per-lane IDELAY 扫眼(业内高速标准;此时半位几 ns,IDELAY 的 ~2.5ns 够用——
   低频反而不够,所以低频必须过采样)。

**待实测**:在 LA 可覆盖区(/64=1.31MHz、/16=5.25MHz,可能 /8=10.5MHz)做 LA+FPGA 对拍标定,验证
12.5MHz 舒适线;并先修 soft re-arm 高速竞态(加"新捕获已写入"确认),否则高频测量继续被旧 buffer 污染。


## 9. 舒适区实测(gen 确认 + worst-case 跟踪)——发现间歇性损坏

### 9.1 新增可信度机制

- **捕获代数计数器(gen)**:每次 soft re-arm 递增,暴露在状态字节 NB+3。trace_dump `--prev-gen`
  轮询直到 gen 变化且 full=1,**确认读到的是新捕获**(根除"读到旧 buffer"的假象,这是 /1 那个 0% 假象的根源)。
- 状态区(NB+0..3)是组合 mux,无 BRAM 读延迟,故**不**需要丢首字节(数据区才需要)。

### 9.2 实测结论:存在间歇性区域损坏(EYE 无法消除)

DIV/64(TRACECLK 1.31MHz)EYE 细扫 + worst-case:

| EYE | unk% 中位 | unk% 最差 | 说明 |
|-----|------|------|------|
| 4 | 0.003 | 0.003(8次) / **12.8(20次)** | 多数完美,偶发整段坏 |
| 6 | 0.003 | 0.005 | 同上,偶发 |
| 8 | 0.003 | 18.3 | 偶发坏更频繁 |

- 单次捕获是**双峰**:要么 0.000%(完美),要么整段 6–18%(坏),没有中间态。
- 坏捕获的 decile 剖面 = **干净段 + 脏段**,边界位置随机(mid-capture sync-loss)。
- 坏捕获换 parity/phase **救不回来**(内部真损坏,非全局配对偏移)。
- 原始 nibble 层面结构均匀(HSYNC 密度处处 ~245/6KB),坏在**去帧**层 → 少量散落 nibble 错打断 TPIU 帧对齐一段。
- /8(10.5MHz)**整体失败**(17–21%,0 锚点)——舒适区上限 12.5MHz 的理论值偏乐观,实际 ~5MHz 以上就开始不稳。

### 9.3 根因判断(标注把握度)

- **已排除**:读出(gen 确认 + drop-first,h2 等多次 0.000%)、采样架构逻辑(SELFTEST 干净时钟 99.998%
  连续)、EYE 相位(各值都偶发坏)。
- **指向(推断,待证)**:真实 STM32 TRACECLK/数据经物理链路(杜邦线/面包板)的**边沿质量**导致 ref 域
  2-FF 边沿检测**偶发误判**(多检/漏检/亚稳),一旦错位就连坏一段直到自然重对齐。SELFTEST 用的是
  FPGA 内部干净方波,所以不出现——这正是 SELFTEST(99.998%)与真实(双峰间歇坏)的差异来源。
- **频率相关性**:1.31MHz 偶发、5.25MHz 更频繁、10.5MHz 全坏 → 与"边沿/采样裕量随频率收紧"一致。

### 9.4 下一步(targeted,不再调参打地鼠)

1. **加深 TRACECLK 同步链 + 边沿检测去毛刺**:把 tck_sync 加到 3–4 级,并要求边沿后电平**连续 N 拍稳定**
   才认边沿(数字去抖),抑制振铃/慢沿造成的多检/误检。这是针对"间歇 sync-loss"的直接 RTL 对策。
2. **用 LA 同步对拍实测边沿质量**:在 /64 同时 LA 抓 TRACECLK + FPGA 抓,定位坏段对应的真实波形,确认是否
   边沿质量问题(拿可对齐 ground truth,别再跨会话猜)。
3. 若坐实是物理边沿质量 → 阻抗匹配/短线转接板(最初就规划的 SI 路线)。


## 10. 采样方案的频率窗口(IDDR+IDELAY vs 过采样)—— 选型定论

### 10.1 orbtrace 的采法(实读 trace/glue.py)

纯源同步 IDDR:把 **TRACECLK 当 FPGA 采样时钟**(进时钟域),每 lane 用 `DDRInput`(ECP5→IDDRX1F)
在 TRACECLK 双沿采,trace_a=上升沿/trace_b=下降沿。**无过采样、无 ref 时钟、无边沿检测、无 CDC。**
采样相位靠 ECP5 IDDRX1F 输入路径**固有时序天然落在眼内**(testbench 注释 "don't worry about phase")
——碰运气式、依赖器件、无显式校准。所以它**没有**我们过采样那个"边沿误判 → mid-capture sync-loss"的
失败模式(它不判断边沿),但移植性差、无相位裕量保证(Xilinx IDDR 无 ECP5 那个天然偏移,直接抄会坏)。

### 10.2 IDELAYE2 硬参数(Artix-7)

- ~78 ps/tap,常用 0–31 tap → 最大延迟 ≈ **2.5 ns**(用满 63 tap 也就 ~5ns)。

### 10.3 IDDR+IDELAY 的最低可用频率

edge-aligned 源要把数据移到半位中心 = 移**半个 UI**:

| TRACECLK | 半 UI | IDELAY(max 2.5ns)够移? |
|----------|------|------|
| 100MHz | 5ns | ✅ 勉强 |
| 50MHz | 10ns | ❌ 差 4× |
| 10MHz | 50ns | ❌ 差 20× |
| 1.3MHz | 380ns | ❌ 差 **150×** |

→ **IDDR+IDELAY 最低可用 ≈ 50–100MHz。低于此,IDELAY 移不动半 UI,采样点永远卡在跳变区。**
(注:高频时 IDELAY 不是用来"移半个低频 UI",而是 UI 本身只有几 ns,2.5ns 范围正好用来扫过整个眼找
中心——配合 ISERDESE2 + 训练序列。这是它天生的高频定位。)

### 10.4 两方案频率窗口几乎不重叠(选型定论)

| 频率 | IDDR+IDELAY | 过采样(ref=200MHz) |
|------|------|------|
| 1–12MHz | ❌ IDELAY 移不动半 UI | ✅ 舒适区 |
| 12–25MHz | ❌ | ⚠️ 可用边缘 |
| 25–50MHz | ⚠️ IDELAY 接近够 | ❌ 过采点不足(双输区) |
| 50–200MHz | ✅ 半 UI≤5ns | ❌ 不可能 |

**结论**:
- 我们的目标频段 **1–12MHz 只能用过采样**;在 /64(1.3MHz)IDDR 物理上不可行(要移 380ns)。
  → 撤销"低速也试 IDDR 对照"的想法(IDDR 在此频段根本不可能工作)。
- 当前 80% 良率的间歇损坏**必须在过采样架构内解决**(边沿去抖/同步加深/SI),不能靠切 IDDR 逃避。
- 上 50MHz+ 是另一套 **ISERDESE2 + IDELAY 扫眼 + 训练**方案(且 UI 小时不需过采样),需更高 SI 质量
  (阻抗匹配板),属后续阶段。
- 提频路径:过采样吃到 ~25MHz(可能要把 ref 提到 400MHz 翻倍)→ 25–50MHz 是难区 → 50MHz+ 转 ISERDES。


## 11. A7 vs ECP5 采集频率能力估算(器件参数 + 实测点)

> 标注:以下为**估算**(基于数据手册标称值 + 我们已有实测点),非逐一实测。约定 4-bit DDR,
> TRACECLK = f,每 lane bit rate = 2f。

### 11.1 内部主频/资源能力

| 资源 | Artix-7 (-1/-2) | ECP5 |
|------|------|------|
| Fabric(一般设计) | ~200–300 MHz | ~100–150 MHz |
| MMCM/PLL 输出 | ~800 MHz(VCO 600–1600) | PLL ~400 MHz |
| IDDR 双沿输入 | C ~600–950MHz → DDR ~1.2–1.9 Gbps/lane | IDDRX1F ~400MHz → ~0.8 Gbps/lane |
| ISERDES 串并 | ISERDESE2 ~1.25 Gbps/lane | GDDRX 同量级 |

A7 高速能力约为 ECP5 的 ~2×。

### 11.2 ETM trace 采集频率窗口估算

**Artix-7**

| 方案 | TRACECLK | 依据 |
|------|------|------|
| 过采样 ref=200MHz | DC–12.5MHz 舒适 / 25MHz 极限 | 半位 ≥8/≥4 ref 周期(本项目实测点) |
| 过采样 ref=400MHz | DC–25MHz / 50MHz | ref 翻倍 |
| IDDR+固有相位 | ~50–200MHz | 低频 IDELAY 补不动半 UI |
| ISERDES+扫眼 | ~100–300MHz+ | 串并+训练 |
| **综合上限** | **~200–300MHz(~0.8–1.2 Gbps/lane)** | IDDR/ISERDES + SI |

**ECP5**

| 方案 | TRACECLK | 依据 |
|------|------|------|
| IDDRX1F+固有相位(orbtrace 实际) | 低频–~200MHz | 固有偏移落进眼;低频眼更宽更易落入 |
| 过采样(若用,ref~300MHz) | DC–~18MHz | fabric/PLL 较低 |
| **综合上限** | **~150–200MHz(~0.6–0.8 Gbps/lane)** | IDDRX1F + SI |

### 11.3 下限与定论

- **过采样下限 = DC**(两器件皆然,有边沿就产 nibble)。
- **IDDR-only 下限**:ECP5 很低(固有偏移落进低频宽眼,orbtrace 能跑慢 trace);**A7 IDDR-only ≈50MHz**
  (无 ECP5 天然偏移,低频 IDELAY 补不动)→ **A7 低频必须过采样**。
- **结论**:A7 上限更高(~200–300MHz vs ECP5 ~150–200MHz);下限两者过采样都到 DC。差别在
  **A7 低频被迫过采样,ECP5 可 IDDR 一招通吃但上限低**。选 A7 用于"低速钉正确性 + 未来冲高速"是合理的,
  代价仅是低频自写过采样(已完成)。


## 12. r16 红队评审后的实验(E1 做完,结果出乎意料)

### 12.1 接受 r16 的核心批评

- **SELFTEST 证过头**:test_clk 与 ref 同源固定相位,每次 re-arm 命中同一好相位桶 → 永远干净;且绕过
  IDELAY(注入 test_data 而非 data_dly)、零 lane skew、50% 干净方波。它只证"FSM 对良性源+好相位无罪",
  不证"对真实信号无罪"。承认。
- **频率相关性证伪纯亚稳态**:1.3M~7-10% / 5.25M 更频繁 / 10.5M 几乎全坏 → 固定时间量 margin 随眼缩侵蚀。
- **双峰需要 per-capture 锁定常量** → re-arm 相位竞态是头号嫌疑(还能解释 SELFTEST 为何永远干净)。

### 12.2 E1 实测:per-capture clean-start(cap_clear)—— 没修好

实现:每次软 re-arm 复位采样器的 seen_rise,强制每个捕获从全新上升沿开始,解耦"捕获起点 vs re-arm 时
锁定的相位"。sim 字节级一致、146 测试过。

板上 30 次 yield:**87% good / 13% bad**,与未改前(90-93%)无显著差异。

**结论**:r16 的头号嫌疑(seen_rise 级的 re-arm 相位竞态)**被证否**。要么 re-arm 不是病根,要么相位
竞态比 seen_rise 更深(采样器整条流水线相对 TRACECLK 的相位,不只是起始门)——但后者用 cap_clear 也
该缓解却没缓解,所以更可能 re-arm 不是主因。

### 12.3 软件版 E0 失败(印证 r16 警告)

err_classify.py 想用 loop 周期性把坏捕获对齐到好捕获做逐 lane/逐 a-b 错误分类。但两个**不同会话**捕获
在本地对齐窗口之后迅速 desync(69% 失配),per-lane 数被错位主导,不可信。**坐实 r16:E0 必须同会话 LA。**

### 12.4 剩下的判别实验都需要硬件介入(交给用户)

无硬件的实验已做尽(读出/CDC/glitch lockout/clean-start/EYE扫/SELFTEST/频率扫)。剩下能定锤的:
- **E0(同会话 LA+FPGA 逐 nibble diff 分类)**:需 LA 接到 trace 线、与 FPGA 同时抓同一段。这是定性
  "错误长相(偏 lane=skew / 偏 a-b=duty / 均匀=亚稳)"的唯一可靠手段。
- **E2(物理回环 SELFTEST)**:FPGA 输出脚发干净 ramp → 短线回环 → trace 输入脚采。区分"FPGA I/O 路径
  (IBUF/IDELAY/反射/duty)" vs "STM32 信号"。需接一根回环线。
- **E3(FPGA 自测真实 TRACECLK 占空比)**:纯 RTL,加 ref 计数器测 FPGA 输入脚处 TRACECLK 高/低拍数
  直方图——这个**我能自主做**,正面验证"FPGA 脚 duty ≠ LA 探头 duty"这个未验证前提。下一步优先做 E3。


## 13. E3 实测:FPGA 输入脚处的 TRACECLK 半周期 dwell

自主做了 r16 的 E3(纯 RTL,无需 LA):在 trace_capture_a7 里用 ref_200m 计数同步后 TRACECLK
(tck_sync[2])的高/低半周期 dwell(单位 5ns),min/max/sum/cnt 经状态寄存器 NB+4.. 读出
(`decode/duty_probe.py`)。

**关键发现(可靠)**:/64(1.31MHz)下,高、低半周期 dwell:
- **max = 77 cyc = 385ns**(= 正确半位 ✓)
- **min = 1 cyc = 5ns** ← **存在 5ns 级的超短半周期(runt/毛刺)**

LA 在 50MSa/s(20ns 分辨率)**根本看不到 5ns 的 runt**——这解释了为什么 §29 LA 测 TRACECLK"边沿
干净、占空比 50.0%"却仍有间歇坏:**真实存在亚 LA 分辨率的短毛刺/亚稳态双采**,落在同步后的时钟上。
注:duty 计数器测的是 raw `tck_sync`(未经 LOCKOUT),所以它看到的是 LOCKOUT 之前的毛刺——LOCKOUT=4
能滤掉 1 cyc 的 runt,但这证明了"毛刺源真实存在",且若有 5–10 cyc 的中等毛刺可能漏过 LOCKOUT。

**不可靠**:avg/sum 数值异常(疑似 idle gap 时 TRACECLK 停拍产生超长 dwell 使 16-bit dwell 计数器
回绕、污染 sum;min/max 不受影响仍可信)。duty% 因此暂不可信,待修(dwell 计数器加饱和、或排除 idle)。

### 13.1 这条线索的意义

- 坐实了"真实信号上有亚 LA 分辨率的时钟毛刺/亚稳态",这是间歇坏的强候选物理来源。
- 但还没证明这些毛刺就是那 7–10% 的直接原因(需要把毛刺事件与坏捕获时间对齐,或加更强去毛刺看 yield)。
- **下一步可自主**:把 dwell 计数器加饱和修好 duty,并加一个"短 dwell(<LOCKOUT 比如 <8 cyc)计数器",
  统计每个捕获里漏过 LOCKOUT 的中等毛刺数,与该捕获 好/坏 关联——若坏捕获的中等毛刺数显著更高,
  就把根因钉死在"毛刺漏过 LOCKOUT"。
- **需要硬件**:E0(同会话 LA 逐 nibble 分类)、E2(物理回环)仍是定性"偏 lane/偏 a-b/均匀"的金标准。


## 14. 真根因找到:捕获起始瞬态(前 ~7.5KB),其余永远干净

### 14.1 关键否证 + 决定性发现

- **E3b 中等毛刺计数**:好/坏捕获的 glitch_cnt 都 ≈0(median 0,max 1)→ "毛刺漏过 LOCKOUT"假说**否证**。
- **逐 nibble 值分布**:坏捕获 gc22 与好捕获 gc25 的 a/b nibble 值分布**几乎完全相同**(逐项差 <0.2%)
  → 坏捕获的原始字节值**没坏**,问题在去帧/对齐,不在采样值。
- **分块解码(决定性)**:把坏捕获切 8 块独立解码——**chunk0(前 7680B)脏 9.8%,chunk1–7 全 0.00%**。
  两个坏捕获(gc20/gc22)**都是同一模式:只有第一块脏,其余完美**。
- **验证修复**:丢掉前 8KB 再解码,两个坏捕获 → **0.000% / 0.009%,33 锚点**。

### 14.2 真根因

间歇性 ~7–10% 坏**不是**:毛刺/SI/采样相位/re-arm 相位竞态/纯亚稳态/读出(全部已逐一否证)。
**而是**:**捕获起始的前 ~7.5KB 是瞬态垃圾**(re-arm 后采集偶尔从 TPIU 帧中间开始 / 帧锁定前就开始写),
之后永远锁定干净。约 70% 的捕获 chunk0 恰好干净起步 → 全程 0%;约 30% chunk0 起步未对齐 → 前块脏、
污染全局 phase 选择 → 看起来"整段坏"(其实只有头坏)。

这也解释了之前所有困惑:双峰(chunk0 对齐与否是二值)、"均匀脏"(脏的头块拖低全局 phase 使整体看着均匀)、
频率相关(高频帧密、起始未对齐的字节数占比变化)、SELFTEST 永远干净(内部源相位固定,每次都对齐起步)。

### 14.3 修正:不是单纯起始瞬态,是**散布的 ~1KB 脏窗口**(可恢复)

skip 8KB 后良率仍 90%。细查(4KB 滑窗精确扫描,不靠粗分块):坏捕获的脏不只在起始——例如 yt18 在
offset 8192 脏、9KB–21KB 干净、**22KB 又脏 10%**、之后恢复。即**每隔一段出现一个 ~1KB 脏窗口,解码在
每个脏窗口后都能自动重新锁定**。之前"只有 chunk0 脏"是 8-分块太粗 + 全局 phase 被任一脏窗口拖低造成的
假象(又一次粗粒度测量误导,记录在案)。

**真实画像**:原始字节值正常(分布与好捕获一致),偶发 ~1KB 局部去帧失锁窗口,散布在捕获各处,每个窗口
后自动恢复。固定 skip 不可靠(窗口位置/长度可变)。

### 14.4 修复方向(更新)

- **解码侧(本质,推荐)**:TPIU 去帧做**局部重锁**——遇到一段解不动就前跳找下一个帧边界重新锁定,
  不让单个脏窗口污染全局 phase 选择。这样无论脏窗口散布在哪都能跳过、保留其余干净数据。
- **采集侧**:start-on-sync 仍有益(消除起始那个窗口),但解决不了中段散布窗口。
- 固定 lead-in skip:**否决**(窗口可变,不可靠)。

下一步:实现解码侧局部重锁 deframe,用 yield_test 验证良率→100%(按"可恢复字节数/锚点全中"判定)。
