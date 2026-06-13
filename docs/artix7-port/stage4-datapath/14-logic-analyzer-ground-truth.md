# Stage-4 · ★★★ 逻辑分析仪 ground-truth 对拍:整条解码链路实测验证通过

> 用户用 50MSa/s 逻辑分析仪(DSLogic U2Basic / DSView)直接抓 STM32 的 5 根 trace 引脚,
> 跑已知固件 `while(1){__NOP();}`(`proj_while_nop.axf`),把物理引脚的真值拿来对拍。
> **这是整个 Stage-4 第一次有"物理 ground truth",一锤定音地证明了解码链路正确。**

---

## 0. 结论(决定性)

**逻辑分析仪抓的真实引脚 bit → 解码 → I-sync PC = `0x08000ff0` = ELF 里 `while(1){__NOP();}` 的确切地址。** 整条链路(nibble 映射 / DDR 边沿序 / ETM 字节组装 / I-sync 提取)**全部实测正确**,不再是推断。

```
8000fe4 <main>:
 8000ff0: bf00   nop            ← 我们解出的 I-sync PC(29 次)
 8000ff2: e7fd   b.n 8000ff0    ← while(1) 回跳
```

---

## 1. 实验设置

| 项 | 值 |
|----|----|
| 逻辑分析仪 | DSLogic U2Basic,50 MSa/s,5 通道 |
| 降频 | HCLK /64 ≈ 2.6 MHz(`downclock.cfg DIV=64`) |
| TRACECLK 实测 | **1313 kHz**(.dsl 解析,与 /64 预测吻合) |
| 接线 | D0=PE2(CLK) D1=PE3(TD0) D2=PE4(TD1) D3=PE5(TD2) D4=PE6(TD3) + 共地 |
| 固件 | `while(1){__NOP();}`,ELF `proj_while_nop.axf` |
| 采集 | 50M 样本,RLE off,无外部时钟 |

## 2. 解析(`dsl_parse.py`)

`.dsl` 是 zip:`header`(ini)+ 每通道 bit-packed 块 `L-<ch>/<blk>`(每字节 8 样本,LSB 在前)。
1. 解 5 通道 → 找 TRACECLK 边沿(52505 上升 + 52504 下降)。
2. **DDR**:每个边沿采一次 D0-D3 = 一个 nibble。
3. 两种边沿序拼字节对比:

| 边沿序 | A-sync 数 | 判定 |
|--------|----------|------|
| **rise=低 nibble, fall=高 nibble** | **31** | ✅ 正确 |
| rise=高, fall=低 | 0 | ✗ |

→ **实测确定:TRACECLK 上升沿 = trace_a(低 nibble),下降沿 = trace_b(高 nibble)**。这把我们之前反复纠结的 nibble/边沿映射**一次定死**。

## 3. 解码结果(对拍)

`rise=low` 字节流(52504 字节)喂 `etm35lib`:
- **A-sync = 31,I-sync(严格,含 r14 加固)= 42**
- I-sync 绝对 PC 直方图:

| PC | 次数 | addr2line(proj_while_nop.axf) |
|----|------|------|
| **0x08000ff0** | **29** | **`while(1){__NOP()}` 的 nop(main+0xc)** ✅ |
| 0x08000ef2 | 12 | 中断/handler 上下文(0x8000eec 区段) |
| 0x08000fd0 | 1 | main 之前(Delay_Init 附近) |

字节流主峰是 **0x88(21635 次)= ETM Format-1 P-header"执行了 2 条指令"** —— 完全符合 `nop; b` 这种两指令紧循环的预期。

## 4. 这验证了什么(把推断变实测)

| 之前状态 | 现在 |
|----------|------|
| nibble 高低位映射(反复猜) | ✅ 实测:rise=低 nibble |
| DDR 哪个沿是高 nibble | ✅ 实测:上升沿=trace_a |
| 是裸 ETM 还是 formatter | ✅ 裸 ETM(A-sync/I-sync/P-header 结构,无 TPIU 帧) |
| I-sync PC 解码正确性 | ✅ **= 真实 while(1) 地址,ground truth 对上** |
| etm35lib 解码逻辑 | ✅ 物理真值 + golden 单测双重确认 |
| r14 BUG-1 锚点可信度 | ✅ 加固后的严格锚定,42 个全部落在真实代码地址 |

## 5. 意义

- **采样链 + traceIF + 解码器整条 = 实测正确**。之前所有"指示性/推断"的限定词,在 ground-truth 这条上可以去掉了。
- 真实 LVGL 抓取里解出的那些函数(lv_timer_handler 等)**因此也是可信的**——同一条已被 ground truth 验证的链路。
- 剩余的"连续流"问题是**覆盖率/采样窗口**问题(锚点间靠 P-header/branch 续解、会脱轨),不是正确性问题。正确性这一关,过了。

> 一句话:**逻辑分析仪给我装上了眼睛。抓 `while(1){__NOP();}`,解出的 I-sync PC = `0x08000ff0` = 那个 NOP 的确切地址。整条 trace 解码链路第一次有了物理 ground truth,实测验证通过——nibble/边沿映射、裸 ETM 判定、I-sync 解码全部坐实。**
