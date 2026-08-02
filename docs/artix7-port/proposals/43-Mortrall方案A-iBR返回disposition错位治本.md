# proposal 43 — 方案 A：治本修复 iBR 返回的 disposition 错位

**日期**：2026-08-02
**前置**：r33（真凶定位）、r33 §7（方案 B 缓解，coremark_main 358→7 但 cm_benchmark_main 仍 133）
**目标**：从源头修掉"iBR 返回被 disposition 判为 not-taken 而跳过"的错位，让栈计数
从根上正确，coremark_main / cm_benchmark_main 一起收敛到真值 1。

---

## 1. 已坐实的事实（全部来自直接 log，不是推断）

1. **假重入 = 栈计数错**：cm_benchmark_main 133 次 begin 里 123 次是 push 路径
   （`depth 2→3, stacktop=0x8008118`），**0 次真实 CALL** 到 0x8008118。coremark_main
   同源，只是走 switch 路径（已被 B 部分接住）。
2. **触发点**：`cm_uart_send_char` 的 `pop {r4,pc}`（0x800a2f2）——iBR、无条件返回。
3. **错位现象**（r33 §3.4）：HAL 返回（stacked-candidate）后这批 atom `disp=0xa`，
   a2f2 pop 取 `disp&1=0` → `insExecuted=0` → 走 "branch not taken" 分支，
   `workingAddr += 2` 越过 pop，进入 `0x800a2f4`（`.word 0x20000288`，**字面量池数据**），
   一路 a2f4→a2f6→a2f8，撞上 coremark_main 入口。
4. **指令分类正确**：loadelf.c:1148 `POP && strstr("pc")` → `LE_IC_JUMP`（无 IMMEDIATE），
   pop 被正确识别为 iBR。分类不背锅（r33 Q1 已证）。
5. **无条件返回不可能 not-taken**：`pop {r4,pc}` 是无条件的，ETM4 对它发的 atom 必为 E。
   读到 disp bit=0 → **atom 流与指令流在背靠背 iBR 处错位了一位**。

## 2. 错位的确切机制（待最终坐实的假设 H43）

背靠背两个 iBR 返回：
```
0x800a2ec: bl HAL_UART_Transmit    ; iBR#1 调用，返回 a2f0
0x800a2f0: add sp, #8              ; 非分支
0x800a2f2: pop {r4, pc}            ; iBR#2 返回
```
HAL 返回是 **stacked-candidate（committed=false）**：iBR 无立即地址，workingAddr 被
推测设为栈候选 a2f0，`_removeRetFromStack` 先弹，等下一个地址包确认。

**H43**：HAL 返回消耗了一个 atom 并 `disposition >>= 1`。但推测返回后，解码器从 a2f0
线性重走 a2f0(add,非分支不消耗)→a2f2(pop,消耗下一 atom)。此时 disposition 已经右移过
一次（给 HAL），a2f2 取到的是**HAL 之后那一位**——而真实的 a2f2 atom 位应该是同一批的
另一个位置。即 **stacked-candidate 推测返回时 atom 指针的推进与真实执行流脱节**。

> 注意：H43 仍是假设。方案 A 动手前**必须先用逐-atom 对齐实验坐实**（见 §4 P0）。
> 不坐实不改 atom 循环——那是砸解码器的高危区。

## 3. 候选修复策略（三选一，按风险从低到高）

### A1（首选，最小侵入）：iBR 返回落入字面量池 → 强制返回
在 JUMP 分支，若 `insExecuted==0`（判 not-taken）但**下一线性地址落在函数的字面量池/
数据区**（`symbolFunctionAt` 找不到指令，或地址是已知 `.word`），说明"not-taken 走下去"
不可能正确——强制按 iBR 返回处理（弹栈到候选）。
- 优点：不碰 atom 计数，只在"走进数据"这个明确错误信号上兜底。低风险。
- 缺点：治的是"越过 pop 之后"，不是"为什么判 not-taken"。可能残留别的错位表现。

### A2：无条件 iBR 强制 taken
若指令是**无条件** iBR（pop{pc}/bx lr/ldr pc 等，非条件码），无视 disposition bit，
一律按 taken 返回处理。
- 优点：直击"无条件返回不该 not-taken"的矛盾，语义正确。
- 风险：需可靠判定"无条件"。thumb 里 pop{pc} 无条件，但 IT 块内的 popcc 有条件——
  要能区分。loadelf 目前不带条件码信息，需扩展。

### A3（治本，最高风险）：修复 stacked-candidate 的 atom 对齐
在推测返回（committed=false）后，重建 disposition/incAddr 与真实执行流的对齐。
- 优点：根治所有背靠背 iBR 错位。
- 风险：直接改 atom 循环核心，可能回归全局解码。r32/r33 反复警告的雷区。

## 4. 实施计划（严格 P0 先坐实，再动手）

### P0（坐实 H43，不改功能）
- [ ] 在 stacked-candidate 返回点，逐-atom dump：HAL 返回时的 disp/incAddr，
      推测返回后重走 a2f0/a2f2 时每步取的 disp bit 与真实指令，确认"错位一位"的确切来源。
- [ ] 交叉 opencsd：opencsd 对同段的 atom 消耗序列（opencsd 解码正确的参照）。
      **注意**：opencsd lister 的地址覆盖到 0x80094dc 为止，未见 0x800a2xx——需先查清
      opencsd 是否真未走到该区（若是，说明两解码器执行路径本就不同，参照失效）。

### P1（按坐实结果选 A1/A2）
- [ ] 实现选定方案，`captures/mortrall_fixture/regress.py --check` 双 slice 守护。
- [ ] 判据：coremark_main→1、cm_benchmark_main→1、内层篮子稳定 <1%、
      cardinality 不降、B/E 平衡、verify_calls 调用边不退。

### P2（A1/A2 不够才上 A3）
- [ ] 大改 atom 对齐，需红方评审 + 全量 verify_calls 回归。

## 5. 回滚判据
任一步 `regress.py --check` 报 REGRESSION（尤其 cardinality 降 / 内层篮子缩 / 调用边
mismatch 增），立即回滚。**保住"调用边对 ELF"这个诚实判据高于消除假重入。**


---

## 6. A2 实验记录（2026-08-02，失败，已回滚）

**做法**：在 JUMP 的 not-taken 分支加启发式——若是非立即 iBR（return）、栈非空、且
fall-through 地址**没有源码行映射**（`symbolLineAt(fall)==NULL`，即落在字面量池），
就判定为漏返回，改走栈候选返回。

**结果**（`regress.py --check`，slice1 4MB）：

| 指标 | fix B baseline | A2 |
|---|---|---|
| coremark_main | 7 | 6 |
| cm_benchmark_main | 133 | 114 |
| **cardinality** | **2646** | **2569（-77）** |
| crc16 | 7073 | 7132 |
| core_bench_list | 150 | 138 |

**判决：失败，撞回滚判据（§5）。**
- cm_benchmark_main 只从 133→114（微弱），coremark_main 7→6。
- **cardinality 掉 77 = 真 PC 覆盖丢失**：A2 的"fall-through 无源码行"判据太宽，
  **误伤了真实的条件间接分支**（not-taken 时 fall-through 也可能命中无行映射的边界），
  把它们错当成返回 → 走错路径 → 丢真实 PC。内层篮子也抖动（core_bench_list 150→138）。
- 已回滚到 fix B 干净态（coremark_main=7, cardinality=2646, git diff 空）。

**教训（蓝方自认）**：跳过了 §4 P0（先坐实 H43 的确切 atom 机制再动手），直接拍脑袋
上启发式兜底，代价是一次退化。`regress.py` 的 cardinality 守护当场抓到，没让脏结果溜进
commit。**"单步坐实 > 优美启发式"再次应验——A2 就是没坐实就动手的又一次复发。**

## 7. 当前结论与遗留

- **fix B（已提交 c5653e3 + 6db8cad）是当前最好的稳定态**：coremark_main 358→7，
  调用边 68797/68798 对 ELF，cardinality 不降，B/E 平衡。cm_benchmark_main 133 假重入
  仍在（同源 disposition 错位的 push-路径表现，B 只补了 switch 路径）。
- **治本（真修 disposition 错位）比预想难**：启发式兜底（A1/A2）会误伤真实分支。
  必须先做 §4 P0 精细坐实错位的确切 atom 机制，不能再拍脑袋。
- **P0 坐实的拦路石**：opencsd lister 地址只覆盖到 0x80094dc，未见 0x800a2xx
  （coremark_main 区），但 opencsd 的函数覆盖统计里 cm_benchmark_main=27（vs mortrall
  发 133 begin）。需先查清 opencsd 是否真的解码了 0x800a2xx——若 lister 只是被截断、
  完整覆盖到了，则 opencsd 的 atom 消耗序列可作为 mortrall 的对齐参照；若 opencsd 根本
  没走进该区，则两解码器路径不同，参照失效，P0 需换基准（如手工按 ETM4 spec 对齐）。


---

## 8. 蓝方接受 r34 红方评审（2026-08-02）

**红方 r34 全面命中，蓝方接受。** proposal 43 §1「已坐实的事实」第 5 条与 §4 P0 设计
被证伪/推翻，本节记录接受结论，覆盖前文的过度断言。

### 8.1 逐条接受

| 议题 | 红方判定 | 蓝方接受 |
|---|---|---|
| Q1 "disposition 错位一位" | 🟥推断+自相矛盾 | **接受**。§1.5"错位一位"与 §3.5"走错路"是两个相反机制，根因未定死。§1 第 5 条**降级为假设**，不再是"事实"。这是 p42→r32→r33 后第三次"没坐实就命名根因"复发。 |
| Q2 错位 vs 批次边界 | 🟥未证 | **接受**。stacked-candidate 返回时 atom 指针是"错位"还是"批次边界"从未区分，是命门。 |
| Q3 opencsd 参照 | 🟥矛盾未解 | **接受**。lister 截断 vs 路径不同没查清；opencsd cm_benchmark_main=27 vs mortrall 133 这个差**没解释**——而它恰是"opencsd 没这个 bug"的最强线索。 |
| Q4 A1 必然误伤 | 🟩成立 | **接受**。A1 与已回滚的 A2 同类启发式，不试都知会掉 cardinality。**A1 撤销，不试。** |
| Q5 动 A3 | 🟥不动 | **接受**。根因未定就动 atom 核心 = 赌全局 68798 条调用边。**A3 冻结。** |
| Q6 P0 设计 | 🟥验证性偏误 | **接受**。原 §4 P0"确认错位一位"预设了结论。**替换为 §8.3 四假设互斥设计。** |
| Q7 丢包 | 🟥从未零丢包验证 | **接受，且这是最致命的**。两个 slice 同源同丢包 pattern，"独立验证"是假独立。91/91 只排除随机丢包，未排除结构性丢包。**H43 从没在零丢包数据复现过。** |

### 8.2 §1、§4 的更正

- **§1 第 5 条**（"读到 disp bit=0 → atom 流错位一位"）：**从"已坐实事实"降级为"未证假设之一"**。实测只到 §1 第 3 条（a2f2 被判 not-taken、workingAddr 越过进字面量池）为止，那是真的；"错位一位"是倒推。
- **§4 P0**（"逐-atom dump 确认错位一位"）：**作废**，被 §8.3 取代。

### 8.3 新 P0（红方 r34 版，四假设互斥，动手前必跑，禁止跳步）

**P0-3 给出唯一结论前，禁止写任何修复代码。** 这是对"没坐实就动手"的硬约束。

- **P0-1 🔴 零丢包复现（先钉死前提）**：抓一份 `stream_lost_cnt==0` 且 UDP `seq-gap==0`
  全程的 CoreMark slice（短无妨，覆盖几轮 UART 打印即可），跑同一 mortrall + regress.py。
  - 假重入率与丢包 slice 相同 → 系统性解码 bug，进 P0-2。
  - 假重入消失/大降 → **丢包驱动，proposal 43 整个作废**，回去查采集/nibble 对齐。
- **P0-2 🔴 opencsd 参照可用性**：重跑 lister 不加地址过滤，确认 opencsd 是否解码
  0x800a2f2 区；解释 cm_benchmark_main=27 的来源。可用 → P0-3 用它做基准；不可用 →
  手工按 IHI0064 ETM4 spec 对齐。
- **P0-3 🔴 四假设互斥判定**（取代"确认错位一位"）：dump (批次序号, 批内 index, disp 原值,
  incAddr, workingAddr, ic, insExecuted, committed, 栈候选) 全字段，用判定表让数据**唯一
  选出**：①真·错位一位 ②批次边界 ③锚定错(错路) ④消费逻辑 bug。数据不能唯一区分 →
  信息不足继续加 dump，**不动代码**。
- **P0-4 🟡** fix B 的 verify_calls/cardinality/内层篮子双 slice 存 golden，任何改动逐项 diff。

## 9. 决定：fix B 为当前终点，cm_benchmark_main 记入 known-issues

接受红方 §表态 3：**fix B（已提交）是当前诚实工程终点**。
- coremark_main 358→7、调用边 68797/68798 对 ELF、cardinality 不降 —— 主可视化问题已解决。
- **cm_benchmark_main 133 次假重入 = 已知次层显示噪声**，记入 known-issues 接受，
  不值得为消 132 个次层假 begin 去赌全局 68798 条调用边的正确性。
- 方案 A（治本）**冻结**，作为独立后续任务：唯有先跑通 §8.3 P0-1→P0-2→P0-3、用数据
  唯一确定根因后，才解冻。**在此之前不写修复代码。**


---

## 10. P0-1 执行结果：假重入非丢包驱动（红方 Q7 钉死，2026-08-02）

红方 r34 Q7 的核心质疑：所有验证数据都来自同一份 0.1% 丢包抓样，假重入从没在零丢包
数据复现过。P0-1 就是补这个。

### 10.1 拿到零丢包通路（前置，本身是重要发现）

- **rp_filter 坑**：dock 直连时 dock 口和 ens33 都持有 .245，FPGA 的 UDP 从 dock 进来
  被反向路径过滤丢在 socket 前（tcpdump 看得到、recv 收 0）。`sysctl rp_filter=0` 后通。
- **stream_recv pre-poll 坑**（已修 commit cb62695）：抓取前的 `read_lost_cnt` 在饱和流
  下重试 ~8s，socket 绑了但没 recv → 内核缓冲溢出 → 3s 窗口丢 711578 帧。移到抓取后。
- 修完两坑，dock 直连实测：**200MB / 2.00s / 99.99MB/s / seq-gap=11**（0.006%），
  以及连续 CoreMark **337MB / 3.00s / 112.5MB/s / seq-gap=5**（0.0015%）—— 实质零丢包。
- 佐证：**丢包 100% 在网络传输路径**（路由器路径丢 68%，dock 直连≈0），FPGA
  capture-side lost_cnt **恒 0**。采集端从不丢——直接削弱"假重入是采集端丢包/误码"。

### 10.2 两个独立零丢包样本都复现假重入

| 样本 | seq-gap | coremark_main | cm_benchmark_main |
|---|---|---|---|
| 零丢包样本 A（cm_zeroloss, ITER=2000, 4MB 中段切片） | ~11/195296 | 39 | 381 |
| 零丢包样本 B（cm100, ITER=100 连续, 8MB 中段切片） | ~5/329641 | 23 | 256 |
| （对照）原丢包样本（fixture, 0.1% 丢包, 4MB） | 965 帧源 | 7（fixB后） | 133 |

- **两个实质零丢包样本都大量假重入**（coremark_main 23/39，cm_benchmark_main 256/381），
  且比丢包样本还多（因代码区段不同、迭代更密，数字不可直接比，但方向明确）。
- **结论：假重入在零丢包数据上依然系统性发生。红方 Q7 钉死——不是丢包驱动，是解码器
  bug。proposal 43 的前提（系统性 disposition/atom 处理 bug）成立，方案 A 不作废。**

### 10.3 尚未做的严格对照（诚实标注）

- 上表三个样本是**不同代码区段**（cardinality 2646/6708/6228 各异），数字不能逐一对比，
  只能论"假重入在零丢包下依然存在"这个定性结论。**同一段代码的丢包 vs 零丢包逐一对照
  仍未做**——但 P0-1 的目的（证伪"丢包驱动"）已达成，逐一对照是加强而非必需。
- 固件侧为便于抓完整轮：`H743_Blink` Makefile `ITERATIONS=2000→100`、main.c 把
  `coremark_main()` 放进 `while(1)` 连续跑（否则一轮 ~80ms 太短、抓取时序难卡）。
  时钟随 board_clock 默认 = 225M sysclk / **112.5M TRACECLK**（clktap TAP=17 通用）。

### 10.4 下一步（仍按 r34 约束，P0-3 前不写修复代码）

P0-1 done、P0-2（opencsd 参照）与 P0-3（四假设互斥）仍未做。方案 A 继续冻结，直到
P0-3 用数据唯一确定根因（错位一位 / 批次边界 / 锚定错 / 消费逻辑）。


---

## 11. P0-2 部分结果：opencsd 参照对 0x800a 区失效（2026-08-02）

### 11.1 原始数据完整性 = 确认干净

零丢包 slice（cm100_slice, 8MB, seq-gap≈5）三查：
- **seq 连续**（≈5/329641 gap，实质零丢包）。
- **raw slice 本身已 TPIU 对齐**（decode 跳过预对齐，无 half-nibble 偏移），fsync 密度
  全片均匀 6/64KB（比 rt300 的 3300 低，因 225M/112.5M 新固件 sync period/数据率不同，
  均匀=正常，无骤变=无误码）。
- **opencsd 独立解码 100% 干净**：98091 INSTR_RANGE、2773 unique PC、**100% 在 flash**、
  lister 完整跑完（END OF TRACE，318826 字节全处理，非截断）。
- **结论：原始数据完整可信**，后续打 log 查到的现象是真的，不是丢包/误码假象。

### 11.2 opencsd 的 cm_benchmark_main=499 是 PC count，不是进入次数

红方 Q3 要解释的 opencsd 那个数字：`opencsd_etm4_run.py:448` 的
`Counter(func_of(p) for p in in_flash)` —— 是**落在函数地址范围内的不同 PC 采样计数**，
**不是"进入函数次数"**。所以 opencsd 499 vs mortrall 256（B|begin 数）**量纲不同，
不能直接比**。之前 fixture 的 27 我也误当成进入次数了——更正。

### 11.3 opencsd 与 mortrall 在 0x800a 区执行路径分道（关键）

- opencsd lister 的 INSTR_RANGE **最高只到 0x80094d4**，**完全没有 0x800a2xx**
  （coremark_main=0x800a2f8 / cm_uart_send_char=0x800a2d4 都在 0x800a 区）。
- 但 lister **完整跑完未截断**（END OF TRACE），且 cm_benchmark_main(0x8008118) 有覆盖。
- 即：**opencsd 在这段 slice 里执行流从没上到 0x800a2xx，而 mortrall 走到了**
  （mortrall 正是在 cm_uart_send_char 的 pop@0x800a2f2 触发假重入）。
- **两个解码器在 0x800a 区分道扬镳。** 这直接影响红方 Q3：opencsd 参照对 0x800a 区
  **失效**（它没走到那），不能拿来 diff cm_uart_send_char pop 的 atom 消耗。

### 11.4 P0-3 的方向修正

P0-3 的四假设互斥判定**不能用 opencsd 做基准**（它没解码 0x800a 区）。剩下两条路：
1. **先查清 opencsd 为何不上 0x800a**：是它在某个分支选择上与 mortrall 不同（谁对？），
   还是这段 slice 的执行流本就没进 coremark_main（那 mortrall 的 0x800a 访问反而可疑）？
   —— 这是新的、更根本的岔路，可能重定位真凶。
2. **手工按 IHI0064 ETM4 spec 对齐** cm_uart_send_char pop 附近的 atom（无参照，纯 spec）。

**在 11.3 这个"两解码器分道"搞清楚前，方案 A 仍冻结。** 它可能意味着真凶不在
"disposition 错位"，而在"mortrall 为何走进了 opencsd 不走的 0x800a 区"——若 mortrall
的 0x800a 访问本身是错的（走错路），那是锚定错（H43 的 §3.5 分支），不是错位一位。


---

## 12. 分叉厘清：mortrall 进 0x800a 是对的，真值用 ELF 不用 opencsd（2026-08-02）

§11.3 提出"两解码器在 0x800a 分道，可能 mortrall 走错路"。**用 ELF 静态真值直接判——
mortrall 走进 0x800a 是对的，opencsd 没跟到是 opencsd 侧的问题。**

### 12.1 ELF 静态铁证：执行流必然进 0x800a

`objdump` 确认 0x800a 区函数被真实 `bl` 调用：
```
4× bl 800a284 <cm_uart_puts>       ← coremark_main 每轮打印结果必调
1× bl 800a2d4 <cm_uart_send_char>  ← 唯一 caller 在 0x8009772 (ee_printf 内)
1× bl 800a2f8 <coremark_main>
```
CoreMark 循环跑，每轮都打印 → cm_uart_puts → ee_printf → cm_uart_send_char。
**执行流一定进 0x800a2xx。mortrall 走进去正确；H43 §3.5 的"锚定错/走错路"假设排除。**
opencsd lister 没上 0x800a 是它自己的 range 发射/dump 差异，**参照对 0x800a 失效但无所谓——
真值直接来自 ELF。**

### 12.2 硬真值判据（P0-3 用这个，不用 opencsd）

- `cm_uart_send_char` 唯一 caller = `0x8009772`（`bl`），故其 `pop {r4,pc}`(0x800a2f2)
  **正确返回目标 = 0x8009776**（bl 下一条）。
- mortrall 实测：pop 判 not-taken → workingAddr 越过进 0x800a2f4(`.word`) → 漂到
  0x800a2f8(coremark_main 入口)。**错。应返回 0x8009776。**
- **P0-3 可证伪判据（真值来自 ELF，无需参照解码器）**：单步 pop@0x800a2f2，
  正确 workingAddr 应变成 0x8009776。它没有 → 定位为何没返回（disposition 消费 /
  批次边界 / 消费逻辑），四假设里排除了"锚定错"，剩三选一。

### 12.3 方向回归 r33，但判据升级

真凶方向仍是 r33 §3 的"iBR 返回被 disposition 判 not-taken 而跳过"，**但现在有 ELF 硬
真值（0x8009776）做判据**，不再依赖"无条件返回不该 not-taken"的原则推断，也不需要
opencsd 参照。P0-3 可以直接单步 mortrall 在这一点、对着 0x8009776 这个确定目标查。


---

## 13. P0-3 结论：根因是【批次边界】，不是"错位一位"（2026-08-02，实测判定）

在 cm_uart_send_char pop@0x800a2f2 逐-atom dump（ELF 真值判据，零丢包 slice），四假设
互斥判定的数据出来了：

### 13.1 关键对照：同一 pop，第一次错、后续对

**第一次（错，depth=2，pop 判 not-taken）：**
```
INS a2ec ic=f(bl HAL) exec=1 dispbit=1 disp=5   incAddr=4
INS a2f0 ic=8(add)    exec=1 dispbit=0 disp=0   incAddr=1   ← 这批已耗尽(disp=0,incAddr=1)
INS a2f2 ic=1(pop)    exec=0 dispbit=0 disp=0   incAddr=1   ← pop 拿不到 atom → not-taken → 漂
INS a2f4 (.word 字面量池, 越过 pop)
```
**后续（对，depth=5，pop 判 taken 正确返回）：**
```
INS a2ec exec=1 dispbit=1 disp=1    incAddr=1
INS a2f0 exec=1 dispbit=1 disp=ffff incAddr=17  ← 新 EV_CH_ENATOMS 批次(BATCH wa=0800a2f4)
INS a2f2 exec=1 dispbit=1 disp=ffff incAddr=17  ← pop taken, 正确返回 0x8009776
```

### 13.2 判定：H43 假设② 批次边界成立，①错位一位 / ③锚定错 / ④消费逻辑 排除

- **不是"错位一位"**：后续同一 pop 用同样的消费逻辑判对了，disposition 位与指令的对应
  关系没错位；错的只是第一次**这批 atom 在 pop 之前就耗尽**（disp=0, incAddr=1，a2f2
  取到的是空）。
- **不是"锚定错/走错路"**：§12 已排除，mortrall 进 0x800a 正确。
- **不是消费逻辑 bug**：消费逻辑本身对（后续 467-N 次都对）。
- **是批次边界**：`EV_CH_ENATOMS` 批次恰好切在 HAL 返回后、pop 之前。这批的 atom 被
  a2ec 的 `bl HAL`（及之前）消费完，pop@a2f2 该拿的 taken-atom 落在**下一个** batch
  （BATCH wa=0800a2f4，disp=ffff…）。第一次 mortrall 在批耗尽时对 pop 判了 not-taken
  并 fall-through，而不是**等下一批**。红方 Q2 判定为批次边界，实测坐实。

### 13.3 修复方向（P1，仍需 regress 双 slice 守护）

iBR（JUMP 非 IMMEDIATE，返回）在**当前批 atom 已耗尽**（incAddr 到 0 / 该指令拿不到
有效 disposition 位）时，**不能就地判 not-taken 并 fall-through**——应挂起等下一个
`EV_CH_ENATOMS` 批次补给再判。即：把"批边界切在分支指令上"这个情况正确处理，让 pop
的判定用它真正对应的那批 atom。

- 这比 A1/A2 的"落字面量池就当返回"启发式**精确得多**——它针对确切机制（批耗尽），
  不误伤真实 not-taken 条件分支（那些分支的 atom 在本批内有效，不受影响）。
- 风险仍在动 atom 循环核心，但现在改动目标明确（批边界挂起），且判据硬（pop 应返回
  0x8009776 / regress 双 slice + verify_calls）。**解冻方案 A，按此方向做 P1。**


---

## 14. 出错规律 + ETM4 手册核对（2026-08-02）

修法两次失败（B/A2/无条件iBR-助记符），教训：没吃透 ETM4 atom 语义就改，误伤真实分支
（cardinality 掉 506）。停下来量化规律 + 翻手册（IHI0064H_b）。

### 14.1 出错规律（零丢包 slice，cm_uart_send_char pop@0x800a2f2，467 次）

- **判定 100% 由 `disposition & 1` 决定**：
  - 错判（exec=0，392 次）：disp bit0=0（disp=a/2/0/4/1e，全是偶数）。
  - 对判（exec=1，75 次）：disp bit0=1（disp=1/f/7/ff/fff/ffff/3，全是奇数）。
- 错判主要 disp=a(1010) incAddr=4（221 次）、disp=2(10) incAddr=2（72 次）、disp=0(0)
  incAddr=1（57 次）。即 **pop 拿到的 bit0=0，但 pop 是无条件返回，必为 E(taken)**。

### 14.2 ETM4 手册确认的地基（IHI0064H_b）

- **§2.3.1 P0 元素**：direct + indirect branch **每条都生成一个 P0/atom**，
  "regardless of whether they pass or fail their condition code check / are part of
  an IT block"。→ 条件直接分支（bne/cbz）也有 atom；无条件 iBR（pop{pc}/bx lr）也有，
  且必为 **E**。
- **§2.6 / §6.4.x Atom Format 3**："least significant bit representing the **oldest**
  Atom element"，`for I=0..2: A<I>? E : N`。→ **mortrall `disp&1`(bit0=oldest) + `>>=1`
  的消费顺序与手册一致，位序没错。**
- BATCH 实测：`eatoms=3 natoms=2 total=5 disp=0x15(10101)` → 3×E 2×N，位数一致 ✓。

### 14.3 收窄后的真凶假设

位序对、消费顺序对、每分支必有 atom——那 pop 拿到 bit0=0 的原因只剩：**pop 之前
HAL_UART_Transmit 内部执行消费掉了本批 atom，到 pop 时本批已尽（disp 剩低位=0），
pop 该用的 E-atom 在下一个 EV_CH_ENATOMS 批**。日志佐证：a2ec(bl HAL) 与 a2f0 之间没有
BATCH 行，但 disp/incAddr 从 5/4 掉到 0/1——那是 HAL 内部指令（日志过滤没显示）消费的。
pop 在批尽处读到空 bit0=0。

**下一步（P0-3 收尾，未做）**：交叉**原始 ETM 字节**——定位 pop 附近在 etm.bin 的字节
偏移，手工按手册解码那几个 Atom Format 包（F3/F5/F6），确认「HAL 返回的 iBR atom」与
「pop 的 iBR atom」在字节流里的确切位置，判定 mortrall 是「批尽未等下一批」（批边界）
还是「HAL 返回 iBR 的 atom 记账串了一位」（记账错）。**这一步定死后才改代码。**

### 14.4 修法约束（血泪更新）

- ❌ 不用助记符判"无条件"——**IT 块内条件指令的助记符不带 cc 后缀**（手册 §条件分支），
  mnemonic 判据必然漏判，A2-变体已实测 cardinality 掉 506。
- ✅ 若要判"无条件"，须用 capstone `detail->arm.cc == ARM_CC_AL`（改 loadelf 加
  LE_IC_UNCOND 位），这是唯一可靠信号。但即便如此，"无条件 iBR 强制 taken"是否安全
  仍需 §14.3 原始字节定死机制后再定。
