# scripts/attic — 归档脚本（历史阶段性产物）

**⚠️ 这里的脚本不再使用，只保留 git 历史。** 新的调用入口是
`syn/artix7/bringup/scripts/trace_doctor.py`（proposal 41）。

| 脚本 | 归档原因 | 替代 |
|------|---------|------|
| `pin_multi_toggle.py` | 旧调试遗留（proposal 早期，pin_la bit 前） | `trace_doctor probe wire` |
| `eye_scan_42m.sh` | 42MHz 特定，主线已过 100M+ TRACECLK | `trace_doctor tap eye-sweep` |
| `perlane_idelay_cal.py` | proposal 33 per-lane IDELAY 已撤销，clktap 主力 | `trace_doctor tap set-lane` |
| `freq_scan_oversample.sh` | OVERSAMPLE 方法已被 IDDR 替代（doc 16） | `trace_doctor freq sweep` |
| `mmcm_q42.sh` | Q42 阶段性 | `trace_doctor mmcm test` |
| `swo_dump_banked.py` | 非 ETM 主线（SWO 分支） | 无（保留归档） |
| `swo_live_bridge.py` | 非 ETM 主线 | 无 |
| `swo_to_orbetto.sh` | 非 ETM 主线 | 无 |
| `decode.sh` | 被 `trace_doctor decode` 替代 | `trace_doctor decode opencsd` |

**恢复方法**：`git mv attic/xxx.py ../xxx.py`；或直接 `python3 attic/xxx.py`。

**agent 找不到某脚本**：先 `trace_doctor <group> --help`；仍找不到 → `grep -rn <name>
attic/` 看归档去向。
