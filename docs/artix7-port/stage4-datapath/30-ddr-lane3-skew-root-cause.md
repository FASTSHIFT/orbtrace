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

## 根因（仿真确认）：la_ddr_writer 打包器 late-sample 组合字

用 `tb_prbs_cdc.v`（真实 axis_async_fifo + 真实打包器，纯功能仿真、零时序/零
亚稳态）**在仿真里 1:1 复现了硬件症状**：FIFO 裸弹出的字节流完全正确，但打包成
128-bit 字后，**每个字里 cap_bidx==9 那个字节被延迟 2 个字（32 字节），got=ref[i-32]**，
mod16 恒为同一位置。→ 故障不是时序、不是 CDC 亚稳态，是**打包器纯逻辑 bug**。

bug 在 `la_ddr_writer.v`：
```
wire [127:0] cap_word_full = cap_word_next;   // 组合
// FIFO 用 cap_word_valid（寄存器，晚一拍）当 tvalid 采样 cap_word_full
```
`cap_word_valid` 是寄存器，比第 16 个字节晚一拍拉高。在它拉高那一拍，如果又来了
第 17 个字节（`cap_valid_in` 高——正是数据经 trace_clk→cap_clk CDC FIFO 连续
背靠背流入的稳态），`cap_word` 已经把第 17 字节移入，`cap_word_next` 变成
bytes[1..16]+byte17，而不是 bytes[0..15]。存进 FIFO 的 128-bit 字因此错位，
一个字节位置带着 2 个字之前的旧值。

**为什么 ramp 测不出**：ramp 在 clk200 域注入，受 DDR 背压/间隙节流，`cap_valid_in`
不是连续高，几乎不触发"完成拍又来一字节"的碰撞；PRBS 经 CDC FIFO 以 200M 连续
背靠背弹出，每个字都碰撞。

## 修复

在完成拍（`cap_bidx==WORDS_PER-1`）把整字锁进 `cap_word_latched` 寄存器，
`cap_word_full` 改接这个寄存器而非组合的 `cap_word_next`。仿真验证：
`FIX_LATCH` 版 packed 流 0 错。

改动：`la_ddr_writer.v`（+ `tb_prbs_cdc.v` 复现/回归仿真）。

## 硬件回归结果（lane 修复已验证）

- 帧化 PRBS（`iddr-prbs 1`）：修复前每 16 字节坏，修复后干净跨度内 0 错。
- **真实 56M trace，A-sync 坏率 87.7% → 27.1%**；cortrace 解码从 786KB 处 fatal
  推进到 **7.7MB**（10×），begin/end 平衡 305617 对、max depth 11、解出真实函数。

## 仍存在的第二个缺陷（burst 边界 ±1024 错位）

PRBS 还暴露了一个独立的次级 bug，真实 trace 也受影响（残余 27% 坏 async / 7.7MB
处 fatal 的来源）：

- **低速（10M）表现**：ring streamer 把每个 1024B burst 发两遍（相邻包字节完全相同，
  seq 仍 +1）。纯低速 ring 饥饿：drain 快于 slow writer 填充。56M 下 packet 重复=0。
- **56M 表现**：偶发 burst 边界错位——某包头部 32 字节（=2 个 128-bit 字）来自
  "下一 burst"，随后回跳 **−1024**（正好一个 burst）到正确位置。signature：
  `pkt = ref[a:a+32] 然后 ref[a-1024:...]`。
- 嫌疑：`la_ddr_writer` 的突发 staging（`wbuf`/`out_idx` 组合读 `ddr3_wr_data`，
  W_RUN→W_DONE 的 out_idx wrap）或 streamer R_NEXT→R_START 边界多吐 2 个字。
- 行为级 MIG 仿真（tb_la_ddr_ring TEST E, CAP_DIV=40）**未复现**——触发点在真实
  MIG 读时序（`app_rd_data_end`/`ddr3_rd_data_vld` 节拍），需真实时序或更精确的
  MIG 模型才能仿真定位。

## 标准方案：用成熟 IP 替换手搓打包器（已做）

不再手写"移位打包 + 独立 async FIFO"，改用 verilog-ethernet 的
`axis_async_fifo_adapter`（S_DATA_WIDTH=8 → M_DATA_WIDTH=128），一个经过验证的
块同时完成 **8→128 位宽转换 + cap_clk→ui_clk CDC**，由它自己管 tvalid/tkeep，
从根上消除"数据 vs valid 差一拍"这类 bug。注意 adapter 是小端（首字节进 LS lane），
下游是大端，故对 128 位输出做字节反转保持线上字节序不变。

硬件验证（`trace_ddr_stream_stdip.bit`，56M PRBS）：
- **lane-3 skew 消失**：不含 burst 边界毛刺的包 100% 逐字节正确（每 16 字节错误清零）。
- **低速重复消失**：相邻包重复 = 0。
- 回归：`tb_la_ddr_ring` A–E 全过。

## 仍存在：−1024 burst 边界跳变（第二 bug，独立于打包器）

标准 IP 修好了打包器，但暴露出**另一个独立缺陷仍在**：约一半的包，开头 2 个字
（32 字节）来自"下一个 burst"（payload_ref 位置 +? ），随后回跳 **−1024**（正好
一个 burst/一个 packet）到正确位置。signature：`pkt = ref[s:s+32]` 然后
`ref[s-1024+32:...]`。1750/3500 非跨界包中招。

这不在打包器（已用标准 IP），在 **DDR ring 读路径**（`la_ddr_ring_streamer` /
`ddr3_rd_ctrl`）：每个读 burst 的头 2 个 beat 疑似是上一次读残留/预取。方向：
查 `ddr3_rd_data_vld`（=valid&end）与 streamer R_RUN 首拍捕获的关系，读数据流水
延迟是否让首 2 拍落到错误 burst。

## 下一步
定位读 burst 头部 2-word 错位：检查 ddr3_rd_ctrl 的 `app_rd_data_valid`/
`app_rd_data_end` 与 streamer 首拍 f_wr_data 捕获时序；或在 tb_la_ddr_ring 用
non-ramp（位置编码）源 + 精确读延迟模型复现。

## 现存改动（未 commit）
- `trace_capture_a7.v`：加 `test_src_en` + 帧化 xorshift32 PRBS 源（诊断用，
  CSR 0x0D 门控；正常抓取时 =0，走真实 IDDR）
- `trace_ddr_stream_top.v`：CSR 0x0D `iddr_prbs_125` 接线
- `trace_ctrl.py`：`iddr-prbs` 子命令；`prbs_check.py`：帧化校验器
- 固件：`PLL_R_OVR=22`（10M 诊断态）、boot 默认 selftrace——**这两个是临时诊断态，
  查完要回退到 R=4 / 正常**
