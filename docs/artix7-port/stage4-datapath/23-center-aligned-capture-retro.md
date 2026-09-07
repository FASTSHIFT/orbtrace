# Stage-4 · 采集相位复盘：TPIU 数据是 center-aligned，IDELAY/MMCM 全是弯路

> 日期：2026-09-07
> 结论一句话：**STM32H743 TPIU 并口输出的数据相对 TRACECLK 是 CENTER-ALIGNED**
> （数据跳变落在离时钟边沿半个 UI 处，时钟边沿正好在数据眼中心）。
> 因此 **IDDR 直接在 TRACECLK 边沿采就命中眼中心**，我们做的 IDELAY tap 扫描
> 和 MMCM 90° 相移两套机制**都是基于一个错误的 "edge-aligned" 假设**，属于
> 不必要的复杂度。

---

## 1. 实测证据

`phase_check.py`（已删的一次性脚本）直接读 CH1(TRACECK)+CH2(TRACED) 的**原始
模拟波形**（无 LA、无 `LA_SAMPLE_FRAC` 软件偏移），在 1.65V 阈值做插值过零，
统计每个数据边沿到最近时钟边沿的距离：

```
pin 时钟 28.2 MHz (= pll1_r_ck 56.25MHz / 2)
数据边沿到最近时钟边沿的中位距离 = 0.84 个半 UI
=> CENTER-ALIGNED：时钟边沿在数据眼中心
```

对照两个采集前端上板抓的 raw（56 MHz 档，0.2s）：

| 前端 | recover_assemble 后 FSYNC | 说明 |
|------|--------------------------:|------|
| `trace_capture_a7`（IDELAY tap=2） | ~同量级 | raw 头字节 `f7ff…`，与 direct 同构 |
| `trace_capture_direct`（无 IDELAY） | 20538 | 加不加 IDELAY 一样好 |

**两个前端 raw 逐字节同构** → IDELAY 对结果零贡献，坐实"时钟边沿本就在眼中心"。

三方独立路径在 56 MHz 都恢复出真 ETMv4 A-sync：

| 路径 | ETM 字节 | A-sync |
|------|---------:|-------:|
| Golden (ETF-DAP over SWD) | 4096 | 4 |
| FPGA (direct bit, 0.2s) | 6.36 MB | 459 |
| LA (STM32 pin) | 9.7 KB | 9 |

---

## 2. 错在哪

历史文档（`trace_capture_a7.v` 注释、doc 14 §21、doc 16）反复写：

> "The STM32 TPIU is EDGE-aligned (ARM CoreSight TRM: traceclk edges are not
>  offset from data edges), so IDDR samples right on the data transition."

**这是误读。** 实测 STM32H743 的 TPIU 是 center-aligned（TRACEDATA 相对 TRACECLK
setup/hold 对称，跳变居中）。基于错误假设衍生了两套机制：

1. **IDELAYE2 per-lane tap 扫描**（`iddr_tap_sweep.py` / `freq_ceiling_sweep.py`）：
   给数据线加延迟把采样点"推进眼中心"。但眼中心本就在时钟边沿，tap 扫描
   只是在把一个已经对的相位挪来挪去，还引入了**频率耦合**（tap 是固定 ps 延迟，
   换频率就要重扫）。
2. **MMCM 90° 相移采样时钟**（`trace_capture_mmcm.v` / `trace_mmcm_stream_top.v`）：
   生成移相 90° 的采样时钟"落到眼中心"。同样是解决一个不存在的问题，还带来
   低频 MMCM 锁不上、PHASE 编译期锁死等新麻烦。

## 3. upstream orbtrace 早就是对的

`refs/orbtrace-upstream/orbtrace/trace/glue.py` 采集端就三行：

```python
DDRInput(clk=traceclk, i=tracedata[i], o1=trace_a[i], o2=trace_b[i])
```

**无 IDELAY、无相移**，直接在 TRACECLK 边沿双沿采。之所以行，正是因为数据
center-aligned + IOB 走线延迟让采样点落在眼内。我们的 `trace_capture_direct.v`
就是它的忠实 Xilinx 移植，上板验证等效。

所谓 "IDDRX1F 内建 90° 相移" 也是误解——普通 DDR 触发器，没有相移。

## 4. TRACECLK = pll1_r_ck / 2（顺带修正）

同一轮实测还纠正了一个频率换算错：pin 上的 TRACECLK = pll1_r_ck / **2**。
- R=2：pll1_r_ck 225MHz → TRACECLK pin **112MHz**
- R=8：pll1_r_ck 56.25MHz → TRACECLK pin **28MHz**（示波器实测 28.2MHz）

TPIU 并口 DDR：pin 时钟跑内部 bit-clock 的一半，数据双沿。`pll_ctrl_traceclk_hz()`
已修为 `pll1_r_ck / 2`。（此前一次重构误把 pll1_r_ck 当 pin TRACECLK，依据是被
采样率搞混的 LA 读数——已撤回。）

## 5. 行动项

- [x] `trace_capture_a7` 加 `USE_IDELAY=0` 旁路（IBUF→IDDR 直连），综合+上板验证
- [x] `pll_ctrl_traceclk_hz` 修为 /2
- [ ] **P1 减法**：确认 direct 前端在 112MHz 也 OK 后，删除
  - `trace_capture_a7.v` 的 IDELAY 分支 + `iddr_tap_sweep.py` / `freq_ceiling_sweep.py`
  - `trace_capture_mmcm.v` / `trace_mmcm_stream_top.v` / `trace_mmcm_top.v`
  - `eyescan_top.v` / `trace_pin_la_top.v` 等相位实验 top
- [ ] 独立战线（与采集无关）：cortrace/libopencsd 在 ~64-196KB 处 fatal，
  deframe 后仍掺 HSYNC `0xf7` 残留——PC 端解码质量问题。

## 6. 教训

**一个未经实测的物理假设（"edge-aligned"）繁殖出两套复杂子系统。** 复盘方法论
（AGENT.md §6）本该更早用示波器 raw 波形量一次相位——30 秒的实验，省掉几个月的
IDELAY/MMCM 弯路。center-aligned 这个结论用最原始的手段（CH1/CH2 原始波形过零
统计）一测即知，不依赖任何软件重组或猜测。
