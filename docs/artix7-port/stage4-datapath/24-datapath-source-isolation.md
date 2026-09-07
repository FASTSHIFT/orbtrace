# 24 — Data-path source isolation: the pollution is at the pins, not in the ring

Date: 2026-09-07
Bitstream under test: `trace_ddr_stream.bit` (BUILD_ID 0x6a9aa5e7, tap2/IDELAY
build), live on the board. Front-end config is irrelevant for this test — the
selftest CSRs bypass the trace pins entirely.

## Question

Earlier work (doc 23 retro, TASK 7 notes) saw periodic pollution in the decoded
ETM stream: a recurring `0x96`, gap-3 clustering, and only a handful of ETMv4
A-syncs recovered from megabytes of "real" capture. The open question was
whether that pollution is injected by:

* the **capture front-end** (trace_capture_a7 sampling the physical TRACECLK /
  TRACEDATA pins — an SI / eye problem), or
* the **data path** (la_ddr_writer packing → DDR3 ring → la_ddr_ring_streamer
  gearbox → packetiser → UDP — a logic / CDC problem).

These had been conflated before. This is the single-variable test that separates
them.

## Method

`trace_ddr_stream_top` has two FPGA-internal byte sources that feed the *exact
same* DDR-ring → UDP path as real trace, chosen at runtime with no reflash:

| CSR | value | source |
|-----|-------|--------|
| 0x09 | 1 | free-running **ramp** (byte = ++counter) |
| 0x09=1, 0x0B=1 | | **fixed 0x42** |
| 0x09=0 | | real trace (capture pins) |

Both internal sources are injected at `src_byte` in the clk200 domain, *upstream
of* la_ddr_writer, so they traverse the identical packing / DDR3 / gearbox /
packetiser logic. Any corruption they show is 100% data-path. Any corruption
that appears **only** with real trace is 100% front-end.

Capture tool: `stream_grab` (C, zero-loss, decouples recv from disk). 3 s each,
~335 MB, on `enxc8a36266dcae`.

## Results

| source | bytes | corruption | detail |
|--------|-------|-----------|--------|
| fixed 0x42 | 335,373,312 | **0** non-0x42 | host-side AND FPGA diag latch (0 bad / 194k pkts) |
| ramp | 335,373,312 | **0** ramp breaks | every `a[i+1] == a[i]+1 (mod 256)`, across all packet boundaries |
| real trace | 335,373,312 | heavy | 249 distinct byte values; 0x96 recurs at **gap=1024** (once per payload) |

The fixed and ramp streams are byte-perfect over 335 MB **each**. The ramp is the
stronger of the two: it is time-varying data that crosses every packet boundary,
every DDR burst boundary (LENGTH=64 words), and the 128b→8b gearbox, and it
stayed monotonic with zero breaks. If the writer packing, the DDR ring address
math, the streamer gearbox, or the CDC FIFOs dropped/duplicated/reordered even a
single byte, the ramp would show a break there. It did not.

## Conclusion

**The FPGA→DDR-ring→UDP data path is provably clean.** Packing (big-endian
16-byte word), the DDR3 ring (+8 app-addr/word, wrap), the concurrent
writer/streamer sharing the arbiter, the 161-bit {rtx,seq,data} CDC FIFO, the
clk125 gearbox, and the packetiser all pass both a constant and a time-varying
payload with zero error at 112 MB/s sustained.

**The pollution is entirely at the physical-pin capture front-end.** This is the
same SI / eye-closure story as doc 23: the live bitstream is the tap2/IDELAY
build and the STM32 is (per committed firmware) booting into the selftrace loop.
The `0x96`-at-gap-1024 signature is a capture artifact aligned to the packet
payload length, not a transport bug — transport carried ramp and fixed across
those very boundaries flawlessly.

### What this retires

* "period-3 pollution from la_ddr_writer packing" — **disproven**. Ramp is
  monotonic through the packer.
* "DDR-ring / gearbox / CDC drops bytes" — **disproven**. 0 loss, 0 reorder over
  670 MB combined.
* Any further data-path debugging is wasted effort. The lever is front-end SI:
  lower the trace-pin frequency (R=4 → 56 MHz pin, eye open per doc 23) and/or
  fix board-level SI, exactly as doc 23 concluded.

### Reproduce

```
# fixed 0x42
python3 -c "...csr write 0x09=1, 0x0B=1..."
sudo ./stream_grab enxc8a36266dcae 3 captures/fixed42.bin
python3 read_bad_byte_latch.py --iface enxc8a36266dcae   # expect bad_count=0

# ramp
python3 trace_ctrl.py stream-selftest 1                   # 0x09=1, 0x0B=0
sudo ./stream_grab enxc8a36266dcae 3 captures/ramp.bin
# analyze: every byte delta == 1 mod 256

# real
python3 trace_ctrl.py stream-selftest 0 ; python3 trace_ctrl.py rearm
sudo ./stream_grab enxc8a36266dcae 3 captures/real.bin
```
