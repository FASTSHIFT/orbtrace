# Black-box readback decode — root-cause diagnosis (proposal 32 P2b-3)

## Symptom
The DDR3 black-box readback deframes cleanly (TPIU OK, ~5.7% unknown) but
orbetto recovers **0 PCs** (cardinality=0), while the LIVE direct-capture stream
from the *same* STM32/ETM decodes ~1597 PCs.

## Decisive comparison (parity=0/order=0, same decode path)
| metric | live direct stream | black-box readback |
|--------|--------------------|--------------------|
| flash I-sync | 16 | **0** |
| ETMv4 A-sync count | 3601 | 255 |
| first A-sync offset | 571 (early) | 227677 (late) |
| orbetto PC cardinality | 1597 | **0** |

## Root cause: every 128-bit word is DUPLICATED
Raw readback bytes have **period = 16** almost everywhere (16 bytes = one
128-bit DDR3 word). In a real-trace region, consecutive 16-byte words are
**byte-for-byte identical** (12403 / 12500 consecutive word-pairs equal):

```
word0 77776f66c9666f6689766f6699a9216c
word1 77776f66c9666f6689766f6699a9216c   <- identical
word2 77776f66c9666f6689766f6699a9216c   <- identical
...
```

This is NOT program behaviour — the hardware is emitting the same 128-bit word
many times. The decode then sees the same ~16 bytes looped, so A-sync density
collapses (255 vs 3601) and no valid address/atom packet stream survives ->
0 PCs. The A-syncs that ARE found are just the same repeated fragment.

## Where the duplication is (to fix next)
Candidates in the DDR3 write/read path (la_ddr_writer / la_ddr_reader):
- writer: the 64-word burst staging (`wbuf`) may be filled with one repeated
  word (word_sr not advancing per unique byte-group), OR the same word written
  to many ring addresses.
- reader: the 128-bit->byte gearbox or the wide AsyncFIFO read side may replay
  the same word (read pointer not advancing per `m_ready`), OR each
  `ddr3_rd_data_vld` word pushed multiple times.

P1 (ddr3_selftest) proved the vendor ddr3_ctrl write+read round-trips
byte-exact for its OWN pattern, so the duplication is in la_ddr_writer/reader
packing/gearbox, not the MIG core.

## Next step
Add a word-level counter/signature test (write an incrementing word pattern via
la_ddr_writer, read via la_ddr_reader, check for the period-16 duplication) to
localise writer vs reader, then fix the offending advance condition.
