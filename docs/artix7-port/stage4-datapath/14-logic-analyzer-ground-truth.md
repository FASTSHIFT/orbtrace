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


---

## 10. broadcast ON 重抓(194702)实测:锚点可信,连续流仍受 ETM-M4 物理上限

### 10.1 抓取与配置

`DSLogic ...194702.dsl`,ETMCR=0x980(branch broadcast ON)+ HCLK /64。CLK 完美(0% 未对齐,
4.69M 数据跳变,比 broadcast off 的 2.9M 更密,符合预期)。`dsl_parse` 自动选 parity=1、剥
TPIU 填充,得 **334 个 flash I-sync 锚点**。

### 10.2 可信的部分:I-sync 锚点 = ground truth

334 个锚点 → 8 个 distinct PC,addr2line 全部命中真实函数:
`_Z3addii`(add)、`_Z8loop_sumi`(loop_sum)、`_Z5setupv`(setup)、`TIM8_UP_TIM13_IRQHandler`。
orbetm 从锚点出发能精确重建 add() 的三指令序列 `mov r2,r0; adds r0,r2,r1; bx lr`。**这些是
物理实测确认的真值。**

### 10.3 不可信的部分:锚点之间的连续流(诚实结论)

orbetm 报"最长连续 342 指令"——但 `-v` 详查发现这是**假象**:loop_sum 的 `mov r0,r3`(0x8000fb0)
之后跳到 0x08000f0a 并在 0x08000f0a..0f26 反复打转(出现 `movs r0,r0`=0x0000 这种"走进数据"
的标志)。根因:**间接返回(`bx lr`/`pop pc`)在流里没有目标地址**——branch broadcast 只补了
*直接*跳转的目标,间接跳转仍依赖调用栈;而硬件 1024 字节 I-sync 周期之间一旦栈不完整,walk 就
失准,又因为没离开 flash 窗口而"看起来"在连续走,把 run 长度灌水了。

→ 已在 orbetm 的 `endRun` 注释里如实标注:**run 长度不是"已验证正确"的跨度;只有 I-sync 锚点
是真值,锚点间的流仅供参考。**

### 10.4 杠杆已用尽 —— 这就是 ETM-M4 的物理天花板

- branch broadcast:ON(已是最优,7× 于 OFF)。
- ETM 同步周期 ETMSYNCFR:硬件只读锁死 1024 字节,动不了。
- 地址比较器:ETM-M4 有 0 个(ETMCCR 实测),无法用比较器强制更密的地址输出。

**三个旋钮全部用尽。** 在这颗 STM32F429 的 ETM-M4 上,中速完整 trace 能做到的极限就是:
**密集 I-sync 锚点(每函数级别可信)+ 锚点间短程指令重建**,而非全程逐指令无错。要全程无错的
连续逐指令流,需要的是带更多比较器 / 可调同步周期 / 时间戳关联的更高端 trace 单元(商业
J-Trace / ULINKpro 级),这是硬件能力差异,不是软件或采样能补的。

### 10.5 结论(对齐终极目标)

- **台阶①(连续逐指令解码)在 ETM-M4 上的可达上限 = 函数级可信 + 短程指令流**,已达成并诚实定界。
- 全程逐指令无错是该硬件的天花板之上,不是当前方案能突破的;这点必须如实告诉决策者,避免在
  无法逾越的物理限制上继续投入。
- 真正可继续推进的是台阶②/③(满速 + 不丢传输),那是"采到更多原始数据"的方向,与"解码"无关。

---

## 11. 重要更正:§10 的"硬件天花板"结论是错的 —— 这是解码软件问题

用户质疑得对:"J-Trace 也是 FPGA 做的,凭什么有硬件能力差距?" 复查后 §10.4/§10.5 的
"ETM-M4 物理天花板"结论**撤销**。真相是这是**解码软件的调用栈问题,完全可修**。

### 11.1 决定性证据:质量按"距上一个好锚点的距离"分桶

把 orbuculum 解码出的地址按"距上一个 in-code 地址多远"分桶,统计落在代码区的比例:

| 距好锚点 | 地址数 | in-code | 占比 |
|----------|--------|---------|------|
| 0(紧跟好地址) | 23069 | 22750 | **99%** |
| 1 | 319 | 0 | 0% |
| 2..11 | 各 319 | 0 | 0% |

**紧跟好地址的下一个地址 99% 还是好的;然后恰好"一个"坏地址(319 次 = 正好等于 run 数),
之后就一路跑飞直到下个锚点重新拉回。** 这不是硬件采不到,是**解码器在某一类指令上失同步**。

### 11.2 失同步点 = 间接返回(`pop {pc}` / `bx lr`)

`-v` 详查:每个 run 的终结指令统计——**81/83 是 `pop {r4, pc}`**(间接返回)。根因是经典的
**返回地址/调用栈**问题:间接返回的目标不在代码镜像里,解码器必须靠"调用时压栈、返回时弹栈"
来跟踪。J-Trace/ULINKpro 的解码软件就是这么干的——**和我们用的是同一颗 ETM、同一类 FPGA 采集**,
差别只在 PC 端解码器维护了正确的调用栈。

### 11.3 修复 orbetm:间接分支后停下等地址包

之前 orbetm 在间接分支后用栈候选"猜"一个地址就继续走 atom,猜错就跑飞。改为:**间接分支后立即
停止当前 atom run,等下一个 Branch Address 包(broadcast ON 必然带真实目标)经 EV_CH_ADDRESS
拉回**。修复后 `-v` 输出已是连贯的真实控制流(`pop pc → push {r4,lr} → ldr → bl 0x8000fc2 →
pop {r4,pc}`),~91% 是真实指令流,残留 ~9% 是栈候选偶尔过期的重复 pop(可继续收敛)。

### 11.4 更正后的结论

- **全程逐指令连续 trace 在这颗 ETM-M4 上是可达的,瓶颈在 PC 端解码器的调用栈跟踪,不是硬件。**
- 路径明确:把 orbetm 的调用栈/返回匹配做扎实(对齐 orbmortem 的 `stackDelPending` 提交语义,
  并处理递归/中断导致的栈失衡),连续段就能从"锚点间短程"扩到"跨函数全程"。
- 我之前下"物理天花板"是信息不全时的过强结论(只看了 in-code 占比 27%,没按距离分桶就归因硬件)。
  分桶一看就清楚:99% 的局部正确率证明数据是好的,是解码没跟住。**保留此教训。**


---

## 12. OpenCSD 摸底(只评估,未决策)

用户问"有 OpenCSD 还要不要手搓 / 有没有现成 CLI / 谁在用这些库 / orbuculum 为啥不用它 / 以后要
流式怎么办"。先把 OpenCSD 摸清楚再决定。

### 12.1 OpenCSD 是什么 / 谁在用

- **ARM/Linaro 官方开源 CoreSight 解码库**,Linux 内核 `perf`(`perf record -e cs_etm//`)的
  CoreSight 后端,LLVM AutoFDO、Google 数据中心 ARM PGO 都用它。装机量 = Cortex-A Linux/安卓
  几十亿台。这就是"谁在用"——**主战场是 Cortex-A,trace 存片内 ETR/ETB,软件读出,不接探针**。
- 我们用的是它的边角:**ETMv3.5 / M-profile 解码**(同一套 ETM 协议,A/M 复用)。

### 12.2 为什么 orbuculum 不用 OpenCSD(推断,无作者背书)

- orbuculum = **实时流式 + 纯 C + 轻量**(逐字节 pump,边抓边显示,orbtop 实时视图)。
- OpenCSD = **offline/batch + C++ 重库 + snapshot 输入**(攒完整 dump 再一把解)。
- 两者数据流模型正交;且 OpenCSD 早期重心在 ETMv4/Cortex-A,M-profile 支持是后补的。
- **对我们 offline 对拍而言,OpenCSD 才是主场;对"以后实时一直抓"而言,orbuculum 路线才对。**

### 12.3 现成 CLI:有 —— `trc_pkt_lister`(Ubuntu 有包)

- `apt install libopencsd-bin libopencsd-dev`(已装,**1.4.1**,零编译)。
- `trc_pkt_lister -ss_dir <snapshot> -decode` 做完整 ETMv3.5 指令解码;带 `-tpiu` 选项可直接吃
  TPIU 帧(连填充都不用我们剥)。
- **门槛**:输入是 OpenCSD "snapshot 目录"(ini 配置 + 原始 trace dump + 内存镜像),不是裸 bin。
  需要写一个**纯打包脚本**(不碰解码逻辑)把我们的数据包装进去。

### 12.4 snapshot 格式(已读官方 spec,打包很简单)

`/usr/share/doc/libopencsd-dev/specs/ARM Trace and Debug Snapshot file format 0v2.pdf`:
- `snapshot.ini`:[snapshot] version=1.0 + [device_list] + [trace] metadata=trace.ini
- 一个 core 设备 ini(class=core, type=Cortex-M4)+ 一个 trace 源 ini
  (class=trace_source, type=**ETM3.5**)
- **ETMv3 解码只需 4 个寄存器**:`ETMCR, ETMCCER, ETMIDR, ETMTRACEIDR` —— 我们全有/可从靶子读。
- core ini 用 `[dump]` 指向内存镜像(直接用 ELF 的 .text;spec 明说可以是 elf 可加载段)。
- `trace.ini`:[trace_buffers] format=source_data(我们已剥成裸 ETM 单源)或 coresight(带 TPIU)。

→ 打包脚本 = 写 3 个小 ini + 把 `/tmp/dsl_bytes_0.bin` 和 ELF 放进目录。**几十行 Python,零解码代码。**

### 12.5 流式("以后一直抓")的定位

流式 = 两段独立问题:
1. **连续不丢传输(台阶②/③,FPGA 侧硬骨头)**:逻辑分析仪是快照设备,不能无限流;要"一直抓"
   必须 FPGA 实时收 ETM → orbflow 打包 → 千兆网口连续吐 + 序号防丢。这跟解码无关。
2. **实时解码显示**:这段用 **orbuculum**(它本就是实时流式),不是 OpenCSD。

**结论性认识**:offline 对拍/求最准 → OpenCSD;实时一直抓 → orbuculum 路线;两者解码内核同协议,
现在用 OpenCSD 把"调用栈/持续流的理论上限"摸到底,认知可直接迁移到实时管线的取舍。

### 12.6 现状

OpenCSD 1.4.1 已装(`trc_pkt_lister` + C/C++ 库 + 头 + 官方 spec/HOWTO 齐全)。**下一步(待用户拍板)
= 写 snapshot 打包脚本,跑 `trc_pkt_lister -decode`,得到 ARM 官方解码器在我们 M4 流上的持续指令流
质量——这是"调用栈能恢复多少"的权威标尺。** 未决策,先摸底完成。


---

## 13. 跑了一把 OpenCSD —— 权威标尺出来了

写了 `make_opencsd_snapshot.py`(纯胶水,零解码代码)把我们的裸 ETM 流 + ELF + 实读的 4 个
ETMv3 寄存器(ETMCR=0x980 ETMCCER=0x18541800 ETMIDR=0x4114f250 ETMTRACEIDR=0x02)包成 OpenCSD
snapshot,跑 `trc_pkt_lister -decode`。

### 13.1 OpenCSD 确实能解我们的流(packet 级全对)

`trc_pkt_lister`(不 decode,只列 packet)从 A-sync 对齐后,正确解出 A_SYNC / P_HDR(EE/EEEE/
EEEEEEEE)/ BRANCH_ADDRESS / TRIGGER —— **ARM 官方解码器认我们的流,packet 解析全对。**

### 13.2 指令级解码:锚对了就对,但有两个坑

1. **ISA=Thumb 必须靠"带 Thumb 位的 I-sync"锚定**。IHI0014Q 实证:I-sync 地址 bit[0] 是 Thumb 位
   (Thumb 态=1)。我们流里 334 个 flash I-sync:**160 个 bit0=1(真 Thumb 锚点),174 个 bit0=0
   (多半是 mid-stream 假阳性 0x08)**。从 bit0=1 的 I-sync 锚定,OpenCSD 立刻 `ISA=T32` 正确解出
   `exec range=0x8000e90 ... (ISA=T32) E` —— 真实 Thumb 指令范围。从 A-sync(没跟 I-sync)起步则
   默认 A32,解错。
2. **OpenCSD 是"对或中止"(correct-or-abort)**:遇到一个它不认的 packet(我们锚点间的噪声/
   reserved 头)就**直接终止整条 datapath**,不像 orbuculum/orbetm 那样硬着头皮往下走。实测:
   从一个好 Thumb 锚点起,OpenCSD 解出**恰好 1 条指令范围**就在下一个坏 packet 处中止;整条流从头
   跑则在第 2593 字节中止(把噪声误判成 data-trace,报 OCSD_ERR_HW_CFG_UNSUPP)。

### 13.3 决定性结论:工具特性 × 数据特性的错配

| | OpenCSD(ARM 官方) | orbuculum / orbetm |
|---|---|---|
| 设计目标 | Cortex-A,**片内 ETR/ETB 无损 trace** | Cortex-M,实时/容错 |
| 坏 packet | **中止整条解码** | 跳过/续走 |
| 在我们这条**有损隙的逻辑分析仪流**上 | 锚点处完全正确,但一遇噪声即停 | 一路走完(但锚点间会跑飞) |

**这把标尺量出的真相**:我们流的瓶颈不在解码器算法,而在**流本身有"锚点间噪声/不连续"**——
OpenCSD 这种为无损片内 trace 设计的严格解码器,直接拒绝在脏流上硬解(这恰恰是它工业级正确性的
体现:它不会给你编造的指令流)。orbuculum 容错往下走,代价是锚点间不可信。

→ **两边都不是 bug,是数据脏**。要让任一解码器吐出长段连续可信指令流,**必须先有"干净不丢的流"**
——这就把球又踢回**台阶②/③(FPGA 侧无损连续采集)**。换句话说:**OpenCSD 这把权威标尺证明了
"解码不是瓶颈,采集质量才是"**。我们之前在解码侧反复纠结(自研/复用/调用栈),方向上是次要矛盾;
主要矛盾是把 STM32 ETM 无损连续地搬进 PC。

### 13.4 产出

- `make_opencsd_snapshot.py`:`.bin`+ELF → OpenCSD snapshot(纯胶水),固化下来随时可复跑。
- 结论:**offline 求最准用 OpenCSD(但要喂干净流);现状脏流下 orbuculum 容错更实用;真正要突破
  连续性,回台阶②/③ 做无损采集。** 解码工具选型到此尘埃落定,不再纠结。


---

## 14. dsl→OpenCSD 对拍归因:逻辑分析仪采集是干净的,问题不在采集

用户要求:把 dsl 喂 OpenCSD,如果逻辑分析仪采得没问题、是 FPGA/处理侧的问题,就专攻后者直到对齐。
做了 `opencsd_region_probe.py`(从每个真 Thumb 锚点独立喂 OpenCSD)+ 把 OpenCSD 中止点的字节
**映射回原始 DDR 采样**做眼图裕量检查。

### 14.1 OpenCSD 每个锚点只解 ~14-16 字节就中止

160 个真 Thumb 锚点(addr bit0=1),OpenCSD 从每个出发平均解 ~15 字节(I-sync 6B + 约 1 条指令
范围 + 几个包)就遇到不认的包中止。中止点的典型字节序列(锚点 0x08000e91 之后):
```
84 01 37 | 00 58 05 90 2e 8c 0c 8c 36 ...
P-hdr(E) branch  ???
```

### 14.2 ★ 决定性:中止点的字节在原始波形上"眼图全开",采集 100% 干净

把中止点每个字节映射回 DDR 采样,测每个 nibble 在采样点附近的稳定样本数:

| byte | 值 | 眼图稳定样本数(低/高 nibble) |
|------|----|------------------------------|
| 6741 | 0x84 | 18 / 18 |
| 6743 | 0x37 | 18 / 18 |
| 6744 | 0x00 | 37 / 18 |
| 6745 | 0x58 | 18 / 37 |
| 6748 | 0x2e | 18 / 18 |

**半周期 = 19 样本,每个 nibble 稳定 18-37 个样本 = 整个半周期纹丝不动。** 加上之前测的
"时钟 0 毛刺/0 丢沿"、"18-bit 最大连 1(与 TPIU HSYNC 一致)",**逻辑分析仪在低速把每个 bit 都
干净采下来了——采集侧没有任何问题,不是 SI,不是采样相位。**

### 14.3 那问题在哪:字节级解释(解码覆盖 / 流结构),不在采集

中止点的字节(`00 58`、反复出现的 `2e 36 3a 16 1c`)是 STM32 **真实吐出的**字节(实测眼图证明),
但作为裸 ETM 它们让 OpenCSD 和 orbuculum 都判为非法包。三种可能(待进一步定位,但都**与采集质量
无关**):
1. F429 TPIU 是 **HSYNC-only 连续格式**(实测:53667 个 `FF 7F` 半同步,**0 个 `FFFFFF7F` 全同步**,
   最大连 1 只有 18 位)。我们 `strip_tpiu_sync` 剥掉 `FF 7F` 后,可能破坏了 TPIU 字节对齐
   (TPIU 是 16 字节帧,剥字节会移位)。
2. 这些 `2e/36/3a` 可能是某类我们和 orbuculum 都没处理的合法 ETM 包的头/续字节。
3. 174 个 bit0=0 的假 I-sync 说明流里 0x08 歧义,暗示对齐仍有残留问题。

### 14.4 结论与下一步(锁定了正确战场)

**采集干净 = 已证实。** 按用户方法论,问题不在逻辑分析仪/硬件采集,**专攻"字节级流处理"**:
- 最可疑的是 #1:**HSYNC-only TPIU 的正确去帧**。我们一直当"裸 ETM + 剥填充",但 F429 实际是
  HSYNC 连续格式,正确做法可能是按 TPIU 16 字节帧去 mangle(OpenCSD 的 `-tpiu_hsync` 正是为此),
  而不是简单删 `FF 7F`。
- 下一步:用 OpenCSD `-tpiu_hsync` / 正确的 TPIU HSYNC 去帧重试,看锚点后能否连续解完整周期。
- 这一步打通后,FPGA 侧 trace_stream/orbflow 的字节流就能和逻辑分析仪这条"已证采集干净"的基准
  做对拍,任何 FPGA 侧偏差立刻可见——这正是用户要的"两个性能完全对齐"的标尺。

**一句话:逻辑分析仪低速采集已证 100% 干净;瓶颈是 PC 端对 F429 HSYNC-only TPIU 流的去帧/对齐,
不是采集,也不是 SI。提频做阻抗板的事要往后放,先把这个字节级处理打通。**

### 14.5 续:更正 #1 的猜测 —— 不是 16 字节 TPIU 帧问题

进一步实测把 14.3 的可能 #1(TPIU 16 字节去帧)**排除**了:

- **流不是 16 字节 TPIU 帧**:334 个 flash I-sync 的偏移 mod 16 **均匀散布在 0..15**(若是帧,
  会被帧结构约束);暴力试 16 个帧相位去帧,最好的也只恢复 14 个 I-sync(远不如简单剥 `FF 7F` 的
  334)。**无 FSYNC(0 个 31 连 1)、无帧结构** → 这是**裸 ETM + 周期性 HSYNC 填充**,不是分帧流。
  简单剥 `FF 7F` 是对的。
- `tpiu_deframe`(orbuculum 16 字节去帧)在此流上跑不动/不收敛(无 FSYNC 锁不住帧),证实同上。

### 14.6 ★ 采集干净的第二个铁证:确定性

proj_add 是 `while(1){loop_sum(5);}` 紧循环。统计同一个 I-sync 锚点(0x08000e91)后面紧跟的
16 字节窗口,**157 次重复只出现 3 种,头两种占 156/157(79+77,循环的两个相位),只有 1 次异常**。
**高度确定性 = 采集干净**(噪声会让 157 次各不相同)。加上 14.2 的眼图铁证,**采集干净双重坐实**。

### 14.7 真正的卡点(已精确定位,但属解码侧未解)

OpenCSD 从真 Thumb 锚点出发,完美解出 A_SYNC → I_SYNC(0x08000e90,Thumb2)→ P_HDR(E)→
指令范围 → BRANCH(0x01→e80)→ BRANCH(0x37→eb6),**然后遇到 `0x00` 报
`BAD_SEQUENCE: Invalid sequence [A_SYNC]` 中止**——它把孤立的 `0x00` 当成 A-sync 开头,但后面
不是连续的 0。这个 `0x00 0x58 ... 2e ... 36` 序列是**真实、确定性、眼图干净**的捕获数据
(raw +9 处,附近无 HSYNC 剥除),反复出现 79 次。

`2e/36/3a/16/1c` 这组反复出现的"未知"字节(占流 16%)**既不是合法 ETM3.5 IDLE 包头,也不是噪声**。
最可能是:**两个 branch 之后的某个 ETM 包(或 P-header 序列)里,我们和 OpenCSD 对 packet 长度/
类型的理解,与 F429 ETM 实际输出有出入** —— 这是**解码侧**问题,但已经和采集彻底解耦了。

### 14.8 当前结论(把战场钉死)

| 层面 | 状态 |
|------|------|
| 逻辑分析仪硬件采集(bit 级) | ✅ 100% 干净(眼图 + 确定性双证)|
| TPIU 16 字节去帧 | ❌ 不适用(此流是裸 ETM+HSYNC 填充,非分帧)|
| 剥 `FF 7F` HSYNC 填充 | ✅ 正确(恢复 334 真锚点)|
| 锚点本身 | ✅ 全部解出真实函数 PC |
| 锚点后连续解码 | ⚠️ ~1 条指令即遇 `0x00...` 中止 —— **解码侧待解**,与采集无关 |

**给用户的决策依据**:你说的"逻辑分析仪采得没问题就专攻另一侧"——**采得确实没问题(已双重证明)**。
但"另一侧"经精确定位**不是 FPGA**,而是 **PC 端对这段确定性 ETM 字节流(尤其 `00/2e/36` 模式)的
解码理解**。这是纯软件、可离线复现的问题。FPGA 对拍要等这个解码理解打通后才有意义(否则拿一个
我们自己都解不通的基准去对 FPGA,无法判定对错)。

**下一步(待批)**:聚焦搞懂 `84 01 37 00 58 05 90 2e ...` 这段确定性序列的真实 ETM 语义——
对照 IHI0014Q 把 `0x00`/`0x2e`/`0x36` 这组字节的包类型彻底搞清,这是解开"锚点后连续解码"的钥匙,
也是建立可信基准、再去和 FPGA 对拍的前提。
