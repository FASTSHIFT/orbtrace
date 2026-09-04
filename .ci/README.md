# CI baseline files

## `coverage-baseline.txt`

Minimum line-coverage percent (integer) enforced by the `test` job in
`.github/workflows/build.yml` for `orbtrace.trace` + `orbtrace.stream`.

**Policy** (r38 §6.4 discussion): current CI coverage becomes the floor. It
may only ratchet up, never down without explicit review.

### Raising the bar

1. Run locally (or read the last green CI run's `Coverage gate` step output):
   ```bash
   pip install 'amaranth==0.5.4' amaranth-yosys 'cobs>=1.2.1' 'pytest>=8.3.5' pytest-cov
   PYTHONPATH=. pytest tests/ --cov=orbtrace.trace --cov=orbtrace.stream --cov-report=term
   ```
2. Note the `TOTAL` line's percentage (e.g. `47%`).
3. Bump `coverage-baseline.txt` to that integer (or a few points lower for
   flexibility). Commit and open a PR titled
   `ci: raise coverage baseline to N%`.
4. CI enforces the new bar on subsequent PRs.

### Initial value = 0

The baseline is bootstrapped at `0` so the first successful CI run establishes
the real number without blocking merges. Once that PR lands, the follow-up PR
should bump the baseline to the observed percent (rounded down for slack).

**Do not** lower the baseline without a documented reason in the commit
message — coverage regressions are exactly what this gate exists to catch.
