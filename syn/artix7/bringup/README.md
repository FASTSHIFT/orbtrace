# Artix-7 bring-up workspace

Tooling for bringing up the A7-Lite (XC7A35T) ORBTrace port and decoding
Cortex-M ETM trace, organised by function. See `docs/artix7-port/` for the
narrative; this directory is the hands-on toolkit.

## Layout

| Dir | What | Run from |
|-----|------|----------|
| `rtl/` | FPGA sources: Verilog tops + XDC + `sim/` | (read by `fpga_flow/`) |
| `fpga_flow/` | Vivado build / program / flash TCL | `build/` (via wrappers) |
| `target/` | OpenOCD `.cfg` for the STM32 trace source | repo / via wrappers |
| `scripts/` | One-key bash wrappers tying it all together | anywhere |
| `decode/` | PC-side ETM3.5 decode: Python lib, tests, fixtures | `decode/` |
| `jtag_pinscan/` | Boundary-scan pin discovery (self-contained) | `jtag_pinscan/` |
| `build/` | Vivado outputs (git-ignored) | — |

Each subdir has its own README with details.

## Typical flows

Build + program a bitstream:
```
source $XILINX_VIVADO/settings64.sh
scripts/build.sh stream          # -> build/trace_stream.bit
scripts/program.sh stream jtag   # volatile JTAG load
```

Capture + decode trace (correct ordering enforced: ETM first, then arm FPGA):
```
scripts/trace_run.sh             # enable ETM -> arm FPGA -> dump -> decode
```

Decode a logic-analyser `.dsl` capture (the "eyes" front-end):
```
cd decode
python3 dsl_parse.py /path/to/capture.dsl     # -> /tmp/dsl_bytes_0.bin
ELF=/tmp/axf/proj.axf python3 etm_reconstruct.py /tmp/dsl_bytes_0.bin
```

Run the decode regression suite:
```
cd decode && python3 -m pytest -q
```

## Note on decode vs. orbuculum

`decode/etm35lib.py` reimplements ETM3.5 decode in Python for testable,
ground-truth cross-checking against the logic-analyser captures (a front-end
orbuculum does not have). For full instruction-level decode of an OFLOW/ETM
stream, the upstream `orbmortem` / `orbcat` are the reference (see
`scripts/decode.sh` and `decode/drive_orbmortem.py`). `dsl_parse.py` is the
genuinely new piece: DSView `.dsl` → bare-ETM byte stream.
