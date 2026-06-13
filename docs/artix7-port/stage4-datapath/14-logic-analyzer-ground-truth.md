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


---

## 6. proj_add 对拍 + 台阶① 连续逐指令重建(实测)

> 把固件从 `while(1){__NOP();}` 换成有真实控制流的 `proj_add`,验证解码链路不仅能
> 锚定单点 PC,还能**逐条指令重建执行路径**。

### 6.1 固件 ground truth(反汇编)

```c
int add(int a,int b){ return a+b; }                 // _Z3addii  @0x08000f8c
int loop_sum(int n){ int s=0;
    for(int i=0;i<n;i++) s+=add(i,i); return s; }   // _Z8loop_sumi @0x08000fa4
while(1){ volatile int x = loop_sum(5); __NOP(); }
```

```
08000f8c <_Z3addii>:        08000fa4 <_Z8loop_sumi>:
 f8c: mov  r2, r0            ...
 f8e: adds r0, r2, r1         fb2: bl   8000f8c <add>   ← 调 add(每次循环1次)
 f90: bx   lr                 fbc: blt.n 8000fae        ← for 回跳(取5次/不取1次)
```

### 6.2 抓取 + 解码(`DSLogic ...162903.dsl`,HCLK /64,TRACECLK 1313 kHz)

CLK 检查完美(0% 数据未对齐)。`etm_decode_cli` 锚点解析:

| PC | addr2line | 判定 |
|----|-----------|------|
| 0x08000f8c | `_Z3addii` (main.cpp:22) | ✅ add 函数 |
| 0x08000fb2 | `_Z8loop_sumi` (main.cpp:23) | ✅ loop_sum 里 `bl add` |
| 0x08000fbc | `_Z8loop_sumi` | ✅ loop_sum 的 `blt` 回跳 |
| 0x08000e90 / 0x08000c90 | TIM IRQ / SystemInit | 中断/启动上下文(预期内) |

锚点全部命中预期函数。

### 6.3 台阶①:连续逐指令重建(`etm_reconstruct.py`,纯软件)

新增 `etm35lib.expand_pheader`(P-header→有序 atom 列表,IHI0014Q Table 7-2)+
`decode_branch_thumb`(压缩分支地址,Fig 7-4)+ `etm_reconstruct.py`(对着 ELF 反汇编
走 PC:**直接分支目标从镜像推算,间接分支吃 Branch Address 包**,IHI0014Q §4.5.2/§4.10.3,
与 orbuculum `traceDecoder_etm35.c` 模型一致)。

实测重建出 add() 的**精确三指令序列**:
```
0x08000f8c  mov  r2, r0
0x08000f8e  adds r0, r2, r1
0x08000f90  bx   lr            ← 间接返回,吃下一个 branch 包
```
以及 loop_sum 的 `bl add` / `blt` 回边。

**诚实边界**:连续区段最长约 7 条指令就因 4-bit 口的子字节失步而脱轨(中位数 2 条),
随后由下一个 I-sync 重新锚定。**解码正确性 = 实测通过;连续性 = 受当前有损采样限制**。
这正是台阶①(纯软件解码,已达成)与台阶②(满速无损采样,物理命门)的分界:
逐指令重建逻辑本身正确,要拿到长连续路径需要采样侧不丢数据。

### 6.4 回归固化

- 提交了两个稳定 fixture:`captures/while_nop_ground_truth.bin`(0x08000ff0)、
  `captures/proj_add_ground_truth.bin`(含 add/bl-add/blt 三锚点的 16KB 窗口)。
- `test_etm_reconstruct.py` 新增 20 用例(指令分类、Thumb 分支解码、间接分支吃包、
  I-sync 中途重锚、proj_add 三指令序列集成)。全套 **120 用例通过**,etm35lib 覆盖率 97%。
- ground-truth 测试不再依赖易失的 `/tmp/dsl_bytes_0.bin`,改读committed fixture。


---

## 7. dsl_parse 固化 + TPIU 同步填充剥离(branch-broadcast 关闭后)

### 7.1 关掉 branch broadcast 重抓(172817.dsl)

按"路 2"把 `ETMCR` bit8(branch broadcast)清掉(`0xd80/0x980 → 0xc80/0x880`,
已上板读回 `0x880`),让流匹配镜像驱动重建器的模型(直接跳转目标查 ELF、间接跳转吃包)。

### 7.2 两个真问题被揪出来

**问题 A — DDR edge-parity 偏移(解析器 bug)**:172817 这次采集从 DDR 半拍**中间**开始,
整体错位一个时钟沿,旧 `dsl_parse`(硬编码 `rise=low`、从第一个沿开始配对)把每个字节都搅坏,
直接表现为"满屏 `0xFFFFFF7F`、0 个锚点"。

→ **修复**:`dsl_parse.py` 重写为**自动搜索对齐**——试全部 4 种(parity 0/1 × nibble 序
low/high),用"flash 区间合法 I-sync 锚点数"打分挑赢家;中眼采样(沿后半个半周期);
任何对齐都解不出锚点时大声告警。验证:162903 自动选 parity=0(332 锚点,和旧硬编码一致),
172817 自动选 parity=1(92 锚点,旧解析器是 0)。

**问题 B — TPIU 同步填充(真实存在,非 artifact)**:对齐修正后,流里**确实**有
33902 个 `0xFFFFFF7F`(满同步)+ 大量 `FF 7F`(半同步)。这是 TPIU formatter 在 ETM 空闲时
往链路里填的同步字。branch broadcast 关掉后数据稀疏,填充占比更高(652788 有效字节 vs 填充
659826 字节,几乎一半)。

→ 关键判断(实测):这颗单源 STM32 ETM **不是 stream-ID 分帧**(按 stream 去帧会散成几十个
假流、0 锚点),而是**裸 ETM + 同步填充**。所以正确前端是**剥离填充**,不是跑 16 字节去帧器。
新增 `etm35lib.strip_tpiu_sync`(去 `0xFFFFFF7F` 满同步 + `FF 7F` 半同步)+ `has_tpiu_sync`,
并集成进 `dsl_parse.py`(检测到填充自动剥离并报告)。同时把 orbuculum `_getPacket` 的完整
16 字节去帧器也忠实移植为 `tpiu_deframe`(供真·多源分帧场景,golden 测试覆盖)。

### 7.3 效果

剥离填充后重建,proj_add 最长连续路径从 **4 条指令提升到 33 条**(能看到 loop_sum 的
`add r5; adds r3; cmp; blt` 完整循环体)。**这坐实了:低速采样物理无损,卡点在解码前端
没处理 TPIU 填充。**

仍有少量错步(如 `bl` 后跨函数跳错),是 from-scratch 重建器在调用/返回配对上的模型不全,
属台阶①待完善项(可对齐 orbuculum 状态机解决),不影响"采样无损"这个结论。

### 7.4 回归

新增 13 个测试(strip 5 种情形 + has_tpiu_sync + 透过填充恢复 I-sync + tpiu_deframe golden),
**全套 129 用例通过**。`dsl_parse.py` 现在是健壮可复用脚本:喂任意 `.dsl`,自动定对齐、
自动剥 TPIU 填充、报告锚点、写 `/tmp/dsl_bytes_0.bin`。


---

## 8. 复用 orbuculum 解码核心(orbetm)+ 对照验证

### 8.1 动机

我之前自研的 `etm_reconstruct.py` 在 call/return 配对上会错步。与其继续追 orbuculum 的状态机,
不如**直接复用它**。做了 `orbetm.c`:link orbuculum 的 `traceDecoder*` + `loadelf.c`(capstone
反汇编),忠实搬 orbmortem 的 `_traceCB` 指令流重建循环,去掉 ncurses TUI,逐条打印执行指令。

### 8.2 编译坑(回答"为什么官方能编我编不出来")

裸 `cc` 一开始失败,两个根因都是**没复刻 orbuculum 的 meson 环境**:
1. **`dwarf.h` 找不到**:orbuculum 把 **libdwarf 作为 meson subproject 自带**(`subprojects/
   libdwarf-0.7.0/`),不用系统 dwarf.h。本机只装了运行时 `libdw1`、没装 `-dev` 头。
   → 指向 vendored 头 + 已编好的 `build/subprojects/.../libdwarf.so`。
2. **`C_VERB_* undeclared`**:meson 全局 `-include uicolours_default.h`(定义颜色宏)。
   → 手动加 `-include`。
3. 还漏链 `readsource.c`(loadelf 依赖)。

修好后见 `build_orbetm.sh`。官方一直能编,编不出来的是我绕过 meson 的手写命令。
orbuculum 无 release tag(滚动 main,内部版本 2.2.0);当前是 debug 构建,需要时
`meson setup build_rel --buildtype=release` 即可出 -O2 版(已验证可编)。

### 8.3 对照验证(决定性):runaway 是数据固有,非解码器 bug

把 172817 剥填充流喂 orbuculum **自己的**解码器统计地址事件落点:

| 指标 | 值 |
|------|----|
| 解出的 ADDR 事件总数 | 343366 |
| 落在 flash 代码区的 | 91986(**26.8%**) |
| branch-broadcast ON(162903)同样测 | 62728/214451(**29.3%**) |

**两份流都只有 ~27-29% 地址落在代码区,73% 是乱解。** 这证明:**orbuculum 久经考验的解码器
在我们这份流上和我自研的表现一样会跑飞**——根因是 branch-broadcast-off 的稀疏锚点流,间接
返回(`pop pc`/`bx lr`)在调用栈不完整时拿不到目标地址,PC 失控走进向量表。**这是数据特性
的固有限制,不是哪个解码器实现的 bug。**

### 8.4 orbetm 的处置:窗口门控,只信能落在代码区的

给 orbetm 加了代码窗口门控(跳过 0x08000200 以下的向量表;PC 离开 flash 代码区就停止当前
run、等下一个 I-sync/branch 重新锚定)。门控后从 172817 流稳定解出真实函数:
`TIM8_UP_TIM13_IRQHandler`、`TIM_GetITStatus`、`USART_ClearITPendingBit`、`USART3_IRQHandler`、
`HardwareSerial::IRQHandler` 等——与锚点法解出的函数集一致,且现在是**逐指令流**(带反汇编)。

### 8.5 结论

- **复用达成**:解码核心从自研切到 orbuculum(`orbetm` link liborb 解码器 + capstone)。
  `etm35lib` 降级为锚点快速校验 + 测试夹具,不再承担完整指令重建。
- **诚实边界没变**:稀疏流下的连续逐指令 100% 还原,是 orbuculum 也做不到的——卡在数据,
  不在解码器。要真正连续,得回到台阶②(更密的同步/不丢的满速采样),不是换解码器能解决。
- `dsl_parse.py`(.dsl → 剥填充裸 ETM)依然是我们独有、不可替代的前端。


---

## 9. 连续性的两个杠杆:分支广播(有效)+ 同步周期(硬件锁死)

台阶②的目标是让锚点更密、解码器不跑飞。能动的旋钮只有两个,实测验证如下。

### 9.1 杠杆 A:branch broadcast(ETMCR bit8)—— 有效,7×

把两份已有 capture 喂 orbetm(orbuculum 解码核心)比"落在代码区的指令占比":

| capture | ETMCR | executed(代码区) | dropped(跑飞) | 代码区占比 |
|---------|-------|------------------|---------------|-----------|
| 172817 | 0x880(bcast **OFF**) | 39099 | 1456967 | **2.6%** |
| 162903 | 0x980(bcast **ON**)  | 70163 | 303836  | **18.8%** |

**branch broadcast ON 把可用指令占比从 2.6% 提到 18.8%(7×)。** 原理:bit8=1 让**每个直接跳转
也吐地址包**,于是解码器在硬件固定的 1024 字节 I-sync 周期之间,靠这些地址包不断重新锚定;
关掉它,一遇到拿不到目标的间接返回(`pop pc`/`bx lr`)PC 就失控冲进向量表。

→ **结论性修正**:之前为了迁就我手写的 image-walk 解码器把 bit8 关了,那是错的方向——它饿死了
真正的流式解码器。已把 `etm_enable.cfg` 改回 **0xd80/0x980(bcast ON)**。

### 9.2 杠杆 B:ETM 同步周期(ETMSYNCFR)—— 硬件锁死,动不了

ETMSYNCFR(0xE00411E0)本想缩短到 256B/64B 让 I-sync 更密。实测:**只读,固定 0x400=1024 字节**
(写 0x100、0x40 都读回 0x400)。这颗 M4 的 ETM 同步周期硬件钉死,没法调。

### 9.3 当前可行的最优 + 下一步

- 最优配置 = **branch broadcast ON + 降频保证采样无损**(已设好:ETMCR=0x980,HCLK /64)。
- 用这个配置重抓一份,预期连续段比 172817 长得多(代码区占比 ~19% vs 2.6%)。
- 残余的跑飞来自间接返回 + 1024B 周期的固有空窗,这是 ETM-M4 的物理上限,不是软件能再压的。
  要再进一步只能上**满速 + 不丢传输的连续流**(台阶②/③),或换有更多比较器/可调同步的更高端
  trace 单元(商业 J-Trace 级)。
