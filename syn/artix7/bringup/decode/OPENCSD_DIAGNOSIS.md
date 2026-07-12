# OpenCSD ETMv4 交叉验证：采集链系统性 bit-error 定位

**日期**：2026-07-12  
**捕获**：`/tmp/nc50_2m.bin`（CPU 50 M / pll1_r_ck 150 M / TRACECLK pin 50 M / cache OFF / 2 MB 原始）

## 结论

OpenCSD（ARM 官方参考解码器）跑起来了，但**看到的字节流里有 ~30 % 的 header-position bit-error**。这些 bit-error 是**采集链问题，不是 mortrall 或 OpenCSD 的问题**。

## 关键实测数据

### 阶段流量

| 阶段 | 字节数 | 说明 |
|------|--------|------|
| 原始 `{a,b}` 流 | 2,000,000 | 50 MHz × 20 ms × 2 lane |
| 半字节组装（parity=1 order=0） | 1,999,998 | 唯一收敛出 A-sync 的组合 |
| TPIU deframe | 149,742 | 只保留 stream-2（ETM） |
| A-sync 对齐修复 | 149,736 | 丢 6 字节 stray |

### A-sync/Trace-Info 完整性

- 13 个 A-sync
- 6 个 A-sync 之后要额外**丢 1 字节**才能对齐到 Trace-Info（0x01）
- 修复后 10 个 A-sync 直接紧跟 Trace-Info；剩 3 个内容仍有噪声

### 关键指标：Atom 后一字节

Atom 包是 no-payload 单字节，下一字节**必是新 header**。这给了一个**清晰的 header-position 观测点**：

```
after-Atom next byte: 60,360 次
  合法 header:        ~70 %
  strict-reserved 头: 29.5 %  ← 17,804 次
    其中 100 % 都能靠 XOR 0x40（bit6 翻转）变回合法 Atom
```

**换句话说：所有 header-position 错误都集中在 bit6 上**。

### 错误字节分布

| 错误值 | 次数 | XOR 0x40 | 目标 |
|--------|------|----------|------|
| 0x97 | 9,112 | 0xD7 | Atom-F5 |
| 0x9F | 6,920 | 0xDF | Atom-F5 |
| 0x99 | 1,024 | 0xD9 | Atom-F2 |
| 0x84 | 324 | 0xC4 | Atom-F6 |
| （其它） | ~400 | | Atom-F6/F5/F2 |

## 诊断结论

采集链上有一根信号（几乎肯定就是**TRACE_D2 或 D2 的 IDDR 采样窗**）在 30 % 的 TRACECLK 周期上把 bit6 送错了。翻位就能变回合法，不是随机噪声，是**稳态相位错**。

## 补丁验证

`opencsd_etm4_run.py --repair-bit6`：把所有 Atom→reserved 的下一字节 XOR 0x40。

**只修 header 位有效但不彻底**：因为 payload（address / cyct）也走同一根 lane，同样被同一根线的 30 % 位错破坏。所以尽管修好了 18,647 个 header，OpenCSD 依然出：
- 4 个 CYCLE_COUNT
- 2 个 PE_CONTEXT（内容错——`EL2S`）
- 2 个 ADDR_NACC（0x80028 应该是 0x08000028，说明地址包高位丢了 `0x08`）
- **0 个 INSTR_RANGE**

## 下一步的选择

### 选项 A：源头修（**推荐**，用户偏好这条路）

TRACECLK-direct 前端里检查 IDDR 采样对每根 trace data lane 的相位；很可能 D2 需要单独 IDELAY tap 校准。

**行动**：
1. 在 FPGA 侧的 `trace_capture_direct.v` 里，为每根 TRACE_D[0..3] 加独立 `IDELAY2` tap
2. 校准脚本：跑 known-pattern（Trace-Info 后的可预测 Atom 序列），扫 tap 找 0-error 窗口
3. 用 proposal 32 的板载 LA 抓 raw pin，直接测每根线的 setup/hold

### 选项 B：软件补丁（快速验证解码 pipeline 通不通）

在 `--repair-bit6` 基础上再加：
- payload 字节的 bit6 修复（需要 packet-aware 修复，因为 payload 无 "next-must-be-header" 约束）
- 全流启发式：连续 3 字节都能 XOR 0x40 恢复到常见 Atom pattern 就修

### 选项 C：换固件配置降 lane 数

TRACE port 从 4-lane 降到 1-lane（TPI_SPPR = manchester/UART SWO），出错就变成单 lane 稳定性——但吞吐降 4 倍。

## 生成物

- `orbtrace/syn/artix7/bringup/decode/make_opencsd_snapshot.py` — 已加 ETMv4 支持
- `orbtrace/syn/artix7/bringup/decode/opencsd_etm4_run.py` — 端到端 pipeline
- `read_h743_etm4_regs.sh` — 通过 openocd 实测 ETMv4 寄存器
- `/tmp/ocsd_run3/etm.bin` — 149,742 B 干净 ETM 数据
- `/tmp/ocsd_run4/etm.bin` — 同上 + bit6 修复
- `/tmp/ocsd_run{3,4}.log` — trc_pkt_lister 完整输出

## 实测的 ETMv4 寄存器（H743 板上，openocd）

| Reg | Val | 说明 |
|-----|-----|------|
| TRCIDR0 | 0x080006E1 | 无 branch broadcast、无 data trace |
| TRCIDR1 | 0x4100F401 | ETMv4.1 |
| TRCIDR2 | 0x00000004 | IA size 32-bit |
| TRCIDR8 | 0x00000001 | Max spec depth = 1 |
| TRCIDR12 | 0x00000001 | 1 counter |
| TRCTRACEIDR | 0x01 | trace ID = 1 |
| TRCCONFIGR | 0x00000000 | 读时被 openocd 复位；采集时非 0 但必为极简 |
| TRCAUTHSTATUS | 0x000000C0 | Non-secure invasive+non-invasive enabled |
