# decode/ — PC-side trace decode tooling

Python (+ reference C) tooling that turns a captured byte stream into decoded
ETM3.5 instruction flow. All Python modules import flat (`import etm35lib`), so
run pytest / scripts from inside this directory.

## Core library
- `etm35lib.py` — spec-grounded ETM3.5 decode library (I-sync anchoring,
  P-header atoms, Thumb branch decode, TPIU sync strip/deframe, region
  reconstruction). Unit-tested; the single source of decode truth.
- `etm_reconstruct.py` — image-driven per-instruction reconstruction: walks the
  atom/branch stream against the disassembled ELF.
- `perfproto.py` — shared Perfetto `.perf` protobuf reader (`read_varint`,
  `parse_fields`, `iter_ftrace_prints`, `load_ftrace_prints`). Single copy of
  the varint/wire-format walk the perf tools below used to each inline.
- `nibble_align.py` — shared FPGA nibble→byte alignment (`best_align`): picks
  the phase/order that maximises TPIU HSYNC (FF7F). Used by the SI / period /
  completeness probes.

## perf (.perf) inspection tools
- `perf_dump_tree.py` — indented B/E call tree per PID (demangled), to eyeball
  nesting sanity + whether timestamps are real FPGA wall-clock.
- `anomaly.py` — flags impossible symbols / raw 0x slices / absurd-duration
  slices in the main callstack (stack-desync suspects).
- `diag_deepstack.py` — replays B/E to check func_test over/under-nesting
  (deep>6, factorial<4) against known ground truth.
- `verify_functest.py`, `exc_audit.py`, `perf_ts*.py`, `perf_slice_ts.py`,
  `pb_dump.py` — func_test scorer, per-PID exception audit, timestamp probes.

## capture-quality probes (self-supervised, no logic analyser)
- `si_probe.py` — per-lane / per-half signal-integrity probe using TPIU HSYNC
  as a known reference pattern (localises skew to a lane/DDR-half).
- `period_find.py` / `loop_period.py` — find the deterministic main_loop period
  (autocorrelation / I-sync anchor gaps) — prerequisite for voting.
- `period_vote.py` — cross-iteration majority-vote channel error rate.
- `nibble_completeness.py` — unknown-byte rate under the HSYNC-max alignment.

## CLIs
- `etm_decode_cli.py` — end-to-end report: anchors → functions via addr2line.
- `etm_isync_decode.py` — thin I-sync anchor extractor CLI.
- `dsl_parse.py` — parse a DSView `.dsl` logic-analyser capture → byte stream
  (auto DDR alignment + TPIU sync-filler strip).
- `dsl_clkcheck.py` — TRACECLK health check on a `.dsl`.
- `drive_orbmortem.py` — drive the ncurses orbmortem non-interactively (reuse
  the upstream decoder instead of our own).

## Reusing the orbuculum decoder (preferred for instruction flow)
- `orbetm.c` + `build_orbetm.sh` — non-interactive instruction-flow
  reconstruction that LINKS orbuculum's decoder (`traceDecoder*` + `loadelf.c`
  + capstone). A stripped port of orbmortem's `_traceCB` loop. Build with
  `./build_orbetm.sh` (needs the orbuculum checkout built once so its vendored
  libdwarf exists), then `./orbetm <elf> <bare-etm-file>`. Input must be a
  bare-ETM stream (run `dsl_parse.py` first to strip TPIU fillers).
  NOTE: on branch-broadcast-off sparse trace the PC runs away after unresolved
  indirect branches — a data limitation orbuculum shares (~27% of decoded
  addresses land in code); orbetm gates on a code window to suppress the junk.

## Investigation scratch (kept for provenance)
- `etm35_walk.py`, `etm_raw_scan.py`, `tpiu_analyze.py`, `lane_sweep.py` —
  one-off analyses used while reverse-engineering the stream format.
- `etmdecode.c`, `etmdecode2.c` — minimal non-interactive decoders built
  against orbuculum's traceDecoder lib.

## Tests + fixtures
- `test_etm35lib.py`, `test_etm35_golden.py`, `test_etm_reconstruct.py`
- `captures/` — committed regression fixtures (small `.bin` slices).

Run: `python3 -m pytest -q` from this directory.
