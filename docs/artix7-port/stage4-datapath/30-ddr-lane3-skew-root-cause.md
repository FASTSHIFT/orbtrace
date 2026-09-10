# 30 — 根因锁定：DDR 数据通路 byte-lane 3 延迟 2 个字（不是 IDDR，不是时序）

日期：2026-09-10

## 结论（决定性）

长期的"变化数据解不出、静态图案完美"的根因是：**128-bit DDR 数据通路里第 3
号字节 lane（byte position 3 mod 16）比其余 15 条 lane 延迟了整整 32 字节
= 2 个 DDR 字**。其余 15 条 lane 完全正确（delay 0）。

这不是 IDDR 采样问题，不是信号完整性，不是 CDC FIFO 丢字节。

## 怎么定位的：帧化 PRBS 压测

关键实验设计（用户建议加固定同步帧）：

1. **降频排除时序**：TRACECLK 56M→10.2M（固件 `PLL_R_OVR=22`，sysclk 不变），
   坏率几乎不变 → 逻辑 bug，非时序。
2. **ramp 排除大部分传输链**：clk200 域 +1 ramp 经 DDR→UDP，223MB 零错——但它
   在 la_ddr_writer 的字节打包**之后**注入，覆盖不到 IDDR 和 byte-lane 打包。
3. **帧化 PRBS 精确定位**（CSR 0x0D，`trace_capture_a7` 内 trace_clk 域）：
   在 **trace_clk 域**生成 xorshift32 PRBS，走**与真实 IDDR 采样完全相同的
   CDC FIFO + DDR ring + gearbox + packetiser + UDP**，只跳过 IDDR primitive 本身。
   每 8192 字节一个块，块首 8 字节固定 marker + PRBS 重播种，主机据此锁定并逐字节比对。

## gdb 级证据（每 lane 延迟测量）

```
lane : best byte-delay (got[i]==ref[i-d])
   0..2 : delay=0   match=59/59
   3    : delay=32  match=59/59   <-- 唯一异常
   4..15: delay=0   match=58/58
```

lane 3 的字节 = `ref[i-32]`，即它输出的是 **2 个 128-bit 字之前**同一 lane 的
旧数据。命中率 59/59 完美，说明是确定性的固定延迟，不是随机丢字节。

**复现两次，坏 lane 的 payload 位置会变（第一次=3，第二次=7）**：因为 marker
(blkpos=0) 落在相对 DDR 16 字节字栅格的不同相位（抓取窗口起点不 16 对齐）。
不变量是：**每个 128-bit DDR 字里恰好有一个固定的物理字节位置，输出的是 2 个字
之前的旧值**；其余 15 个字节位置完全正确。position 3 vs 7 只是 payload 索引相对
物理字位置的相位差。

这个"某一物理字节位置延迟 2 个字"的特征，指向 **wbuf 突发缓冲 / ddr3_wr_data
组合读 out_idx / MIG app_wdf 的某个字节 lane 多打了流水**，而不是 IDDR。

## 为什么之前所有"干净"测试都测不出

- **静态 TPIU 图案（AA/55、walking-1）**：每个字都一样，lane 3 延迟 2 个字
  读出的还是同一个值 → 完全隐形。这就是"采集链 100% 干净"的假象来源。
- **真实 ETM trace**：每字节都在变，lane 3 拿的是 2 字前的旧字节 → 每 16 字节
  错 1 个，正是"变化数据坏、静态数据好"的精确特征。
- **A-sync 长零游程**：对单 lane 错位最敏感，所以最先崩。

## 下一步：修 RTL

在 128-bit DDR 写/读通路里找 lane 3（byte 3）比其它 lane 多一级/两级寄存器的
地方（la_ddr_writer 的 byte→128b 打包，或 ring streamer 的 128b→8b gearbox，
或 MIG 用户接口的某个 byte lane 接线）。定位后对齐该 lane 的流水级数。

## 现存改动（未 commit）
- `trace_capture_a7.v`：加 `test_src_en` + 帧化 xorshift32 PRBS 源（诊断用，
  CSR 0x0D 门控；正常抓取时 =0，走真实 IDDR）
- `trace_ddr_stream_top.v`：CSR 0x0D `iddr_prbs_125` 接线
- `trace_ctrl.py`：`iddr-prbs` 子命令；`prbs_check.py`：帧化校验器
- 固件：`PLL_R_OVR=22`（10M 诊断态）、boot 默认 selftrace——**这两个是临时诊断态，
  查完要回退到 R=4 / 正常**
