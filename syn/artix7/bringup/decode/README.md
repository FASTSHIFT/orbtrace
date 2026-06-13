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
