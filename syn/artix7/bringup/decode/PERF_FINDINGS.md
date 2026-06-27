# LVGL orbetto.perf inspection (simple verification first)

Tool: `perf_slice_ts.py` (counts FtraceEvent call-stack slices B|/E|/I|).

## Slice density: proj_add (baseline) vs LVGL

| capture | ETM bytes | window | call-stack slices | named funcs |
|---------|-----------|--------|-------------------|-------------|
| proj_add (streamed) | 772157 | 1.34 ms | **4438** | add×1761, loop_sum×351, setup×107 (all named) |
| LVGL (streamed)     | 945419 | 171 ms  | **381**  | mostly raw `B|0|0x080..` (derailed) |

proj_add: dense, fully-named nested call stack -> the streaming + orbetto + FPGA
uniform-time pipeline is CORRECT.

LVGL: only 381 slices over 171ms, most are raw PCs (e.g. `0x0800559c` =
`_lv_ll_get_next`, resolvable by addr2line but emitted raw by Mortrall).

## Why LVGL is sparse (root cause)

- The LVGL ELF (proj.axf) HAS full DWARF (.debug_info/.debug_line) -> not a
  symbol/debug-info problem.
- The raw-address slices are emitted when Mortrall's call-stack reconstruction
  is DERAILED (lost PC). orbetm independently shows 98% of LVGL instructions
  dropped (off-code) vs 0.1% for proj_add.
- Root cause = LVGL's heavy INDIRECT control flow (callbacks, function pointers,
  vtable-like dispatch, deep nesting, interrupts). After an indirect return
  (`pop {pc}` / `bx lr`) whose target isn't in the stream, the decoder loses the
  PC until the next anchor; with broadcast ON the next branch-address packet
  re-anchors, but between them the reconstruction emits raw/unknown PCs.
- This is exactly doc 14 §11: the fix is robust call-stack / return-address
  tracking (indirect branch -> WAIT for the next address packet, don't guess),
  not a sampling or symbol issue.

## What IS reliable from the LVGL trace (usable now)

- I-sync ANCHORS: 203 distinct real LVGL functions across 0x800130a..0x803f2c2
  (lv_timer_handler, lv_draw_label, lv_draw_sw_line, draw_letter_normal,
  lv_font_get_glyph_dsc, fill_normal, lv_color_mix, lv_obj_redraw,
  lv_obj_update_layout, ...) -> a trustworthy function HOT-SPOT view.
- PC bitmap cardinality 1232 on a real 190ms time axis (PC sampling).

## Next: fix the call-stack reconstruction for indirect returns (doc 14 §11)
