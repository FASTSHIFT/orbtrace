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
