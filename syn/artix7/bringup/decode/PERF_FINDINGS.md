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

## Deliverable 1: reliable anchor-level LVGL timeline (mmcm_stream_timeline.py)

Each I-sync anchor (ground-truth absolute PC) placed on the FPGA uniform
wall-clock. Two outputs:
- `<out>_flat.json`  : flat track, one slice per [anchor, next-anchor) labelled
  with the function. NO nesting heuristic -> honest "which function ran when".
- `<out>.json`       : best-effort nested call stack (build_stack_events
  heuristic; exact for clean call/return like proj_add, approximate for LVGL).

Drag either into https://ui.perfetto.dev.

LVGL 4MB capture -> 244 flat slices over 189.6 ms. Time distribution (top):
  lv_timer_handler 8.5%, lv_draw_sw_line 7.2%, lv_tick_elaps 5.4%,
  lv_timer_time_remaining 5.1%, lv_draw_sw_polygon 4.5%, get_prop_core 4.3%,
  inv_arc_area, lv_font_get_glyph_dsc_fmt_txt, ...  (a real LVGL UI profile).

Honest caveat: a flat slice's duration spans to the NEXT I-sync anchor (the
F429 I-sync period is ~1024 ETM bytes), so durations are a COARSE attribution
(they include whatever ran between anchors), not exact per-function cycle
counts. The function identity at each anchor is ground truth; the inter-anchor
attribution is approximate. Exact per-function timing needs the per-instruction
nesting (Mortrall §11 return-stack work).

## UPDATE: orbetto DOES handle indirect calls — two real bugs, now fixed

The earlier "LVGL call stack is hopeless / indirect calls derail" conclusion was
WRONG. orbetto/Mortrall reconstructs indirect-call nesting fine (branch
broadcast puts every taken-branch target in the stream). The 381-slice mess was
two unrelated bugs:

### Bug 1: wrong deframe fed to orbetto (mmcm_stream_orbetto.py)
I deframed the capture with `want_stream=2`. The F429 capture is a SINGLE-source
bare-ETM-in-TPIU stream; stream-id filtering treats data bytes whose even-slot
bit0=1 as spurious stream switches and drops the bytes after them -> 8.9%
unknown, corrupt. Fix: use the continuous re-aligning walker over ALL data
(`tpiu_deframe_walk`, 2.9%). Reframe THAT to stream 2 for orbetto.
  -> slices 381 -> 65040.

### Bug 2: loadelf resolved only DWARF functions (orbuculum Src/loadelf.c)
symbolFunctionAt() used only DWARF DW_TAG_subprogram ranges. Functions present
in .symtab but with incomplete DWARF function DIEs (millis, lv_tick_get,
lv_tick_elaps, ...) returned NULL -> Mortrall emits `B|0|0x........` raw.
Verified with symprobe.c (links the same loadelf): NULL before, named after.
Fix: _addSymtabFunctions() appends symtab STT_FUNC entries for ranges DWARF
missed (additive; DWARF wins where present). Patch saved as
orbuculum-loadelf-symtab-fallback.patch (the orbetto meson subproject copy is
gitignored, so re-apply there after a fresh checkout).
  -> named call slices 0% -> 98%.

### Result (LVGL, 4 MB / 190 ms)
65040 call-stack slices, 98% named, real nested LVGL flow on the FPGA wall-clock
(lv_timer_handler, lv_tick_*, lv_draw_*, millis, ...). The residual 2% raw +
sparse spots are the 2.9% unknown ETM bytes (real capture noise at this phase),
not a decoder limitation.

Tools: symprobe.c / build_symprobe.sh (query symbolFunctionAt for an addr),
mmcm_stream_orbetto.py (clean walker -> reframe -> .tpiu + .fpga_ns).
