# 25 — 频率 + eye 扫描：残留错误是单条数据 lane

日期：2026-09-07
前端：`trace_ddr_stream_direct.bit`（USE_IDELAY=0，忠实照抄上游 IBUF→IDDR）。
STM32 selftrace 循环。112M+IDELAY 已退役（按用户 + doc 23/24）。

## 重要前提更正：当前 bitstream 就是"边沿直接采"，没有偏移

综合日志确认 direct bitstream 里 `trace_capture_a7` 绑定的是
**CAP_METHOD=IDDR**（不是 OVERSAMPLE）：

```
Parameter CLK_BUF  bound to: BUFR_IO
Parameter CAP_METHOD bound to: IDDR
Parameter EYE_DELAY bound to: 4
u_capture | g_iddr.u_cdc_fifo/mem_reg   <- 网表里是 g_iddr 分支
```

也就是说，出厂路径正是最朴素的做法：

```
TRACECLK 边沿 --(IDDR 原语,Q1=上升沿 Q2=下降沿)--> 4-bit 半字节对
   --> {下降沿nibble, 上升沿nibble} 组成 1 字节
   --> gray-code 异步 FIFO (trace_clk -> ref_200m, 原子跨时钟)
   --> la_ddr_writer -> DDR3 ring -> streamer -> UDP
```

**没有任何 eye 偏移。** EYE_DELAY / CSR 0x01 只服务于 **OVERSAMPLE** 方法，而
OVERSAMPLE 那一整块（边沿检测、glitch lockout、双向 EYE 倒计时、mid-eye latch）
在这个 bitstream 里被 `generate` 整块裁掉，根本没进网表。它是早期为"模仿逻辑分析仪
边沿+N 采样"留下的、当前用不到的代码。既然 IDDR 已经能在边沿直接采，就不需要它。

> 副带纠正：IDDR 分支源码里那句"只对 center-aligned 源正确，STM32 是 edge-aligned"
> 是早期误解留下的旧注释。doc 23 已实测在这些频率下 STM32 数据是 center-aligned
> （时钟边沿落在数据眼中心），所以 IDDR 恰恰是对的选择。

## 测了什么

用解码器自带的 `diagnose_bitflip` 给出诚实错误率：ETM Atom header 紧跟一个
*reserved* 字节（非法 ETMv4 编码 = 坏字节）的比例，以及翻转 bit 6（0x40）能否把
它恢复成合法 Atom header。

每个点：direct bitstream，`stream_grab` 3 秒，取 2 MB 切片用 `recover_assemble`
（自动选中 parity=0 order=0）→ `T.deframe` → `diagnose_bitflip`。

### 频率扫描（eye = 默认 4，但 IDDR 模式下无效）

| TRACECLK 引脚 | 数据率 | reserved%（坏） | bit6 可恢复 |
|--------------|--------|----------------|------------|
| 56.25 MHz (R=4)  | 111 MB/s | 18.1% | 100% |
| 28.13 MHz (R=8)  | 55 MB/s  | 6.5%–11% | 100% |
| 14.06 MHz (R=16) | 28 MB/s  | 11.0% | 100% |

* 每次 R 翻倍数据率减半——证明 trace 时钟确实变了（另经 SWD 读 RCC PLL1DIVR 独立
  确认：0x03030423→R=4，0x07030423→R=8，0x0f030423→R=16）。
* 错误率 vs 频率**非单调**（56→28 变好，28→14 变差），所以不是简单的边沿速率 SI。
* 28 MHz 在不同 run 之间不稳定：第一次烧 R=8 后紧接的一次采集，四个 40 MB 窗口都是
  干净的 6.5%；而在切到 14M 又切回来之后——包括一次完整 FPGA 重载 + STM32 复位——
  每次都读到约 11%。6.5% 是一次侥幸的 lane 对齐，没能复现。28 MHz 可信数值约 11%。

### eye 扫描（28 MHz，CSR 0x01 = 1..9）

| eye | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|-----|---|---|---|---|---|---|---|---|---|
| reserved% | 10.97 | 11.04 | 11.05 | 10.92 | 11.05 | 11.07 | 11.01 | 11.02 | 11.03 |

**完全平。** 因为当前 bitstream 是 IDDR，`EYE_DELAY`/CSR 0x01 根本没接线——这个扫描
从一开始就没意义。它反过来确认了上面的前提：出厂路径不带偏移。

## 唯一铁一样稳定的信号

**100% 的坏字节都能靠翻转 bit 6 恢复**，在每一次采集、每个频率下都成立（全局翻
bit 6 会把流打烂，说明污染是**稀疏的逐周期**错误，不是恒定偏移）。

bit 6 映射到一条具体的物理 lane。当前选中的 `assemble(parity=0, order=0)`：
`byte = (下降沿nibble << 4) | 上升沿nibble`，每个 nibble 的 bit b = data lane b
（`d0 | d1<<1 | d2<<2 | d3<<3`）。所以 **byte bit 6 = TRACED2（STM32 PE5）的
下降沿采样**。一条 lane，在一个 DDR 相位上，间歇性出错。

## 结论 / 下一步

残留 trace 错误是 **TRACED2 下降沿采样的单 lane 采集故障**，不是频率、eye、或数据
通路问题。杠杆按优先级：

1. **物理**：TRACED2（PE5）飞线/探针搭接的完整性——线长、stub、地回流。这条 lane
   的下降沿眼在别的 lane 都正常的地方偏偏是临界的。单 lane 故障几乎总是接线，不是
   芯片。
2. bit6 这个知识可以在**测量时**做一次校正，但按项目规矩（measure don't fix），我们
   不在解码器里遮盖硬件故障。
3. 拿示波器专门对比 PE5 vs PE3/PE4/PE6 的下降沿（lane_eye_check.py），从物理上确认
   这个 lane 的不对称。

### 顺带的死代码清理建议
既然出厂就是 IDDR、OVERSAMPLE 从不使用，`trace_capture_a7.v` 里的 OVERSAMPLE 分支
（约 g_oversample 整段）、`eye_delay_rt` 端口、CSR 0x01、以及 `eye_sweep.py` 都可以
删掉，减少混淆。见下一步减法工作。

### 新增工具
* `scripts/eye_sweep.py` —— 在当前频率扫 CSR 0x01、报每个 eye 的 reserved%（无需
  重烧）。**注意：仅在 CAP_METHOD=OVERSAMPLE 的 bitstream 上有意义；IDDR 版恒平。**

### 复现
```
# 频率：用 R 分频重编固件、烧录、验 RCC
make clean && make -j4 OPT=-O0 EXTRA_CFLAGS="-DPLL_R_OVR=8"
openocd ... flash write_image erase build/H743_Blink.hex
# 读 RCC PLL1DIVR: mdw 0x58024430  (R = ((val>>24)&0xF)+1)

# 单次测量
python3 -c "import opencsd_etm4_run as R; raw=open('cap.bin','rb').read()[:2<<20]; \
  _,p,o,d,_,_,_=R.recover_assemble(raw,2); e,_=R.T.deframe(d,want_stream=2); \
  print(R.diagnose_bitflip(e))"
```

---

## 更新（2026-09-07 晚）：修 I/O 补偿单元 + 纠正机理

### 修复：SYSCFG I/O 补偿单元没使能（真固件 bug）

`etm_selftrace.c` 把 PE2..PE6 的 OSPEEDR 设成了 very-high（0b11），但 H7 上
very-high pad 只有在 **SYSCFG_CCCSR.EN** 使能后才达到额定压摆率；否则退回慢速默认
驱动。固件从来没开这个补偿单元。加上：clock SYSCFG（RCC_APB4ENR.SYSCFGEN）→ 置
`SYSCFG_CCCSR.EN` → 等 READY。

示波器实测（56 MHz pin，半 UI = 8.8 ns，CH2=PE5）：

| | 修前 | 修后 |
|---|---|---|
| PE5 上升 | 5.47 ns | **2.8 ns** |
| PE5 下降 | 3.25 ns | **2.4 ns** |

边沿几乎砍半，上升/下降也对称了。**这是个真 bug，值得修**（对 PE2..PE6 全部生效）。

### 但：解码错误率几乎没变 —— 上面的"慢边沿眼闭"假设被推翻

补偿单元开启后重抓 56M：

| | reserved% | 可恢复 |
|---|---|---|
| 修前 56M | 18.1% | 100% bit6 |
| 修后 56M | **17.5%** | 100% bit6 |
| IDELAY(tap2) 56M | 18.8% | 100% bit6 |

边沿砍半、错误率纹丝不动（3 个窗口 17.3–17.6% 稳定）。per-lane 数据 IDELAY 也无效。
**如果是压摆率导致的眼闭，边沿砍半应该大幅开眼——没有。所以不是 SI 压摆问题。**

### 纠正后的机理：TRACED2 下降沿采样 stuck-at-0

对每一个候选单 bit 翻转统计"reserved-after-atom 变合法"的数量：**只有 0x40 有效**
（10418 个），其余 bit 全 0。再看方向：

* 坏字节 bit6=1 应为 0：**0 个**
* 坏字节 bit6=0 应为 1：**10418 个（100%）**

**单向 stuck-at-0**，不是随机翻转（随机翻转/慢边沿会双向大致均匀）。

bit6 = 下降沿 nibble 的 bit2 = **lane2（TRACED2）的下降沿（IDDR Q2）采样**。同一
lane 的上升沿采样（bit2 / 0x04）完全干净。也就是：

> TRACED2 的**下降沿** DDR 采样约 17% 概率把真值 1 读成 0；上升沿采样正常。

STM32 引脚两个相位是同一个驱动、示波器边沿也干净（2.8 ns），所以问题在 **FPGA 侧
lane2 的下降沿捕获路径（IDDR Q2 的 hold/相位）**，不是 STM32、不是压摆、不是数据
IDELAY。已测两个杠杆（补偿单元压摆、per-lane IDELAY）都无效，停止试错。

### 下一步候选（未验证）
* clock-lane IDELAY（tap_clk）移动采样时钟相位——下降沿 hold 问题可能对时钟相位敏感，
  而对数据 IDELAY 不敏感（数据两相位一起动，时钟只动一边的相对关系）。
* 检查 lane2 IOB 的布局/约束是否与其它三条不对称（set_input_delay / IDELAY_GROUP）。
* 直接示波器测 PE5 下降沿相对 TRACECLK 的 hold 窗口 vs 其它 lane。
