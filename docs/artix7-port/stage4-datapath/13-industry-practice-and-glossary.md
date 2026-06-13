# Stage-4 · 业内怎么对付这个问题 + ORBTrace 怎么解 + 名词通俗科普

> 上网查了 sigrok、ARM CoreSight 设计指南、Cortex-M4 TRM、SEGGER 论坛、orbtrace，把"4-bit 并行 trace 字节对齐/帧同步"这个我们卡住的问题对照业内做法理一遍，并把 I-sync 这些名词讲人话。

---

## 0. 名词通俗科普(先把黑话翻译成人话)

我们这条链路上的"I 什么的"其实是 ARM 给指令流压缩定义的几种**数据包**。打个比方:**ETM 就像给 CPU 装的行车记录仪,但为了省带宽,它不录"每一帧画面",只录"拐弯/变道"和偶尔报一次"我现在在哪条路上"。**

| 名词 | 全称 | 人话解释 |
|------|------|----------|
| **ETM** | Embedded Trace Macrocell | CPU 里的"行车记录仪"硬件,把执行过的指令压成 trace 流吐出来 |
| **TPIU** | Trace Port Interface Unit | "打包快递的"——把 ETM(可能还有 ITM)的数据打包成统一格式从引脚发出去 |
| **A-sync** | Alignment Sync(对齐同步) | 一长串 0 再加个 0x80(`00 00 00 00 00 80`)。作用是**"找字节边界"**——解码器在乱码里找到这串就知道"包从这之后重新开始"。像广播里的"嘀——"对时声 |
| **I-sync (ISYNC)** | Instruction Sync(指令同步) | **"我现在在哪条路上"的绝对报告**:带一个完整的 4 字节绝对 PC 地址。解码器靠它才知道当前执行到哪。是我们解码的"铁锚" |
| **P-header** | Packet header(原子包头) | **"过去这几条指令执行了没"**:一个字节编码"执行了 N 条 / 没执行 M 条"。不带地址,只说"往前走了几步" |
| **Branch packet** | 分支包 | **"拐弯了,拐到这个地址"**:带跳转目标地址(压缩编码)。间接跳转才发 |
| **Atom** | 原子 | P-header 里的最小单位:一条指令"执行了(E)"或"没执行(N)" |
| **D-sync / T-sync** | 数据/时间戳同步 | 数据 trace、时间戳的对齐包,我们指令 trace 用不到 |
| **TraceID** | — | 多个 trace 源(ETM/ITM)共用一根线时,每个源的编号。我们配的是 2 |
| **Formatter** | TPIU 格式化器 | 把多个源的数据切成 **16 字节帧**、每帧打上 TraceID、周期插一个"帧对齐同步字"`0xFFFFFF7F`。多源复用时必须开 |

**解码怎么工作(人话版)**:解码器先靠 A-sync 找到字节边界 → 等一个 I-sync 知道绝对位置 → 之后靠 P-header(走了几步)+ Branch(拐到哪)推算每条指令的 PC,直到下一个 I-sync 再校准。**丢了字节边界,后面全乱,直到下一个 A-sync 重新对齐。**

---

## 1. 业内怎么对付"4-bit 并行 trace 字节对齐"

查了 sigrok(开源逻辑分析仪的事实标准)的 `arm_tpiu` 解码器,业内做法很清楚:

### (a) 帧同步字很稀疏,靠"手动 sync_offset"对齐
sigrok 原文:**"sync 包以相当长的间隔发出(好几秒一次)"**,所以它提供 **`sync_offset` 选项(0-15)跳过开头若干字节手动对齐**。这正是我们做的 bit/byte-shift 重对齐——**业内标准做法就是手动试偏移**,因为不能等几秒一次的全同步。

### (b) 单源可以关 formatter 去掉开销
sigrok 原文:**"有些芯片单源时可关掉 TPIU formatting 去掉帧开销,这时 arm_etmv3 解码器可以直接叠在 uart 上"** —— 即**单源裸 ETM 直解,不过 TPIU**。这正是我们消去法得到的路线(`etm35lib` 直接锚 I-sync,绕过 demux)。

### (c) 靠"≥16 字节空闲"自然重同步
sigrok:**"如果偶尔有 ≥16 字节的暂停,同步会在那之后自动恢复"**。

---

## 2. ★ 关键发现:Cortex-M4 上 formatter【不能】关(否则 ETM 数据被丢)

这条解开了我前几轮的矛盾。**Cortex-M4 TRM (DDI0439B) 明确**:
> "if [formatter] is bypassed, only the ITM and DWT trace source passes through. **The TPIU accepts and discards data from the ETM.**"

即 **M4 上一旦 bypass formatter,ETM 数据被直接丢弃**,只剩 ITM/DWT。所以**要并行 ETM 指令 trace,formatter 必须开**(我们 FFCR=0x102 开着,对)。→ **我们引脚上的流确实是 formatter 16 字节帧**,不是裸 ETM。

那为什么我们看不到周期 `0xFFFFFF7F`?**因为 TPIU 的帧同步计数器(FSCR)默认每 65536 字节才插一次全同步**(CoreSight SoC TRM:12-bit 计数器,4096 帧 × 16 字节 = 65536 字节)。**我们才抓 60KB,所以可能一个全同步都没有或只有一个!** 这和 sigrok 说的"sync 好几秒一次"完全一致。

→ **这就是根因(高把握)**:不是 SI、不是 nibble、不是裸 ETM。是 **formatter 帧同步字 64KB 才一个,我们 60KB 窗口抓不到,所以 TPIU 解码器没有帧边界锚点**;而 ETM 的 A-sync(每 1024 字节)我们有,所以**绕过 TPIU、直接按 ETM A-sync/I-sync 解**反而能出结果——这正是我们走通的路。

---

## 3. ORBTrace 怎么解(对照)

- **硬件侧**:ORBTrace Mini 用 ECP5 收 trace,gateware 里 `TPIUSync` 找 `0xFFFFFF7F` 锁帧 → `TPIUDemux` 解 16 字节帧 → 按 TraceID 分流 → COBS/OrbFlow 封装走 USB。
- **它为什么不卡这个**:① ORBTrace 通常配合**会缩短帧同步周期**的配置,或抓**长时间连续流**(几秒以上,等得到 65536 字节一次的全同步);② 它是**连续 USB 流**不是我们的 60KB one-shot 快照,跑够久总会撞上全同步帧而锁定;③ 之后**自然重同步**(sigrok 的 (c))维持。
- **我们的差异**:我们是 **60KB one-shot 快照**,小于一个 formatter 同步周期(64KB),所以**大概率抓不到帧同步字**→ 不能走 TPIU 帧解码。这不是 bug,是**抓取窗口 < 同步周期**的必然。

---

## 4. 结论:三条可选正路(都对齐业内做法)

| 路 | 做法 | 业内依据 | 我们状态 |
|----|------|----------|----------|
| **A 缩短 formatter 同步周期** | 写 STM32 TPIU 的 **FSCR** 把帧同步从 64KB 缩到 ~1KB,让 60KB 窗口里有几十个全同步 → TPIUSync 能锁 → 标准 TPIU 解码 | sigrok/CoreSight 标准路 | **没试过(高价值,下一步)** |
| **B 抓更大窗口** | capture 加深到 >64KB(35T 的 BRAM 够),保证至少一个 formatter 全同步 | ORBTrace 连续流思路 | 容量够,没试 |
| **C 绕过 TPIU 直解 ETM** | 按 ETM A-sync(1KB/个)+ I-sync 锚点直接解,不要 TPIU 帧 | sigrok"单源直叠 etmv3" | **已走通(当前方案)** |

**最该试的是 A**:STM32 的 TPIU `FSCR`(Formatter Sync Counter,寄存器偏移 0x308)如果能写小,60KB 里就有几十个 `0xFFFFFF7F`,TPIUSync 一锁,后面就是标准 16 字节帧解码——**这是最干净、最对齐业内、且能让连续流变铁证的路**,而且不依赖我们自己的子字节 trick。

---

## 5. 一句话总结

**业内对付 4-bit trace 字节对齐就两招:① 手动 sync_offset 试偏移(sigrok 标配,我们的 bit-shift 就是这个);② 单源时绕过 TPIU 直解 ETM(我们走通的路)。** 而我前几轮的核心困惑——"为什么没有 TPIU 帧同步字"——根因查清了:**Cortex-M4 必须开 formatter(否则丢 ETM),但 formatter 的帧同步字默认 64KB 才一个,我们 60KB one-shot 抓不到**。所以要么**缩短 FSCR 同步周期(路 A,最该试)**,要么**抓 >64KB**,要么**继续绕过 TPIU 直锚 ETM I-sync(现方案)**。这三条都对齐业内,不再是玄学。
