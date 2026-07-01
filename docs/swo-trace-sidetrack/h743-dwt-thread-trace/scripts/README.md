# H743 DWT 线程追踪脚本

STM32H743 + NuttX 零侵入线程切换追踪的可复现脚本。完整背景与结论见上级 `../README.md`。

## 硬件 / 环境前提

- STM32H743ZI + DAPLink（CMSIS-DAP），**SWO 接 PB3**，SWD 接 PA13/PA14，共地
- NuttX 固件启用 SEGGER RTT（脚本通过 RTT 发命令触发线程切换；无 RTT 也能跑，只是不主动触发）
- Python：`pyocd`
- 工具链：`arm-none-eabi-nm`、`gdb-multiarch`（从 ELF 提取符号地址与 TCB 字段偏移）

## 脚本

| 脚本 | 用途 |
|------|------|
| `dwt_thread_trace.py` | 自包含：配置 DWT Data Trace + ITM + SWO，捕获 `g_running_tasks` 写入的 TCB 指针，解析并输出 CSV |

## 跑法

```bash
python3 dwt_thread_trace.py --elf /path/to/nuttx/nuttx --duration 12 --outdir ./out
# ELF 路径也可用环境变量：NUTTX_ELF=/path/to/nuttx python3 dwt_thread_trace.py
```

参数：

| 参数 | 默认 | 说明 |
|------|------|------|
| `--elf` | `$NUTTX_ELF` | NuttX ELF 路径（必需）|
| `--duration` | 12 | 捕获秒数 |
| `--outdir` | `.` | 输出目录 |
| `--nm` | `arm-none-eabi-nm` | nm 工具 |
| `--gdb` | `gdb-multiarch` | gdb 工具（提取 DWARF 字段偏移）|

## 输出

| 文件 | 内容 |
|------|------|
| `dwt_thread_trace.csv` | `ts_local,tcb_addr,pid,state,pri,thread_name` |
| `dwt_swo_raw.bin` | 原始 SWO 字节流 |

## 工作原理（简述）

1. `auto_init=False` 连接，释放 nRESET，手动 `board.init()`（避免 reset 清配置）。
2. 先写 `DBGMCU_CR` 使能 TRACECLKEN，再把 **PB3 显式配成 TRACESWO(AF0)**（重启/拔插后不依赖残留状态），然后配 DWT 比较器0（`FUNCTION=0x0D` 数据值写包）监控 `g_running_tasks`。
3. 配 ITM（本地时间戳）、SWO Trace Funnel、TPIU（禁 formatter）、SWO（NRZ）。
4. `resume` CPU，通过 RTT 发 `hello`/`uname` 等命令触发线程切换。
5. 读 SWO 流，解析数据值写包（TCB 指针）+ 本地时间戳包，按需读 TCB 身份（带缓存），写 CSV。

寄存器编码依据官方 ARMv7-M ARM (DDI0403E)，见 `../README.md` 第 3 节。

## 注意

- **SWO 必须物理接到 PB3**，否则捕获 0 字节。
- SWO 波特率由 `SWO_CODR` 决定，脚本已让 `swo_configure()` 与之匹配；改波特率两处要一致。
- 只读 TCB 身份用的是硬件捕获到的确切指针（定向读、带缓存），不是轮询 `g_running_tasks`。
