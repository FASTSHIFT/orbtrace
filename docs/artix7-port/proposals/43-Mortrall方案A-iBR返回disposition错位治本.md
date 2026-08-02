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
