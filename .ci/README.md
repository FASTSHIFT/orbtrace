# CI baseline files

## `coverage-baseline.txt`

Minimum line-coverage percent (integer) enforced by the `test` job in
`.github/workflows/build.yml` for `orbtrace.trace` + `orbtrace.stream`.

**Current baseline: 49%** (2 pp headroom below the 51% measured by CI run
33861557437 on the `test(sim)` framework commit).

### Per-file baseline (informational, as of run 33861557437)

```
orbtrace/stream.py                 47      0   100%
orbtrace/trace/__init__.py          0      0   100%
orbtrace/trace/cobs.py            102     16    84%
orbtrace/trace/core.py             97     97     0%
orbtrace/trace/glue.py             48     48     0%
orbtrace/trace/orbflow.py          53     26    51%
orbtrace/trace/swo.py             130     35    73%
orbtrace/trace/tpiu.py            126      0   100%
orbtrace/trace/usb_handler.py      89     89     0%
orbtrace/trace/util.py             56     56     0%
TOTAL                             748    367    51%
```

Low-coverage modules (`core.py`, `glue.py`, `usb_handler.py`, `util.py`) are
either Amaranth HDL constructs that require an Amaranth simulator harness or
USB-driver glue that needs a hardware fixture. Both are on the roadmap.

**Policy** (r38 §6.4): current CI coverage is the floor. It may only ratchet
up, never down without documented review.

### Raising the bar

1. Wait for a green CI run on `test(sim)` after adding new tests.
2. Find the coverage table in the CI log (look for `TOTAL ... N%`).
3. Bump `coverage-baseline.txt` to the new integer (round down for slack).
4. Commit as `ci: raise coverage baseline to N%`.
5. CI enforces the new bar on subsequent PRs.

**Do not** lower without a documented reason in the commit message — coverage
regressions are exactly what this gate exists to catch.
