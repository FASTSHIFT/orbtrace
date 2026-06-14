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
