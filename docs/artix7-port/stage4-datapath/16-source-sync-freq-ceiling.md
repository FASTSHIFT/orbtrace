# Stage-4 · 源同步 IDDR 采集频率上限实测

> 日期：2026-07-18
> 方法：CURTPM AA/55 已知图案 + IDDR 源同步捕获（CAP_METHOD=IDDR, CAP_RAW=1）
> 频率控制：CPU halt + runtime 改 PLL1 DIVN1/DIVR1（`target/set_pll_n.cfg`，
>           不重烧 firmware）。频率用 FPGA 200MHz timebase 数字节率实测（无混叠）。

## 结论（先给）

**这套硬件（飞线 + 47R 串阻 + GND 双绞）源同步 IDDR 采集在实测可达的最高
TRACECLK = 197.8 MHz 下仍 0.002% 误码，眼图开 7/9 个 IDELAY tap。而且这不是
FPGA 采集的上限——是 STM32 的 PLL1 VCO 先到顶（当前 ref/RGE 配置下 VCO 最高
~198MHz），频率随 DIVN1 上升到 N=31 达峰后回落，是典型 VCO 撞顶行为。**

即：**采集链不是瓶颈**。197.8MHz DDR = 395 Mbps/lane × 4 lane = 1.58 Gbps 总
线速率，源同步捕获零误码。远超 F429 的 84MHz 和上游 orbtrace ECP5 的能力。

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
