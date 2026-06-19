# SWO Trace 支线脚本

这些是 STM32F429 SWO/ETM/ITM 实测中保留的代表性脚本（每类取最终可用版）。
完整背景与结论见上级目录 `../README.md`。

## 硬件/环境前提

- STM32F429ZI + J-Link（SWD，**NRST 必须接好**——stall 模式可能锁死 CPU，靠复位救回）
- CH343P（或其它 USB 转串口）接 **PB3 / TRACESWO**，共地
- `JLinkExe` 带 `-NoGUI 1`（抑制固件更新弹窗）
- orbuculum 用 fork 分支 `feature/ch343-swo-sparse-sync`（含 CH343 适配补丁），`meson setup build && ninja -C build`
- Python：`pyserial`、`capstone`、`pyelftools`；`arm-none-eabi-*` 工具链

## 脚本清单

| 脚本 | 用途 | 跑法 |
|------|------|------|
| `pb3_wiggle.jlink` | PB3 GPIO 方波自检（排查引脚/探针/接线/共地）| `JLinkExe -NoGUI 1 -CommanderScript pb3_wiggle.jlink` |
| `itm_paced.s` | 限速 ITM 写入循环（避免 FIFO 溢出丢数据）汇编源 | `arm-none-eabi-as -mthumb -mcpu=cortex-m4 itm_paced.s -o x.o` |
| `itm_bypass.jlink` | 纯 ITM over SWO（formatter **bypass**, NRZ）—— CH343 当 UART 直接解 | `JLinkExe -NoGUI 1 -CommanderScript itm_bypass.jlink`（常驻）|
| `etm_2m_forever.jlink` | ETM over SWO（2MHz, br_out=0, stall, formatter on），常驻挂住 | 同上 |
| `etm_6m_forever.jlink` | 同上 6MHz 版（CH343 顶格）| 同上 |
| `etm_sync.gdb` | 用 GDB + gdbtrace.init 配 ETM（频繁同步版）| `JLinkGDBServer ...` 后 `gdb-multiarch -batch -x etm_sync.gdb` |
| `mix_final.jlink` | ETM+ITM 混流尝试（降频）—— 实测 Simple TPIU **不支持**，留作反例 | — |
| `ch343_grab.py` | 从串口抓原始 SWO 字节 | `python3 ch343_grab.py /dev/ttyACM1 2000000 3 out.bin` |
| `csv3.py` | 逻辑分析仪 UART 解码 CSV → 二进制 + 同步密度分析 | `python3 csv3.py decoder.csv out.bin` |
| `etm_full_decode.py` | 自写 ETMv3.5 解码器：TPIU解帧 + capstone 反汇编 → 指令流 | `python3 etm_full_decode.py etm.bin firmware.axf flow.txt` |
| `etm_swo_openocd.cfg` | **ST-Link 版** ETM-over-SWO 配置（OpenOCD），与 J-Link `etm_2m_forever.jlink` 等效，OpenOCD 常驻=持续输出 | `openocd -f interface/stlink.cfg -f target/stm32f4x.cfg -f etm_swo_openocd.cfg` |

## 调试器选择：J-Link vs ST-Link

两条路等效，都是配同一套 TPIU/ETM 寄存器后让 CPU 持续运行：

- **J-Link**：`JLinkExe -NoGUI 1 -CommanderScript etm_2m_forever.jlink`，靠脚本末尾长 `sleep` 挂住会话保持 CPU 运行。
- **ST-Link**：`openocd -f interface/stlink.cfg -f target/stm32f4x.cfg -f etm_swo_openocd.cfg`，OpenOCD 配好 `resume` 后**常驻 server 本身就保持连接**，CPU 持续运行（比 J-Link sleep 更自然）。Ctrl-C 停止。
  - hla_swd 模式实测可正常写 TPIU/ETM(PPB 区 0xE004xxxx) 寄存器；读回 ETM_CR=0x880 / FFCR=0x102 / ACPR=0x53 / SPPR=0x2 全部生效。

两者都不负责抓 SWO —— SWO 由 CH343/逻辑分析仪从 PB3 抓（NRZ 2Mbaud），调试器只管配置 + 保持 CPU 跑。

## 典型流程

1. 自检引脚：`pb3_wiggle.jlink` → 逻辑分析仪/表确认 PB3 有方波。
2. 配 ETM 并常驻：`etm_2m_forever.jlink`（CPU 持续运行，SWO 持续输出）。
3. 抓数据：`ch343_grab.py /dev/ttyACMx 2000000 3 etm.bin`。
4. 解码：`etm_full_decode.py etm.bin firmware.axf flow.txt` 看指令流；
   或实时：`orbuculum -p /dev/ttyACMx -a 2000000 -T -N -t 2` + `orbmortem -s localhost:3402 -P ETM3.5 -e firmware.axf -t 2`。

> 注意：`-N`（保持 TPIU 同步）是 fork 补丁新增项，CH343/稀疏同步源必须加。
> ETM 用 formatter on（FFCR=0x102），ITM 单独用 formatter bypass（0x100）。
