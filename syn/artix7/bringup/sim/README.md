# RTL simulation (iverilog)

Pure-software regression tests for the Artix-7 bring-up RTL. No hardware or
Vivado needed — runs in CI under the `iverilog_testbenches` job.

## `tb_la_ddr_writer.v` — on-chip pin-LA writer stress test

Exercises the full `la_ddr_writer` datapath:

```
cap_byte (200 MHz) -> 16B pack -> 128-bit AsyncFIFO -> burst stage -> DDR3 mock
```

A behavioural DDR3 write mock records every 128-bit word actually committed so
the checker can unpack it back to a byte stream and verify integrity against a
free-running 8-bit counter stimulus (a stricter, per-byte-predictable version
of the hardware 3-bit canary).

| Test | Setup | Asserts |
|------|-------|---------|
| A  | 200 MB/s in, fast drain | byte stream perfectly contiguous, `overflow`=0 |
| A2 | 100 MB/s in, fast drain | contiguous, `overflow`=0 (matched-rate control) |
| B  | 200 MB/s in, DDR3 drain slowed 40× | `overflow` sticky flag set, **zero duplicates**, loss is forward-only (clean truncation, canary stays monotonic) |

### Why this exists (regression guard)

The v1 writer fed the AsyncFIFO 8 bits/cap_clk (200 MB/s) but the ui_clk pack
path popped only 1 byte/ui_clk = 100 MB/s (MIG UI = 400 MHz DDR3 / 4:1 PHY).
That permanent 2:1 overrun silently dropped ~half the bytes — the "86% step=2 +
14% step=0" the hardware canary caught (red-team R8). The fix (method X v2)
packs 16 bytes into a 128-bit word **in the cap_clk domain** before the FIFO,
dropping the write rate to 12.5 Mword/s vs 100 Mword/s pop (8:1 margin). This
test locks that in: any reintroduced throughput shortfall or dishonest
(silent/duplicating) loss fails CI.

## Run locally

```
./run_tb.sh          # compile + run, exits non-zero on failure
./run_tb.sh vcd      # also dump tb_la_ddr_writer.vcd for GTKWave
```
