# scripts/ — one-key orchestration wrappers

Bash wrappers that tie the pieces together. They locate sibling dirs relative
to their own location (`$root = <bringup>`), so they can be run from anywhere.

| Script | Does |
|--------|------|
| `build.sh` | Vivado build of a bitstream (`fpga_flow/run_*.tcl` → `build/`) |
| `program.sh` | JTAG volatile load or QSPI flash a built bitstream |
| `etm_enable.sh` | Enable STM32 4-bit ETM (`target/etm_enable.cfg`) |
| `capture.sh` | Arm FPGA one-shot + dump captured stream (`decode/trace_dump.py`) |
| `decode.sh` | Decode a captured byte stream → functions |
| `trace_run.sh` | Full chain: enable ETM → arm FPGA → dump → decode |
| `etm_recover.sh`, `etm_recover2.sh` | ETM recovery experiments |

All assume `source $XILINX_VIVADO/settings64.sh` (for Vivado steps) and the ARM
toolchain on PATH (for decode steps).
